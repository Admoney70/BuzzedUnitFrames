-- ============================================================
-- BuzzardFrames: Core_Migrations.lua
-- All Migrate*Profile functions. Each moves a set of keys from
-- one SV location to another as part of a versioned schema change.
-- Invoked from Core_DB.lua (the dbVersion dispatcher in RegisterDB)
-- and from Core_ProfileLifecycle.lua (the lazy-migration block in
-- OnProfileChanged, which catches profiles the user switches to
-- that haven't yet been migrated).
-- Extracted from Core.lua in the Core split refactor.
-- ============================================================
local BF = _G["BuzzardFrames"]

-- ── Flat defaults backfill helper ───────────────────────────────────────
-- Restores any keys that are missing from a migrated flat because AceDB
-- stripped them from SavedVariables on logout (default-equal values get
-- removed). Only fills nil keys; never overwrites user data. Picks the
-- constructor based on flat.type.
--
-- NOTE (v23): This helper is superseded by the metatable __index fallback
-- in Core_FlatDefaults.lua. It is kept for backward compatibility in case
-- any external code still calls it. New code should rely on BF:WireFlatDefaults
-- which attaches a fresh template as __index instead of materializing keys.
function BF:BackfillFlatDefaults(flat)
    if type(flat) ~= "table" then return end
    local template
    if flat.type == "raid" then
        template = self:CreateRaidProfile(flat.anchorX, flat.anchorY)
    elseif flat.type == "party" then
        template = self:CreatePartyProfile()
    else
        return
    end
    for k, v in pairs(template) do
        if flat[k] == nil then
            -- Deep-copy table values so shared references don't cause cross-flat
            -- mutation (e.g. color tables).
            if type(v) == "table" then
                flat[k] = self:DeepCopy(v)
            else
                flat[k] = v
            end
        end
    end
end

-- ── UnitFrames namespace migration ──────────────────────────────────────────
-- Extracted as a standalone function so it can run both from RegisterDB (initial
-- migration) and from OnProfileChanged (lazy migration of profiles the user
-- switches to that haven't been migrated yet).
-- Grid2 pattern: Grid2:UpdateDefaults runs on every profile load.
function BF:MigrateUnitFramesProfile(profileName)
    profileName = profileName or self.db.keys.profile

    -- Read from the RAW SavedVariables table (self.db.profiles), not from
    -- self.db.profile. AceDB's self.db.profile merges defaults into the
    -- saved data at runtime. Since we removed the UF defaults from
    -- BF.defaults.profile, self.db.profile no longer has default UF values.
    -- But the user's saved customizations still exist in the raw SV table.
    -- We must read from there to capture them.
    local rawProfile = self.db.profiles[profileName]
    if not rawProfile then return end  -- pure-defaults profile, nothing to migrate

    -- Destination: namespace's raw SV for this profile. For the currently-active
    -- profile this is the same table as self.ufDB.profile (AceDB exposes it via
    -- the profiles[] accessor). For a non-active profile, we create an empty raw
    -- SV entry if one doesn't exist yet. AceDB's PLAYER_LOGOUT handler strips
    -- default-equal keys from all profiles, so writing default-equal values here
    -- is harmless.
    local ufp = self.ufDB.profiles[profileName]
    if not ufp then
        self.ufDB.profiles[profileName] = {}
        ufp = self.ufDB.profiles[profileName]
    end

    -- Per-unit sub-tables: deep-copy then nil from raw SavedVariables.
    local UF_TABLE_KEYS = {
        "player", "target", "focus", "pet", "boss", "targettarget", "focustarget",
        "ufLayouts", "ufLayoutFrames", "ufRoleLayouts", "ufRoleLayoutAssignment",
        -- (ufGlobalLayout is a scalar; see UF_SCALAR_KEYS below.)
        "ufSpecLayouts", "ufSpecLayoutAssignment",
    }
    for _, key in ipairs(UF_TABLE_KEYS) do
        if rawProfile[key] ~= nil then
            if type(rawProfile[key]) == "table" then
                ufp[key] = self:DeepCopy(rawProfile[key])
            else
                ufp[key] = rawProfile[key]
            end
            rawProfile[key] = nil
        end
    end

    -- Scalar keys: copy value then nil from raw SavedVariables.
    local UF_SCALAR_KEYS = {
        -- Master switches
        "ptfEnabled", "ptfFrameStyle",
        "showPlayerFrame", "showTargetFrame", "showFocusFrame",
        "showTargetOfTargetFrame", "showFocusTargetFrame",
        "showBossFrames", "showPetFrame",
        -- UF layout system
        "activeUFLayout", "ufGlobalLayout", "separateUFByGroupType",
        "enableUFRoleLayouts", "enableUFSpecLayouts",
        -- Font settings
        "oufAdjustFonts", "oufSeparateFonts", "oufGlobalFont",
        "oufNameFont", "oufLevelFont",
        "oufHealthPctFont", "oufHealthValFont",
        "oufPowerPctFont", "oufPowerValFont",
        "oufAltPowerPctFont", "oufAltPowerValFont",
        -- Global UF colors
        "globalUseClassColor", "globalHealthColor",
        "globalUseHostilityColor", "globalNpcHealthColor",
        "globalUseClassColorName", "globalNameColor",
        "globalUseHostilityColorName", "globalNpcNameColor",
        "globalNpcClassificationColors",
        "globalNpcBossColor", "globalNpcLieutenantColor",
        "globalNpcCasterColor", "globalNpcNeutralColor",
        "globalNpcFriendlyColor", "globalNpcTrivialColor",
        "globalNpcRegularColor",
        -- Cast bar colors
        "castBarColor", "castBarUninterruptibleColor", "castBarBgColor",
        -- Icon / shape
        "iconSize", "iconShape", "iconOffsetX", "iconOffsetY",
        "playerShowClassIcon",
        "iconStyle", "iconLocation", "classIconPosition",
        "classIconBorderEnabled", "classIconBorderColor",
        "classIconBorderThickness", "classIconBorderUseHealthColor",
        "showEliteDragonBorder",
        -- Target cast bar
        "targetShowCastBar", "targetCastBarPosition", "targetCastBarDetached",
        "targetCastBarAnchorX", "targetCastBarAnchorY",
        "targetCastBarWidth", "targetCastBarGap", "targetCastBarHeight",
        "targetCastBarBorderEnabled", "targetCastBarBorderThickness",
        "targetCastBarBorderColor", "targetCastBarShowIcon",
        "targetCastBarIconSide", "targetCastBarIconSize", "targetCastBarIconGap",
        -- Focus cast bar
        "focusShowCastBar", "focusCastBarPosition", "focusCastBarDetached",
        "focusCastBarAnchorX", "focusCastBarAnchorY",
        "focusCastBarWidth", "focusCastBarGap", "focusCastBarHeight",
        "focusCastBarBorderEnabled", "focusCastBarBorderThickness",
        "focusCastBarBorderColor", "focusCastBarShowIcon",
        "focusCastBarIconSide", "focusCastBarIconSize", "focusCastBarIconGap",
        -- Boss cast bar
        "bossShowCastBar", "bossCastBarPosition", "bossCastBarGap",
        "bossCastBarHeight", "bossCastBarFontSize",
        "bossCastBarBorderEnabled", "bossCastBarBorderThickness",
        "bossCastBarBorderColor", "bossCastBarShowIcon",
        "bossCastBarIconSide", "bossCastBarIconSize", "bossCastBarIconGap",
        "bossCastBarAvoidAuras",
        -- Blizzard frame hiding (per unit frame)
        "hideBlizzardPlayerFrame", "hideBlizzardTargetFrame",
        "hideBlizzardFocusFrame", "hideBlizzardPetFrame",
        "hideBlizzardTargetOfTargetFrame", "hideBlizzardBossFrames",
        "hideBlizzardPlayerCastBar",
        -- Resource bar (oUF)
        "oufResourceBarEnabled", "oufResourceBarDetached",
        "oufResourceBarAnchorX", "oufResourceBarAnchorY",
        "oufResourceBarWidth", "oufResourceBarHeight",
        "oufResourceBarGap", "oufResourceBarPipGap",
        "oufResourceBarBgColor", "oufResourceBarUseTypeColor",
        "oufResourceBarColor", "oufResourceBarShowEmpty",
        "oufResourceBarEmptyDim", "oufResourceBarPartialFill",
        -- Astral Power bar
        "oufAstralBarEnabled", "oufAstralBarUseTypeColor",
        "oufAstralBarColor", "oufAstralBarBgColor",
        "oufAstralBarBorderEnabled", "oufAstralBarBorderThickness",
        "oufAstralBarBorderColor", "oufAstralBarShowPct",
        "oufAstralBarShowVal", "oufAstralBarFontSize",
        "oufAstralBarPctPos", "oufAstralBarValPos",
        -- Per-bar border controls (bluzzard)
        "frameBorderEnabled", "frameBorderThickness", "frameBorderColor",
        "healthBorderEnabled", "healthBorderThickness",
        "powerBorderEnabled", "powerBorderThickness",
        "nameBorderEnabled", "nameBorderThickness",
        "nameDividerEnabled", "nameDividerThickness",
        "oufResourceBarBorderEnabled", "oufResourceBarBorderThickness",
        "oufResourceBarPipBorderEnabled", "oufResourceBarPipBorderThickness",
        "oufResourceBarPipBorderColor",
        -- Raid target / combat indicator (oUF)
        "oufShowRaidTarget", "oufShowCombatIndicator",
        "oufCombatIndicatorSize", "oufRaidTargetSize",
        "oufRaidTargetOffsetX", "oufRaidTargetOffsetY",
        "oufRaidTargetLocation",
        -- Boss frame spacing
        "bossFrameSpacing",
        -- UF aura settings
        "auraShowDuration", "auraFont", "auraFontSize",
        -- Alt power bar
        "showAltPowerBar", "altPowerBarHeight", "altPowerBarDetached",
        "altPowerBarDruidSpecs", "oufAltPowerBarWidth",
        "altPowerShowPct", "altPowerShowVal", "altPowerFontSize",
        "altPowerPctPos", "altPowerValPos",
        -- Power bar detach
        "oufPowerBarAnchorX", "oufPowerBarAnchorY", "oufPowerBarDetached",
        -- Aura border style
        "oufAuraUseBlizzardBorders",
    }
    for _, key in ipairs(UF_SCALAR_KEYS) do
        if rawProfile[key] ~= nil then
            if type(rawProfile[key]) == "table" then
                ufp[key] = self:DeepCopy(rawProfile[key])
            else
                ufp[key] = rawProfile[key]
            end
            rawProfile[key] = nil
        end
    end
end

-- ── AuraCustomizations namespace migration ──────────────────────────────────
-- Moves aura customization keys (spell assignments, custom buff containers,
-- filter modes, show/hide toggles, PA overrides, per-spec spell tables)
-- from the parent profile into the AuraCustomizations namespace.
function BF:MigrateAuraCustomizationsProfile(profileName)
    profileName = profileName or self.db.keys.profile
    local rawProfile = self.db.profiles[profileName]
    if not rawProfile then return end

    local acp = self.acDB.profiles[profileName]
    if not acp then
        self.acDB.profiles[profileName] = {}
        acp = self.acDB.profiles[profileName]
    end

    -- All AC keys: tables and scalars handled uniformly.
    -- Most are dynamically created (only exist if user customized them).
    local AC_KEYS = {
        -- Spell assignment & per-spec customization
        "spellAssign",
        "specSpellColors",
        "specSpellBorders",
        "specSpellBorderColors",
        "specSpellOverlays",
        "specSpellSolidIcons",
        "specSpellOrdering",
        -- Spec buff display toggles
        "specBuffsBorder",
        "specBuffsBorderColor",
        "specBuffsOverlay",
        "specBuffsSolidIcon",
        -- Custom buff containers
        "customBuffContainers",
        -- Filter modes
        "healerBuffFilter",
        "nonHealerBuffFilter",
        "debuffFilter",
        -- specBuffFilter retired 2026-08-15: nothing reads it, so relocating a
        -- legacy copy into acDB only to have the load-time purge remove it
        -- again is churn. Left out deliberately.
        -- Show/hide toggles
        "showSatedDebuffs",
        "showDeserterDebuffs",
        "showSkyridingDebuffs",
        "showArcaneEmpowermentDebuffs",
        "showTimeTrialDebuffs",
        "showRaidBuffs",
        -- Missing raid buff icons
        "showMissingRaidBuff",
        "showMissingRaidBuffInCombat",
        "showMissingSymbiotic",
        "missingRaidBuffAnchor",
        "missingRaidBuffOffsetX",
        "missingRaidBuffOffsetY",
        "missingRaidBuffSize",
        "missingRaidBuffShowGlow",
        -- Per-raid tier separation
        "separateRaidAuraCustomizations",
        -- Private aura overrides
        "enableGlobalPAOverrides",
        "globalPASettings",
        "encounterPASettings",
        "dungeonPASettings",
    }
    for _, key in ipairs(AC_KEYS) do
        if rawProfile[key] ~= nil then
            if type(rawProfile[key]) == "table" then
                acp[key] = self:DeepCopy(rawProfile[key])
            else
                acp[key] = rawProfile[key]
            end
            rawProfile[key] = nil
        end
    end
end

-- ── CustomFrameGroups namespace migration ────────────────────────────────────
-- Moves customFramesEnabled and customFrameGroups from the parent profile
-- into the CustomFrameGroups namespace.
function BF:MigrateCustomFrameGroupsProfile(profileName)
    profileName = profileName or self.db.keys.profile
    local rawProfile = self.db.profiles[profileName]
    if not rawProfile then return end

    local cfgp = self.cfgDB.profiles[profileName]
    if not cfgp then
        self.cfgDB.profiles[profileName] = {}
        cfgp = self.cfgDB.profiles[profileName]
    end

    local CFG_KEYS = {
        "customFramesEnabled",
        "customFrameGroups",
        "customFrameGroupPositions",
    }
    for _, key in ipairs(CFG_KEYS) do
        if rawProfile[key] ~= nil then
            if type(rawProfile[key]) == "table" then
                cfgp[key] = self:DeepCopy(rawProfile[key])
            else
                cfgp[key] = rawProfile[key]
            end
            rawProfile[key] = nil
        end
    end
end

-- ── Global settings migration ────────────────────────────────────────────
-- Moves preview, test mode, debug, experimental, profile auto-switch,
-- and aura filter settings from db.profile to db.global.
-- db.global is shared across all profiles, so the first profile migrated
-- wins; subsequent profiles only nil out their keys.
function BF:MigrateGlobalSettings(profileName)
    local g = self.db.global
    profileName = profileName or self.db.keys.profile
    local rawProfile = self.db.profiles[profileName]
    if not rawProfile then return end

    local isFirst = not g._globalSettingsMigrated

    local GLOBAL_KEYS = {
        "_optionsPanelW", "_optionsPanelH", "minimapPos",
        "enableExperimentalOptions", "tinyHandle",
        -- v70: showPreviewAuras/simulateDispellableDebuff are RETIRED (converted
        -- to previewModeBuffs/Debuffs by dbVersion-63 migration). Kept here so a
        -- legacy per-profile copy is hoisted to global BEFORE that migration
        -- reads and nils them.
        "showPreviewAuras", "simulateDispellableDebuff",
        "previewModeBuffs", "previewModeDebuffs",
        "previewBuffCount", "previewDebuffCount", "previewPrivateAuraCount",
        "showDummyBuffs", "showDummyDebuffs", "showDummyPrivateAuras",
        "showDummyBigDef", "showDummyImportant", "showDummyCrowdControl",
        "showSetupGrid", "showPreview",
        "partyTestMode",
        "testAggroHighlight", "testDebuffBorder", "testDebuffOverlay",
        "testReadyCheck", "testPhased", "testSummonPending",
        "testResurrectPending", "testVehicleIcon",
        "testHealPrediction", "testHealAbsorb", "testAbsorb", "testAbsorbSize",
        "testReducedMaxHealth", "testCyrillicNames",
        "privateAuraBorderHideFirstSlot", "privateAuraBorderWidthRatio",
        "privateAuraBorderScale", "privateAuraBorderFrameLevel",
        "privateAuraBorderDrawOrder",
        "enableProfileAutoSwitch", "profileAutoSwitchMode",
        "specProfileAssignment", "roleProfileAssignment",
        "nonHealerBuffFilter", "debuffFilter",  -- MOVED to acDB in dbVersion 12 migration; kept here to nil from old profiles
        "pvpSwapDebuffsPrivate", "reverseBuffs",
        "setupFrameColor",
    }
    for _, key in ipairs(GLOBAL_KEYS) do
        if rawProfile[key] ~= nil then
            if isFirst then
                if type(rawProfile[key]) == "table" then
                    g[key] = self:DeepCopy(rawProfile[key])
                else
                    g[key] = rawProfile[key]
                end
            end
            rawProfile[key] = nil
        end
    end

    -- Flatten raid40/30/20 testMode sub-tables into global flat keys
    if rawProfile.raid40 and rawProfile.raid40.testMode ~= nil then
        if isFirst then BF.db.global.raid40TestMode = rawProfile.raid40.testMode end
        rawProfile.raid40.testMode = nil
        if not next(rawProfile.raid40) then rawProfile.raid40 = nil end
    end
    if rawProfile.raid30 and rawProfile.raid30.testMode ~= nil then
        if isFirst then BF.db.global.raid30TestMode = rawProfile.raid30.testMode end
        rawProfile.raid30.testMode = nil
        if not next(rawProfile.raid30) then rawProfile.raid30 = nil end
    end
    if rawProfile.raid20 and rawProfile.raid20.testMode ~= nil then
        if isFirst then BF.db.global.raid20TestMode = rawProfile.raid20.testMode end
        rawProfile.raid20.testMode = nil
        if not next(rawProfile.raid20) then rawProfile.raid20 = nil end
    end

    g._globalSettingsMigrated = true
end

-- ── RaidPartyFrames namespace migration ──────────────────────────────────────
-- Moves ~300 flat raid/party frame keys from the parent profile into the
-- RaidPartyFrames namespace, organized by Options panel tab.
-- Also moves missing raid buff keys from AuraCustomizations back to rpDB.icons,
-- and moves root-level enable/lock/hide keys to db.global.
function BF:MigrateRaidPartyFramesProfile(profileName)
    profileName = profileName or self.db.keys.profile
    local rawProfile = self.db.profiles[profileName]
    if not rawProfile then return end

    local rp = self.rpDB.profiles[profileName]
    if not rp then
        self.rpDB.profiles[profileName] = {}
        rp = self.rpDB.profiles[profileName]
    end
    -- Ensure all sub-tables the moveKeys helper expects exist on this raw SV
    -- entry. (When the destination is self.rpDB.profile, AceDB's defaults
    -- layer creates these on-demand; on raw SV we must materialize them.)
    rp.layouts      = rp.layouts      or {}
    rp.sorting      = rp.sorting      or {}
    rp.auras        = rp.auras        or {}
    rp.auraText     = rp.auraText     or {}
    rp.borders      = rp.borders      or {}
    rp.healthPower  = rp.healthPower  or {}
    rp.absorbs      = rp.absorbs      or {}
    rp.icons        = rp.icons        or {}
    rp.text         = rp.text         or {}
    rp.tooltips     = rp.tooltips     or {}

    -- Helper: copy a key from rawProfile to a sub-table of rpDB.profile, then nil it.
    local function moveKey(subtable, key)
        if rawProfile[key] ~= nil then
            if type(rawProfile[key]) == "table" then
                rp[subtable][key] = self:DeepCopy(rawProfile[key])
            else
                rp[subtable][key] = rawProfile[key]
            end
            rawProfile[key] = nil
        end
    end

    -- Helper: move a list of keys to a sub-table.
    local function moveKeys(subtable, keys)
        for _, key in ipairs(keys) do
            moveKey(subtable, key)
        end
    end

    -- ── layouts sub-table ─────────────────────────────────────────────────
    moveKeys("layouts", {
        "layouts", "activeLayout",
        "enableRoleLayouts", "enableSpecLayouts",
        "specLayouts", "specLayoutAssignment", "roleLayoutAssignment",
        "separateRaidBySize", "enableRaid30", "enableRaid20", "enableRaid40",
        "scaleRaidToFit",
        "openWorldSolo", "openWorldRaid", "showLayoutAnnounce",
        "separateRaidAuras",
        -- Legacy
        "frameWidth", "frameHeight", "frameSpacing",
    })

    -- ── sorting sub-table ─────────────────────────────────────────────────
    -- These keys previously lived on rp.layouts.*. They are now routed
    -- into rp.sorting.* so the Frames - Sorting section has a clean 1:1
    -- pattern matching all other per-layout-capable sections.
    moveKeys("sorting", {
        "sortingMode", "strictGroupLayout", "strictGroupSortBy",
        "unitsPerColumn", "raidGrowDirection", "raidSecondaryGrowDirection",
        "groupOrderingMode",
    })

    -- ── auras sub-table ───────────────────────────────────────────────────
    moveKeys("auras", {
        "dispelIndicatorSize", "dispelIndicatorPosition",
        "dispelIndicatorOffsetX", "dispelIndicatorOffsetY",
        "dispelIndicatorStyle",
        "showBigDefParty", "partyBigDefSize", "bigDefAnchorParty",
    })

    -- ── auraText sub-table ────────────────────────────────────────────────
    moveKeys("auraText", {
        -- Stack text
        "showStackText", "stackAutoScale", "stackTimerScale",
        "stackTextFont", "stackTextBorder", "stackTextSize",
        "stackTextAnchor", "stackTextX", "stackTextY",
        -- Global unified
        "globalAuraTextConfig", "globalDurationShow", "globalAutoScale",
        "globalTimerScale", "globalFontSize", "globalDurationFont",
        "globalDurationBorder", "globalReverseSwipe", "globalDisableSwipe",
        "globalDisableSpark", "globalDebuffDurationDispelColor",
        "globalThresholdColorEnabled", "globalThresholdColorThreshold",
        "globalThresholdColor", "globalThresholdBorderEnabled",
        "globalThreshold2ColorEnabled", "globalThreshold2ColorThreshold",
        "globalThreshold2Color", "globalThreshold2BorderEnabled",
        -- Buff
        "showBuffDuration", "buffAutoScale", "buffTimerScale",
        "buffFontSize", "buffDurationFont", "buffDurationBorder",
        "reverseBuffSwipe", "disableBuffSwipe", "disableBuffSpark",
        "buffThresholdColorEnabled", "buffThresholdColorThreshold",
        "buffThresholdColor", "buffThresholdBorderEnabled",
        "buffThreshold2ColorEnabled", "buffThreshold2ColorThreshold",
        "buffThreshold2Color", "buffThreshold2BorderEnabled",
        -- Debuff
        "showDebuffDuration", "debuffAutoScale", "debuffTimerScale",
        "debuffFontSize", "debuffDurationFont", "debuffDurationBorder",
        "reverseDebuffSwipe", "disableDebuffSwipe", "disableDebuffSpark",
        "debuffDurationDispelColor",
        "debuffThresholdColorEnabled", "debuffThresholdColorThreshold",
        "debuffThresholdColor", "debuffThresholdBorderEnabled",
        "debuffThreshold2ColorEnabled", "debuffThreshold2ColorThreshold",
        "debuffThreshold2Color", "debuffThreshold2BorderEnabled",
        -- Big Defensive
        "showBigDefDuration", "bigDefAutoScale", "bigDefTimerScale",
        "bigDefFontSize", "bigDefDurationFont", "bigDefDurationBorder",
        "reverseBigDefSwipe", "disableBigDefSwipe", "disableBigDefSpark",
        "bigDefThresholdColorEnabled", "bigDefThresholdColorThreshold",
        "bigDefThresholdColor", "bigDefThresholdBorderEnabled",
        "bigDefThreshold2ColorEnabled", "bigDefThreshold2ColorThreshold",
        "bigDefThreshold2Color", "bigDefThreshold2BorderEnabled",
        -- Private Aura
        "showPrivateAuraDuration", "disablePrivateAuraSwipe",
        -- Crowd Control
        "showCrowdControlDuration", "crowdControlAutoScale",
        "crowdControlTimerScale", "crowdControlFontSize",
        "crowdControlDurationFont", "crowdControlDurationBorder",
        "reverseCrowdControlSwipe", "disableCrowdControlSwipe",
        "disableCrowdControlSpark",
        -- Important
        "showImportantDuration", "importantAutoScale", "importantTimerScale",
        "importantFontSize", "importantDurationFont", "importantDurationBorder",
        "reverseImportantSwipe", "disableImportantSwipe", "disableImportantSpark",
    })

    -- ── borders sub-table ─────────────────────────────────────────────────
    moveKeys("borders", {
        "enableBorder", "borderColor", "borderThickness", "borderOpacity",
        "aggroEnabled", "aggroStyle", "aggroScale", "aggroBorderWidth",
        "enableMouseoverHighlight", "mouseoverHighlightColor", "mouseoverHighlightOpacity",
        "enableTargetHighlight", "targetHighlightColor",
        "targetHighlightOpacity", "targetHighlightWidth",
        "enableDebuffBorder", "debuffBorderMode", "debuffBorderWidth",
        "enableDebuffOverlay", "debuffOverlayAlpha", "debuffOverlayHeight",
        "debuffOverlayMode", "debuffOverlayFillOnly",
        "dispelBorderOnlyIfReady", "dispelOverlayOnlyIfReady", "dispelDotOnlyIfReady",
    })

    -- ── healthPower sub-table ─────────────────────────────────────────────
    moveKeys("healthPower", {
        "useCustomHealthColor", "healthColor",
        "useHealthGradient", "healthGradientHigh", "healthGradientMid", "healthGradientLow",
        "useCustomHealthBarTexture", "healthBarTexture",
        "useCustomBackgroundColor", "backgroundColor", "backgroundAlpha",
        "useBgGradient", "bgGradientHigh", "bgGradientMid", "bgGradientLow",
        "useCustomOfflineColor", "useCustomDeadColor",
        "useCustomHostileColor", "hostileColor",
        "performanceMode",
        "showPowerBar", "showAllPowerBars", "showPowerBarHealers", "showPowerBarBloodDK",
        "powerBarHeight", "useCustomPowerBarTexture", "powerBarTexture",
        "useCustomPowerBarBgColor", "powerBarBgColor", "powerBarBgOpacity",
        "useCustomPowerColors", "customPowerColors",
        "enableRangeFade", "rangeFadeAlpha",
        "enableRangeDesaturate", "rangeDesaturation",
        "aurasAbovePowerBar",
    })

    -- ── absorbs sub-table ─────────────────────────────────────────────────
    moveKeys("absorbs", {
        "showHealPrediction", "healPredictionAnchor", "healPredictionColor",
        "useCustomHealPredictionTexture", "healPredictionTexture",
        "showOvershield", "overshieldStyle", "overshieldAnchor",
        "showHealAbsorb", "healAbsorbStyle", "healAbsorbBarHeight",
        "healAbsorbColor",
        "useCustomHealAbsorbTexture", "healAbsorbTexture",
        "useCustomHealAbsorbSymbolColor", "healAbsorbSymbolColor",
        "absorbAnchorPos", "absorbBaseColor", "absorbOverlayColor",
        "showAbsorbShadow", "absorbShadowColor",
        "overshieldBaseColor", "overshieldOverlayColor",
        "useCustomAbsorbColor", "useCustomAbsorbBarTexture", "absorbBarTexture",
        "useCustomOvershieldColor", "useCustomOvershieldBarTexture", "overshieldBarTexture",
        "showReducedMaxHealth", "reducedMaxHealthColor",
        "useCustomReducedMaxTexture", "reducedMaxHealthTexture",
        "showReducedMaxHealthText", "appendReducedMaxText", "appendReducedMaxTarget",
        "reducedMaxHealthTextPosition", "reducedMaxHealthTextX", "reducedMaxHealthTextY",
        "reducedMaxHealthTextColor", "reducedMaxHealthFont",
        "reducedMaxHealthFontSize", "reducedMaxHealthFontBorder",
    })

    -- ── icons sub-table ───────────────────────────────────────────────────
    moveKeys("icons", {
        "showRoleIcons", "showRoleIconTank", "showRoleIconHealer", "showRoleIconDPS",
        "roleIconSize", "roleIconStyle", "roleIconPosition",
        "showReadyCheck", "showPhased", "showSummonPending",
        "showResurrectPending", "showVehicleIcon",
        "statusIconSize", "statusIconPosition",
        "showRaidTargetIcon", "raidTargetIconSize", "raidTargetIconPosition",
        "showLeaderIcon", "showAssistantIcon",
        "leaderIconSize", "leaderIconPosition",
        "assistantIconSize", "assistantIconPosition",
    })

    -- ── text sub-table ────────────────────────────────────────────────────
    moveKeys("text", {
        -- Name
        "showName", "nameFontSize", "abbreviateNames", "scaleNameToFit",
        "maxNameChars", "capitalizeNames", "adjustNameColors", "classColorNames",
        "transliterateCyrillicNames", "nameColor", "adjustNameFont",
        "nameFont", "nameFontBorder", "namePosition", "linkNameAndRole",
        -- Health text
        "showHealthText", "healthTextFormat", "adjustHealthFont",
        "healthFont", "healthFontBorder", "healthFontSize",
        "healthTextPosition", "healthTextX", "healthTextY",
        "adjustHealthTextColor", "classColorHealthText", "healthTextColor",
        -- Status
        "adjustStatusFont", "appendStatusTextToNames", "capitalizeStatusText",
        "applyStatusColorsToNames", "statusAppendSeparator", "statusBeforeName",
        "abbreviateStatusNames", "maxStatusNameChars",
        "fadeOfflineNameText", "fadeOfflineFrames", "abbreviateOffline",
        "showDeadStatus",
        "showOfflineStatus",
        "statusTextPosition", "statusTextX", "statusTextY",
        "statusFont", "statusFontBorder", "statusFontSize",
        "showAFKStatus", "afkColorUseClassColor", "afkColor",
        "deadColor", "deadColorUseClassColor",
        "deadBackgroundColor", "deadBackgroundOpacity",
        "offlineColor", "offlineColorUseClassColor",
        "offlineBackgroundColor", "offlineBackgroundOpacity",
        "deadColorOORFactor",
        -- Vehicle
        "showVehicleName", "vehicleNamePosition", "adjustVehicleFont",
        "vehicleFont", "vehicleFontBorder", "vehicleFontSize",
        "abbreviateVehicleNames", "maxVehicleNameChars",
        -- Group labels
        "showGroupLabels", "groupLabelFontSize", "groupLabelYOffset",
        "groupLabelColor", "adjustGroupLabelFont",
        "groupLabelFont", "groupLabelFontBorder",
    })

    -- ── tooltips sub-table ────────────────────────────────────────────────
    moveKeys("tooltips", {
        "showUnitTooltip", "showUnitTooltipInCombat", "unitTooltipPosition",
        "showBuffTooltip", "showBuffTooltipInCombat", "buffTooltipPosition",
        "showDebuffTooltip", "showDebuffTooltipInCombat", "debuffTooltipPosition",
        "showBigDefTooltip", "showBigDefTooltipInCombat", "bigDefTooltipPosition",
        "showImportantTooltip", "showImportantTooltipInCombat", "importantTooltipPosition",
        "showCrowdControlTooltip", "showCrowdControlTooltipInCombat", "crowdControlTooltipPosition",
    })

    -- ── Move missing raid buff keys from AuraCustomizations → rpDB.icons ──
    -- These were incorrectly migrated to acDB; move them back.
    local acRawNS = self.db.sv and self.db.sv.namespaces and self.db.sv.namespaces.AuraCustomizations
    local acRawProfile = acRawNS and acRawNS.profiles and acRawNS.profiles[profileName]
    if acRawProfile then
        local MRB_KEYS = {
            "showMissingRaidBuff", "showMissingRaidBuffInCombat", "showMissingSymbiotic",
            "missingRaidBuffAnchor", "missingRaidBuffOffsetX", "missingRaidBuffOffsetY",
            "missingRaidBuffSize", "missingRaidBuffShowGlow",
        }
        for _, key in ipairs(MRB_KEYS) do
            if acRawProfile[key] ~= nil then
                if type(acRawProfile[key]) == "table" then
                    rp.icons[key] = self:DeepCopy(acRawProfile[key])
                else
                    rp.icons[key] = acRawProfile[key]
                end
                acRawProfile[key] = nil
            end
        end
    end

    -- ── Move root-level enable/lock/hide keys to db.global ────────────────
    local g = self.db.global
    local isFirst = not g._rpGlobalSettingsMigrated
    local RP_GLOBAL_KEYS = {
        "partyFramesEnabled", "raidFramesEnabled", "locked",
        "hideBlizzardParty", "hideBlizzardRaid",
    }
    for _, key in ipairs(RP_GLOBAL_KEYS) do
        if rawProfile[key] ~= nil then
            if isFirst then
                g[key] = rawProfile[key]
            end
            rawProfile[key] = nil
        end
    end
    g._rpGlobalSettingsMigrated = true
end

-- ── IncomingCasts namespace migration ────────────────────────────────────
-- Moves the 17 IncomingCasts keys from p.modules.incomingCasts into the
-- IncomingCasts namespace (BF.icDB.profile). Also nils the source sub-table
-- once all keys are copied so it doesn't linger in SavedVariables.
-- Follows the same pattern as MigrateAuraCustomizationsProfile.
function BF:MigrateIncomingCastsProfile(profileName)
    profileName = profileName or self.db.keys.profile
    local rawProfile = self.db.profiles[profileName]
    if not rawProfile then return end
    if not rawProfile.modules or not rawProfile.modules.incomingCasts then return end

    local icp = self.icDB.profiles[profileName]
    if not icp then
        self.icDB.profiles[profileName] = {}
        icp = self.icDB.profiles[profileName]
    end

    local src = rawProfile.modules.incomingCasts
    local IC_KEYS = {
        "incomingCastsEnabled",
        "incomingCastsDisplayType",
        "incomingCastsShowTimer",
        "incomingCastsShowOnPlayerFrame",
        "incomingCastsShowOnPartyFrame",
        "incomingCastsAnchorPoint",
        "incomingCastsGrowDirection",
        "incomingCastsSpacing",
        "incomingCastsOffsetX",
        "incomingCastsOffsetY",
        "incomingCastsPlayerAnchorX",
        "incomingCastsPlayerAnchorY",
        "incomingCastsPlayerGrowDirection",
        "incomingCastsPlayerSpacing",
        "incomingCastsBarWidth",
        "incomingCastsBarHeight",
        "incomingCastsIconSize",
    }
    for _, key in ipairs(IC_KEYS) do
        if src[key] ~= nil then
            if type(src[key]) == "table" then
                icp[key] = self:DeepCopy(src[key])
            else
                icp[key] = src[key]
            end
            src[key] = nil
        end
    end

    -- Remove the now-empty incomingCasts sub-table
    if not next(src) then
        rawProfile.modules.incomingCasts = nil
    end
    -- Remove the modules container if it's empty (incomingCasts was its only entry)
    if rawProfile.modules and not next(rawProfile.modules) then
        rawProfile.modules = nil
    end
end

-- ── IncomingCasts per-display split (dbVersion 64) ─────────────────────
-- The two Incoming Casts display sections -- the bar on the party player
-- frame, and the detached "Incoming Casts Frame" -- were rendered from the
-- same makeOptionsArgs generator and wrote to the SAME 43 profile keys,
-- because icGet/icSet resolve the storage key from the option's own name.
-- The two tabs looked independent and were not: editing the bar width,
-- colors, fonts, borders, display type or the Show Casts filter on either
-- tab silently changed both.
--
-- The party display keeps the unprefixed keys; the detached display now owns
-- incomingCastsPlayer<Suffix>, extending the convention the position keys
-- (incomingCastsPlayerAnchorX/Y, PlayerGrowDirection, PlayerSpacing) already
-- used. Suffix list: BF.incomingCastsPerDisplayKeys (Defaults_IncomingCasts).
--
-- Seeds each new key from the value the user already had, so nothing visibly
-- moves on upgrade. Only copies where the user had an explicit value: leaving
-- the key absent lets it inherit its default, which keeps the SavedVariables
-- small and lets future default changes still propagate.
--
-- TABLES ARE DEEP-COPIED. Pointing both keys at one color table would
-- reproduce the exact bug this migration exists to fix.
function BF:MigrateIncomingCastsPerDisplay(profileName)
    local icp = self.icDB and self.icDB.profiles and self.icDB.profiles[profileName]
    if not icp then return end
    -- Per-profile sentinel: this must not re-run and clobber a value the
    -- user has since changed on one of the two tabs.
    if rawget(icp, "_perDisplaySplitV64") then return end
    icp._perDisplaySplitV64 = true

    local keys = self.incomingCastsPerDisplayKeys
    if not keys then return end

    for _, suffix in ipairs(keys) do
        local playerKey = "incomingCastsPlayer" .. suffix
        if rawget(icp, playerKey) == nil then
            local v = rawget(icp, "incomingCasts" .. suffix)
            if v ~= nil then
                if type(v) == "table" then
                    icp[playerKey] = self:DeepCopy(v)
                else
                    icp[playerKey] = v
                end
            end
        end
    end
end

-- ── Layouts by Instance Type migration (dbVersion 19) ──────────────────
-- Phase 1 of the "Layouts by Instance Type" rework. Seeds two new
-- tables on rp.layouts:
--   * flatLayouts              — each entry is ONE flat config (no
--                                party/raidNN sub-tables), deep-copied
--                                from the active layout's tier data.
--   * instanceLayoutAssignment — map of instance-type slot → flatLayout
--                                id (or "none" for solo).
-- Nothing reads these tables yet; they are dormant until Phase 2.
-- The old rp.layouts.layouts[*] table is left untouched so that a
-- future Profiles migration can mine per-role/per-spec settings.
--
-- Idempotent via rp.layouts._flatLayoutsMigrated sentinel.
function BF:MigrateLayoutsByInstanceType(profileName)
    profileName = profileName or self.rpDB.keys.profile
    local rp = self.rpDB.profiles[profileName]
    if not rp then return end  -- pure-defaults profile, nothing to migrate
    if not rp.layouts then return end  -- no layouts sub-table → predates v15
    if rp.layouts._flatLayoutsMigrated then return end
    -- v93 HOTFIX: refuse to run without the pre-flat named-layout tree.
    -- Everything below REBUILDS rpl.flatLayouts from that tree -- line
    -- `rpl.flatLayouts = {}` is unconditional -- so with no tree to mine
    -- this would replace a modern profile's live flats with factory
    -- defaults. Sentinel-absence alone does NOT mean "legacy": a profile
    -- CREATED at DB_VERSION >= 19 is stamped straight at DB_VERSION by the
    -- OnNewProfile callback, never enters the dispatcher, and so never
    -- receives _flatLayoutsMigrated either. This guard makes the
    -- destructive path unreachable from any caller, present or future.
    if type(rawget(rp.layouts, "layouts")) ~= "table" then return end

    local rpl = rp.layouts

    -- ── Resolve active layout ──
    local activeID = rpl.activeLayout or "default"
    local layouts  = rpl.layouts or {}
    local L        = layouts[activeID] or layouts.default

    -- ── Seed rp.sorting.{hideSelf, growDirection} from the active layout's
    -- party sub-table. These settings previously lived per-party-profile
    -- (on layouts[id].party.*) but under the new model they are global by
    -- default (and per-flat only when the Frames - Sorting section's
    -- per-layout toggle is ON). Only seed if the destination is still nil
    -- so a re-run never clobbers user values. ──
    rp.sorting = rp.sorting or {}
    local _partySrc = L and L.party
    if type(_partySrc) == "table" then
        if _partySrc.hideSelf ~= nil and rp.sorting.hideSelf == nil then
            rp.sorting.hideSelf = _partySrc.hideSelf
        end
        if _partySrc.growDirection ~= nil and rp.sorting.growDirection == nil then
            rp.sorting.growDirection = _partySrc.growDirection
        end
    end

    -- ── Build enabled raid tier list ──
    -- When separateRaidBySize is off, only raid40 data was ever used by
    -- the old system, so only raid40 becomes a flat. When on, include
    -- any tier the user explicitly enabled.
    --
    -- IMPORTANT: this migration reads from the raw SavedVariables table
    -- (self.rpDB.profiles[profileName]) rather than self.rpDB.profile,
    -- so AceDB's defaults are NOT merged in. AceDB's PLAYER_LOGOUT
    -- handler also strips default-equal keys from the raw SV. That
    -- means:
    --   * raid20/raid30 default to false → an absent key means "not
    --     enabled". Only an explicit `== true` counts as enabled.
    --   * raid40 defaults to true  → an absent key means "enabled".
    --     Only an explicit `== false` counts as disabled.
    local enabled = {}
    if rpl.separateRaidBySize == true then
        if rpl.enableRaid20 == true  then enabled[#enabled + 1] = "raid20" end
        if rpl.enableRaid30 == true  then enabled[#enabled + 1] = "raid30" end
        if rpl.enableRaid40 ~= false then enabled[#enabled + 1] = "raid40" end
    else
        enabled[#enabled + 1] = "raid40"
    end
    -- Safety: must have at least one raid tier, else fallback logic dies.
    if #enabled == 0 then enabled[1] = "raid40" end

    local enabledSet = {}
    for _, tier in ipairs(enabled) do enabledSet[tier] = true end

    -- ── Create flat layouts ──
    rpl.flatLayouts = {}

    -- flat_party: always created, deep-copied from L.party if present,
    -- otherwise seeded from CreatePartyProfile defaults.
    local partySrc = L and L.party
    local partyFlat
    if type(partySrc) == "table" and next(partySrc) then
        partyFlat = self:DeepCopy(partySrc)
    else
        partyFlat = self:CreatePartyProfile()
    end
    partyFlat.name = "Party"
    partyFlat.type = "party"
    rpl.flatLayouts.flat_party = partyFlat

    -- flat_raidNN for each enabled raid tier. Naming: "Raid" if there is
    -- only one raid tier, otherwise "Raid (20)" / "Raid (30)" / "Raid (40)".
    local raidLabels = { raid20 = "Raid (20)", raid30 = "Raid (30)", raid40 = "Raid (40)" }
    local singleRaid = (#enabled == 1)
    for _, tier in ipairs(enabled) do
        local src = L and L[tier]
        local flat
        if type(src) == "table" and next(src) then
            flat = self:DeepCopy(src)
        else
            flat = self:CreateRaidProfile(-260, -200)
        end
        flat.name = singleRaid and "Raid" or raidLabels[tier]
        flat.type = "raid"
        rpl.flatLayouts["flat_" .. tier] = flat
    end

    -- ── Helpers for assignment resolution ──
    -- nextLargestOrFallback: prefer target tier; else walk up (20→30→40);
    -- else walk down. Guaranteed to return a flat id because enabled is
    -- non-empty.
    local function nextLargestOrFallback(target)
        if enabledSet[target] then return "flat_" .. target end
        local upOrder   = { raid20 = { "raid30", "raid40" }, raid30 = { "raid40" }, raid40 = {} }
        local downOrder = { raid20 = {}, raid30 = { "raid20" }, raid40 = { "raid30", "raid20" } }
        for _, t in ipairs(upOrder[target] or {}) do
            if enabledSet[t] then return "flat_" .. t end
        end
        for _, t in ipairs(downOrder[target] or {}) do
            if enabledSet[t] then return "flat_" .. t end
        end
        -- Fallback to first enabled (shouldn't be reached).
        return "flat_" .. enabled[1]
    end

    local function smallestEnabled()
        for _, t in ipairs({ "raid20", "raid30", "raid40" }) do
            if enabledSet[t] then return "flat_" .. t end
        end
        return "flat_" .. enabled[1]
    end

    -- ── Build instanceLayoutAssignment ──
    local assignment = {}

    assignment.openWorldParty = "flat_party"
    assignment.dungeon        = "flat_party"
    assignment.delve          = "flat_party"
    assignment.arena          = "flat_party"

    -- Solo mirrors openWorldSolo: "party", "none", or a raidNN tier.
    local ows = rpl.openWorldSolo
    if ows == "none" then
        assignment.solo = "none"
    elseif ows == "raid20" or ows == "raid30" or ows == "raid40" then
        assignment.solo = nextLargestOrFallback(ows)
    else
        -- "party", nil, or anything unrecognized → party flat
        assignment.solo = "flat_party"
    end

    -- Raid (Open World) mirrors openWorldRaid: "auto" means pick raid40
    -- (with fallback), otherwise the specified tier (with fallback).
    local owr = rpl.openWorldRaid
    if owr == "raid20" or owr == "raid30" or owr == "raid40" then
        assignment.raidOpen = nextLargestOrFallback(owr)
    else
        -- "auto", nil, or unrecognized → 40-man with fallback
        assignment.raidOpen = nextLargestOrFallback("raid40")
    end

    assignment.raid20 = smallestEnabled()
    assignment.raid30 = nextLargestOrFallback("raid30")
    assignment.raid40 = nextLargestOrFallback("raid40")
    assignment.bg15   = smallestEnabled()
    assignment.bg40   = nextLargestOrFallback("raid40")

    rpl.instanceLayoutAssignment = assignment

    -- Sentinel so re-running this migration is a no-op.
    rpl._flatLayoutsMigrated = true
end

-- ============================================================
-- MigrateRoleSpecToFlatOverrides (v20)
-- Phase 2 of "Layouts by Instance Type".
--
-- Pre-v20 profiles used a per-role and per-spec OLD-layout
-- assignment model: roleLayoutAssignment[role] and
-- specLayoutAssignment[specID] pointed into the old `layouts`
-- table. Under the flat model we express overrides as sparse
-- per-slot maps of flat IDs.
--
-- For each referenced old layout this migration:
--   1. Splits its tier sub-tables (party, raid20, raid30, raid40)
--      into new flat layouts under flatLayouts[],
--   2. Populates roleOverrides[role][slot] / specOverrides[spec][slot]
--      to point at those new flats for each of the 11 slots.
--
-- Only non-"default" role/spec assignments are migrated.
-- Idempotent via the _roleSpecOverridesMigrated sentinel.
-- ============================================================
function BF:MigrateRoleSpecToFlatOverrides(profileName)
    profileName = profileName or self.rpDB.keys.profile
    local rp = self.rpDB.profiles[profileName]
    if not rp or not rp.layouts then return end
    local rpl = rp.layouts
    if rpl._roleSpecOverridesMigrated then return end

    -- Nothing to migrate if role/spec was never used.
    local hasRole = false
    if rpl.roleLayoutAssignment then
        for _, v in pairs(rpl.roleLayoutAssignment) do
            if v and v ~= "default" then hasRole = true; break end
        end
    end
    local hasSpec = false
    if rpl.specLayoutAssignment then
        for _, v in pairs(rpl.specLayoutAssignment) do
            if v and v ~= "default" then hasSpec = true; break end
        end
    end

    if not hasRole and not hasSpec then
        rpl._roleSpecOverridesMigrated = true
        return
    end

    rpl.flatLayouts    = rpl.flatLayouts    or {}
    rpl.roleOverrides  = rpl.roleOverrides  or { HEALER = {}, TANK = {}, DAMAGER = {} }
    rpl.specOverrides  = rpl.specOverrides  or {}

    local layouts = rpl.layouts or {}

    -- Which tiers should be split into flats, based on the profile-level
    -- enable gates. IMPORTANT: we must NOT emit _Raid20 / _Raid30 flats for
    -- tiers the user never turned on -- the old layout container always has
    -- raid20/raid30 sub-tables populated by the options-panel `ensureLayout`
    -- helper regardless of whether the user enabled them. Gating here on
    -- the profile-level switches matches the v19 seeding logic.
    --
    -- separateRaidBySize defaults to false -> only raid40.
    -- When on, enableRaid20/raid30 default to false, enableRaid40 to true.
    local splitTiers = {}
    if rpl.separateRaidBySize == true then
        if rpl.enableRaid20 == true  then splitTiers[#splitTiers + 1] = "raid20" end
        if rpl.enableRaid30 == true  then splitTiers[#splitTiers + 1] = "raid30" end
        if rpl.enableRaid40 ~= false then splitTiers[#splitTiers + 1] = "raid40" end
    else
        splitTiers[#splitTiers + 1] = "raid40"
    end
    if #splitTiers == 0 then splitTiers[1] = "raid40" end
    local splitTierSet = {}
    for _, t in ipairs(splitTiers) do splitTierSet[t] = true end

    -- Helper: generate a unique flat ID that doesn't collide with existing ones.
    local function nextFlatID()
        local i = 1
        while rpl.flatLayouts["flat_migrated_" .. i] do i = i + 1 end
        return "flat_migrated_" .. i
    end

    -- For each old-layout ID referenced by role/spec assignments, split it
    -- into up to 4 flats (party / raid20 / raid30 / raid40). Only emit a
    -- flat when the tier was actually initialized and has data.
    local splitCache = {}  -- oldLayoutID -> { party=flatID, raid20=..., raid30=..., raid40=... }
    local function splitOldLayout(oldID)
        if splitCache[oldID] then return splitCache[oldID] end
        local L = layouts[oldID]
        if not L then splitCache[oldID] = {}; return splitCache[oldID] end

        local result = {}
        local baseName = L.name or oldID

        -- Party sub-table
        if type(L.party) == "table" and next(L.party) then
            local flatID = nextFlatID()
            local flat = self:DeepCopy(L.party)
            flat.name = baseName .. "_Party"
            flat.type = "party"
            rpl.flatLayouts[flatID] = flat
            result.party = flatID
        end

        -- Raid tiers (only emit if the tier is enabled at the profile level
        -- AND the tier was initialized on this old layout AND has data)
        local raidLabels = { raid20 = "Raid20", raid30 = "Raid30", raid40 = "Raid40" }
        for _, tier in ipairs({ "raid20", "raid30", "raid40" }) do
            if splitTierSet[tier]
               and L[tier .. "Initialized"]
               and type(L[tier]) == "table"
               and next(L[tier]) then
                local flatID = nextFlatID()
                local flat = self:DeepCopy(L[tier])
                flat.name = baseName .. "_" .. raidLabels[tier]
                flat.type = "raid"
                rpl.flatLayouts[flatID] = flat
                result[tier] = flatID
            end
        end

        splitCache[oldID] = result
        return result
    end

    -- Pick a raid flat from a split result, preferring the requested tier,
    -- walking upward (20→30→40) then downward if unavailable.
    local function pickRaid(result, preferred)
        if result[preferred] then return result[preferred] end
        local up   = { raid20 = { "raid30", "raid40" }, raid30 = { "raid40" }, raid40 = {} }
        local down = { raid20 = {}, raid30 = { "raid20" }, raid40 = { "raid30", "raid20" } }
        for _, t in ipairs(up[preferred]   or {}) do if result[t] then return result[t] end end
        for _, t in ipairs(down[preferred] or {}) do if result[t] then return result[t] end end
        return nil
    end

    -- Slot-to-flat mapping:
    --   party-typed slots (solo, openWorldParty, dungeon, delve, arena)
    --     → result.party
    --   raid20 / bg15            → result.raid20 (with fallback)
    --   raid30                   → result.raid30 (with fallback)
    --   raid40 / raidOpen / bg40 → result.raid40 (with fallback)
    local function writeOverrides(destTable, oldID)
        local split = splitOldLayout(oldID)
        local partyFlat = split.party
        if partyFlat then
            for _, s in ipairs({ "solo", "openWorldParty", "dungeon", "delve", "arena" }) do
                destTable[s] = partyFlat
            end
        end
        local r20 = pickRaid(split, "raid20")
        local r30 = pickRaid(split, "raid30")
        local r40 = pickRaid(split, "raid40")
        if r20 then destTable.bg15     = r20; destTable.raid20   = r20 end
        if r30 then destTable.raid30   = r30 end
        if r40 then destTable.bg40     = r40; destTable.raid40   = r40; destTable.raidOpen = r40 end
    end

    -- Apply to each assigned role
    if hasRole then
        for role, oldID in pairs(rpl.roleLayoutAssignment) do
            if oldID and oldID ~= "default" and layouts[oldID] then
                rpl.roleOverrides[role] = rpl.roleOverrides[role] or {}
                writeOverrides(rpl.roleOverrides[role], oldID)
            end
        end
    end

    -- Apply to each assigned spec
    if hasSpec then
        for specID, oldID in pairs(rpl.specLayoutAssignment) do
            if oldID and oldID ~= "default" and layouts[oldID] then
                -- specID may be stored as a number or string key; we always
                -- use string keys in specOverrides to match ResolveActiveFlat.
                local specIDStr = tostring(specID)
                rpl.specOverrides[specIDStr] = rpl.specOverrides[specIDStr] or {}
                writeOverrides(rpl.specOverrides[specIDStr], oldID)
            end
        end
    end

    rpl._roleSpecOverridesMigrated = true
end

-- ── Group Settings to Flat Keys migration (dbVersion 21) ──────────────────
-- MigrateGroupSettingsToFlatKeys (v21)
-- Phase 2: per-flat aura container scoping.
--
-- Pre-v21 custom aura containers stored per-group-type settings
-- keyed by "party" / "raid20" / "raid30" / "raid40" / "cfGroup_N":
--
--   container.groupSettings = {
--     party   = { showForGroupType = true,  ... },
--     raid40  = { showForGroupType = false, ... },
--     cfGroup_1 = { ... },
--   }
--   container.containerEditingGroupType = "raid40"  -- transient last-pick
--
-- Under the flat model, keys become flat IDs. Party/raid40 entries
-- map 1:1 onto the seeded flats; raid20/raid30 entries have no flat
-- equivalent (no seeded flat_raid20/flat_raid30) and are discarded.
-- cfGroup_N entries are unchanged here; migration 52
-- (_AuraMig_RekeyGroupSettings) rekeys them onto cfgFlatID.
--
-- Idempotent via _groupSettingsMigratedToFlat sentinel on acDB.
-- Fresh installs are no-ops.
-- ============================================================
function BF:MigrateGroupSettingsToFlatKeys(profileName)
    profileName = profileName or self.acDB.keys.profile
    local acp = self.acDB.profiles[profileName]
    if not acp then return end
    if acp._groupSettingsMigratedToFlat then return end

    -- Key remap table: old tier key → new flat ID
    -- raid20/raid30 map to nil → discarded (no seeded flat for them)
    local REMAP = {
        party  = "flat_party",
        raid40 = "flat_raid40",
        raid20 = nil,
        raid30 = nil,
    }

    local containers = acp.customBuffContainers
    if type(containers) == "table" then
        for _, c in pairs(containers) do
            if type(c) == "table" then
                -- Remap container.groupSettings keys
                if type(c.groupSettings) == "table" then
                    local newGS = {}
                    for key, entry in pairs(c.groupSettings) do
                        if key:find("^cfGroup_") then
                            -- CF groups unchanged
                            newGS[key] = entry
                        elseif REMAP[key] then
                            -- Known old tier key → new flat ID
                            newGS[REMAP[key]] = entry
                        elseif key == "raid20" or key == "raid30" then
                            -- Discarded — no flat maps to these tier IDs
                        else
                            -- Unknown key (possibly a flat ID already, or
                            -- something we don't recognize). Pass through
                            -- unchanged to avoid data loss.
                            newGS[key] = entry
                        end
                    end
                    c.groupSettings = newGS
                end

                -- Remap container.containerEditingGroupType (transient
                -- "last picked editing group" string). If it pointed at a
                -- discarded tier, reset to flat_raid40 as a stable default.
                local ce = c.containerEditingGroupType
                if ce then
                    if ce:find("^cfGroup_") then
                        -- CF group unchanged
                    elseif REMAP[ce] then
                        c.containerEditingGroupType = REMAP[ce]
                    elseif ce == "raid20" or ce == "raid30" then
                        c.containerEditingGroupType = "flat_raid40"
                    end
                    -- Other values pass through unchanged
                end
            end
        end
    end

    acp._groupSettingsMigratedToFlat = true
end

-- ── Flat showGroup backfill (dbVersion 22) ───────────────────────
-- MigrateBackfillFlatShowGroup (v22)
-- AceDB strips default-equal tables from SavedVariables on logout. Raid
-- profiles have `showGroup = { true, true, true, true, true, true, true, true }`
-- as a default; if the user never toggled any group, AceDB removes the
-- entire `showGroup` key from their saved profile. The v19 migration then
-- `DeepCopy(src)`'d the raw tier table into `flat_raid40`, producing a
-- raid-typed flat with no `showGroup` field. The Options → Frames tab's
-- group1..group8 toggles then crash when AceConfig calls their get/set.
--
-- This migration walks every flat in every profile and materializes a
-- default-all-true `showGroup` on any raid-typed flat that is missing it.
--
-- Sparse-table variant: a user who had some groups toggled off pre-migration
-- (e.g. groups 7-8 unchecked) would end up with a partial showGroup like
-- `{[7]=false, [8]=false}` — either because an older sparse-storage pass
-- stripped the default-equal `true` entries, or because WoW's serializer
-- wrote out the gaps as literal nils. The Options UI reads `showGroup[i]`
-- directly and renders nil slots as unchecked, losing the implicit-true
-- default. Densify by filling any nil index from 1..8 with `true`. This
-- preserves explicit `false` entries (the user's real toggle-offs) while
-- restoring the implicit `true`s to their on-disk form so the UI agrees
-- with the user's actual intent.
--
-- Party-typed flats are left alone (they never had `showGroup`).
--
-- Idempotent via _showGroupBackfilled sentinel on rp.layouts.
-- ============================================================
function BF:MigrateBackfillFlatShowGroup(profileName)
    profileName = profileName or self.rpDB.keys.profile
    local rp = self.rpDB.profiles[profileName]
    if not rp or not rp.layouts then return end
    local rpl = rp.layouts
    if rpl._showGroupBackfilled then return end

    local fl = rpl.flatLayouts
    if type(fl) == "table" then
        for _, flat in pairs(fl) do
            if type(flat) == "table" and flat.type == "raid" then
                if flat.showGroup == nil then
                    flat.showGroup = { true, true, true, true, true, true, true, true }
                elseif type(flat.showGroup) == "table" then
                    -- Densify a sparse showGroup. Any index 1..8 that is nil
                    -- represents the implicit default (true); materialize it
                    -- so Options reads back the user's intent. Explicit false
                    -- entries (real toggle-offs) are preserved.
                    for i = 1, 8 do
                        if flat.showGroup[i] == nil then
                            flat.showGroup[i] = true
                        end
                    end
                end
            end
        end
    end

    rpl._showGroupBackfilled = true
end

-- ── Flat defaults collapsed to sparse storage (dbVersion 23) ──────
-- MigrateCollapseFlatDefaults (v23)
-- Paired with Core_FlatDefaults.lua's __index fallback mechanism.
--
-- Every existing flat in every rpDB profile was fully materialized by
-- earlier migrations (v19 DeepCopy'd tier tables into flats, v20 did
-- the same for role/spec splits, v22 backfilled missing showGroup).
-- With the v23 switch to sparse storage + __index template fallback,
-- any rawkey whose value equals the template default becomes redundant:
-- AceDB would strip it at logout anyway, and if we leave those rawkeys
-- materialized they waste SavedVariables space and obscure which keys
-- the user actually customized.
--
-- This migration walks every flat and nils any rawkey matching the
-- template (CreateRaidProfile / CreatePartyProfile). The four invariants
-- (name, type, anchorX, anchorY, layoutAnchor) are always preserved as
-- rawkeys so the template can be built for each flat.
--
-- Table-valued keys are compared deeply so color tables ({r,g,b,a})
-- and similar compare structurally, not by identity.
--
-- Idempotent via _flatsCollapsedToSparse sentinel on rp.layouts.
-- ============================================================
local function _bfDeepEqual(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do
        if not _bfDeepEqual(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

function BF:MigrateCollapseFlatDefaults(profileName)
    profileName = profileName or self.rpDB.keys.profile
    local rp = self.rpDB.profiles[profileName]
    if not rp or not rp.layouts then return end
    local rpl = rp.layouts
    if rpl._flatsCollapsedToSparse then return end
    if type(rpl.flatLayouts) ~= "table" then
        rpl._flatsCollapsedToSparse = true
        return
    end

    for _, flat in pairs(rpl.flatLayouts) do
        if type(flat) == "table" and (flat.type == "raid" or flat.type == "party") then
            local template
            if flat.type == "raid" then
                template = self:CreateRaidProfile(flat.anchorX, flat.anchorY)
            else
                template = self:CreatePartyProfile()
            end
            for k, tv in pairs(template) do
                -- Preserve invariants so BF:WireFlatDefaults can always
                -- pick the right template shape and anchor coordinates.
                if k ~= "name" and k ~= "type"
                   and k ~= "anchorX" and k ~= "anchorY"
                   and k ~= "partyLayoutAnchor"
                   and k ~= "raidLayoutAnchor" then
                    if _bfDeepEqual(flat[k], tv) then
                        flat[k] = nil
                    end
                end
            end
        end
    end

    rpl._flatsCollapsedToSparse = true
end

-- ── v24: tooltip key relocation + per-layout section fallback wiring ──
--
-- Two independent fixes bundled under one dbVersion bump:
--
-- (a) MigrateTooltipsLocation
--     The 10 aura-tooltip show toggles (showBuffTooltip, showBuffTooltipInCombat,
--     showDebuffTooltip, showDebuffTooltipInCombat, showBigDefTooltip,
--     showBigDefTooltipInCombat, showImportantTooltip, showImportantTooltipInCombat,
--     showCrowdControlTooltip, showCrowdControlTooltipInCombat) were being written
--     to self.db.profile[key] by getTooltip_global / setTooltip_global /
--     setTooltipBigDef_global in Options.lua, even though the runtime reader
--     (UpdateAuraSizeCache) correctly read from self.rpDB.profile.tooltips[key].
--     Result: toggling the widget updated db.profile but runtime kept using
--     the defaults stored in rpDB.profile.tooltips. This migration moves any
--     orphaned db.profile values into rp.tooltips (db.profile wins -- it holds
--     the user's most recent intent since v15's initial move) and nils the
--     db.profile keys.
--
--     suppressPrivateAuraTooltip lived on each flat's root (flat.suppressPrivateAuraTooltip),
--     written by the options widget via GetRaidProfile() / GetActivePartyProfile()
--     and read at runtime by LayoutPrivateAuraFrames / UpdateAuraSizeCache from
--     the same flat-root location. It now lives in rp.tooltips.suppressPrivateAuraTooltip
--     alongside the other tooltip keys. Merge policy: if ANY flat had suppress=true,
--     the global becomes true (preserves the user's suppression intent from any flat).
--     All flat-root copies are nilled.
--
-- (b) MigrateWirePerLayoutSectionFallbacks
--     Every flat[section] sub-table (for sections that support the "Separate
--     configuration per Layout" toggle) gets a metatable whose __index points
--     at rpDB.profile[section]. Missing keys fall through to the global, which
--     AceDB's defaults layer re-materializes from Defaults_RaidPartyFrames.lua
--     on every login. Without this, adding a new key to a section's defaults
--     after users have already seeded per-flat copies would leave the key
--     missing from those copies (readers would get nil instead of the default).
--     See Docs/PHASE_3_PLAN.md Part 2 for the full rationale.
--
--     This migration is a one-time retrofit for flats that were seeded under
--     an older addon version. Going forward, SeedAllFlatsForSection wires the
--     metatable at seed time, and RehydrateFlats re-wires on every login /
--     profile change. The migration only needs to handle the initial pass.
-- ============================================================

-- Part (a): tooltip key relocation.
function BF:MigrateTooltipsLocation(profileName)
    profileName = profileName or self.rpDB.keys.profile
    local rp = self.rpDB.profiles[profileName]
    if not rp then return end
    if not rp.layouts then return end
    if rp._tooltipsLocationMigrated then return end

    rp.tooltips = rp.tooltips or {}
    local ttp = rp.tooltips

    -- The 10 aura-tooltip show keys previously written to db.profile by
    -- the (deleted) getTooltip_global / setTooltip_global helpers.
    -- Read from the raw SV for the same-named core profile. If no core
    -- profile exists (user-created rpDB profile without matching core
    -- profile), skip -- nothing to migrate.
    local coreProfile = self.db.profiles[profileName]
    if coreProfile then
        local KEYS = {
            "showBuffTooltip",         "showBuffTooltipInCombat",
            "showDebuffTooltip",       "showDebuffTooltipInCombat",
            "showBigDefTooltip",       "showBigDefTooltipInCombat",
            "showImportantTooltip",    "showImportantTooltipInCombat",
            "showCrowdControlTooltip", "showCrowdControlTooltipInCombat",
        }
        for _, key in ipairs(KEYS) do
            if coreProfile[key] ~= nil then
                -- db.profile value wins -- it holds the user's most recent
                -- intent (setTooltip_global kept writing there after v15's
                -- initial move into rp.tooltips).
                ttp[key] = coreProfile[key]
                coreProfile[key] = nil
            end
        end
    end

    -- suppressPrivateAuraTooltip previously lived at the flat root. Walk
    -- every flat, collect any true values, nil the flat-root key. If ANY
    -- flat had true, the global becomes true (preserves the suppression
    -- intent from at least one flat). Otherwise leave at default (false).
    local fl = rp.layouts.flatLayouts
    if type(fl) == "table" then
        local anyTrue = false
        for _, flat in pairs(fl) do
            if type(flat) == "table" then
                if flat.suppressPrivateAuraTooltip == true then anyTrue = true end
                flat.suppressPrivateAuraTooltip = nil
            end
        end
        if anyTrue and ttp.suppressPrivateAuraTooltip == nil then
            ttp.suppressPrivateAuraTooltip = true
        end
    end

    rp._tooltipsLocationMigrated = true
end

-- Part (b): per-layout section fallback wiring retrofit.
function BF:MigrateWirePerLayoutSectionFallbacks(profileName)
    profileName = profileName or self.rpDB.keys.profile
    local rp = self.rpDB.profiles[profileName]
    if not rp or not rp.layouts then return end
    local rpl = rp.layouts
    if rpl._perLayoutSectionFallbacksWired then return end

    -- NOTE: this migration wires metatables on raw SavedVariables tables.
    -- The __index target is self.rpDB.profile[section] (the live AceDB-
    -- managed global), NOT the raw SV. That's intentional: the metatable
    -- needs to follow profile switches and defaults re-materialization.
    -- The raw SV here is the same object AceDB returns as
    -- self.rpDB.profiles[profileName] for the currently-loaded profile,
    -- so setting its metatable is the same as setting it on the live
    -- profile. For non-active profiles, the raw SV table is still the
    -- storage AceDB will use next time the user switches to them --
    -- RehydrateFlats runs on every profile change and re-wires, so the
    -- metatable set here is harmless for non-active profiles (it would
    -- target the current profile's global, but RehydrateFlats corrects
    -- it post-switch).
    local SECTIONS = BF._perLayoutSections or {
        "sorting", "tooltips",
        "auras", "icons", "text", "borders",
        "healthPower", "auraText", "absorbs", "castBar",
    }

    local fl = rpl.flatLayouts
    if type(fl) == "table" then
        for _, flat in pairs(fl) do
            if type(flat) == "table" then
                for i = 1, #SECTIONS do
                    -- WireSectionFallback is a no-op when the section
                    -- sub-table doesn't exist on this flat, so passing
                    -- every section name is safe.
                    self:WireSectionFallback(flat, SECTIONS[i])
                end
            end
        end
    end

    rpl._perLayoutSectionFallbacksWired = true
end

-- ── v25: text section data-location fix + font-name fix ──────────────
--
-- Two related bugs bundled as one migration:
--
-- (a) Text-section scalar/toggle keys were written by Options_Text.lua's
--     custom setters to self.rpDB.profile.text[key] but read via the
--     deps.get factory which reads self.db.profile[key] (the CORE profile
--     DB, not rpDB). So toggling a widget wrote to the right place but
--     the UI kept reading the stale value from db.profile. Worse, several
--     runtime readers correctly read from rpDB.profile.text -- meaning
--     the runtime behavior reflected the user's intent while the UI
--     showed a stale state. Same bug class as the tooltips v24 fix.
--
-- (b) Font-name keys (nameFont, healthFont, statusFont, groupLabelFont,
--     vehicleFont) were written by setFont(key, val) to self.db.profile[key]
--     and read by getFont(key) from the same place. Runtime reads font
--     names from self.rpDB.profile.text[key]. Net effect: selecting a
--     font in the UI persists the choice and shows it in the dropdown,
--     but runtime never picks it up -- frames keep rendering in the
--     default "PT Sans Narrow" (or whatever the last correct write was).
--
-- Cross-section widgets in Options_HealthPower.lua (offlineBackgroundColor,
-- offlineBackgroundOpacity, fadeOfflineFrames, deadBackgroundColor,
-- deadBackgroundOpacity, deadColorOORFactor) used to write to rp.text too
-- and were handled here. As of v50 those keys live in the healthPower
-- section to match their UI location; this migration still relocates them
-- from db.profile → rp.text (the historical write site), and the v50
-- MigrateOfflineDeadColorsToHealthPower migration then moves them onward
-- from rp.text → rp.healthPower. Two-step relocation is intentional --
-- it preserves the historical merge policy (db.profile wins over rp.text)
-- before the section move.
--
-- Merge policy: if db.profile[key] ~= nil, it wins -- db.profile holds
-- the user's most recent edit (the setters kept writing there even after
-- the runtime started reading from rp.text). Mirrors MigrateTooltipsLocation.
function BF:MigrateTextLocation(profileName)
    profileName = profileName or self.rpDB.keys.profile
    local rp = self.rpDB.profiles[profileName]
    if not rp then return end
    if rp._textLocationMigrated then return end

    rp.text = rp.text or {}
    local tp = rp.text

    -- All text-section keys that Options_Text.lua / Options_HealthPower.lua
    -- (for the cross-section widgets) may have written to db.profile while
    -- the runtime was reading from rp.text. This is the union of the get=get
    -- read sites and the custom setters' write keys across those two files.
    local KEYS = {
        -- Names
        "adjustNameFont", "nameFont", "nameFontBorder", "nameFontSize",
        "adjustNameColors", "classColorNames",
        "abbreviateNames", "maxNameChars", "capitalizeNames",
        "transliterateCyrillicNames",
        -- Health text
        "showHealthText", "healthTextFormat",
        "adjustHealthFont", "healthFont", "healthFontBorder", "healthFontSize",
        "adjustHealthTextColor", "classColorHealthText",
        -- Status text
        "appendStatusTextToNames", "statusBeforeName", "statusAppendSeparator",
        "adjustStatusFont", "statusFont", "statusFontBorder", "statusFontSize",
        "abbreviateStatusNames", "maxStatusNameChars",
        "capitalizeStatusText", "applyStatusColorsToNames",
        "showDeadStatus",
        "showOfflineStatus", "abbreviateOffline", "showAFKStatus",
        "fadeOfflineNameText",
        -- Labels
        "showGroupLabels", "groupLabelYOffset",
        "adjustGroupLabelFont", "groupLabelFont",
        "groupLabelFontBorder", "groupLabelFontSize",
        -- Vehicle
        "showVehicleName", "abbreviateVehicleNames", "maxVehicleNameChars",
        "adjustVehicleFont", "vehicleFont", "vehicleFontBorder", "vehicleFontSize",
        -- Cross-section (owned by text, written from Options_HealthPower.lua)
        "offlineBackgroundColor", "fadeOfflineFrames",
        "deadBackgroundColor", "deadBackgroundOpacity",
        "deadColorOORFactor",
    }

    local coreProfile = self.db.profiles[profileName]
    if coreProfile then
        for _, key in ipairs(KEYS) do
            if coreProfile[key] ~= nil then
                -- db.profile value wins. For table-typed values (the three
                -- cross-section colors) we need to deep-copy rather than
                -- aliasing the same table between the two DBs.
                local v = coreProfile[key]
                if type(v) == "table" then
                    tp[key] = self:DeepCopy(v)
                else
                    tp[key] = v
                end
                coreProfile[key] = nil
            end
        end
    end

    rp._textLocationMigrated = true
end

-- ── v50: offline/dead bar colors moved text → healthPower ──────────────
--
-- The six keys offlineBackgroundColor, offlineBackgroundOpacity,
-- fadeOfflineFrames, deadBackgroundColor, deadBackgroundOpacity, and
-- deadColorOORFactor used to live in the TEXT section but the UI widgets
-- for them are rendered on the Health & Power tab. With independent
-- per-section per-layout toggles, this meant that toggling the
-- healthPower per-layout flag had no effect on these values; instead the
-- TEXT per-layout flag governed them, which was both unexpected and
-- contradicted the obvious UI grouping (e.g. offline bar color would
-- silently change when switching from party to raid even though the
-- Health & Power per-layout toggle was OFF).
--
-- This migration moves any saved values from rp.text → rp.healthPower,
-- and (for users who had the text per-layout toggle on with per-flat
-- copies) from each flat.text → flat.healthPower. Idempotent per profile
-- via rp._offlineDeadColorsRelocated.
--
-- Merge policy: source value wins -- the user's customisation flows
-- forward. Existing rp.healthPower values for these keys (e.g. a default
-- left over from a brand-new profile) are overwritten.
function BF:MigrateOfflineDeadColorsToHealthPower(profileName)
    profileName = profileName or self.rpDB.keys.profile
    local rp = self.rpDB.profiles[profileName]
    if not rp then return end
    if rp._offlineDeadColorsRelocated then return end

    local KEYS = {
        "offlineBackgroundColor", "offlineBackgroundOpacity",
        "fadeOfflineFrames",
        "deadBackgroundColor", "deadBackgroundOpacity",
        "deadColorOORFactor",
    }

    local function move(src, dst)
        if type(src) ~= "table" or type(dst) ~= "table" then return end
        for _, key in ipairs(KEYS) do
            local v = rawget(src, key)
            if v ~= nil then
                if type(v) == "table" then
                    dst[key] = self:DeepCopy(v)
                else
                    dst[key] = v
                end
                src[key] = nil
            end
        end
    end

    -- Global pseudo-layout.
    rp.text        = rp.text or {}
    rp.healthPower = rp.healthPower or {}
    move(rp.text, rp.healthPower)

    -- Per-flat sub-tables. Iterate every flat; both text and healthPower
    -- per-flat tables are sparse (only user-modified keys are present),
    -- so move() is a no-op for flats that never had these keys
    -- customised at the per-layout level.
    local rpl = rp.layouts
    local fl  = rpl and rpl.flatLayouts
    if type(fl) == "table" then
        for _, flat in pairs(fl) do
            if type(flat) == "table" then
                local ft = rawget(flat, "text")
                local fh = rawget(flat, "healthPower")
                if type(ft) == "table" then
                    -- Materialise flat.healthPower if missing so we have
                    -- a destination. WireSectionFallback will be applied
                    -- by RehydrateFlats on the next access path.
                    if type(fh) ~= "table" then
                        fh = {}
                        flat.healthPower = fh
                    end
                    move(ft, fh)
                end
            end
        end
    end

    rp._offlineDeadColorsRelocated = true
end

-- ── v26: icons section data-location fix + test-toggle cleanup ─────────
--
-- Two related fixes bundled as one migration:
--
-- (a) Missing-raid-buff keys relocation from acDB → rpDB.icons.
--     8 keys: showMissingRaidBuff, showMissingSymbiotic,
--     showMissingRaidBuffInCombat, missingRaidBuffAnchor,
--     missingRaidBuffOffsetX, missingRaidBuffOffsetY, missingRaidBuffSize,
--     missingRaidBuffShowGlow.
--
--     The v15 migration (MigrateRaidPartyFramesProfile) moved these keys
--     from acDB.profile into rpDB.profile.icons. But Options_Icons.lua was
--     never updated to match -- it kept writing to acDB on every edit,
--     while runtime read from rpDB.icons. So the user's UI writes never
--     took effect at runtime; the live behavior has always been the
--     rpDB.icons defaults.
--
--     Merge policy: strict-rpDB-wins. Runtime has been reading from
--     rpDB.icons since v15, so rpDB.icons is the source of truth. Never
--     copy acDB values into rpDB (that would silently enable a feature
--     users thought was off, since the UI writes to acDB were never
--     visible at runtime). Always nil the acDB copies. Users who had
--     toggled showMissingRaidBuff on via the broken UI will need to
--     re-toggle; this is acceptable because silently enabling a feature
--     they believed was off would be worse.
--
-- (b) Test-toggle orphan cleanup on db.profile.
--     5 keys: testReadyCheck, testPhased, testSummonPending,
--     testResurrectPending, testVehicleIcon.
--
--     These were moved to db.global in v14 MigrateGlobalSettings, but
--     Options_Icons.lua kept writing them to db.profile (via deps.set
--     which writes to self.db.profile[key]). Runtime reads from
--     db.global, so those writes never took effect. Nil the dead
--     db.profile copies here.
--
--     Going forward, Options_Icons.lua reads and writes these keys
--     directly via BF.db.global. Core_DB.lua also resets them to false
--     at every reload (they are transient debug flags, not persistent
--     user config).
--
-- Idempotent via rp._iconsLocationMigrated sentinel on the rpDB profile.
function BF:MigrateIconsLocation(profileName)
    profileName = profileName or self.rpDB.keys.profile
    local rp = self.rpDB.profiles[profileName]
    if not rp then return end
    if rp._iconsLocationMigrated then return end

    -- (a) Nil the 8 missing-raid-buff keys on acDB.profile. Runtime has
    -- been reading from rpDB.icons since v15; the acDB copies are dead
    -- reads from Options_Icons.lua's stale writes. Strict-rpDB-wins means
    -- we never copy acDB values into rpDB.icons -- we just delete them.
    -- Handle both pre-v18 (acDB as namespace under db.sv.namespaces) and
    -- post-v18 (self.acDB.profiles) storage locations.
    local acRawProfile
    local acRawNS = self.db.sv and self.db.sv.namespaces and self.db.sv.namespaces.AuraCustomizations
    if acRawNS and acRawNS.profiles then
        acRawProfile = acRawNS.profiles[profileName]
    end
    if not acRawProfile and self.acDB and self.acDB.profiles then
        acRawProfile = self.acDB.profiles[profileName]
    end
    if acRawProfile then
        local MRB_KEYS = {
            "showMissingRaidBuff", "showMissingSymbiotic", "showMissingRaidBuffInCombat",
            "missingRaidBuffAnchor", "missingRaidBuffOffsetX", "missingRaidBuffOffsetY",
            "missingRaidBuffSize", "missingRaidBuffShowGlow",
        }
        for _, key in ipairs(MRB_KEYS) do
            acRawProfile[key] = nil
        end
    end

    -- (b) Nil the 5 orphaned test-toggle keys on db.profile. Runtime
    -- reads from db.global (via v14 MigrateGlobalSettings). These
    -- db.profile copies are dead writes from Options_Icons.lua's
    -- get=get/set=set path.
    local coreProfile = self.db.profiles[profileName]
    if coreProfile then
        coreProfile.testReadyCheck       = nil
        coreProfile.testPhased           = nil
        coreProfile.testSummonPending    = nil
        coreProfile.testResurrectPending = nil
        coreProfile.testVehicleIcon      = nil
    end

    rp._iconsLocationMigrated = true
end

-- ── v27: auras section rollout (nested sub-categories + per-layout) ──
--
-- Relocates all flat-root aura-section keys (buffs/debuffs/privateAuras/
-- bigDef/important/crowdControl/dispelIndicator) into nested sub-category
-- sub-tables under flat.auras.<subcat>. Enables the per-layout toggle for
-- auras so existing users keep their per-flat aura configuration as the
-- default UX (they can toggle OFF manually if they prefer the shared-global
-- model). Also relocates db.profile.pvpSwapDebuffsPrivate into nested
-- flat.auras.privateAuras.pvpSwapDebuffsPrivateBattleground (per-flat for
-- raid flats) and rp.auras.privateAuras.pvpSwapDebuffsPrivateBattleground
-- (global fallback). The new pvpSwapDebuffsPrivateParty key is not migrated
-- — it's genuinely new in v27 and defaults to false for all users.
--
-- Ordering vs v23 (MigrateCollapseFlatDefaults):
--   v23 already ran on upgraded users and stripped default-equal aura
--   rawkeys before this restructure. That's fine: v27 only relocates
--   rawkeys that are still present. Un-customized keys (already stripped
--   by v23) are correctly absent from flat.auras and flow through the
--   fallback chain (flat.auras.__index -> global.auras,
--   flat.auras.<subcat>.__index -> global.auras.<subcat>) to the global
--   defaults in Defaults_RaidPartyFrames.lua.
--
-- Idempotent via rp._aurasSectionMigrated sentinel.
function BF:MigrateAurasToSection(profileName)
    profileName = profileName or self.rpDB.keys.profile
    local rp = self.rpDB.profiles[profileName]
    if not rp then return end
    if rp._aurasSectionMigrated then return end
    rp.layouts = rp.layouts or {}

    -- Per-flat relocation: for every flat, move flat.<auraKey> into
    -- flat.auras.<subcat>.<auraKey> using the BF.AURAS_SUBCATEGORY_OF
    -- key-to-subcat map. Sub-tables are created lazily; an existing
    -- flat.auras.<subcat> is preserved and extended.
    local fl = rp.layouts.flatLayouts
    if type(fl) == "table" then
        for _, flat in pairs(fl) do
            if type(flat) == "table" then
                for key, subcat in pairs(BF.AURAS_SUBCATEGORY_OF) do
                    if flat[key] ~= nil then
                        flat.auras = flat.auras or {}
                        flat.auras[subcat] = flat.auras[subcat] or {}
                        if type(flat[key]) == "table" then
                            flat.auras[subcat][key] = self:DeepCopy(flat[key])
                        else
                            flat.auras[subcat][key] = flat[key]
                        end
                        flat[key] = nil
                    end
                end
            end
        end
    end

    -- Enable the per-layout toggle for auras so existing users keep
    -- their per-flat aura configuration as the default UX. They can
    -- toggle OFF manually if they prefer the shared-global model.
    rp.layouts.perLayoutToggles = rp.layouts.perLayoutToggles or {}
    rp.layouts.perLayoutToggles.auras = true

    -- Migrate pvpSwapDebuffsPrivate -> pvpSwapDebuffsPrivateBattleground under
    -- flat.auras.privateAuras (per-flat, raid flats only) and
    -- rp.auras.privateAuras (global fallback).
    --
    -- Source locations checked, in priority order:
    --   1. db.profile.pvpSwapDebuffsPrivate (per-profile) -- where recent-era
    --      widgets in Options_Preview.lua Special Options wrote to.
    --   2. db.global.pvpSwapDebuffsPrivate (shared across profiles) -- where
    --      the v14 MigrateGlobalSettings migration relocated any pre-v14
    --      saved value. Used as a fallback for users who upgraded from
    --      pre-v14 and had their setting moved to db.global by that
    --      migration. db.global source wins only when the per-profile source
    --      is nil, matching the "most-recent wins" principle.
    --
    -- Per-flat migration: each raid flat (flat.type == "raid") inherits the
    -- user's old value under flat.auras.privateAuras.pvpSwapDebuffsPrivateBattleground,
    -- so toggle-ON users preserve old behavior. Party flats never had the
    -- setting apply in old code (the runtime gate was `isRaid and ...`), so
    -- they are left alone.
    --
    -- The db.global source is nilled by the FIRST profile that runs this
    -- migration (first-profile-wins), since db.global is shared across
    -- profiles. Subsequent profiles still get per-raid-flat seeding because
    -- that's driven by the per-profile rp.layouts.flatLayouts, but they see
    -- the db.global source already gone.
    --
    -- The new `pvpSwapDebuffsPrivateParty` key is not migrated from anywhere:
    -- it is a genuinely new setting (party-frame swap had no predecessor in
    -- old code) and defaults to false for all users.
    local pp = self.db and self.db.profiles and self.db.profiles[profileName]
    local g  = self.db and self.db.global
    local oldVal
    if pp and pp.pvpSwapDebuffsPrivate ~= nil then
        oldVal = pp.pvpSwapDebuffsPrivate
        pp.pvpSwapDebuffsPrivate = nil
    elseif g and g.pvpSwapDebuffsPrivate ~= nil then
        oldVal = g.pvpSwapDebuffsPrivate
        -- Don't nil db.global yet; let only the first profile clear it so
        -- late-migrating profiles can still see it. We nil it after the
        -- seeding block below only when this is the first profile to do so,
        -- but for simplicity we just nil it here -- subsequent profiles
        -- fall through to oldVal=nil and skip seeding, which is fine
        -- because every profile shares the same db.global source anyway.
        g.pvpSwapDebuffsPrivate = nil
    end
    if oldVal ~= nil then
        -- Seed into rpDB global so toggle-OFF users see their preserved value.
        rp.auras = rp.auras or {}
        rp.auras.privateAuras = rp.auras.privateAuras or {}
        if rp.auras.privateAuras.pvpSwapDebuffsPrivateBattleground == nil then
            rp.auras.privateAuras.pvpSwapDebuffsPrivateBattleground = oldVal
        end
        -- Also seed into every raid flat's auras.privateAuras so toggle-ON
        -- users see their old behavior per-raid-flat. Only seed non-default
        -- (true) values -- leaving false to fall through the metatable chain.
        if type(fl) == "table" and oldVal then
            for _, flat in pairs(fl) do
                if type(flat) == "table" and flat.type == "raid" then
                    flat.auras = flat.auras or {}
                    flat.auras.privateAuras = flat.auras.privateAuras or {}
                    if flat.auras.privateAuras.pvpSwapDebuffsPrivateBattleground == nil then
                        flat.auras.privateAuras.pvpSwapDebuffsPrivateBattleground = oldVal
                    end
                end
            end
        end
    end

    rp._aurasSectionMigrated = true
end

-- ── v27: Private Aura Border namespace migrations ─────────────────────
--
-- Relocates six private-aura-border settings out of db.profile (where they
-- were originally written by widgets in Options_Preview.lua Special Options
-- and Options_Auras.lua) into the namespaces matching their new UI
-- locations:
--
--   1. privateAuraBorderScale       -> rpDB.profile.privateAuraBorderScale
--      (widget moved to Raid/Party Frames → Auras → Private Auras subtab)
--
--   2. privateAuraBorderAutoScale   -> acDB.profile.privateAuraBorderAutoScale
--   3. privateAuraBorderWidthRatio  -> acDB.profile.privateAuraBorderWidthRatio
--   4. privateAuraBorderFrameLevel  -> acDB.profile.privateAuraBorderFrameLevel
--      (widgets moved to Aura Customizations → Private Aura Customizations
--       → Frame Border subtab)
--
--   5. Per-flat raidProfile.privateAuraFrameBorderScaleOverride ->
--      acDB.profile.privateAuraFrameBorderScaleRaid (global one-value-per-scope)
--   6. Per-flat partyProfile.privateAuraFrameBorderScaleOverride ->
--      acDB.profile.privateAuraFrameBorderScaleParty (global one-value-per-scope)
--
-- For 5 and 6, the old storage was per-flat-per-tier (each raid/party flat
-- had its own override). The new storage is global one-raid-value +
-- one-party-value. The migration collapses by "first flat with a non-nil
-- override wins" for each scope -- a best-effort compromise since the old
-- model has no canonical "this is the one true value".
--
-- Idempotent via rp._privateAuraBorderNamespacesMigrated on the rpDB
-- profile. The migration reads from self.db.profiles[profileName] and
-- writes to self.rpDB.profiles[profileName] + self.acDB.profiles[profileName]
-- so it's safe to dispatch across all three DBs by profileName.
function BF:MigratePrivateAuraBorderNamespaces(profileName)
    profileName = profileName or self.db.keys.profile
    local pp = self.db    and self.db.profiles    and self.db.profiles[profileName]
    local rp = self.rpDB  and self.rpDB.profiles  and self.rpDB.profiles[profileName]
    local ac = self.acDB  and self.acDB.profiles  and self.acDB.profiles[profileName]
    local g  = self.db    and self.db.global
    if not pp or not rp or not ac then return end
    if rp._privateAuraBorderNamespacesMigrated then return end

    -- Each of the four scalar keys (privateAuraBorderScale, privateAuraBorderAutoScale,
    -- privateAuraBorderWidthRatio, privateAuraBorderFrameLevel) can live in either
    -- db.profile (where recent-era widgets wrote) or db.global (where the v14
    -- MigrateGlobalSettings migration relocated pre-v14 saved values for three
    -- of them: Scale, WidthRatio, FrameLevel -- AutoScale wasn't in v14's
    -- GLOBAL_KEYS list, so only db.profile applies for that one, but checking
    -- db.global is harmless). Per-profile source wins; db.global source is the
    -- fallback, and is cleared by the first profile that reads it
    -- (first-profile-wins, matching MigrateGlobalSettings semantics).
    local function pickOldValue(key, checkGlobal)
        if pp[key] ~= nil then
            local v = pp[key]
            pp[key] = nil
            return v
        elseif checkGlobal and g and g[key] ~= nil then
            local v = g[key]
            g[key] = nil
            return v
        end
        return nil
    end

    -- 1. privateAuraBorderScale -> rpDB.profile.privateAuraBorderScale
    do
        local v = pickOldValue("privateAuraBorderScale", true)
        if v ~= nil and rp.privateAuraBorderScale == nil then
            rp.privateAuraBorderScale = v
        end
    end

    -- 2. privateAuraBorderAutoScale -> acDB.profile.privateAuraBorderAutoScale
    -- (AutoScale wasn't in v14 GLOBAL_KEYS but we check db.global defensively.)
    do
        local v = pickOldValue("privateAuraBorderAutoScale", true)
        if v ~= nil and ac.privateAuraBorderAutoScale == nil then
            ac.privateAuraBorderAutoScale = v
        end
    end

    -- 3. privateAuraBorderWidthRatio -> acDB.profile.privateAuraBorderWidthRatio
    do
        local v = pickOldValue("privateAuraBorderWidthRatio", true)
        if v ~= nil and ac.privateAuraBorderWidthRatio == nil then
            ac.privateAuraBorderWidthRatio = v
        end
    end

    -- 4. privateAuraBorderFrameLevel -> acDB.profile.privateAuraBorderFrameLevel
    do
        local v = pickOldValue("privateAuraBorderFrameLevel", true)
        if v ~= nil and ac.privateAuraBorderFrameLevel == nil then
            ac.privateAuraBorderFrameLevel = v
        end
    end

    -- 5-6. Per-flat privateAuraFrameBorderScaleOverride -> acDB global collapse.
    -- First raid flat with a non-nil override wins for the Raid key; same for
    -- Party. All flat-root copies are nil'd regardless of whether their value
    -- was selected as the winner (the old model's per-flat granularity is
    -- being intentionally discarded per user decision).
    local fl = rp.layouts and rp.layouts.flatLayouts
    if type(fl) == "table" then
        for _, flat in pairs(fl) do
            if type(flat) == "table" and flat.privateAuraFrameBorderScaleOverride ~= nil then
                local dstKey
                if flat.type == "raid" then
                    dstKey = "privateAuraFrameBorderScaleRaid"
                elseif flat.type == "party" then
                    dstKey = "privateAuraFrameBorderScaleParty"
                end
                if dstKey and ac[dstKey] == nil then
                    ac[dstKey] = flat.privateAuraFrameBorderScaleOverride
                end
                flat.privateAuraFrameBorderScaleOverride = nil
            end
        end
    end

    rp._privateAuraBorderNamespacesMigrated = true
end

-- ── v29: pvpSwapDebuffsPrivate orphan repair ──────────────────────────
--
-- A previous revision of v27 MigrateAurasToSection wrote the swap value
-- to the WRONG storage path: rp.auras.pvpSwapDebuffsPrivate = true
-- (flat on the auras sub-table, using the OLD key name without the
-- Battleground suffix). The current v27 code writes to
-- rp.auras.privateAuras.pvpSwapDebuffsPrivateBattleground (nested under
-- privateAuras, with the new key name). Because the v27 sentinel
-- rp._aurasSectionMigrated is already set, v27 will never re-run on
-- affected profiles, leaving their value stranded at the old path where
-- nothing reads it.
--
-- This repair migration:
--   1. Checks for a stranded value at rp.auras.pvpSwapDebuffsPrivate
--      (the orphan path), falling back to db.profile.pvpSwapDebuffsPrivate
--      (in case the original Options_Preview.lua widget's value survived
--      the previous buggy v27 pass), then db.global.pvpSwapDebuffsPrivate
--      (v14 relocation target).
--   2. Writes it to rp.auras.privateAuras.pvpSwapDebuffsPrivateBattleground
--      (the correct global fallback location) if not already set there.
--   3. If the value is true, also seeds every raid flat's
--      flat.auras.privateAuras.pvpSwapDebuffsPrivateBattleground so
--      toggle-ON users see the correct per-flat behavior. Only seeds
--      when the per-flat slot is nil to avoid clobbering values the
--      user explicitly customized post-v27.
--   4. Nils all orphan sources.
--
-- Idempotent via rp._pvpSwapRepairedV29 sentinel on the rpDB profile.
-- Fresh installs are no-ops (no orphan, no db.profile source, no
-- db.global source).
function BF:MigratePvpSwapOrphanRepair(profileName)
    profileName = profileName or self.rpDB.keys.profile
    local rp = self.rpDB and self.rpDB.profiles and self.rpDB.profiles[profileName]
    if not rp then return end
    if rp._pvpSwapRepairedV29 then return end

    -- Source priority: orphan on rp.auras -> db.profile -> db.global.
    -- The orphan wins because it's the one the previous buggy v27 pass
    -- already "claimed" as the user's value; the other two are
    -- upstream sources that may or may not have been cleared by that
    -- same buggy pass.
    local oldVal
    if type(rp.auras) == "table" and rp.auras.pvpSwapDebuffsPrivate ~= nil then
        oldVal = rp.auras.pvpSwapDebuffsPrivate
        rp.auras.pvpSwapDebuffsPrivate = nil
    end

    local pp = self.db and self.db.profiles and self.db.profiles[profileName]
    if pp and pp.pvpSwapDebuffsPrivate ~= nil then
        if oldVal == nil then oldVal = pp.pvpSwapDebuffsPrivate end
        pp.pvpSwapDebuffsPrivate = nil
    end

    local g = self.db and self.db.global
    if g and g.pvpSwapDebuffsPrivate ~= nil then
        if oldVal == nil then oldVal = g.pvpSwapDebuffsPrivate end
        -- First profile clears db.global; subsequent profiles see nil
        -- and fall through, which is fine because db.global is shared
        -- and every profile ends up with the same seed.
        g.pvpSwapDebuffsPrivate = nil
    end

    if oldVal ~= nil then
        rp.auras                        = rp.auras                        or {}
        rp.auras.privateAuras           = rp.auras.privateAuras           or {}
        if rp.auras.privateAuras.pvpSwapDebuffsPrivateBattleground == nil then
            rp.auras.privateAuras.pvpSwapDebuffsPrivateBattleground = oldVal
        end
        if oldVal and rp.layouts and type(rp.layouts.flatLayouts) == "table" then
            for _, flat in pairs(rp.layouts.flatLayouts) do
                if type(flat) == "table" and flat.type == "raid" then
                    flat.auras              = flat.auras              or {}
                    flat.auras.privateAuras = flat.auras.privateAuras or {}
                    if flat.auras.privateAuras.pvpSwapDebuffsPrivateBattleground == nil then
                        flat.auras.privateAuras.pvpSwapDebuffsPrivateBattleground = oldVal
                    end
                end
            end
        end
    end

    rp._pvpSwapRepairedV29 = true
end

-- ============================================================
-- MigrateAuraTextToSubcats  (v30)
-- ============================================================
-- Relocates every flat-root auraText key into a nested sub-category
-- under auraText.<subcat>.<key> (stackText/global/buffs/debuffs/
-- bigDef/important/crowdControl/privateAuras), mirroring the v27
-- MigrateAurasToSection shape.
--
-- Applies to both:
--   * rp.auraText                             (the global pseudo-layout)
--   * rp.layouts.flatLayouts[*].auraText      (per-flat caches)
--
-- globalAuraTextConfig is NOT relocated; it stays at the top of the
-- auraText table (inside the section, NOT inside any sub-category).
--
-- Runs AFTER v23 (MigrateCollapseFlatDefaults) -- any auraText key
-- that was already default-equal was stripped by v23, and the
-- fallback chain (flat.auraText -> global.auraText, plus each
-- flat.auraText.<subcat> -> global.auraText.<subcat>) covers those
-- un-customized keys. v30 only relocates rawkeys that are still
-- present as flat rawkeys at the auraText top level.
--
-- Also clears the pre-v15 fossil copies in db.profile (the core DB)
-- that AuraCustomizations.lua:ResolveDurationSettings had been
-- reading from. The actual storage has lived in rp.profile.auraText
-- since v15; the core DB copies are dead reads that have been
-- returning nil for every user since v15 shipped. Clearing them
-- now prevents any future confusion about where the truth lives.
--
-- Idempotent per profile (guarded by rp._auraTextSubcatMigrated).
-- Fresh installs are no-ops (no flat-root auraText rawkeys exist).
-- ============================================================
function BF:MigrateAuraTextToSubcats(profileName)
    profileName = profileName or self.rpDB.keys.profile
    local rp = self.rpDB and self.rpDB.profiles and self.rpDB.profiles[profileName]
    if not rp then return end
    if rp._auraTextSubcatMigrated then return end

    local SUBCAT_OF = BF.AURA_TEXT_SUBCATEGORY_OF or {}

    -- Local helper: relocate every top-level auraText key whose name is
    -- in SUBCAT_OF into auraText.<subcat>.<key>. Preserves existing
    -- sub-category tables; extends them if already present.
    local function relocate(atTable)
        if type(atTable) ~= "table" then return end
        for key, subcat in pairs(SUBCAT_OF) do
            if atTable[key] ~= nil then
                atTable[subcat] = atTable[subcat] or {}
                if type(atTable[key]) == "table" then
                    atTable[subcat][key] = self:DeepCopy(atTable[key])
                else
                    atTable[subcat][key] = atTable[key]
                end
                atTable[key] = nil
            end
        end
    end

    -- 1. Global pseudo-layout.
    relocate(rp.auraText)

    -- 2. Every flat's per-flat cache.
    if rp.layouts and type(rp.layouts.flatLayouts) == "table" then
        for _, flat in pairs(rp.layouts.flatLayouts) do
            if type(flat) == "table" and type(rawget(flat, "auraText")) == "table" then
                relocate(flat.auraText)
            end
        end
    end

    -- 3. Clear pre-v15 core-DB fossil copies. These have been dead
    --    reads since v15 (AuraCustomizations.lua ResolveDurationSettings
    --    was reading them from db.profile instead of rpDB.profile). They
    --    never held the user's real value after v15, but some SavedVariables
    --    files may still carry default-written copies from pre-v15 times.
    --    Clearing them prevents any future confusion.
    local pp = self.db and self.db.profiles and self.db.profiles[profileName]
    if pp then
        pp.globalAuraTextConfig = nil
        -- Every key that is now recognized as an auraText sub-category key.
        for key in pairs(SUBCAT_OF) do
            pp[key] = nil
        end
    end

    rp._auraTextSubcatMigrated = true
end

-- ============================================================
-- MigrateRestorePerFlatAuraDefaults (v31)
-- ============================================================
-- Repairs per-flat aura divergence that was silently erased by the
-- v23 -> v27 migration sequence for a small set of aura keys where
-- the raid template and party template disagree on the default.
--
-- Background:
--   Pre-v27, aura keys lived at flat.<key> and were resolved at
--   runtime through WireFlatDefaults's __index metatable fallback
--   onto a per-flat template (CreateRaidProfile for raid flats,
--   CreatePartyProfile for party flats). For keys where the two
--   templates differ (e.g. debuffAnchorPoint: raid="LEFT",
--   party="BOTTOMLEFT"), that fallback chain correctly produced
--   different values per flat-type.
--
--   v23 MigrateCollapseFlatDefaults stripped any flat rawkey equal
--   to its template default. For users whose saved values matched
--   the relevant template, this nilled those rawkeys -- correctly
--   for the pre-v27 runtime, because the template fallback still
--   produced the right value.
--
--   v27 MigrateAurasToSection then relocated flat.<auraKey> into
--   flat.auras.<subcat>.<auraKey>. But for users whose values were
--   already nil (stripped by v23), there was nothing to move. v27
--   also enabled perLayoutToggles.auras = true, switching the aura
--   read path from "template fallback per flat" to
--   "GetSectionProfile("auras", flat)" -- which returns
--   rpDB.profile.auras (a single global shared across all flats)
--   when flat.auras has no rawkey.
--
--   Result: keys that used to resolve via the party-vs-raid-
--   differentiated template fallback now resolve via a single global
--   for all flats. Party-vs-raid divergence is lost.
--
-- Fix:
--   For each flat, seed the flat-type's template default for the 4
--   keys where the templates diverge -- BUT ONLY WHEN THE RAWKEY IS
--   MISSING from flat.auras.<subcat>. Any existing rawkey is a value
--   the user set (either pre-v27 and survived v23 because it wasn't
--   template-equal, or post-v27 via the Options UI) and MUST NOT be
--   overwritten. Uses rawget to bypass metatable fallback so we only
--   detect true rawkey presence, not inherited values from the global.
--
--     * buffs.buffSize               (raid 12, party 14)
--     * debuffs.debuffSize           (raid 12, party 14)
--     * debuffs.debuffAnchorPoint    (raid "LEFT", party "BOTTOMLEFT")
--     * privateAuras.privateAuraAnchorPoint (raid "BOTTOMLEFT", party "LEFT")
--
--   Uses GetOrCreateAurasSubCategory so the sub-category tables get
--   the second-tier metatable fallback wired in (flat.auras.<subcat>
--   -> rpDB.profile.auras.<subcat>) for un-customized keys.
--
-- Idempotent per profile (guarded by rp._aurasTemplateDivergenceRestoredV31b).
-- Note: sentinel name is _V31b -- a prior buggy revision of this
-- migration (_V31) unconditionally overwrote the 4 keys and destroyed
-- user customizations. The new sentinel ensures that any profile that
-- ran the buggy version also runs the fixed version. The fixed version
-- is safe to run over buggy-migrated data: it only fills nil rawkeys,
-- so values that the buggy pass already wrote are left alone (the user
-- would need to manually restore them via Options or SV restore).
function BF:MigrateRestorePerFlatAuraDefaults(profileName)
    profileName = profileName or self.rpDB.keys.profile
    local rp = self.rpDB and self.rpDB.profiles and self.rpDB.profiles[profileName]
    if not rp then return end
    if rp._aurasTemplateDivergenceRestoredV31b then return end

    local fl = rp.layouts and rp.layouts.flatLayouts
    if type(fl) == "table" then
        -- Per-flat-type seed values for the 4 keys where raid and party
        -- templates disagree. Keys match CreateRaidProfile /
        -- CreatePartyProfile in Defaults.lua. Any future divergence
        -- added to the templates must be mirrored here.
        local SEEDS = {
            raid = {
                buffs        = { buffSize              = 12 },
                debuffs      = { debuffSize            = 12,
                                 debuffAnchorPoint     = "LEFT" },
                privateAuras = { privateAuraAnchorPoint = "BOTTOMLEFT" },
            },
            party = {
                buffs        = { buffSize              = 14 },
                debuffs      = { debuffSize            = 14,
                                 debuffAnchorPoint     = "BOTTOMLEFT" },
                privateAuras = { privateAuraAnchorPoint = "LEFT" },
            },
        }

        for _, flat in pairs(fl) do
            if type(flat) == "table" and (flat.type == "raid" or flat.type == "party") then
                local seed = SEEDS[flat.type]
                if seed then
                    for subcat, kv in pairs(seed) do
                        local sub = self:GetOrCreateAurasSubCategory(flat, subcat)
                        if sub then
                            for k, v in pairs(kv) do
                                -- rawget bypasses the metatable fallback
                                -- to rpDB.profile.auras.<subcat>, so we
                                -- only detect true rawkeys on this flat
                                -- (not inherited global values). If the
                                -- user never customized this key on this
                                -- flat, rawget returns nil and we seed
                                -- the template default.
                                if rawget(sub, k) == nil then
                                    sub[k] = v
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    rp._aurasTemplateDivergenceRestoredV31b = true
end

-- ============================================================
-- MigrateColorAuraBorder (v33)
-- ============================================================
-- Collapses the two separate `<prefix>ThresholdBorderEnabled` and
-- `<prefix>Threshold2BorderEnabled` toggles into a single new
-- `<prefix>ColorAuraBorder` toggle for global / buffs / bigDef / (and
-- new-for-v33) important, plus the per-container `thresholdBorderEnabled`
-- and `threshold2BorderEnabled` fields into a single per-container
-- `colorAuraBorder`.
--
-- Merge policy per destination key:
--   new<prefix>ColorAuraBorder = old<prefix>ThresholdBorderEnabled
--                             OR old<prefix>Threshold2BorderEnabled
--
-- So any user who had either of the pre-v33 toggles on (primary or
-- secondary) has the new unified toggle on. Users with both off stay
-- at the default (false / absent).
--
-- Applies to:
--   1. rp.auraText.<subcat>.<key>           (global pseudo-layout)
--   2. rp.layouts.flatLayouts[*].auraText.<subcat>.<key> (per-flat)
--   3. acDB.customBuffContainers[*]         (custom buff containers)
--
-- The old keys are nilled after relocation so SavedVariables stays tidy.
--
-- Debuffs are explicitly excluded from this migration: they already have
-- hidden no-op widgets flagged "Removed for performance" and are out of
-- scope per the v33 design (deferred to a follow-up restructure).
-- Crowd control is similarly out of scope.
--
-- Idempotent per profile via rp._colorAuraBorderMigratedV33 on the rpDB
-- profile, and via acp._colorAuraBorderMigratedV33 on the acDB profile
-- (containers live in acDB, so the container relocation runs under a
-- separate sentinel on the acDB side).
-- ============================================================
function BF:MigrateColorAuraBorderRP(profileName)
    profileName = profileName or self.rpDB.keys.profile
    local rp = self.rpDB and self.rpDB.profiles and self.rpDB.profiles[profileName]
    if not rp then return end
    if rp._colorAuraBorderMigratedV33 then return end

    -- Local helper: collapse the two old toggles into the new one on a
    -- single sub-category table. Only writes the new key when at least
    -- one old rawkey existed, so flats that never customized either
    -- toggle stay sparse (AceDB will still strip default-false on logout,
    -- but migration keeps the flat clean from day one).
    local PREFIX_MAP = {
        global    = "global",
        buffs     = "buff",
        bigDef    = "bigDef",
        important = "important",
    }

    local function relocateOne(subTable, prefix)
        if type(subTable) ~= "table" then return end
        local oldPrimary   = rawget(subTable, prefix .. "ThresholdBorderEnabled")
        local oldSecondary = rawget(subTable, prefix .. "Threshold2BorderEnabled")
        local hasOld = (oldPrimary ~= nil) or (oldSecondary ~= nil)
        if hasOld then
            local newVal = (oldPrimary == true) or (oldSecondary == true)
            local newKey = prefix .. "ColorAuraBorder"
            -- Only write when true -- false is the default, and writing it
            -- would just add a default-equal rawkey that AceDB strips on
            -- logout anyway. rawget bypasses the metatable fallback so we
            -- only check true rawkeys on this sub-table.
            if newVal and rawget(subTable, newKey) == nil then
                subTable[newKey] = true
            end
            -- Nil the old keys unconditionally.
            subTable[prefix .. "ThresholdBorderEnabled"]  = nil
            subTable[prefix .. "Threshold2BorderEnabled"] = nil
        end
    end

    -- 1. Global pseudo-layout (rp.auraText.<subcat>).
    if type(rp.auraText) == "table" then
        for subcat, prefix in pairs(PREFIX_MAP) do
            relocateOne(rawget(rp.auraText, subcat), prefix)
        end
    end

    -- 2. Per-flat caches (flat.auraText.<subcat>).
    if rp.layouts and type(rp.layouts.flatLayouts) == "table" then
        for _, flat in pairs(rp.layouts.flatLayouts) do
            if type(flat) == "table" and type(rawget(flat, "auraText")) == "table" then
                for subcat, prefix in pairs(PREFIX_MAP) do
                    relocateOne(rawget(flat.auraText, subcat), prefix)
                end
            end
        end
    end

    rp._colorAuraBorderMigratedV33 = true
end

-- Companion migration for the acDB (custom buff containers).
-- Each container has its own per-container border toggles:
--   thresholdBorderEnabled  (primary)
--   threshold2BorderEnabled (secondary)
-- Collapsed into a single colorAuraBorder per container.
-- Also walks any per-group-type override entry (container.groupSettings[*])
-- since the same two fields can live there when separateGroupConfig is on.
function BF:MigrateColorAuraBorderAC(profileName)
    profileName = profileName or self.acDB.keys.profile
    local acp = self.acDB and self.acDB.profiles and self.acDB.profiles[profileName]
    if not acp then return end
    if acp._colorAuraBorderMigratedV33 then return end

    local function relocateContainerLevel(t)
        if type(t) ~= "table" then return end
        local oldPrimary   = t.thresholdBorderEnabled
        local oldSecondary = t.threshold2BorderEnabled
        if oldPrimary ~= nil or oldSecondary ~= nil then
            local newVal = (oldPrimary == true) or (oldSecondary == true)
            if newVal and t.colorAuraBorder == nil then
                t.colorAuraBorder = true
            end
            t.thresholdBorderEnabled  = nil
            t.threshold2BorderEnabled = nil
        end
    end

    if type(acp.customBuffContainers) == "table" then
        for _, c in pairs(acp.customBuffContainers) do
            if type(c) == "table" then
                -- Top-level container fields.
                relocateContainerLevel(c)
                -- Per-group-type override entries.
                if type(c.groupSettings) == "table" then
                    for _, gs in pairs(c.groupSettings) do
                        relocateContainerLevel(gs)
                    end
                end
            end
        end
    end

    acp._colorAuraBorderMigratedV33 = true
end

-- ── v34: Migrate dispelIndicatorMode + dispelDotOnlyIfReady ───────────
--        from borders section → auras.dispelIndicator section
--
-- Old keys (borders section):
--   dispelIndicatorMode   ("dispellable" | "allDispellable")
--   dispelDotOnlyIfReady  (boolean)
--
-- New keys (auras.dispelIndicator sub-category):
--   dispelIndicatorMode          (same name, new location)
--   dispelIndicatorOnlyIfReady   (renamed from dispelDotOnlyIfReady)
--
-- Migration rules:
--   • If per-layout borders was ON: each flat had its own borders values.
--     Migrate each flat's per-flat borders values into each flat's
--     auras.dispelIndicator. If per-layout auras was OFF, turn it ON
--     so the per-flat values are actually consumed (otherwise they'd be
--     hidden behind the global auras fallback). Also seed the global
--     auras.dispelIndicator from the global borders as a fallback.
--   • If per-layout borders was OFF: migrate global borders values into
--     global auras.dispelIndicator. If per-layout auras IS on, seed
--     every flat's auras.dispelIndicator with the global borders values
--     so existing per-flat aura configs get the user's chosen values.
--
-- Idempotent via rp._dispelIndicatorToAurasMigratedV34.
function BF:MigrateDispelIndicatorToAuras(profileName)
    profileName = profileName or self.rpDB.keys.profile
    local rp = self.rpDB.profiles[profileName]
    if not rp then return end
    if rp._dispelIndicatorToAurasMigratedV34 then return end

    rp.layouts = rp.layouts or {}
    local perLayoutToggles = rp.layouts.perLayoutToggles or {}
    local perLayoutBorders = perLayoutToggles.borders or false
    local perLayoutAuras   = perLayoutToggles.auras   or false
    local fl = rp.layouts.flatLayouts

    -- Helper: read old keys from a borders sub-table, write new keys
    -- into an auras.dispelIndicator sub-table, nil old keys.
    local function migrateKeys(src, dst)
        if not src then return end
        if src.dispelIndicatorMode ~= nil then
            dst.dispelIndicatorMode = src.dispelIndicatorMode
            src.dispelIndicatorMode = nil
        end
        if src.dispelDotOnlyIfReady ~= nil then
            dst.dispelIndicatorOnlyIfReady = src.dispelDotOnlyIfReady
            src.dispelDotOnlyIfReady = nil
        end
    end

    -- 1. Migrate global borders → global auras.dispelIndicator.
    rp.borders = rp.borders or {}
    rp.auras   = rp.auras   or {}
    rp.auras.dispelIndicator = rp.auras.dispelIndicator or {}
    migrateKeys(rp.borders, rp.auras.dispelIndicator)

    -- 2. Per-flat migration.
    if type(fl) == "table" then
        if perLayoutBorders then
            -- User had per-flat borders: each flat may have its own values.
            -- Migrate each flat's borders values into its auras.dispelIndicator.
            for _, flat in pairs(fl) do
                if type(flat) == "table" and flat.borders then
                    flat.auras = flat.auras or {}
                    flat.auras.dispelIndicator = flat.auras.dispelIndicator or {}
                    migrateKeys(flat.borders, flat.auras.dispelIndicator)
                end
            end
            -- If per-layout auras was OFF, turn it ON so the per-flat values
            -- we just wrote are actually consumed at runtime.
            if not perLayoutAuras then
                rp.layouts.perLayoutToggles = rp.layouts.perLayoutToggles or {}
                rp.layouts.perLayoutToggles.auras = true
            end
        else
            -- Per-layout borders was OFF: the global value is canonical.
            -- If per-layout auras is ON, seed every flat's
            -- auras.dispelIndicator with the global values so the user
            -- sees the same behavior they had before.
            if perLayoutAuras then
                local globalMode    = rp.auras.dispelIndicator.dispelIndicatorMode
                local globalOnlyIf  = rp.auras.dispelIndicator.dispelIndicatorOnlyIfReady
                for _, flat in pairs(fl) do
                    if type(flat) == "table" then
                        flat.auras = flat.auras or {}
                        flat.auras.dispelIndicator = flat.auras.dispelIndicator or {}
                        local di = flat.auras.dispelIndicator
                        if di.dispelIndicatorMode == nil and globalMode ~= nil then
                            di.dispelIndicatorMode = globalMode
                        end
                        if di.dispelIndicatorOnlyIfReady == nil and globalOnlyIf ~= nil then
                            di.dispelIndicatorOnlyIfReady = globalOnlyIf
                        end
                    end
                end
            end
            -- Also nil any stale per-flat borders copies (shouldn't exist
            -- when per-layout borders was OFF, but be safe).
            for _, flat in pairs(fl) do
                if type(flat) == "table" and flat.borders then
                    flat.borders.dispelIndicatorMode = nil
                    flat.borders.dispelDotOnlyIfReady = nil
                end
            end
        end
    end

    rp._dispelIndicatorToAurasMigratedV34 = true
end


-- ── v35: Migrate debuff highlight + overlay keys from borders → auras ──
--        auras.dispelIndicator sub-category
--
-- Old keys (borders section):
--   enableDebuffBorder / debuffBorderMode / debuffBorderWidth
--   enableDebuffOverlay / debuffOverlayStyle / debuffOverlayMode
--   debuffOverlayAlpha / debuffOverlayHeight / debuffOverlayFillOnly
--   dispelBorderOnlyIfReady / dispelOverlayOnlyIfReady
--   privateAuraDispelOverlayMode
--
-- New keys (auras.dispelIndicator sub-category):
--   Same names, new location -- EXCEPT privateAuraDispelOverlayMode is
--   renamed to blizzardDispelOverlayMode since under the new UI the widget
--   drives the Blizzard-style dispel overlay in the Dispel Indicator tab,
--   not a private-aura-specific setting.
--
-- Migration rules mirror v34 (MigrateDispelIndicatorToAuras):
--   • If per-layout borders was ON: each flat had its own borders values.
--     Migrate each flat's per-flat borders values into its
--     auras.dispelIndicator. If per-layout auras was OFF, turn it ON so
--     the per-flat values are actually consumed. Also seed the global
--     auras.dispelIndicator from the global borders as a fallback.
--   • If per-layout borders was OFF: migrate global borders values into
--     global auras.dispelIndicator. If per-layout auras IS on, seed every
--     flat's auras.dispelIndicator with the global borders values so
--     existing per-flat aura configs get the user's chosen values.
--
-- Idempotent via rp._debuffHighlightToAurasMigratedV35.
function BF:MigrateDebuffHighlightToAuras(profileName)
    profileName = profileName or self.rpDB.keys.profile
    local rp = self.rpDB.profiles[profileName]
    if not rp then return end
    if rp._debuffHighlightToAurasMigratedV35 then return end

    rp.layouts = rp.layouts or {}
    local perLayoutToggles = rp.layouts.perLayoutToggles or {}
    local perLayoutBorders = perLayoutToggles.borders or false
    local perLayoutAuras   = perLayoutToggles.auras   or false
    local fl = rp.layouts.flatLayouts

    -- 11 same-name keys + 1 rename. Same-name keys are listed here; the
    -- rename is handled inline below with an explicit src/dst key pair.
    local SAME_NAME_KEYS = {
        "enableDebuffBorder",      "debuffBorderMode",    "debuffBorderWidth",
        "enableDebuffOverlay",     "debuffOverlayStyle",  "debuffOverlayMode",
        "debuffOverlayAlpha",      "debuffOverlayHeight", "debuffOverlayFillOnly",
        "dispelBorderOnlyIfReady", "dispelOverlayOnlyIfReady",
    }

    -- Helper: read old keys from a borders sub-table, write new keys
    -- into an auras.dispelIndicator sub-table, nil old keys. Handles the
    -- same-name bulk + the one rename.
    local function migrateKeys(src, dst)
        if not src then return end
        for _, key in ipairs(SAME_NAME_KEYS) do
            if src[key] ~= nil then
                dst[key] = src[key]
                src[key] = nil
            end
        end
        -- Rename: privateAuraDispelOverlayMode -> blizzardDispelOverlayMode.
        -- Only write the destination key when it's not already set, so we
        -- never clobber a value the user might have set post-migration
        -- (defensive against re-runs on already-partial data).
        if src.privateAuraDispelOverlayMode ~= nil then
            if dst.blizzardDispelOverlayMode == nil then
                dst.blizzardDispelOverlayMode = src.privateAuraDispelOverlayMode
            end
            src.privateAuraDispelOverlayMode = nil
        end
    end

    -- 1. Migrate global borders → global auras.dispelIndicator.
    rp.borders = rp.borders or {}
    rp.auras   = rp.auras   or {}
    rp.auras.dispelIndicator = rp.auras.dispelIndicator or {}
    migrateKeys(rp.borders, rp.auras.dispelIndicator)

    -- 2. Per-flat migration.
    if type(fl) == "table" then
        if perLayoutBorders then
            -- User had per-flat borders: each flat may have its own values.
            -- Migrate each flat's borders values into its auras.dispelIndicator.
            for _, flat in pairs(fl) do
                if type(flat) == "table" and flat.borders then
                    flat.auras = flat.auras or {}
                    flat.auras.dispelIndicator = flat.auras.dispelIndicator or {}
                    migrateKeys(flat.borders, flat.auras.dispelIndicator)
                end
            end
            -- If per-layout auras was OFF, turn it ON so the per-flat values
            -- we just wrote are actually consumed at runtime.
            if not perLayoutAuras then
                rp.layouts.perLayoutToggles = rp.layouts.perLayoutToggles or {}
                rp.layouts.perLayoutToggles.auras = true
            end
        else
            -- Per-layout borders was OFF: the global value is canonical.
            -- If per-layout auras is ON, seed every flat's
            -- auras.dispelIndicator with the global values so the user
            -- sees the same behavior they had before.
            if perLayoutAuras then
                local globalDI = rp.auras.dispelIndicator
                for _, flat in pairs(fl) do
                    if type(flat) == "table" then
                        flat.auras = flat.auras or {}
                        flat.auras.dispelIndicator = flat.auras.dispelIndicator or {}
                        local di = flat.auras.dispelIndicator
                        for _, key in ipairs(SAME_NAME_KEYS) do
                            if di[key] == nil and globalDI[key] ~= nil then
                                di[key] = globalDI[key]
                            end
                        end
                        if di.blizzardDispelOverlayMode == nil
                           and globalDI.blizzardDispelOverlayMode ~= nil then
                            di.blizzardDispelOverlayMode = globalDI.blizzardDispelOverlayMode
                        end
                    end
                end
            end
            -- Also nil any stale per-flat borders copies (shouldn't exist
            -- when per-layout borders was OFF, but be safe).
            for _, flat in pairs(fl) do
                if type(flat) == "table" and flat.borders then
                    for _, key in ipairs(SAME_NAME_KEYS) do
                        flat.borders[key] = nil
                    end
                    flat.borders.privateAuraDispelOverlayMode = nil
                end
            end
        end
    end

    rp._debuffHighlightToAurasMigratedV35 = true
end

-- ── v36: Rename showBlizzardDispelIndicator (bool) → ───────────────────
--        dispelIndicatorOverlayMode (string) under auras.dispelIndicator.
--
-- The boolean master toggle for Blizzard's native dispel icons + overlay
-- was replaced by a two-option dropdown with string values:
--   showBlizzardDispelIndicator == true  → dispelIndicatorOverlayMode = "blizzard"
--   showBlizzardDispelIndicator == false → dispelIndicatorOverlayMode = "custom"
--   showBlizzardDispelIndicator == nil   → (leave new key nil → defaults to "custom")
--
-- Only "blizzard" is written. The "custom" value is the default so we leave
-- the new key nil when the old value was false or absent -- AceDB would strip
-- default-equal rawkeys at logout anyway, and not writing them keeps the
-- sparse-storage pattern clean.
--
-- The old key is nil'd on every table we touch regardless of its value so
-- there's no leftover cruft in SavedVariables.
--
-- Applies to:
--   1. rp.auras.dispelIndicator                     (global pseudo-layout)
--   2. rp.layouts.flatLayouts[*].auras.dispelIndicator (per-flat caches)
--
-- Uses rawget on the per-flat sub-tables so we only see keys that were
-- actually written by the user (not values inherited via the metatable
-- fallback to the global). That means a flat which never customized the
-- toggle stays sparse, and the new key falls through to whatever the
-- global resolves to.
--
-- Idempotent per profile (guarded by rp._dispelIndicatorOverlayModeMigratedV36).
-- Fresh installs are no-ops -- nothing has the old key set.
function BF:MigrateDispelIndicatorOverlayMode(profileName)
    profileName = profileName or self.rpDB.keys.profile
    local rp = self.rpDB and self.rpDB.profiles and self.rpDB.profiles[profileName]
    if not rp then return end
    if rp._dispelIndicatorOverlayModeMigratedV36 then return end

    -- Helper: rename the key on one dispelIndicator sub-table.
    -- `useRawget` controls whether we detect only true rawkeys (per-flat
    -- sub-tables that have a metatable fallback to the global) or all keys
    -- (the global itself, which has no such fallback).
    local function renameOn(di, useRawget)
        if type(di) ~= "table" then return end
        local oldVal
        if useRawget then
            oldVal = rawget(di, "showBlizzardDispelIndicator")
        else
            oldVal = di.showBlizzardDispelIndicator
        end
        if oldVal == nil then return end
        -- Only write "blizzard" -- "custom" is the default, and leaving it
        -- unwritten matches sparse-storage convention.
        if oldVal == true and rawget(di, "dispelIndicatorOverlayMode") == nil then
            di.dispelIndicatorOverlayMode = "blizzard"
        end
        di.showBlizzardDispelIndicator = nil
    end

    -- 1. Global pseudo-layout.
    if type(rp.auras) == "table" then
        renameOn(rp.auras.dispelIndicator, false)
    end

    -- 2. Per-flat caches.
    local fl = rp.layouts and rp.layouts.flatLayouts
    if type(fl) == "table" then
        for _, flat in pairs(fl) do
            if type(flat) == "table" and type(rawget(flat, "auras")) == "table" then
                local aurasT = rawget(flat, "auras")
                renameOn(rawget(aurasT, "dispelIndicator"), true)
            end
        end
    end

    rp._dispelIndicatorOverlayModeMigratedV36 = true
end

-- ============================================================
-- MigrateRemovePvpSwap (v37)
-- ============================================================
-- Final cleanup: nils every saved value of the now-removed
-- pvpSwapDebuffsPrivateBattleground / pvpSwapDebuffsPrivateParty
-- (and the legacy pvpSwapDebuffsPrivate / SwapDebuffsPrivate keys)
-- from every location they could have been written to over the
-- lifetime of the feature.
--
-- The swap feature has been deleted entirely (runtime block removed
-- from Auras/AuraConfig.lua, widgets commented out in Options_Auras.lua,
-- defaults removed from Defaults_RaidPartyFrames.lua, and the keys
-- removed from BF.AURAS_SUBCATEGORY_OF in Core_ProfileAPI.lua). Nothing
-- in the live code reads these keys anymore, but stripping them from
-- SavedVariables keeps the on-disk profile clean and prevents any
-- future mistake from reactivating a stranded value.
--
-- Locations cleared per profile (all unconditional, all idempotent):
--   1. db.profile.pvpSwapDebuffsPrivate                    (legacy v14-)
--   2. db.global.pvpSwapDebuffsPrivate                     (v14 relocation)
--   3. rp.auras.pvpSwapDebuffsPrivate                      (v27 orphan path)
--   4. rp.auras.privateAuras.pvpSwapDebuffsPrivateBattleground
--   5. rp.auras.privateAuras.pvpSwapDebuffsPrivateParty
--   6. Every flat in rp.layouts.flatLayouts:
--      * flat.pvpSwapDebuffsPrivate*                       (pre-v27 root)
--      * flat.auras.pvpSwapDebuffsPrivate                  (v27 orphan)
--      * flat.auras.privateAuras.pvpSwapDebuffsPrivateBattleground
--      * flat.auras.privateAuras.pvpSwapDebuffsPrivateParty
--
-- db.global is shared across all profiles, so the first profile to run
-- this migration clears it. Subsequent profiles see nil and skip that
-- branch, which is fine.
--
-- Idempotent per profile (guarded by rp._pvpSwapRemovedV37). Fresh
-- installs are no-ops because none of the cleared paths ever had
-- values written to them.
function BF:MigrateRemovePvpSwap(profileName)
    profileName = profileName or self.rpDB.keys.profile
    local rp = self.rpDB and self.rpDB.profiles and self.rpDB.profiles[profileName]
    if not rp then return end
    if rp._pvpSwapRemovedV37 then return end

    -- 1. Core db.profile (legacy pre-v14 location).
    local pp = self.db and self.db.profiles and self.db.profiles[profileName]
    if pp then
        pp.pvpSwapDebuffsPrivate             = nil
        pp.pvpSwapDebuffsPrivateBattleground = nil
        pp.pvpSwapDebuffsPrivateParty        = nil
    end

    -- 2. db.global (v14 relocation target). Shared across profiles;
    -- whichever profile gets here first nils it, the rest see nil.
    local g = self.db and self.db.global
    if g then
        g.pvpSwapDebuffsPrivate             = nil
        g.pvpSwapDebuffsPrivateBattleground = nil
        g.pvpSwapDebuffsPrivateParty        = nil
    end

    -- 3-5. rp global pseudo-layout: orphan path + correct nested path.
    if type(rp.auras) == "table" then
        rp.auras.pvpSwapDebuffsPrivate             = nil  -- v27 buggy orphan
        rp.auras.pvpSwapDebuffsPrivateBattleground = nil  -- never canonical, defensive
        rp.auras.pvpSwapDebuffsPrivateParty        = nil  -- never canonical, defensive
        if type(rp.auras.privateAuras) == "table" then
            rp.auras.privateAuras.pvpSwapDebuffsPrivateBattleground = nil
            rp.auras.privateAuras.pvpSwapDebuffsPrivateParty        = nil
            -- And the unsuffixed legacy key in case any pre-v27 path wrote it here.
            rp.auras.privateAuras.pvpSwapDebuffsPrivate             = nil
        end
    end

    -- 6. Every flat: root, flat.auras, flat.auras.privateAuras.
    local fl = rp.layouts and rp.layouts.flatLayouts
    if type(fl) == "table" then
        for _, flat in pairs(fl) do
            if type(flat) == "table" then
                -- Pre-v27 root location.
                flat.pvpSwapDebuffsPrivate             = nil
                flat.pvpSwapDebuffsPrivateBattleground = nil
                flat.pvpSwapDebuffsPrivateParty        = nil
                -- Use rawget so we don't pierce the metatable fallback
                -- and accidentally materialize an empty flat.auras on a
                -- pristine flat that was inheriting via __index. We only
                -- need to clean rawkeys that actually exist on the flat.
                local fa = rawget(flat, "auras")
                if type(fa) == "table" then
                    fa.pvpSwapDebuffsPrivate             = nil  -- v27 buggy orphan
                    fa.pvpSwapDebuffsPrivateBattleground = nil
                    fa.pvpSwapDebuffsPrivateParty        = nil
                    local fpa = rawget(fa, "privateAuras")
                    if type(fpa) == "table" then
                        fpa.pvpSwapDebuffsPrivateBattleground = nil
                        fpa.pvpSwapDebuffsPrivateParty        = nil
                        fpa.pvpSwapDebuffsPrivate             = nil
                    end
                end
            end
        end
    end

    rp._pvpSwapRemovedV37 = true
end

-- ============================================================
-- MigrateCFGToFlatStructure
--
-- Restructures each Custom Frame Group to use a flat-layout-style
-- table (group.flat) with the same structure as raid flats in
-- rpDB.profile.layouts.flatLayouts. This enables CFGs to share
-- options code with Raid/Party Frames and to eventually support
-- the per-layout toggle system.
--
-- For each group:
--   1. Creates group.flat = { name, type="raid", anchorX, anchorY }
--   2. Migrates frame keys: cfFrameWidth → flat.frameWidth, etc.
--   3. Migrates layout/sorting keys into flat.sorting:
--      cfGrowDirection → sorting.raidGrowDirection, etc.
--      NOTE: sortingMode and strictGroupLayout are intentionally
--      absent — see comments in the sorting block below.
--   4. Migrates aura keys into flat.auras.<subcategory>:
--      buffSize → auras.buffs.buffSize, etc.
--      moduleShow* keys are renamed to their standard equivalents
--      (e.g. moduleShowBuffs → auras.buffs.showBuffs).
--   5. Cleans up old keys from the group table.
--
-- Idempotent: skips groups that already have group.flat.
-- ============================================================
function BF:MigrateCFGToFlatStructure()
    if not self.cfgDB then return end

    for _, cfgName in ipairs(self.cfgDB:GetProfiles()) do
        local cfgp = self.cfgDB.profiles[cfgName]
        if cfgp and cfgp.customFrameGroups then
            for _, group in pairs(cfgp.customFrameGroups) do
                if type(group) == "table" and not group.flat then
                    local flat = {
                        name    = group.name or "Custom",
                        type    = "raid",
                        anchorX = group.anchorX,
                        anchorY = group.anchorY,
                    }

                    -- ── Frame keys ────────────────────────────────────
                    flat.frameWidth      = group.cfFrameWidth
                    flat.frameHeight     = group.cfFrameHeight
                    flat.frameSpacingH   = group.cfFrameSpacingH
                    flat.frameSpacingV   = group.cfFrameSpacingV
                    flat.enableFrameScale = group.cfEnableFrameScale
                    flat.frameScale      = group.cfFrameScale
                    flat.scaleIndicators = group.cfScaleIndicators
                    -- raidLayoutAnchor: the raid flat equivalent of
                    -- cfgLayoutAnchor. Used by shared options code.
                    flat.raidLayoutAnchor = group.cfgLayoutAnchor

                    -- ── Sorting sub-table ─────────────────────────────
                    -- Mirrors the rpDB.profile.sorting structure so CFG
                    -- flats can use the same section-fallback wiring and
                    -- eventually the per-layout toggle system.
                    --
                    -- INTENTIONALLY ABSENT from CFG sorting:
                    --   sortingMode — Raid flats use this to choose
                    --     between GROUP / ROLE / CLASS sorting of the
                    --     SecureGroupHeader. CFGs don't use this because
                    --     they manage their own unit composition via
                    --     role/class/name-list filters on the group table.
                    --   strictGroupLayout — Raid flats use this to force
                    --     empty slots when a raid group has fewer than
                    --     unitsPerColumn members. CFGs don't use this
                    --     because their unit list is already filtered and
                    --     doesn't map to raid groups.
                    --   strictGroupSortBy — Accompanies strictGroupLayout;
                    --     not applicable for the same reason.
                    --   hideSelf / groupOrderingMode — Party-only sorting
                    --     keys that don't apply to CFGs.
                    flat.sorting = {
                        raidGrowDirection          = group.cfGrowDirection,
                        raidSecondaryGrowDirection = group.cfSecondaryGrowDirection,
                        unitsPerColumn             = group.cfUnitsPerColumn,
                        maxColumns                 = group.cfMaxColumns,
                        -- maxColumns is CFG-specific. Raid flats use
                        -- maxColumns = "auto" (computed from instance
                        -- player count). CFGs use a fixed integer because
                        -- their unit count is determined by filters, not
                        -- by instance type.
                    }

                    -- ── Aura sub-categories ───────────────────────────
                    -- Mirrors the rpDB flat.auras.<subcategory> structure.
                    -- The AURAS_SUBCATEGORY_OF map defines which keys
                    -- belong to which sub-category. moduleShow* keys are
                    -- renamed to their standard show* equivalents.
                    flat.auras = {
                        buffs = {
                            showBuffs         = (group.moduleShowBuffs == nil) and true or group.moduleShowBuffs,
                            buffSize          = group.buffSize,
                            maxBuffs          = group.maxBuffs,
                            buffsPerRow       = group.buffsPerRow,
                            buffAnchorPoint   = group.buffAnchorPoint,
                            buffOffsetX       = group.buffOffsetX,
                            buffOffsetY       = group.buffOffsetY,
                            buffGrowDirection = group.buffGrowDirection,
                            buffSpacing       = group.buffSpacing,
                            buffRowSpacing    = group.buffRowSpacing,
                        },
                        debuffs = {
                            showDebuffs         = (group.moduleShowDebuffs == nil) and true or group.moduleShowDebuffs,
                            debuffSize          = group.debuffSize,
                            maxDebuffs          = group.maxDebuffs,
                            debuffsPerRow       = group.debuffsPerRow,
                            debuffAnchorPoint   = group.debuffAnchorPoint,
                            debuffOffsetX       = group.debuffOffsetX,
                            debuffOffsetY       = group.debuffOffsetY,
                            debuffGrowDirection = group.debuffGrowDirection,
                            debuffSpacing       = group.debuffSpacing,
                            debuffRowSpacing    = group.debuffRowSpacing,
                        },
                        privateAuras = {
                            showPrivateAuras        = (group.moduleShowPrivateAuras == nil) and true or group.moduleShowPrivateAuras,
                            privateAuraSize         = group.privateAuraSize,
                            maxPrivateAuras         = group.maxPrivateAuras,
                            privateAuraAnchorPoint  = group.privateAuraAnchorPoint,
                            privateAuraOffsetX      = group.privateAuraOffsetX,
                            privateAuraOffsetY      = group.privateAuraOffsetY,
                            privateAuraGrowDirection = group.privateAuraGrowDirection,
                        },
                        bigDef = {
                            showBigDef          = (group.moduleShowBigDef == nil) and false or group.moduleShowBigDef,
                            bigDefSize          = group.bigDefSize,
                            bigDefMaxCount      = group.bigDefMaxCount,
                            bigDefShowGlow      = group.bigDefShowGlow,
                            bigDefAnchor        = group.bigDefAnchor,
                            bigDefOffsetX       = group.bigDefOffsetX,
                            bigDefOffsetY       = group.bigDefOffsetY,
                            bigDefGrowDirection = group.bigDefGrowDirection,
                            bigDefIconsPerRow   = group.bigDefIconsPerRow,
                            bigDefSpacing       = group.bigDefSpacing,
                            bigDefRowSpacing    = group.bigDefRowSpacing,
                        },
                        important = {
                            showImportant          = (group.moduleShowImportant == nil) and false or group.moduleShowImportant,
                            importantSize          = group.importantSize,
                            importantMaxCount      = group.importantMaxCount,
                            importantShowGlow      = group.importantShowGlow,
                            importantAnchor        = group.importantAnchor,
                            importantOffsetX       = group.importantOffsetX,
                            importantOffsetY       = group.importantOffsetY,
                            importantGrowDirection = group.importantGrowDirection,
                            importantIconsPerRow   = group.importantIconsPerRow,
                            importantSpacing       = group.importantSpacing,
                            importantRowSpacing    = group.importantRowSpacing,
                        },
                        crowdControl = {
                            showCrowdControl          = (group.moduleShowCrowdControl == nil) and false or group.moduleShowCrowdControl,
                            crowdControlSize          = group.crowdControlSize,
                            crowdControlMaxIcons      = group.crowdControlMaxIcons,
                            crowdControlShowGlow      = group.crowdControlShowGlow,
                            crowdControlAnchor        = group.crowdControlAnchor,
                            crowdControlOffsetX       = group.crowdControlOffsetX,
                            crowdControlOffsetY       = group.crowdControlOffsetY,
                            -- Fall back to abbreviated widget key names (ccGrowDirection,
                            -- ccIconsPerRow) from a pre-v43 bug where the options UI stored
                            -- these under shortened names instead of the full names.
                            crowdControlGrowDirection = group.crowdControlGrowDirection or group.ccGrowDirection,
                            crowdControlIconsPerRow   = group.crowdControlIconsPerRow or group.ccIconsPerRow,
                            crowdControlSpacing       = group.crowdControlSpacing,
                            crowdControlRowSpacing    = group.crowdControlRowSpacing,
                        },
                        dispelIndicator = {
                            showDispelIndicator       = group.showDispelIndicator,
                            dispelIndicatorStyle      = group.dispelIndicatorStyle,
                            dispelIndicatorSize       = group.dispelIndicatorSize,
                            dispelIndicatorPosition   = group.dispelIndicatorPosition,
                            dispelIndicatorOffsetX    = group.dispelIndicatorOffsetX,
                            dispelIndicatorOffsetY    = group.dispelIndicatorOffsetY,
                        },
                    }

                    group.flat = flat

                    -- ── Clean up old keys ─────────────────────────────
                    -- Frame keys
                    group.cfFrameWidth      = nil
                    group.cfFrameHeight     = nil
                    group.cfFrameSpacingH   = nil
                    group.cfFrameSpacingV   = nil
                    group.cfEnableFrameScale = nil
                    group.cfFrameScale      = nil
                    group.cfScaleIndicators = nil
                    group.cfgLayoutAnchor   = nil
                    -- Sorting keys (renamed to raid flat equivalents)
                    group.cfGrowDirection          = nil
                    group.cfSecondaryGrowDirection = nil
                    group.cfUnitsPerColumn         = nil
                    group.cfMaxColumns             = nil
                    -- Position keys (moved into flat invariants)
                    group.anchorX = nil
                    group.anchorY = nil
                    -- Aura keys (moved into flat.auras sub-categories)
                    group.moduleShowBuffs    = nil
                    group.buffSize           = nil
                    group.maxBuffs           = nil
                    group.buffsPerRow        = nil
                    group.buffAnchorPoint    = nil
                    group.buffOffsetX        = nil
                    group.buffOffsetY        = nil
                    group.buffGrowDirection  = nil
                    group.buffSpacing        = nil
                    group.buffRowSpacing     = nil
                    group.moduleShowDebuffs  = nil
                    group.debuffSize         = nil
                    group.maxDebuffs         = nil
                    group.debuffsPerRow      = nil
                    group.debuffAnchorPoint  = nil
                    group.debuffOffsetX      = nil
                    group.debuffOffsetY      = nil
                    group.debuffGrowDirection = nil
                    group.debuffSpacing      = nil
                    group.debuffRowSpacing   = nil
                    group.moduleShowPrivateAuras   = nil
                    group.privateAuraSize          = nil
                    group.maxPrivateAuras          = nil
                    group.privateAuraAnchorPoint   = nil
                    group.privateAuraOffsetX       = nil
                    group.privateAuraOffsetY       = nil
                    group.privateAuraGrowDirection = nil
                    group.moduleShowBigDef    = nil
                    group.showBigDef          = nil
                    group.bigDefSize          = nil
                    group.bigDefMaxCount      = nil
                    group.bigDefShowGlow      = nil
                    group.bigDefAnchor        = nil
                    group.bigDefOffsetX       = nil
                    group.bigDefOffsetY       = nil
                    group.bigDefGrowDirection = nil
                    group.bigDefIconsPerRow   = nil
                    group.bigDefSpacing       = nil
                    group.bigDefRowSpacing    = nil
                    group.moduleShowImportant    = nil
                    group.showImportant          = nil
                    group.importantSize          = nil
                    group.importantMaxCount      = nil
                    group.importantShowGlow      = nil
                    group.importantAnchor        = nil
                    group.importantOffsetX       = nil
                    group.importantOffsetY       = nil
                    group.importantGrowDirection = nil
                    group.importantIconsPerRow   = nil
                    group.importantSpacing       = nil
                    group.importantRowSpacing    = nil
                    group.moduleShowCrowdControl    = nil
                    group.showCrowdControl          = nil
                    group.crowdControlSize          = nil
                    group.crowdControlMaxIcons      = nil
                    group.crowdControlShowGlow      = nil
                    group.crowdControlAnchor        = nil
                    group.crowdControlOffsetX       = nil
                    group.crowdControlOffsetY       = nil
                    group.crowdControlGrowDirection = nil
                    group.crowdControlIconsPerRow   = nil
                    -- Clean up abbreviated CC widget key names (pre-v43 bug)
                    group.ccGrowDirection           = nil
                    group.ccIconsPerRow             = nil
                    group.crowdControlSpacing       = nil
                    group.crowdControlRowSpacing    = nil
                    group.showDispelIndicator       = nil
                    group.dispelIndicatorStyle      = nil
                    group.dispelIndicatorSize       = nil
                    group.dispelIndicatorPosition   = nil
                    group.dispelIndicatorOffsetX    = nil
                    group.dispelIndicatorOffsetY    = nil
                end
            end
        end
    end
end

-- ============================================================
-- MigrateCFGToIndependentFlats
--
-- Converts CFG groups from metatable-chained inheritance (baseLayoutID)
-- to fully independent deep-copied flats. For each group with
-- baseLayoutID:
--   1. Resolves the base raid flat from rpDB.
--   2. Copies any keys from the base flat that are missing from the
--      CFG flat (deep-copy for tables).
--   3. Does the same for section sub-tables and aura sub-category
--      sub-tables.
--   4. Restores any stashed values from flat._stash.
--   5. Removes baseLayoutID and overrideSizeSpacing from the group.
--
-- Idempotent: skips groups without baseLayoutID.
-- ============================================================
function BF:MigrateCFGToIndependentFlats()
    if not self.cfgDB or not self.rpDB then return end

    -- Helper: deep-copy a value (table → recursive copy, else identity).
    local function dcopy(v)
        if type(v) ~= "table" then return v end
        local c = {}
        for k, sv in pairs(v) do
            c[k] = type(sv) == "table" and dcopy(sv) or sv
        end
        return c
    end

    -- Helper: for each key in src (via pairs, which reads through metatables),
    -- if dst[key] is nil (rawget), copy the value into dst (deep-copy if table).
    local function fillMissing(dst, src)
        if type(dst) ~= "table" or type(src) ~= "table" then return end
        for k, v in pairs(src) do
            if rawget(dst, k) == nil then
                dst[k] = dcopy(v)
            end
        end
    end

    for _, cfgName in ipairs(self.cfgDB:GetProfiles()) do
        local cfgp = self.cfgDB.profiles[cfgName]
        if cfgp and cfgp.customFrameGroups then
            -- Look up the corresponding RP profile for resolving base flats.
            local rp = self.rpDB.profiles[cfgName]
            local rpl = rp and rp.layouts
            local fl = rpl and rpl.flatLayouts

            for _, group in pairs(cfgp.customFrameGroups) do
                if type(group) == "table" and group.baseLayoutID then
                    local flat = group.flat
                    if type(flat) == "table" then
                        -- Resolve base flat.
                        local baseFlat = fl and fl[group.baseLayoutID]

                        -- 1. Restore any stashed values first so they become
                        --    rawkeys and won't be overwritten by base flat values.
                        local stash = flat._stash
                        if type(stash) == "table" then
                            -- Restore stashed size/spacing keys.
                            local sizeStash = stash.sizeSpacing
                            if type(sizeStash) == "table" then
                                for k, v in pairs(sizeStash) do
                                    if rawget(flat, k) == nil then
                                        flat[k] = v
                                    end
                                end
                            end
                            -- Restore stashed section sub-tables.
                            for stashKey, stashVal in pairs(stash) do
                                if stashKey ~= "sizeSpacing" and stashKey ~= "auras"
                                   and type(stashVal) == "table" then
                                    if rawget(flat, stashKey) == nil then
                                        flat[stashKey] = stashVal
                                    end
                                end
                            end
                            -- Restore stashed aura sub-categories.
                            local auraStash = stash.auras
                            if type(auraStash) == "table" then
                                if not rawget(flat, "auras") then flat.auras = {} end
                                local aurasP = flat.auras
                                for subcat, sub in pairs(auraStash) do
                                    if type(sub) == "table" and rawget(aurasP, subcat) == nil then
                                        aurasP[subcat] = sub
                                    end
                                end
                            end
                            -- Remove the stash.
                            flat._stash = nil
                        end

                        -- 2. Copy missing keys from the base flat.
                        if baseFlat then
                            fillMissing(flat, baseFlat)

                            -- 3. Copy missing keys in section sub-tables.
                            for _, sec in ipairs(self._perLayoutSections or {}) do
                                local baseSub = baseFlat[sec]
                                if type(baseSub) == "table" then
                                    if not rawget(flat, sec) then flat[sec] = {} end
                                    fillMissing(flat[sec], baseSub)
                                end
                            end

                            -- 4. Copy missing keys in aura sub-categories.
                            local baseAuras = baseFlat.auras
                            if type(baseAuras) == "table" then
                                if not rawget(flat, "auras") then flat.auras = {} end
                                local aurasP = flat.auras
                                for _, subcat in ipairs(self.AURAS_SUBCATEGORIES or {}) do
                                    local baseSub = baseAuras[subcat]
                                    if type(baseSub) == "table" then
                                        if not rawget(aurasP, subcat) then aurasP[subcat] = {} end
                                        fillMissing(aurasP[subcat], baseSub)
                                    end
                                end
                            end
                        end
                    end

                    -- 5. Remove old inheritance keys from the group.
                    group.baseLayoutID = nil
                    group.overrideSizeSpacing = nil
                end
            end
        end
    end
end

-- ── dbVersion 79: SEED THE raid25 SLOT ──────────────────────────────────
-- BF:MigrateSeedRaid25Slot
--
-- "Raid (25 Man)" is a new assignment slot (Midnight's Mythic Flex caps at
-- 25 players). Before it existed, a 25-player raid resolved through
-- GetCapacityTier's `<= 30` arm and therefore used the raid30 slot, so
-- raid30's assignment is what was actually governing those raids. Every
-- layer that had an opinion about raid30 inherits it for raid25, which
-- makes this update a no-op in game: the same Layout applies in the same
-- raids until the user deliberately splits them.
--
-- Scope is the OVERRIDE layers only. The global instanceLayoutAssignment
-- is seeded by ScrubInvalidSlotAssignments (see its Rule D-prime), which
-- runs on every load and so also covers profiles this dbVersion block
-- cannot reach -- imports above all. The override maps cannot be handled
-- there: they are sparse, a nil entry MEANS "this layer has no opinion,
-- fall through", and a per-load seeder would keep resurrecting a raid25
-- override every time the user cleared one back to global. One shot is
-- the only correct shape for them.
--
-- Seed-only-when-nil, so a profile that somehow already has raid25 keeps
-- what it has, and running this twice changes nothing.
--
-- Walks every rpDB profile, not just the active one -- the same shape
-- migration 75 uses, and for the same reason: the user's other profiles
-- are equally out of date and will not get another dbVersion pass.
function BF:MigrateSeedRaid25Slot()
    if not (self.rpDB and self.rpDB.profiles) then return end

    -- One override map: copy raid30's opinion onto raid25 if that layer
    -- has one and has said nothing about raid25 yet.
    local function seedMap(map)
        if type(map) ~= "table" then return end
        if map.raid25 == nil and map.raid30 ~= nil then
            map.raid25 = map.raid30
        end
    end

    for _, rp in pairs(self.rpDB.profiles) do
        local rpl = type(rp) == "table" and rp.layouts
        if type(rpl) == "table" then
            -- The global map too, so a profile that is not the active one
            -- at load time is already correct rather than waiting for the
            -- scrub to reach it when the user switches to it.
            local ila = rpl.instanceLayoutAssignment
            if type(ila) == "table" then seedMap(ila) end

            local roleOv = rpl.roleOverrides
            if type(roleOv) == "table" then
                for _, roleMap in pairs(roleOv) do seedMap(roleMap) end
            end

            local specOv = rpl.specOverrides
            if type(specOv) == "table" then
                for _, specMap in pairs(specOv) do seedMap(specMap) end
            end
        end
    end
end

-- ── Slot-assignment scrub (runs every load) ─────────────────────────────
-- BF:ScrubInvalidSlotAssignments
--
-- Walks the three slot→flatID maps under rp.layouts and rewrites any
-- entry that points to a non-existent flat or a wrong-typed flat. Also
-- fills in any missing entries on the global instanceLayoutAssignment
-- (all 11 slots must be present there; sparse storage is only legitimate
-- on the role/spec override layers).
--
-- Runs on every addon load — there is no version sentinel. Idempotent on
-- a clean profile: it walks the same ~11 + sparse slots, finds every
-- entry valid, and exits without writing.
--
-- Rationale for being a per-load pass rather than a versioned migration:
-- flats can be deleted between sessions (the user removes a flat in
-- session 1, then session 2 sees stale references in instance/role/spec
-- assignments). A one-shot v-bumped migration would not catch those.
--
-- Rules (applied in order for each non-nil entry encountered):
--   A. Value == "none": preserved (solo-hide sentinel, valid at any layer).
--   B. Value points to a flat that no longer exists: rewrite to the
--      seeded default for the slot's type (flat_party / flat_raid40).
--   C. Value points to a flat whose .type doesn't match the slot's
--      required type: rewrite to the seeded default.
--
-- For instanceLayoutAssignment only, an extra fourth rule:
--   D. Slot key missing entirely (nil): write the seeded default.
--      The global map must be dense across all 11 canonical slots.
--   On role/spec overrides nil entries are LEGITIMATE (they mean "this
--   override layer has no opinion, fall through") and are preserved.
--
-- Safety: if the seeded fallback flat itself is missing from
-- rpl.flatLayouts at scrub time, we do NOT overwrite the entry —
-- writing a known-bad flatID would be strictly worse than leaving the
-- existing one. The runtime resolver (ResolveValidFlatForSlot) handles
-- that pathological case.
--
-- Hot-path constraints: no closures inside loops; a handful of locals
-- only. The work is bounded by ~11 slots × (1 + 3 roles + tiny #specs).
-- ============================================================
function BF:ScrubInvalidSlotAssignments(profileName)
    profileName = profileName or self.rpDB.keys.profile
    local rp = self.rpDB.profiles[profileName]
    if not rp then return end
    local rpl = rp.layouts
    if not rpl then return end

    -- Depend on the canonical map hoisted at the top of Options_Layouts.lua.
    -- All call sites run from OnInitialize (or later) by which point every
    -- .toc-listed file has executed its top-level code, so SLOT_TYPE is
    -- present in the common case. Bail defensively if not — we get another
    -- chance on the next load.
    local SLOT_TYPE = self.SLOT_TYPE
    if type(SLOT_TYPE) ~= "table" then return end

    local fl = rpl.flatLayouts
    if type(fl) ~= "table" then return end

    -- Seeded defaults. If either is missing from flatLayouts, leave any
    -- entries that would have been rewritten as-is.
    local partyDefault = "flat_party"
    local raidDefault  = "flat_raid40"
    local partyDefaultOK = type(fl[partyDefault]) == "table"
                           and fl[partyDefault].type == "party"
    local raidDefaultOK  = type(fl[raidDefault]) == "table"
                           and fl[raidDefault].type == "raid"

    -- Helper inlined as a local function (single allocation, declared
    -- once outside any loop). Returns the replacement flatID for a slot
    -- given its required type, or nil if no safe replacement exists.
    -- nil result signals "leave the existing entry alone".
    local function replacementFor(slotType)
        if slotType == "party" then
            if partyDefaultOK then return partyDefault end
        elseif slotType == "raid" then
            if raidDefaultOK then return raidDefault end
        end
        return nil
    end

    -- ── Pass 1: instanceLayoutAssignment (dense map) ────────────────
    -- Walk all 11 canonical slots. Apply Rules A/B/C on present entries,
    -- Rule D on missing ones.
    local ila = rpl.instanceLayoutAssignment
    if type(ila) ~= "table" then
        -- Pathological: defaults layer should always supply this. Create
        -- an empty table so the per-slot seeding below has somewhere to
        -- write.
        ila = {}
        rpl.instanceLayoutAssignment = ila
    end
    -- Rule D-prime, and it must run BEFORE the Rule D loop below.
    --
    -- raid25 (Midnight Mythic Flex) was added after these profiles were
    -- written, so every existing profile reaches this pass with the slot
    -- missing. Rule D would fill it with the shipped default,
    -- flat_raid40 -- but a 25-player raid used to resolve as raid30, so
    -- the assignment that was ACTUALLY in effect for those raids is
    -- whatever raid30 says. Inheriting it keeps the user's frames
    -- identical on the first login after the update; taking Rule D's
    -- default would silently move anyone whose raid30 pointed somewhere
    -- other than flat_raid40.
    --
    -- Safe to repeat on every load because instanceLayoutAssignment is a
    -- DENSE map: nil here means "not set yet", never "no opinion", so
    -- this can only fire once per profile. The role/spec override layers
    -- are sparse and cannot be seeded this way -- nil there is a
    -- deliberate "fall through", and re-seeding would resurrect an
    -- override the user had cleared. Those get the one-shot
    -- BF:MigrateSeedRaid25Slot instead (dbVersion 79).
    if ila.raid25 == nil and ila.raid30 ~= nil then
        ila.raid25 = ila.raid30
    end

    for slot, slotType in pairs(SLOT_TYPE) do
        local id = ila[slot]
        if id == nil then
            -- Rule D: missing slot — seed the default.
            local rep = replacementFor(slotType)
            if rep then ila[slot] = rep end
        elseif id ~= "none" then
            -- Rule A handled by the elseif (skipped).
            local flat = fl[id]
            if type(flat) ~= "table" then
                -- Rule B: stored flatID doesn't exist anymore.
                local rep = replacementFor(slotType)
                if rep then ila[slot] = rep end
            elseif flat.type ~= slotType then
                -- Rule C: stored flat is the wrong type.
                local rep = replacementFor(slotType)
                if rep then ila[slot] = rep end
            end
        end
    end

    -- ── Pass 2: roleOverrides[role] (sparse maps; nil legitimate) ───
    -- Preserve nil entries — they mean "this role layer has no opinion".
    -- Only validate entries that ARE present. The roleOverrides table
    -- itself may be absent on very old profiles; nothing to do then.
    local roleOv = rpl.roleOverrides
    if type(roleOv) == "table" then
        for _, roleMap in pairs(roleOv) do
            if type(roleMap) == "table" then
                for slot, id in pairs(roleMap) do
                    -- Only consider canonical slot keys. Foreign keys in
                    -- the table (shouldn't happen but defensive) are
                    -- left untouched — we have no slotType for them.
                    local slotType = SLOT_TYPE[slot]
                    if slotType and id ~= "none" then
                        local flat = fl[id]
                        if type(flat) ~= "table" then
                            local rep = replacementFor(slotType)
                            if rep then roleMap[slot] = rep end
                        elseif flat.type ~= slotType then
                            local rep = replacementFor(slotType)
                            if rep then roleMap[slot] = rep end
                        end
                    end
                end
            end
        end
    end

    -- ── Pass 3: specOverrides[specID] (sparse maps; nil legitimate) ──
    -- Same rules as Pass 2. specID keys are strings (specOverrides is
    -- keyed by tostring(specID) per ResolveActiveFlat); we don't assume
    -- either way and just iterate whatever's there.
    local specOv = rpl.specOverrides
    if type(specOv) == "table" then
        for _, specMap in pairs(specOv) do
            if type(specMap) == "table" then
                for slot, id in pairs(specMap) do
                    local slotType = SLOT_TYPE[slot]
                    if slotType and id ~= "none" then
                        local flat = fl[id]
                        if type(flat) ~= "table" then
                            local rep = replacementFor(slotType)
                            if rep then specMap[slot] = rep end
                        elseif flat.type ~= slotType then
                            local rep = replacementFor(slotType)
                            if rep then specMap[slot] = rep end
                        end
                    end
                end
            end
        end
    end
end


-- ============================================================
-- _AuraMig_SplitPerLayoutToggle  (stage of dbVersion 60)
--
-- The single "Auras" nav section became two sections, Buffs and Debuffs,
-- each with its own "Separate configuration per Layout" toggle:
--
--   perLayoutToggles.aurasBuffs    -> buffs / bigDef / important
--   perLayoutToggles.aurasDebuffs  -> debuffs / dispelIndicator /
--                                    privateAuras / crowdControl
--
-- perLayoutToggles.auras is no longer a real storage key (BF:IsPerLayoutSection
-- keeps "auras" as a coarse "either group is ON" alias for whole-section
-- questions). Its saved value is copied onto BOTH group keys so nothing
-- changes for existing users: the v27 MigrateAurasToSection forced
-- perLayoutToggles.auras = true for every upgrader, so without this copy half
-- their aura settings would silently revert to the global values.
--
-- No DATA moves. Aura settings still live at rpDB.profile.auras.<subcat> and
-- flat.auras.<subcat>; only the toggle key changed.
--
-- Idempotent per profile, guarded by rp._aurasUnifiedV65 (stamped by
-- MigrateAurasUnified, which owns every stage of migration 60).
-- ============================================================
function BF:_AuraMig_SplitPerLayoutToggle(rp)
    local lp = rp.layouts
    if type(lp) == "table" then
        local t = lp.perLayoutToggles
        if type(t) == "table" then
            local old = t.auras
            if old ~= nil then
                -- Only seed a group key that hasn't been set already, so a
                -- re-run can't stomp a choice the user made post-upgrade.
                if t.aurasBuffs   == nil then t.aurasBuffs   = old and true or false end
                if t.aurasDebuffs == nil then t.aurasDebuffs = old and true or false end
                t.auras = nil
            end
        end
    end
end

-- ============================================================
-- _AuraMig_SplitPerLayoutToggleBySubcat  (stage of dbVersion 65)
-- ============================================================
-- The two group toggles above split again, one per aura SUB-CATEGORY, so that
-- every subtab owns its own "Enable per-Layout configuration" switch:
--
--   perLayoutToggles.aurasBuffs   -> auras_buffs   + auras_bigDef
--   perLayoutToggles.aurasDebuffs -> auras_debuffs + auras_dispelIndicator
--
-- The translation itself is NOT restated here: it lives in
-- BF:NormalizeAuraPerLayoutKeys (Core_ProfileAPI.lua), which also runs at load
-- from RehydrateFlats to close the import hole. Two copies of the same
-- translation would drift, and the load-time copy has to exist regardless.
--
-- This stage USED to also capture the pre-normalize group values for the
-- container seed (_AuraMig_SeedContainerPerLayout). That seed was REMOVED by
-- owner ruling 2026-08-15 -- per-Layout configuration starts DISABLED for all
-- containers and Single Buffs (see the tombstone where the seed lived) -- so
-- this is now just the dispatcher-time entry point for the normalizer.
--
-- No DATA moves; only the toggle key changed. Idempotent -- the normalizer is
-- seed-only-when-nil.
-- ============================================================
function BF:_AuraMig_SplitPerLayoutToggleBySubcat(rp)
    self:NormalizeAuraPerLayoutKeys(rp)   -- translate, then nil
end

-- ============================================================
-- MigrateSplitCFGOverrideAuras  (stage of dbVersion 60)
--
-- Companion to _AuraMig_SplitPerLayoutToggle for Custom Frame Groups.
--
-- Each CFG had ONE `group.overrideAuras` flag meaning "this group uses its own
-- aura settings instead of the global ones". With the Buffs and Debuffs
-- per-Layout toggles now independent, one flag can no longer express the state
-- "own Buffs, global Debuffs", so it is split into
-- `overrideAurasBuffs` / `overrideAurasDebuffs` (BF.AURAS_GROUP_CFG_FLAG), each
-- owned by its own CFG nav page.
--
-- Seeded from the old flag so behavior is unchanged, then the old flag is
-- nilled. Not keyed to an rpDB profile: CFG groups live in cfgDB, which has its
-- own profile set, so this walks every cfgDB profile (mirroring
-- MigrateCFGToFlatStructure) and is guarded per group rather than per profile.
-- ============================================================
function BF:MigrateSplitCFGOverrideAuras()
    if not self.cfgDB then return end

    for _, cfgName in ipairs(self.cfgDB:GetProfiles()) do
        local cfgp = self.cfgDB.profiles[cfgName]
        if cfgp and cfgp.customFrameGroups then
            for _, group in pairs(cfgp.customFrameGroups) do
                if type(group) == "table" and group.overrideAuras ~= nil then
                    local old = group.overrideAuras and true or false
                    -- Only seed a flag still absent, so a re-run cannot stomp a
                    -- choice the user made after upgrading.
                    if group.overrideAurasBuffs   == nil then group.overrideAurasBuffs   = old end
                    if group.overrideAurasDebuffs == nil then group.overrideAurasDebuffs = old end
                    group.overrideAuras = nil
                end
            end
        end
    end
end

-- ============================================================
-- MigrateSeedCFGOverrideFlags  (stage of dbVersion 65, §6.3/§7.3)
--
-- Behavior-preservation seed for the §6.3 semantics change.
--
-- Until v65 both CFG resolvers short-circuited the override flag whenever the
-- section was per-Layout:
--
--     if section_flag and not self:IsPerLayoutSection(section) then ...
--
-- so with per-Layout ON a Custom Frame Group ALWAYS used its own flat and the
-- flag was never consulted -- it sat nil while the group demonstrably rendered
-- from its own data. v65 makes the flag authoritative. Without this seed, the
-- first login after the upgrade would read those nil flags as "off" and every
-- Custom Frame Group of every per-Layout user would silently switch to the
-- shared settings.
--
-- Modelled on MigrateSplitCFGOverrideAuras above: cfgDB has its own profile
-- set, so this walks cfgDB itself and is dispatched ONCE, outside the
-- per-profile loop. Each cfgDB profile is paired with the SAME-NAMED rpDB
-- profile, which is where the per-Layout toggles live.
--
-- READS THE PAIRED PROFILE'S RAW perLayoutToggles, NEVER BF:IsPerLayoutSection.
-- That helper resolves against self.rpDB.profile -- the ACTIVE profile only --
-- so routing through it would stamp whichever profile happens to be loaded
-- onto every cfgDB profile in the account. BF:NormalizeAuraPerLayoutKeys is
-- called on the paired profile first (idempotent by design, and the same call
-- the dispatcher's rename stage makes) so the four auras_<subcat> keys are
-- guaranteed present before they are read, whatever order the stages run in.
--
-- ONE-SHOT PER cfgDB PROFILE, via cfgp._cfgOverrideSeededV65. Seed-only-when-nil
-- is not sufficient on its own here: this is upgrade-MOMENT behavior
-- preservation, so if the pass ran again after the user later switched a
-- section's per-Layout toggle ON, it would seed that section's flag true on
-- every group -- silently flipping groups the user had deliberately left
-- shared. The sentinel is what makes the RehydrateCFGFlats call site (which
-- runs on every login, profile change and import) a no-op for profiles that
-- have already been through it, while still catching an imported old-build
-- profile that never saw the dispatcher.
--
-- The aura flags are PAGE-level (§6.1 keeps one flag per page), so
-- overrideAurasBuffs is seeded when EITHER auras_buffs or auras_bigDef is on,
-- and overrideAurasDebuffs when either auras_debuffs or auras_dispelIndicator
-- is on.
-- ============================================================
function BF:MigrateSeedCFGOverrideFlags()
    if not self.cfgDB then return end

    for _, cfgName in ipairs(self.cfgDB:GetProfiles()) do
        local cfgp = self.cfgDB.profiles[cfgName]
        if type(cfgp) == "table" and not cfgp._cfgOverrideSeededV65 then
            cfgp._cfgOverrideSeededV65 = true

            local groups = cfgp.customFrameGroups
            local rp = self.rpDB and self.rpDB.profiles and self.rpDB.profiles[cfgName]
            local t
            if type(rp) == "table" then
                self:NormalizeAuraPerLayoutKeys(rp)
                -- 2026-08-24: normalize the five per-subtab section keys
                -- too, so the reads below see the new key space.
                if self.NormalizeSectionPerLayoutKeys then
                    self:NormalizeSectionPerLayoutKeys(rp)
                end
                t = rp.layouts and rp.layouts.perLayoutToggles
            end

            if groups and type(t) == "table" then
                -- Sub-category toggle keys, from the generated map rather than
                -- literals so a retired/added sub-category cannot leave a
                -- stale name behind here.
                local ST = BF.AURAS_SUBCAT_TOGGLE or {}
                local function subcatOn(sc)
                    local key = ST[sc]
                    return key ~= nil and t[key] == true
                end
                local buffsOn   = subcatOn("buffs")   or subcatOn("bigDef")
                local debuffsOn = subcatOn("debuffs") or subcatOn("dispelIndicator")

                for _, group in pairs(groups) do
                    if type(group) == "table" then
                        -- The seven plain sections plus castBar, driven off
                        -- the same table the resolvers consult.
                        for _, entry in ipairs(BF.CFG_OVERRIDABLE_SECTIONS or {}) do
                            -- 2026-08-24: a per-subtab section's old key is
                            -- normalized away above; "any subtab ON" stands
                            -- in for the retired whole-section value (the
                            -- same OR-fold the two aura flags use below).
                            local on = t[entry.section] == true
                            if not on then
                                local togMap = BF.SECTION_SUBTAB_TOGGLE
                                    and BF.SECTION_SUBTAB_TOGGLE[entry.section]
                                if togMap then
                                    for _, tk in pairs(togMap) do
                                        if t[tk] == true then on = true; break end
                                    end
                                end
                            end
                            if on and group[entry.flag] == nil then
                                group[entry.flag] = true
                            end
                        end
                        local bFlag = BF.AURAS_GROUP_CFG_FLAG
                            and BF.AURAS_GROUP_CFG_FLAG.aurasBuffs
                        local dFlag = BF.AURAS_GROUP_CFG_FLAG
                            and BF.AURAS_GROUP_CFG_FLAG.aurasDebuffs
                        if buffsOn and bFlag and group[bFlag] == nil then
                            group[bFlag] = true
                        end
                        if debuffsOn and dFlag and group[dFlag] == nil then
                            group[dFlag] = true
                        end
                    end
                end
            end
        end
    end
end

-- ============================================================
-- _AuraMig_RemoveDeadFeatures  (stage of dbVersion 60)
--
-- Nils the saved keys of three features deleted in v60. All three were
-- already inert before deletion, so this only reclaims SavedVariables space
-- and prevents stale values reappearing if a key name is ever reused.
--
--   1. Blizzard Debuffs -- the experimental Blizzard-native debuff container
--      (Auras/PrivateAuraDebuffs.lua). Storage: auras.blizzardDebuffs, whose
--      four keys were `enabled`, `containerPosition`, `iconSize` and
--      `blizzardDebuffMaxCount`. The whole sub-table goes.
--
--   2. Private Aura Customizations -- the global/dungeon/per-encounter PA
--      override profiles and the PA frame-border settings
--      (AuraCustomizations/PrivateAuraCustomizations.lua + Encounters.lua).
--      Storage: acDB.profile, plus activeEncounterID on db.profile.
--
--   3. privateAuraBorderScale -- the "Icon Border Scale" slider on the
--      Private Auras subtab. Its only reader lived in (2).
--
-- Idempotent per profile, guarded by rp._aurasUnifiedV65 (stamped by
-- MigrateAurasUnified, which owns every stage of migration 60).
-- ============================================================
function BF:_AuraMig_RemoveDeadFeatures(rp, acp, pp)
    -- 1. Blizzard Debuffs: global pseudo-layout + every flat.
    if type(rp.auras) == "table" then
        rp.auras.blizzardDebuffs = nil
    end
    rp.privateAuraBorderScale = nil  -- (3)
    local fl = rp.layouts and rp.layouts.flatLayouts
    if type(fl) == "table" then
        for _, flat in pairs(fl) do
            if type(flat) == "table" then
                flat.privateAuraBorderScale = nil  -- pre-§18.1 flat-root residue
                -- rawget so a pristine flat that inherits auras via __index
                -- isn't given an empty rawkey table just to clean it.
                local fa = rawget(flat, "auras")
                if type(fa) == "table" then
                    fa.blizzardDebuffs = nil
                end
            end
        end
    end

    -- 2. Private Aura Customizations. acDB.profile is the post-§18 home;
    -- db.profile is cleaned too because the pre-§18 keys lived there and
    -- MigrateAuraCustomizationsProfile only relocated some of them.
    local PA_KEYS = {
        "enablePrivateAuraCustomizations",
        "enableGlobalPAOverrides",
        "globalPASettings",
        "encounterPASettings",
        "dungeonPASettings",
        "privateAuraBorderAutoScale",
        "privateAuraBorderAutoScaleRaid",
        "privateAuraBorderAutoScaleParty",
        "privateAuraBorderWidthRatio",
        "privateAuraBorderWidthRatioRaid",
        "privateAuraBorderWidthRatioParty",
        "privateAuraBorderFrameLevel",
        "privateAuraBorderFrameLevelRaid",
        "privateAuraBorderFrameLevelParty",
        "privateAuraFrameBorderScaleRaid",
        "privateAuraFrameBorderScaleParty",
        "privateAuraFrameBorderScaleOverride",
        "privateAuraBorderScale",
    }
    for _, key in ipairs(PA_KEYS) do
        if acp then acp[key] = nil end
        if pp  then pp[key]  = nil end
    end
    -- Encounters.lua was the sole writer of activeEncounterID.
    if pp then pp.activeEncounterID = nil end
end

-- ── Container groupSettings: positional CFG keys → cfgFlatID (dbVersion 52) ──
-- _AuraMig_RekeyGroupSettings (stage of dbVersion 60)
--
-- Finishes the job migration 21 (MigrateGroupSettingsToFlatKeys, above)
-- deliberately left undone. That migration remapped the RP side of
-- container.groupSettings from old tier strings (party / raid40) onto flat IDs
-- and passed "cfGroup_N" entries through unchanged. Those keys are POSITIONAL:
--
--   container.groupSettings = {
--     flat_party = { ... },
--     cfGroup_1  = { ... },   -- customFrameGroups[1]
--     cfGroup_2  = { ... },   -- customFrameGroups[2]
--   }
--
-- Deleting a Custom Frame Group is a table.remove(groups, index), which
-- renumbers every later group, so group 2 became group 1 and silently
-- inherited group 1's per-group container settings. Custom Frame Groups ARE
-- flats and already carry a stable unique flat.cfgFlatID, so the fix is to key
-- this table by flat identity throughout -- one uniform key space, immune to
-- renumbering.
--
-- Entries whose index no longer resolves to a group are DROPPED. That group was
-- deleted, and because of the positional bug those settings were already being
-- misapplied to whichever group inherited the index, so keeping them would
-- preserve corruption rather than data.
--
-- TWO tables share this key space, not one. Besides container.groupSettings,
-- the per-spell cooldown-text entries at
-- specSpellCooldownText[specId][spellId].groupSettings are keyed the same way:
-- the options dropdown that picks the key is the same one (buildGroupTypeValues
-- in Options_AuraCustomizations.lua), and the runtime read
-- (GetSpellCooldownText in AuraCustomizationHelpers.lua) takes its key from
-- BF:ResolveGroupTypeKey, exactly like the container read. Migration 42
-- (Core_DB.lua) also copied container groupSettings entries -- cfGroup_N keys
-- included -- straight into those per-spell entries. Both tables therefore have
-- to be rekeyed in the same pass, or per-spell CFG overrides would read as
-- absent after the key swap.
--
-- ORDERING: flat.cfgFlatID is normally backfilled by ensureCFGFlatIDs() in
-- Options_CustomFrames.lua, which only runs when the options UI is built --
-- i.e. possibly never before this migration. So this mints the ID itself for
-- any group lacking one, using the same "cfg_flat_<n>" scheme and the same
-- first-unused-slot rule as newCFGFlatID(), so no later mint can collide.
--
-- Custom Frame Groups live in cfgDB, which has its own profile set. Profiles
-- are normally same-named across every BF database (_AuraMig_RemoveDeadFeatures
-- above pairs rpDB and acDB profiles by name for the same reason), so the acDB
-- profile is paired with the cfgDB profile of the same name, falling back to
-- the active cfgDB profile for the active acDB profile. If no group list can be
-- paired, the keys are left ALONE rather than dropped -- an unmigrated key reads
-- as "no per-group override" (nothing constructs or matches that prefix any
-- more), which is inert, whereas dropping it would destroy user settings we
-- simply could not resolve.
--
-- Idempotent via the acp._aurasUnifiedV65 sentinel on the acDB profile
-- (stamped by MigrateAurasUnified around the whole acDB half), mirroring
-- migration 21's _groupSettingsMigratedToFlat. Fresh installs are no-ops.
-- ============================================================
function BF:_AuraMig_RekeyGroupSettings(acp, groups)
    -- Backfill missing cfgFlatIDs first, so index → ID resolution below can
    -- never come up empty for a group that actually exists. Same scheme and
    -- same first-unused-slot rule as newCFGFlatID() in Options_CustomFrames.lua.
    local used = {}
    for _, grp in ipairs(groups) do
        if type(grp) == "table" and type(grp.flat) == "table" and grp.flat.cfgFlatID then
            used[grp.flat.cfgFlatID] = true
        end
    end
    for _, grp in ipairs(groups) do
        if type(grp) == "table" and type(grp.flat) == "table" and not grp.flat.cfgFlatID then
            local n = 1
            while used["cfg_flat_" .. n] do n = n + 1 end
            grp.flat.cfgFlatID       = "cfg_flat_" .. n
            used[grp.flat.cfgFlatID] = true
        end
    end

    -- index → cfgFlatID. A group with no flat table at all (pre-flat-structure
    -- and somehow not caught by MigrateCFGToFlatStructure) resolves to nil and
    -- its entry is dropped along with the deleted-group entries.
    local idOf = {}
    for i, grp in ipairs(groups) do
        if type(grp) == "table" and type(grp.flat) == "table" then
            idOf[i] = grp.flat.cfgFlatID
        end
    end

    -- Rekey one owner's groupSettings table in place.
    local function remapGroupSettings(owner)
        if type(owner) ~= "table" or type(owner.groupSettings) ~= "table" then return end
        local newGS = {}
        -- Pass 1: everything that is NOT a legacy positional key. Already a
        -- flat ID, or a key we don't recognize -- passed through unchanged,
        -- matching migration 21's tolerance.
        for key, entry in pairs(owner.groupSettings) do
            if not (type(key) == "string" and key:find("^cfGroup_%d+$")) then
                newGS[key] = entry
            end
        end
        -- Pass 2: remap the legacy positional keys. Split into two passes so the
        -- outcome doesn't depend on pairs() order: if a table somehow held both
        -- "cfGroup_1" and that group's real cfgFlatID, the flat-ID entry is the
        -- correct one and wins.
        for key, entry in pairs(owner.groupSettings) do
            if type(key) == "string" then
                local idx = key:match("^cfGroup_(%d+)$")
                if idx then
                    local newKey = idOf[tonumber(idx)]
                    -- newKey nil => the group was deleted, entry dropped
                    -- (see header comment).
                    if newKey and newGS[newKey] == nil then
                        newGS[newKey] = entry
                    end
                end
            end
        end
        owner.groupSettings = newGS
    end

    -- 1. Custom aura containers.
    local containers = acp.customBuffContainers
    if type(containers) == "table" then
        for _, c in pairs(containers) do
            remapGroupSettings(c)
        end
    end

    -- 2. Per-spell aura cooldown text, same key space (see header comment).
    local sct = acp.specSpellCooldownText
    if type(sct) == "table" then
        for _, bySpell in pairs(sct) do
            if type(bySpell) == "table" then
                for _, entry in pairs(bySpell) do
                    remapGroupSettings(entry)
                end
            end
        end
    end
end

-- ── Containers follow the Buffs section's per-Layout toggle (dbVersion 53) ──
-- _AuraMig_ContainersFollowSection (stage of dbVersion 60)
--
-- Custom aura containers used to decide "does this container have per-Layout
-- settings?" from their own container.separateGroupConfig flag. They now follow
-- the Buffs aura section like every other buff setting: a raid/party frame
-- consults perLayoutToggles.aurasBuffs, a Custom Frame Group frame consults that
-- group's overrideAurasBuffs flag (BF:IsContainerPerLayoutActive in
-- AuraCustomizations.lua).
--
-- NO DATA MOVES. container.groupSettings[<flat ID>] is still the per-scope
-- override table, still sparse, still falling back field-by-field to the
-- container top level. Only the gate changed, so this migration has exactly two
-- jobs:
--
--   1. If ANY container had separateGroupConfig on, force
--      perLayoutToggles.aurasBuffs = true. Without it those users' per-flat
--      container overrides would silently stop being read the moment the gate
--      moved. Mostly moot in practice -- v27 forced perLayoutToggles.auras = true
--      for every upgrader and migration 51 copied that onto aurasBuffs, so only
--      a brand-new profile can have it false -- but a profile imported from a
--      hand-edited SavedVariables can, so it is done unconditionally.
--
--      Custom Frame Groups need no equivalent: overrideAurasBuffs was already
--      seeded from the old group.overrideAuras flag by MigrateSplitCFGOverrideAuras
--      (migration 51), and a group that never overrode its aura settings has no
--      per-Layout container data of its own to preserve either.
--
--   2. Nil the two now-dead per-container fields: separateGroupConfig (no reader
--      left) and containerEditingGroupType (a transient editing selection that
--      was never read back -- the options UI keeps it in a module-local).
--
--   3. WIPE groupSettings on any container whose separateGroupConfig was NOT on.
--      Those entries were INERT under the old gate -- a container with the flag
--      off read everything from its top level no matter what its groupSettings
--      held. Leaving them would make them live the instant the gate moved to the
--      section toggle, so a user who once enabled per-container config, tuned one
--      Layout, then switched it back off would see those abandoned values
--      silently reappear. Wiping keeps what they actually see today: that
--      container renders from its shared top level in every scope. Owner
--      decision. Containers that DID have the flag on keep their groupSettings
--      untouched -- that is live user intent.
--
-- Deliberately NOT touched: specSpellCooldownText[specId][spellId].separateGroupConfig.
-- Per-spell cooldown-text entries share the groupSettings KEY SPACE with
-- containers but keep their own per-entry per-Layout toggle, which is still live.
--
-- Spans two databases: containers live in acDB, the toggle in rpDB. Profiles are
-- normally same-named across every BF database, which is how _AuraMig_RemoveDeadFeatures
-- pairs rpDB with acDB; the same pairing is used here in the other direction,
-- with the active-profile fallback migration 52 uses for cfgDB. If no rpDB
-- profile can be paired the field cleanup still runs -- it is unconditional --
-- and only the toggle is skipped.
--
-- Idempotent via the acp._aurasUnifiedV65 sentinel on the acDB profile
-- (stamped by MigrateAurasUnified around the whole acDB half), same as
-- _AuraMig_RekeyGroupSettings above. Fresh installs are no-ops.
-- ============================================================
function BF:_AuraMig_ContainersFollowSection(acp, ensureRPToggle)
    local containers = acp.customBuffContainers
    if type(containers) == "table" then
        local anySeparate = false
        for _, c in pairs(containers) do
            if type(c) == "table" then
                local wasSeparate = (c.separateGroupConfig == true)
                if wasSeparate then anySeparate = true end
                -- Read the flag BEFORE nilling it -- job 3 depends on it.
                if not wasSeparate then
                    -- Inert under the old gate; would go live under the new one.
                    c.groupSettings = nil
                end
                c.separateGroupConfig       = nil
                c.containerEditingGroupType = nil
            end
        end
        if anySeparate then
            -- ensureRPToggle RESOLVES OR CREATES the paired rpDB profile. The
            -- field wipe above is unconditional and irreversible, so a profile
            -- that could not be paired used to lose separateGroupConfig without
            -- ever getting the toggle that replaces it -- its per-Layout
            -- container geometry then silently reverted to the shared top
            -- level, undiagnosable because the flag was already gone.
            local rp = ensureRPToggle()
            if rp then
                rp.layouts = rp.layouts or {}
                rp.layouts.perLayoutToggles = rp.layouts.perLayoutToggles or {}
                -- dbVersion 65: write the LIVE per-subcat keys, not the retired
                -- aurasBuffs group key this stage originally wrote. Seed-only-
                -- when-nil on purpose -- the old write went through
                -- BF:NormalizeAuraPerLayoutKeys, whose translation is also
                -- seed-only-when-nil, so an unconditional write here would
                -- CHANGE behavior by stomping a user's post-upgrade choice.
                local t = rp.layouts.perLayoutToggles
                if t.auras_buffs  == nil then t.auras_buffs  = true end
                if t.auras_bigDef == nil then t.auras_bigDef = true end
            end
        end
    end
end

-- ── One-spell containers become single buffs (dbVersion 54) ────────────────
-- _AuraMig_OneSpellContainers (stage of dbVersion 60, plan 3.67)
--
-- A "single buff" is a custom aura container with singleBuff = true holding
-- exactly ONE spell, carried on the container as singleBuffSpellID and gated by
-- its own Spec condition (loadSpec / loadSpecTypes). It does NOT participate in
-- spellAssign / selectedSpells / spellToContainer -- that relation is 1:1 at
-- three levels and therefore cannot express the owner's requirement that the
-- SAME spell be added multiple times as separate entries. See the block comment
-- on BF:GetSingleBuffSpellID (AuraCustomizations.lua) for the full rationale.
--
-- This migration does three things, in this order:
--
--   1. BACKFILL existing single buffs. Ones created before this build have no
--      singleBuffSpellID / singleBuffKey and DO use spellAssign. Their spell is
--      derived from selectedSpells, moved onto the container, given a freshly
--      minted key, and their Spec condition is pre-set to the specs they were
--      actually assigned for -- then the assignment is dropped. Runs first so
--      the split pass below cannot see them.
--
--   2. SPLIT one-spell (spec, container) pairs, PER SPEC (owner-specified).
--      spellAssign is walked per spec; for each (spec, container) pair where
--      that container has exactly ONE spell assigned FOR THAT SPEC, the spell
--      becomes its own single buff and is unassigned from the old container for
--      THAT SPEC ONLY. Other specs' assignments on that container are untouched.
--
--      Owner's worked example: a container holding Rejuvenation for Resto Druid
--      and two spells for Preservation Evoker -> Rejuvenation becomes a single
--      buff with its Spec condition set to Resto Druid and is removed from that
--      container for Resto only; Preservation's two-spell container is untouched.
--
--   3. The new single buff COPIES the source container's geometry and appearance
--      (deep-copying every table-valued field, including groupSettings, so the
--      two never share a reference) so it renders identically. Naming follows
--      the owner's rule: an autoNamed source yields a spell-named single buff,
--      a user-named source hands its name over. autoNamed is cleared either way,
--      because RemoveCustomBuffContainer's renumbering loop rewrites the name of
--      every auto-named container that shifts down.
--
-- DECISION -- a container that yields one-spell splits for SEVERAL specs
-- produces ONE single buff PER SPEC, not one merged entry with both specs
-- enabled. The rule is defined per (spec, spell) pair and the settings of each
-- entry are independent (slice 2 lets two entries of one spell diverge), so
-- splitting per pair is lossless and reversible -- the user can delete one and
-- tick the second spec on the survivor. It is also behaviorally identical:
-- each entry's Spec condition admits exactly one spec, so only one of them ever
-- renders at a time and there is no duplicate icon.
--
-- SPEC CONDITION SEMANTICS: loadSpecTypes marks a spec OFF with an explicit
-- `false`; absent or true means ON (fail-open, copied from the Buzzard Auras
-- tracker load conditions). "Only spec X" therefore has to be written as a DENSE
-- table with `false` for every OTHER spec, which is what specUniverse() below is
-- for. Writing only healer specs would leave a migrated single buff fail-open
-- (i.e. VISIBLE) on the player's DPS specs, where the container it came from
-- could never render -- so the universe is every spec the client knows, with the
-- healer list plus the profile's own spellAssign keys unioned in as a fallback
-- for any client where the enumeration API is unavailable.
--
-- Idempotent per acDB profile behind acp._aurasUnifiedV65, the single sentinel
-- EnsureAurasMigratedForProfile stamps once the whole acDB half has run (§14.4:
-- this comment used to name _singleBuffsOwnSpellV62, the v62-era guard, which
-- has no occurrence anywhere in the tree). Fresh installs are no-ops.
-- ============================================================

-- Every spec ID the loadSpecTypes table has to be dense over. Enumerated from
-- the client so a non-healer spec is explicitly OFF rather than fail-open;
-- `extra` (the profile's spellAssign spec keys) and BF.HEALER_SPEC_ORDER are
-- unioned in so the result is never empty even if the API is missing.
local function singleBuffSpecUniverse(extra)
    local ids = {}
    if GetNumClasses and GetNumSpecializationsForClassID and GetSpecializationInfoForClassID then
        for classID = 1, GetNumClasses() do
            local n = GetNumSpecializationsForClassID(classID) or 0
            for i = 1, n do
                local id = GetSpecializationInfoForClassID(classID, i)
                if type(id) == "number" then ids[id] = true end
            end
        end
    end
    local healers = BF.HEALER_SPEC_ORDER
    if type(healers) == "table" then
        for _, s in ipairs(healers) do
            if type(s) == "table" and type(s.id) == "number" then ids[s.id] = true end
        end
    end
    if type(extra) == "table" then
        for id in pairs(extra) do
            if type(id) == "number" then ids[id] = true end
        end
    end
    return ids
end

-- ============================================================
-- Shared helpers for the single-buff migrations
-- ============================================================
-- Migrations 54, 55, 57 and 59 were written incrementally, and each grew its
-- own copy of the same helper -- three copies of the key minter, three of
-- deepCopy, two of the "already held" test and two of the visual-family copy
-- loop. They are hoisted here so each rule is stated exactly once and cannot
-- drift between the four passes.

-- Every family the four reusable subtabs write. specSpellCustomized and
-- specSpellPrevAssign are deliberately absent: they are routing state for the
-- curated flow, and a single buff participates in neither.
local SINGLE_BUFF_VISUAL_FAMILIES = {
    "specSpellIconType", "specSpellSolidIcons", "specSpellBorderColors",
    "specSpellOrdering", "specSpellCooldownText", "specSpellExpirationGlow",
    "specSpellBounce", "specSpellVisualAlert", "specSpellColors",
    "specSpellBorders", "specSpellOverlays",
}

-- Deep copy, so a migrated entry never shares a table reference (font color,
-- threshold colors, groupSettings, ...) with the container or the curated spell
-- it came from -- editing one would otherwise mutate the other.
local function deepCopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, val in pairs(v) do out[k] = deepCopy(val) end
    return out
end

-- "Only these specs are ON", written DENSE over `universe` with an explicit
-- false for every other spec.
--
-- loadSpecTypes is FAIL-OPEN: absent or true means ON, only an explicit false
-- means OFF (copied from the Buzzard Auras tracker load conditions). Writing
-- just the healer specs would therefore leave a migrated entry fail-open --
-- i.e. VISIBLE -- on the player's DPS specs, where the container it came from
-- could never render. Hence singleBuffSpecUniverse and hence dense.
local function onlySpecs(universe, specSet)
    local t = {}
    for id in pairs(universe) do
        t[id] = specSet[id] and true or false
    end
    return t
end

-- The single-spec case, which is what all three creation sites actually want.
local function onlySpec(universe, specId)
    local t = {}
    for id in pairs(universe) do t[id] = (id == specId) end
    return t
end

-- Is some existing single buff already carrying this spell on this spec?
--
-- LOAD-BEARING, not defensive. Migration 54 pass 2 ends each split with
-- `assigns[sid] = "default"` -- so every single buff IT created leaves its
-- spell looking exactly like a migration-57 candidate: Default-assigned,
-- flagged customized, with visual family entries. Without this test the later
-- pass would duplicate the earlier one's entire output. The same relationship
-- holds between 57 and 59.
--
-- loadSpecTypes is fail-open (see onlySpecs), so "covers this spec" is
-- `t[specId] ~= false`.
local function alreadyHeld(containers, sid, specId)
    for i = 1, #containers do
        local c = containers[i]
        if type(c) == "table" and c.singleBuff and c.singleBuffSpellID == sid then
            local t = c.loadSpecTypes
            if not c.loadSpec or type(t) ~= "table" or t[specId] ~= false then
                return true
            end
        end
    end
    return false
end

-- Display name for a migrated entry. Routes through BF.SpellDisplayName so the
-- ambiguous Echo spells are stamped "Dream Breath (Echo)" rather than a second,
-- identical "Dream Breath" -- which is what CreateSingleBuffContainer does for
-- an entry the user makes by hand, so migrated entries now match.
--
-- The `BF.SpellDisplayName and` presence test is REQUIRED, not defensive: the
-- migration tests stub BuzzardFrames without it and rely on the C_Spell branch.
-- `fallback` lets the curated caller supply the name it already has for when
-- the API has not cached the spell yet.
local function spellName(sid, fallback)
    return (BF.SpellDisplayName and BF.SpellDisplayName(sid, fallback))
        or (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(sid))
        or fallback or tostring(sid)
end

-- Mint a stable per-entry identity "<spellID>_<n>" against THIS profile's
-- array. Delegates to the live minter, which takes `containers` for exactly
-- this reason -- a migration mints against a NON-active profile, while
-- BF:NewSingleBuffKey's default is the active one. Three hand-rolled copies of
-- the same first-unused-slot rule used to live in this file; one call site
-- means the key shape cannot drift from the minter the options UI uses.
local function mintKey(containers, sid)
    return BF:NewSingleBuffKey(sid, containers)
end

-- Human-readable spec name, used to disambiguate two migrated entries that
-- would otherwise carry the identical source-container name. Falls back to the
-- raw ID -- the migration harnesses stub HEALER_SPEC_ORDER without names.
-- Remove one container from a NON-ACTIVE profile's array.
--
-- Mirrors BF:RemoveCustomBuffContainer (AuraCustomizations.lua) step for step.
-- That function cannot be called here: it reads self:GetCustomBuffContainers()
-- and self.acDB.profile, i.e. the ACTIVE profile, while a migration walks every
-- profile. The logic is replicated rather than reinvented so the two cannot
-- drift -- if one changes, change both.
--
-- The renumbering is the whole point. customBuffContainers is an ARRAY and
-- spellAssign values are POSITIONAL "c:N", so a bare table.remove silently
-- repoints every later assignment at its neighbor.
local function removeContainerAt(acp, containers, index)
    local doomed = containers[index]
    if not doomed then return end

    -- Drop a Buffs-anchored single buff's legacy Order mirror BEFORE the
    -- remove. That store outlives the container and an orphaned Order is not
    -- inert -- on 12.1 an Order is what promotes a spell into its own sp<sid>
    -- group, and the guard that suppressed it disappears with the entry.
    if doomed.singleBuff and doomed.loadSpec then
        local sid = doomed.singleBuffSpellID
        local t   = doomed.loadSpecTypes
        if sid and type(t) == "table" then
            local order = BF.HEALER_SPEC_ORDER or {}
            local only, ambiguous = nil, false
            for i = 1, #order do
                local id = order[i].id
                if t[id] ~= false then
                    if only then ambiguous = true end
                    only = id
                end
            end
            if ambiguous then only = nil end
            local m = only and acp.specSpellOrdering and acp.specSpellOrdering[only]
            if m then m[sid] = nil end
        end
    end

    table.remove(containers, index)

    -- NO renumbering pass, mirroring BF:RemoveCustomBuffContainer: auto-names
    -- are "Custom <n>", first-unused-slot and stable across deletions, so
    -- rewriting them to the array index would undo the scheme.

    -- Repoint every positional reference: an assignment to the removed
    -- container falls back to default, anything above it decrements.
    if type(acp.spellAssign) == "table" then
        for _, assigns in pairs(acp.spellAssign) do
            if type(assigns) == "table" then
                for sid, val in pairs(assigns) do
                    local n = type(val) == "string" and tonumber(val:match("^c:(%d+)$"))
                    if n then
                        if n == index then
                            assigns[sid] = "default"
                        elseif n > index then
                            assigns[sid] = "c:" .. (n - 1)
                        end
                    end
                end
            end
        end
    end
end

-- ── Shared with the export pipeline (Phase E step 3b) ────────────
-- ProfileExport.lua diffs curated single-buff entries against the
-- shape _AuraMig_CuratedSpells mints, and its import path re-applies
-- those diffs onto receiver-minted entries. Both sides MUST use these
-- exact rules (universe, fail-open coverage, key minting, positional
-- c:N repointing), so the local helpers are exposed here rather than
-- duplicated. Behavior change: none — this is a table of references.
BF._CuratedSBHelpers = {
    universe    = singleBuffSpecUniverse,
    onlySpec    = onlySpec,
    alreadyHeld = alreadyHeld,
    spellName   = spellName,
    mintKey     = mintKey,
    removeAt    = removeContainerAt,
}

local function specDisplayName(specId)
    local order = BF.HEALER_SPEC_ORDER
    if type(order) == "table" then
        for _, sp in ipairs(order) do
            if type(sp) == "table" and sp.id == specId and sp.name then return sp.name end
        end
    end
    return (GetSpecializationInfoByID
            and select(2, GetSpecializationInfoByID(specId)))
        or tostring(specId)
end

-- Copy a spell's curated per-spec visuals into an entry's own sbVisuals store.
-- Returns the new table, or nil when the spell had no entry in any family.
--
-- COPY, NEVER MOVE: the sources are what 12.0.7 keeps rendering from, and
-- leaving them untouched is what keeps that engine byte-for-byte unchanged.
-- Is a stored family entry actually doing anything?
--
-- PRESENCE IS NOT INTENT. The options write a table the moment a subtab is
-- visited, and a feature that was switched back off leaves `enabled = false`
-- behind. Counting those made a spell with no live customization arrive as
-- "Show (Customized Buff)" -- e.g. Prayer of Mending, whose only entries were
-- specSpellColors and specSpellOverlays with enabled = false on one spec.
--
-- Only an explicit `enabled == false` is rejected. A missing `enabled` means
-- the family has no on/off of its own (specSpellIconType stores a bare string),
-- and an empty table means nothing was ever set.
local function familyEntryIsLive(entry)
    if entry == nil then return false end
    if type(entry) ~= "table" then return true end
    if entry.enabled == false then return false end
    return next(entry) ~= nil
end

local function copyVisualFamilies(acp, specId, sid, kspec)
    local dst
    for fi = 1, #SINGLE_BUFF_VISUAL_FAMILIES do
        local family = SINGLE_BUFF_VISUAL_FAMILIES[fi]
        local fam    = acp[family]
        local map    = type(fam) == "table" and fam[specId] or nil
        local entry  = map and map[sid]
        if familyEntryIsLive(entry) then
            dst = dst or {}
            if not dst[family] then dst[family] = {} end
            if not dst[family][kspec] then dst[family][kspec] = {} end
            dst[family][kspec][sid] = deepCopy(entry)
        end
    end
    return dst
end

function BF:_AuraMig_OneSpellContainers(acp)
    local containers = acp.customBuffContainers
    if type(containers) ~= "table" or #containers == 0 then return end
    local assign = type(acp.spellAssign) == "table" and acp.spellAssign or nil

    -- Snapshot the original length: new single buffs are APPENDED and must never
    -- be re-examined by either pass.
    local nOrig = #containers


    local universe = singleBuffSpecUniverse(assign)

    -- Fields the copy must NOT inherit: identity, the spell list, and the
    -- single-buff fields the caller sets explicitly. Anything prefixed "_bf_" is
    -- runtime scratch and is skipped by prefix below.
    local SKIP = {
        selectedSpells = true, name = true, autoNamed = true,
        singleBuff = true, singleBuffSpellID = true, singleBuffKey = true,
        loadSpec = true, loadSpecTypes = true, maxBuffs = true,
    }

    -- ── 1. Backfill single buffs saved before this build ────────────────────
    for i = 1, nOrig do
        local c = containers[i]
        if type(c) == "table" and c.singleBuff and c.singleBuffSpellID == nil then
            -- Lowest assigned spell ID, for determinism: a single buff has one
            -- by construction, but a hand-edited SavedVariables could hold more
            -- and pairs() order must not decide which one survives.
            local sid
            if type(c.selectedSpells) == "table" then
                for k, on in pairs(c.selectedSpells) do
                    if on and type(k) == "number" and (sid == nil or k < sid) then sid = k end
                end
            end
            if sid then
                c.singleBuffSpellID = sid
                c.singleBuffKey     = mintKey(containers, sid)
                c.maxBuffs          = 1
                -- Spec condition from the specs it was actually assigned for,
                -- unassigning each as it is read.
                local assignedSpecs, anySpec = {}, false
                if assign then
                    local key = "c:" .. i
                    for specId, assigns in pairs(assign) do
                        if type(specId) == "number" and type(assigns) == "table"
                           and assigns[sid] == key then
                            assignedSpecs[specId] = true
                            anySpec = true
                            assigns[sid] = "default"
                        end
                    end
                end
                if anySpec then
                    c.loadSpec      = true
                    c.loadSpecTypes = onlySpecs(universe, assignedSpecs)
                end
                -- The spell now travels on the container; drop the mirror.
                if type(c.selectedSpells) == "table" then c.selectedSpells[sid] = nil end
            end
        end
    end

    -- ── 2. Per-spec one-spell splits ────────────────────────────────────────
    if assign then
        -- Deterministic order: sorted spec IDs, then sorted container indices.
        -- pairs() order would otherwise decide the array positions of the new
        -- containers and which of two same-spell entries gets "_1".
        local specIDs = {}
        for specId, assigns in pairs(assign) do
            if type(specId) == "number" and type(assigns) == "table" then
                specIDs[#specIDs + 1] = specId
            end
        end
        table.sort(specIDs)

        -- Pre-count how many specs will yield a split for each source
        -- container. A container that splits for several specs produces one
        -- entry per spec (recorded decision), and a USER-NAMED source hands the
        -- same name to every one of them -- indistinguishable in the options
        -- tree. Where the count is >1 the spec name is appended.
        local splitCount = {}
        for _, specId in ipairs(specIDs) do
            local perCI = {}
            for sid, val in pairs(assign[specId]) do
                if type(sid) == "number" and type(val) == "string" then
                    local ci = tonumber(val:match("^c:(%d+)$"))
                    if ci and ci >= 1 and ci <= nOrig then
                        perCI[ci] = (perCI[ci] or 0) + 1
                    end
                end
            end
            for ci, cnt in pairs(perCI) do
                if cnt == 1 then splitCount[ci] = (splitCount[ci] or 0) + 1 end
            end
        end

        for _, specId in ipairs(specIDs) do
            local assigns = assign[specId]
            -- byCI[ci] = { sid, ... } for this spec only.
            local byCI, cis = {}, {}
            for sid, val in pairs(assigns) do
                if type(sid) == "number" and type(val) == "string" then
                    local n = tonumber(val:match("^c:(%d+)$"))
                    if n and n >= 1 and n <= nOrig then
                        local list = byCI[n]
                        if not list then list = {}; byCI[n] = list; cis[#cis + 1] = n end
                        list[#list + 1] = sid
                    end
                end
            end
            table.sort(cis)
            for _, ci in ipairs(cis) do
                local list = byCI[ci]
                local src  = containers[ci]
                -- Exactly one spell FOR THIS SPEC, and not already a single buff
                -- (pass 1 has emptied those, but a hand-edited profile could
                -- still have a stray assignment pointing at one).
                -- alreadyHeld is defense in depth: pass 2 is naturally
                -- re-entrant (it ends with `assigns[sid] = "default"`, which no
                -- longer matches "^c:%d+$"), but if the sentinel is ever cleared
                -- AFTER the user re-assigns this spell, nothing else would stop
                -- a second split.
                if #list == 1 and type(src) == "table" and not src.singleBuff
                   and not alreadyHeld(containers, list[1], specId) then
                    local sid = list[1]
                    local newC = {}
                    for k, v in pairs(src) do
                        if not SKIP[k] and not (type(k) == "string" and k:find("^_bf_")) then
                            newC[k] = deepCopy(v)
                        end
                    end
                    newC.singleBuff        = true
                    newC.maxBuffs          = 1
                    newC.singleBuffSpellID = sid
                    newC.selectedSpells    = {}
                    newC.loadSpec          = true
                    newC.loadSpecTypes     = onlySpec(universe, specId)
                    -- autoNamed source -> name after the spell; user-named
                    -- source -> carry the name over. Cleared either way so the
                    -- delete-renumbering loop cannot rewrite it.
                    newC.name      = src.autoNamed and spellName(sid) or src.name
                    if not src.autoNamed and (splitCount[ci] or 0) > 1 then
                        newC.name = (src.name or "") ..
                                    " (" .. specDisplayName(specId) .. ")"
                    end
                    newC.autoNamed = false
                    -- Mint BEFORE the insert: mintKey scans the live array, and
                    -- the new entry must not be in it while its own slot is
                    -- being chosen.
                    newC.singleBuffKey = mintKey(containers, sid)
                    containers[#containers + 1] = newC

                    -- Unassign for THIS SPEC ONLY.
                    assigns[sid] = "default"
                    -- selectedSpells has no spec dimension, so the mirror may
                    -- only be dropped once NO spec still routes this spell to
                    -- this container. Checked against the live table, which
                    -- already reflects the unassign just above.
                    if type(src.selectedSpells) == "table" then
                        local stillRouted = false
                        local key = "c:" .. ci
                        for _, other in pairs(assign) do
                            if type(other) == "table" and other[sid] == key then
                                stillRouted = true
                                break
                            end
                        end
                        if not stillRouted then src.selectedSpells[sid] = nil end
                    end
                end
            end
        end
    end

    -- ── 3. One-time sweep of empty containers ───────────────────────────────
    -- A container with no spells renders nothing but still occupies a row in
    -- the options tree and a slot in the array. Most are husks the split above
    -- just emptied; any that were already empty are equally useless, and after
    -- the fact the two are indistinguishable. Owner decision: remove them all,
    -- once, here. The user can always create a new container.
    --
    -- Descending order so a removal cannot invalidate an index still queued;
    -- removeContainerAt repoints spellAssign after each one.
    --
    -- SINGLE BUFFS ARE NEVER CANDIDATES -- they carry their spell on
    -- singleBuffSpellID and have an empty selectedSpells BY DESIGN.
    for i = #containers, 1, -1 do
        local c = containers[i]
        if type(c) == "table" and not c.singleBuff then
            local empty = type(c.selectedSpells) ~= "table"
                          or next(c.selectedSpells) == nil
            -- Belt: never remove something an assignment still points at, even
            -- if the selectedSpells mirror somehow disagrees.
            if empty and assign then
                local key = "c:" .. i
                for _, assigns in pairs(assign) do
                    if type(assigns) == "table" then
                        for _, val in pairs(assigns) do
                            if val == key then empty = false break end
                        end
                    end
                    if not empty then break end
                end
            end
            if empty then removeContainerAt(acp, containers, i) end
        end
    end
end

-- ============================================================
-- MIGRATION 55 (v62, plan 3.67 slice 2) -- single-buff VISUALS
--
-- Slice 1 moved a single buff's spell onto the container but had nowhere to put
-- its APPEARANCE: container-scoped visual storage did not exist yet. So a
-- single buff saved before v62, or produced by migration 54, rendered from
-- CONTAINER-level defaults instead of from the specSpell*[specID][spellID]
-- entries its old per-spell group used -- a v61 single buff whose spell had
-- custom icon / border / cooldown-text settings simply lost them.
--
-- Slice 2 adds that storage (container.sbVisuals[family]["sb"][spellID], see
-- the STORAGE ACCESSOR note in Options_AuraCustomizations.lua), so this pass
-- copies the old entries across.
--
-- WHY A SEPARATE MIGRATION rather than folding it into 54's pass: 54 was
-- idempotent per profile behind its own v62-era flag, and on any profile that
-- had already opened a slice-1 build that flag was set -- the extra work would
-- never have run there. A new version guarded by its own flag runs for both the
-- already-migrated and the not-yet-migrated case, in the right order (the 54
-- block above appends the split entries this pass then reads). Both stages now
-- run under the one acp._aurasUnifiedV65 sentinel, which is what actually
-- guards them today (§14.4: this comment used to name
-- _singleBuffsOwnSpellV62, which has no occurrence anywhere in the tree).
--
-- SOURCE SPEC. A migrated single buff records the spec it came from in its own
-- Spec condition (loadSpec + a dense loadSpecTypes with exactly that spec true),
-- so that is the first choice. A hand-made single buff with no condition falls
-- back to any spec whose curated list flagged the spell as Customized. Lowest
-- spec ID wins so the result does not depend on pairs() order.
--
-- The master customize flag is the gate, exactly as it is at runtime: an
-- UNFLAGGED spell behaves as if it had no customizations at all, so copying its
-- stale entries would make the icon change appearance rather than preserve it.
-- ============================================================

function BF:_AuraMig_SingleBuffVisuals(acp)
    local containers = acp.customBuffContainers
    if type(containers) ~= "table" or #containers == 0 then return end

    local SB_KSPEC = BF.SINGLE_BUFF_VISUAL_KSPEC or "sb"
    local cust = type(acp.specSpellCustomized) == "table" and acp.specSpellCustomized or nil

    -- Lowest flagged spec, preferring the entry's own Spec condition.
    local function sourceSpec(c, sid)
        if not cust then return nil end
        local best
        local t = c.loadSpec and type(c.loadSpecTypes) == "table" and c.loadSpecTypes or nil
        if t then
            for specId, on in pairs(t) do
                if on == true and type(specId) == "number"
                   and cust[specId] and cust[specId][sid] == true
                   and (best == nil or specId < best) then
                    best = specId
                end
            end
            -- RETURN unconditionally. Falling through when this entry has a
            -- Spec condition but no flag on those specs used to copy the
            -- LOWEST-NUMBERED OTHER spec's visuals -- a live collision, since
            -- Prayer of Mending and Power Infusion are curated on both 256 and
            -- 257. The cross-spec scan below is only for a hand-made entry
            -- with no condition at all.
            return best
        end
        for specId, set in pairs(cust) do
            if type(specId) == "number" and type(set) == "table" and set[sid] == true
               and (best == nil or specId < best) then
                best = specId
            end
        end
        return best
    end

    for i = 1, #containers do
        local c = containers[i]
        if type(c) == "table" and c.singleBuff and type(c.singleBuffSpellID) == "number"
           and c.sbVisuals == nil then
            local sid     = c.singleBuffSpellID
            local specId  = sourceSpec(c, sid)
            if specId then
                local dst = copyVisualFamilies(acp, specId, sid, SB_KSPEC)
                if dst then c.sbVisuals = dst end
            end
        end
    end
end

-- ============================================================
-- MIGRATION 57 (v65): Default-assigned customizations -> Single Buffs
--
-- WHY THIS EXISTS AT ALL. IsCust() -- the gate every curated per-spell visual
-- getter routes through -- opens with:
--
--     if BF._useAuraContainers then return false end
--
-- So a spell customized in Aura Customizations and left on the *Default*
-- container keeps its icon type, solid color, border color, cooldown text,
-- expiration glow and bounce on 12.0.7, and silently loses every one of them on
-- 12.1. Per-entry visuals on that engine live only in
-- container.sbVisuals[family]["sb"][spellID], which only a Single Buff
-- container has.
--
-- Migration 54 converted the CONTAINER-assigned one-spell customizations.
-- Default-assigned ones were left behind because there was no way to express
-- "a Single Buff that lives in the regular buff row" -- which is precisely what
-- the v65 "Buffs" anchor point adds. This is the carry-forward that was waiting
-- on it.
--
-- COPY, NEVER MOVE. spellAssign, specSpellCustomized and specSpellOrdering are
-- all left exactly as they were. That is what keeps 12.0.7 byte-for-byte
-- unchanged: IsCust() is still true there, ApplyCustomOrdering still places the
-- icon by the same slot, and the new entry stands aside (see
-- BF:IsSingleBuffBuffsAnchored's callers). The entry only takes over on 12.1,
-- where the old data was being dropped anyway.
--
-- ONE ENTRY PER SPEC, matching migration 54's recorded decision: a spell
-- customized on three specs yields three entries, each with a dense
-- loadSpecTypes naming just its own spec, rather than one merged entry.
function BF:_AuraMig_DefaultCustomizations(acp)
    -- CANDIDATES ARE DERIVED FROM THE CUSTOMIZATION TABLES THEMSELVES, not from
    -- acp.specSpellCustomized.
    --
    -- That master-flag table is seeded LAZILY: BF:EnsureSpellCustomizedSeeded
    -- runs only from EnsureFetchBuffSettings (first render) and the options-UI
    -- build. This migration runs from RegisterDB, which is the FIRST line of
    -- BF:OnInitialize -- before RegisterOptions and long before anything
    -- renders. So on any profile whose saved copy of the flag table is absent
    -- or stale, reading it here found nothing, this stage produced NO entries
    -- at all, and every curated spell fell through to the CuratedSpells stage
    -- as "Show (Default Buff)" with no visuals. Meanwhile 12.0.7 kept rendering
    -- from the untouched source keys, so the settings looked simultaneously
    -- present on the frames and missing from the UI.
    --
    -- Deriving the set here uses the same sources the seeder uses, in the same
    -- order, so the result no longer depends on whether it has run yet.
    local cust = {}
    local function flag(specId, sid)
        if type(specId) ~= "number" or type(sid) ~= "number" then return end
        if not cust[specId] then cust[specId] = {} end
        cust[specId][sid] = true
    end
    -- 1. Any entry in any per-spell customization table.
    for fi = 1, #SINGLE_BUFF_VISUAL_FAMILIES do
        local t = acp[SINGLE_BUFF_VISUAL_FAMILIES[fi]]
        if type(t) == "table" then
            for specId, spells in pairs(t) do
                if type(spells) == "table" then
                    for sid, v in pairs(spells) do
                        if v ~= nil then flag(specId, sid) end
                    end
                end
            end
        end
    end
    -- 2. Any explicit non-default assignment. "c:N" is filtered out by
    --    rendersInBuffRow below; "untracked" yields a hidden entry.
    if type(acp.spellAssign) == "table" then
        for specId, assigns in pairs(acp.spellAssign) do
            if type(assigns) == "table" then
                for sid, val in pairs(assigns) do
                    if val ~= nil and val ~= "default" then flag(specId, sid) end
                end
            end
        end
    end
    -- 3. Whatever the flag table already holds, so a profile that HAS been
    --    seeded never loses a candidate this derivation would miss.
    if type(acp.specSpellCustomized) == "table" then
        for specId, spells in pairs(acp.specSpellCustomized) do
            if type(spells) == "table" then
                for sid, on in pairs(spells) do
                    if on == true then flag(specId, sid) end
                end
            end
        end
    end

    local containers = acp.customBuffContainers
    if type(containers) ~= "table" then
        containers = {}
        acp.customBuffContainers = containers
    end

    local SB_KSPEC = BF.SINGLE_BUFF_VISUAL_KSPEC or "sb"

    -- Which spells are hidden by default unless promoted? Derived from
    -- BF.SPEC_SPELLS rather than read from AuraCustomizations.lua, whose
    -- DEFAULT_UNTRACKED_BY_SPEC is a file local. Same derivation, same source.
    -- `curated` also gates candidacy (below): specSpellCustomized can hold
    -- entries for a spell that has since been REMOVED from a curated list, and
    -- without this test that spell would be resurrected as a visible buff the
    -- user has not seen in versions.
    local defaultUntracked, curated = {}, {}
    local specSpells = BF.SPEC_SPELLS
    if type(specSpells) == "table" then
        for specId, spells in pairs(specSpells) do
            if not curated[specId] then curated[specId] = {} end
            for _, s in ipairs(spells) do
                curated[specId][s.id] = true
                if s.untracked then
                    if not defaultUntracked[specId] then defaultUntracked[specId] = {} end
                    defaultUntracked[specId][s.id] = true
                end
            end
        end
    end

    -- Where does this spell render, and is it currently shown?
    --
    -- Mirrors getAssignedContainerForSpell's "== 0" branch: an explicit
    -- "default", or nothing stored at all. "c:N" is out of scope -- that spell
    -- renders from its custom container, not the buff row.
    --
    -- UNTRACKED IS NOT OUT OF SCOPE, it is out of SIGHT. The original test
    -- folded the two together and returned false for a spell that is untracked
    -- by default, which silently DROPPED the customizations of any such spell
    -- the user had configured: this stage skipped it, and the curated stage
    -- then created a bare entry with singleBuffCustomized = false and no
    -- sbVisuals. Four of the 48 curated spells are untracked by default
    -- (Aspect of Harmony, Hydrobubble, Echo of Light, Source of Magic), so this
    -- was not a corner case. The settings are now carried over and the entry is
    -- created HIDDEN, so unhiding it restores exactly what the user had.
    local function rendersInBuffRow(specId, sid)
        local assign = acp.spellAssign and acp.spellAssign[specId]
        local val = assign and assign[sid]
        if type(val) == "string" and val:find("^c:%d+$") then return false end
        return true
    end
    local function isHidden(specId, sid)
        local assign = acp.spellAssign and acp.spellAssign[specId]
        local val = assign and assign[sid]
        if val == "untracked" then return true end
        if val ~= nil then return false end
        local du = defaultUntracked[specId]
        return (du and du[sid]) and true or false
    end

    -- THE MASTER FLAG IS THE GATE. There used to be a further
    -- hasRealCustomization() test here -- "does this spell have an entry in one
    -- of the 11 visual families?" -- justified by the claim that
    -- specSpellCustomized is "seeded BROADLY (flags whole curated lists), so
    -- flagged does not mean the user configured something".
    --
    -- That claim is FALSE. BF:EnsureSpellCustomizedSeeded
    -- (AuraCustomizations.lua) never flags a whole list: it flags a spell that
    -- has an entry in one of those same 11 tables, an explicit non-default
    -- spellAssign, or membership in a container's selectedSpells -- and its own
    -- stated rule is "Maximal by owner decision: no pre-existing customization
    -- may end up hidden behind an unchecked master toggle". So a flag with no
    -- family entry does not mean "seeded noise", it means the user ticked
    -- Customize and left the visuals at their defaults. The two are
    -- indistinguishable in storage, and the seeder already chose which way to
    -- resolve that.
    --
    -- The old test therefore dropped exactly those spells to the curated stage,
    -- which created them with singleBuffCustomized = false -- "Show (Default
    -- Buff)" -- while on 12.0.7 the still-live IsCust() path kept rendering
    -- them customized. Display Type said Default; the icon disagreed.
    --
    -- Volume is not a concern: the flagged set is derived from real user data,
    -- not from the curated lists.

    local universe = singleBuffSpecUniverse(acp.spellAssign)

    -- Deterministic order: pairs() over specs and spells would mint keys and
    -- append entries in a different order on every run.
    local specIDs = {}
    for specId in pairs(cust) do
        if type(specId) == "number" then specIDs[#specIDs + 1] = specId end
    end
    table.sort(specIDs)

    for si = 1, #specIDs do
        local specId = specIDs[si]
        local flagged = cust[specId]
        if type(flagged) == "table" then
            local sids = {}
            for sid in pairs(flagged) do
                if type(sid) == "number" then sids[#sids + 1] = sid end
            end
            table.sort(sids)

            for k = 1, #sids do
                local sid = sids[k]
                if (curated[specId] and curated[specId][sid])
                   and rendersInBuffRow(specId, sid)
                   and not alreadyHeld(containers, sid, specId) then
                    -- Copy FIRST: whether anything was actually carried over is
                    -- what decides the mode below.
                    local dst = copyVisualFamilies(acp, specId, sid, SB_KSPEC)
                    local newC = {
                        singleBuff        = true,
                        maxBuffs          = 1,
                        singleBuffSpellID = sid,
                        singleBuffKey     = mintKey(containers, sid),
                        selectedSpells    = {},
                        name              = spellName(sid),
                        autoNamed         = false,
                        loadSpec          = true,
                        loadSpecTypes     = onlySpec(universe, specId),
                        -- CUSTOMIZED ONLY IF THERE IS SOMETHING TO SHOW.
                        --
                        -- An unconditional `true` here labeled a large number
                        -- of entries "Show (Customized Buff)" with nothing
                        -- behind them. The candidate set is deliberately wide --
                        -- it includes spells reached only through a non-default
                        -- spellAssign, and the master flag is set for those too
                        -- (EnsureSpellCustomizedSeeded flags any explicit
                        -- assignment, not just visual edits) -- so "is a
                        -- candidate" is not the same question as "has visuals".
                        --
                        -- Tying the mode to dst makes the two agree by
                        -- construction: Customized exactly when SBRoot has
                        -- something to return, Default otherwise.
                        singleBuffCustomized = dst and true or false,
                        -- The v65 anchor: flow in the regular buff row, which
                        -- is where this spell has always been.
                        anchorPoint       = "BUFFS",
                        sbRelativeOrder   = "BEFORE",
                        -- INHERIT the Buffs icon size. A Default-assigned spell
                        -- has always drawn at the Buffs size (the legacy render
                        -- path has one scalar for the whole group), so an entry
                        -- created with its own size would silently resize the
                        -- icon on 12.1. Note CreateSingleBuffContainer seeds
                        -- this FALSE -- correct for a floating entry the user
                        -- made by hand, wrong for a migrated in-row one.
                        containerUsesBuffSettings = true,
                        -- Preserve current visibility. A spell that is
                        -- untracked today must not become visible just because
                        -- its settings are now being carried forward.
                        singleBuffHidden  = isHidden(specId, sid) or nil,
                    }
                    if dst then newC.sbVisuals = dst end
                    containers[#containers + 1] = newC
                end
            end
        end
    end
end

-- ============================================================
-- MIGRATION 58 (v65): seed the Buffs display's preset list
--
-- On 12.1 the Buffs preset list is the ONLY thing that renders ordinary buffs
-- -- the "everything else" group is parked unconditionally in ApplyBuffFilters.
-- An unseeded profile would therefore log in to a completely empty buff row.
--
-- Seeds "Applied by Me (Blizzard's Raid In Combat Filter)", i.e.
-- HELPFUL|PLAYER|RAID_IN_COMBAT, because that is the filter the Buffs display
-- has ALREADY been running on: nonHealerBuffFilter defaults to
-- "player_raid_combat", which builds exactly that string. So for a profile that
-- never touched the old dropdown this is not a change of behavior at all --
-- it is the same filter, now stated where the user can see and remove it.
--
-- Healer specs defaulted to whitelist mode instead, and those profiles DO
-- change: the curated per-spec whitelist has no home in a global preset model.
-- Owner decision, and the loss is smaller than it looks -- spells with per-spell
-- customization are claimed out of the Buffs display by their Single Buff
-- entries (migration 57) and keep rendering with their own settings.
--
-- Runs on EVERY profile regardless of client, so a profile created on 12.0.7
-- is already correct if it is later opened on 12.1. Seeding is inert on
-- 12.0.7, where presets are not consulted for the Buffs display.
-- Delegates to BF.EnsureBuffsPresetsSeeded (AuraCustomizations.lua) rather
-- than restating the seed. That helper also runs from the accessor, which is
-- what covers the profiles this dispatcher never sees -- brand-new ones are
-- stamped at DB_VERSION by OnNewProfile and skip every migration block, and
-- profile copy/reset have the same hole. Two copies of a seeding rule that
-- must fire exactly once per profile is how a preset comes back after the user
-- removes it.
--
-- Kept as a migration anyway so the upgrade is explicit and ordered with the
-- rest, and so an existing profile is seeded at login rather than lazily on
-- first options access.
function BF:_AuraMig_SeedBuffsPresets(acp)
    if BF.EnsureBuffsPresetsSeeded then BF.EnsureBuffsPresetsSeeded(acp) end
end

-- ============================================================
-- _AuraMig_SeedContainerPerLayout -- REMOVED (owner ruling 2026-08-15)
-- ============================================================
-- dbVersion 65 originally seeded c.perLayoutConfig = true on every custom
-- container / Single Buff whose section group toggle was ON -- which v27
-- forced ON for every upgrader, i.e. essentially everyone -- so container
-- per-Layout behavior would carry over invisibly. The owner ruled the
-- opposite: per-Layout configuration starts DISABLED for ALL containers and
-- Single Buffs, existing and new. The user opts in per container.
--
-- Consequences, deliberate:
--   * A container whose groupSettings held per-Layout visibility/geometry
--     renders SHARED after the upgrade until its own toggle is enabled.
--     groupSettings is NOT wiped (unlike v61), so enabling the toggle brings
--     the old per-Layout data straight back.
--   * c.perLayoutConfig stays tri-state (true / explicit false / nil); with
--     no seed, nil simply means "never enabled". The options toggle still
--     writes explicit false so a FUTURE seed-only-when-nil pass could not
--     misread "turned off" as "never touched".
--
-- Do not reintroduce a seed here without an owner ruling.

-- ============================================================
-- MIGRATION 59 (v65): every curated spell becomes a Single Buff entry
--
-- Migration 57 converted only the spells the user had actually CUSTOMIZED.
-- This adds the rest of BF.SPEC_SPELLS -- the whole list that used to be
-- configurable on the Aura Customizations spec tabs -- so that page can stay
-- hidden and Single Buffs is the one place per-spell settings live.
--
-- Entries created here are deliberately INERT: Anchor Point = Buffs and
-- Display Type = Show (Default Buff), i.e. the icon draws exactly as an
-- ordinary buff in the regular row, which is where it drew before. The entry
-- exists so it can be configured, not to change anything.
--
-- HIDDEN-BY-DEFAULT SPELLS STAY HIDDEN. A SPEC_SPELLS entry marked
-- `untracked`, or one the user explicitly set to "untracked" in spellAssign,
-- becomes singleBuffHidden = true. Creating those as visible would turn on a
-- pile of buffs nobody asked for -- the single biggest risk in this migration.
--
-- One entry PER SPEC, matching 54 and 57.
function BF:_AuraMig_CuratedSpells(acp)
    local specSpells = BF.SPEC_SPELLS
    if type(specSpells) ~= "table" then return end

    local containers = acp.customBuffContainers
    if type(containers) ~= "table" then
        containers = {}
        acp.customBuffContainers = containers
    end

    local universe = singleBuffSpecUniverse(acp.spellAssign)

    -- Deterministic: pairs() over specs would mint keys in a different order
    -- every run.
    local specIDs = {}
    for specId in pairs(specSpells) do
        if type(specId) == "number" then specIDs[#specIDs + 1] = specId end
    end
    table.sort(specIDs)

    for si = 1, #specIDs do
        local specId = specIDs[si]
        local list   = specSpells[specId]
        local assign = acp.spellAssign and acp.spellAssign[specId]
        if type(list) == "table" then
            for li = 1, #list do
                local spell = list[li]
                local sid   = type(spell) == "table" and spell.id or nil
                local assigned = sid and assign and assign[sid]
                -- A spell assigned to a CUSTOM CONTAINER already renders from
                -- that container. Migration 54 only split containers holding
                -- exactly ONE spell for the spec, so anything in a 2+-spell
                -- container keeps its "c:N" assignment -- and an entry created
                -- here would be a SECOND AuraContainer whitelisting the same
                -- spell ID. Two containers whitelisting one ID populate
                -- INDEPENDENTLY, so the buff would draw twice: once in its
                -- container and once in the regular buff row.
                local inContainer = type(assigned) == "string"
                                    and assigned:find("^c:%d+$") ~= nil
                if type(sid) == "number" and not inContainer
                   and not alreadyHeld(containers, sid, specId) then
                    -- Hidden when the curated entry is untracked by default and
                    -- the user never promoted it, or when they explicitly set
                    -- it to untracked.
                    local hidden = (assigned == "untracked")
                        or (spell.untracked and assigned == nil) and true or false
                    containers[#containers + 1] = {
                        singleBuff        = true,
                        maxBuffs          = 1,
                        singleBuffSpellID = sid,
                        singleBuffKey     = mintKey(containers, sid),
                        selectedSpells    = {},
                        name              = spellName(sid, spell.name),
                        autoNamed         = false,
                        loadSpec          = true,
                        loadSpecTypes     = onlySpec(universe, specId),
                        anchorPoint       = "BUFFS",
                        sbRelativeOrder   = "BEFORE",
                        -- Show (Default Buff): draws with the container's own
                        -- settings, no per-entry visuals. `false`, not nil --
                        -- see the Display Type setter, where nil means
                        -- Customized and only an explicit false means Default.
                        singleBuffCustomized = false,
                        singleBuffHidden  = hidden or nil,
                        -- Inherit the Buffs icon size, so an entry that changes
                        -- nothing looks like nothing changed.
                        containerUsesBuffSettings = true,
                    }
                end
            end
        end
    end
end

-- ============================================================
-- SeedLateCuratedSingleBuffs (v92)
--
-- BF.SPEC_SPELLS gains rows over time, but _AuraMig_CuratedSpells runs once
-- per profile (behind _aurasUnifiedV65) -- a profile migrated before a curated
-- row was added never gets that row's Single Buff entry. This top-up mints the
-- late additions, one sentinel per batch, using the exact entry shape and
-- guards of _AuraMig_CuratedSpells (inert Show (Default Buff) entry, Spec
-- condition pinned to the curated spec, skip when assigned to a container or
-- already held, honor an explicit "untracked" assignment as Blacklist).
--
-- Dual-caller pattern (see SeedCrowdControlContainer): dispatched from the
-- GetCustomBuffContainers accessor, so new/copied/reset acDB profiles -- which
-- never reach the dbVersion dispatcher -- are covered too. On a FRESH profile
-- the unified migration mints these rows itself (they are in SPEC_SPELLS now)
-- and alreadyHeld makes this a no-op, in either dispatch order.
-- ============================================================
local LATE_CURATED_SEEDS_V92 = {
    -- Holy Bulwark: added to SPEC_SPELLS[65] (Holy Paladin) in v70, after
    -- migration 59 had already run on live profiles (owner request 2026-08-19).
    { specId = 65, sid = 432496, name = "Holy Bulwark" },
}

function BF:SeedLateCuratedSingleBuffs(acp)
    if type(acp) ~= "table" then return end
    -- Pseudo entries ride the same access hook (its own sentinel makes this
    -- one cheap compare after the first call). Must run BEFORE the early-out
    -- below, or a profile already past the curated seed never gets them.
    if self.SeedPseudoSingleBuffs then self:SeedPseudoSingleBuffs(acp) end
    if acp._lateCuratedSeedV92 then return end
    acp._lateCuratedSeedV92 = true

    local containers = acp.customBuffContainers
    if type(containers) ~= "table" then
        containers = {}
        acp.customBuffContainers = containers
    end
    local universe = singleBuffSpecUniverse(acp.spellAssign)

    for i = 1, #LATE_CURATED_SEEDS_V92 do
        local seed     = LATE_CURATED_SEEDS_V92[i]
        local assign   = acp.spellAssign and acp.spellAssign[seed.specId]
        local assigned = assign and assign[seed.sid]
        -- Same candidacy guards as _AuraMig_CuratedSpells: a spell assigned to
        -- a custom container already renders from that container, and a spell
        -- already held as a single buff for this spec must not be duplicated.
        local inContainer = type(assigned) == "string"
                            and assigned:find("^c:%d+$") ~= nil
        if not inContainer
           and not alreadyHeld(containers, seed.sid, seed.specId) then
            containers[#containers + 1] = {
                singleBuff        = true,
                maxBuffs          = 1,
                singleBuffSpellID = seed.sid,
                singleBuffKey     = mintKey(containers, seed.sid),
                selectedSpells    = {},
                name              = spellName(seed.sid, seed.name),
                autoNamed         = false,
                loadSpec          = true,
                loadSpecTypes     = onlySpec(universe, seed.specId),
                anchorPoint       = "BUFFS",
                sbRelativeOrder   = "BEFORE",
                singleBuffCustomized = false,
                singleBuffHidden  = (assigned == "untracked") or nil,
                containerUsesBuffSettings = true,
            }
        end
    end
end


-- ============================================================
-- PSEUDO BUFF LIST ENTRIES  (dbVersion 77)
--
-- A pseudo entry is a Buff List row that configures a FEATURE rather than an
-- aura. It lives in customBuffContainers alongside the real single buffs (so
-- it sorts, searches, and exports like one) but carries `pseudoKind`, which
-- makes BF:GetSingleBuffSpellID return nil -- the one choke point that keeps
-- it out of the aura engine entirely: no group, no slot, no claim/exclude
-- set, no icon pool, no preview, no Order. `singleBuffSpellID` is still
-- stored as the row's FACE (icon, name, key mint, export round-trip), read
-- through BF:GetSingleBuffDisplaySpellID.
--
-- Swiftmendable is the first: its settings (acDB.profile.swiftmendRecolorName
-- / swiftmendNameColor / swiftmendFx.{hc,bd,ov}) previously had no reachable
-- UI at all, sitting inside the permanently-hidden Aura Customizations
-- section. The keys did not move -- only the UI did.
--
-- loadSpec / loadSpecTypes are seeded so the tree's Filter by Spec matches the
-- feature's runtime gate; they are NOT user-editable (a pseudo entry gets no
-- Conditions tab) because that gate is hardcoded -- Swiftmendable's is
-- `specId2 == 105` in the cfg build.
local PSEUDO_SEEDS = {
    {
        kind   = "swiftmendable",
        sid    = 18562,          -- Swiftmend: the row's face, never an aura
        name   = "Swiftmendable",
        specId = 105,            -- Restoration Druid
    },
}

-- Lazy seed, mirroring SeedLateCuratedSingleBuffs: dbVersion blocks cannot
-- reach a profile created by import, copy or reset, and those must get the
-- row too or the feature becomes unconfigurable again.
function BF:SeedPseudoSingleBuffs(acp)
    if type(acp) ~= "table" then return end
    if acp._pseudoSeedV77 then return end
    acp._pseudoSeedV77 = true

    local containers = acp.customBuffContainers
    if type(containers) ~= "table" then
        containers = {}
        acp.customBuffContainers = containers
    end
    local universe = singleBuffSpecUniverse(acp.spellAssign)

    for i = 1, #PSEUDO_SEEDS do
        local seed = PSEUDO_SEEDS[i]
        -- Identity is the KIND, not the spell: the face spell may change and
        -- the user may separately hold Swiftmend as a real single buff.
        local exists = false
        for _, c in ipairs(containers) do
            if type(c) == "table" and c.pseudoKind == seed.kind then
                exists = true
                break
            end
        end
        if not exists then
            containers[#containers + 1] = {
                singleBuff        = true,
                pseudoKind        = seed.kind,
                maxBuffs          = 1,
                singleBuffSpellID = seed.sid,
                singleBuffKey     = mintKey(containers, seed.sid),
                selectedSpells    = {},
                name              = seed.name,
                autoNamed         = false,
                loadSpec          = true,
                loadSpecTypes     = onlySpec(universe, seed.specId),
                anchorPoint       = "BUFFS",
                sbRelativeOrder   = "BEFORE",
                singleBuffCustomized = false,
                containerUsesBuffSettings = true,
            }
        end
    end
end

-- ============================================================
-- MigrateSwiftmendableToBuffList  (dbVersion 77)
--
-- (a) Purge the two health-TEXT keys. Health-text recolor existed only on the
--     pre-12.1 Lua path (BF:UpdateSwiftmendable, removed with this change),
--     whose latch (frame._bf_swiftmendable) nothing ever armed. The live
--     feature is the fxSM slot: an engine-driven name MIRROR FontString plus
--     the hc / bd / ov fx kinds -- no health-text kind exists.
-- (b) Seed the pseudo entry in every acDB profile.
--
-- Idempotent by construction (deleting absent keys is a no-op; the seed has
-- its own per-profile sentinel), so it is safe to re-run.
-- ============================================================
local PURGE77_AC = {
    "swiftmendRecolorHealthText",
    "swiftmendHealthTextColor",
}

function BF:MigrateSwiftmendableToBuffList()
    if not (self.acDB and self.acDB.profiles) then return end
    for _, acp in pairs(self.acDB.profiles) do
        if type(acp) == "table" then
            for _, k in ipairs(PURGE77_AC) do acp[k] = nil end
            self:SeedPseudoSingleBuffs(acp)
        end
    end
end

-- ============================================================
-- MigrateAurasUnified  (v65, dbVersion 60)
-- ============================================================
-- The single aura migration. dbVersions 51..59 were nine separate migrations
-- written incrementally across 12.1 PTR testing; none ever shipped, so they are
-- merged here. Each _AuraMig_* stage above is one of them, stripped of its own
-- profile resolution and sentinel -- this function owns both.
--
-- TWO SENTINELS, one per database, because the two halves touch disjoint data
-- and either can legitimately exist without the other:
--   rp._aurasUnifiedV65   guards the rpDB half
--   acp._aurasUnifiedV65  guards the acDB half
--
-- `rp` IS RESOLVED STRICTLY -- self.rpDB.profiles[profileName], never the
-- active-profile fallback. The old migration 53 used a fallback to find the
-- profile that owns the Buffs per-Layout toggle, and sharing one fallback-
-- resolved `rp` across both halves would run the rpDB half against a
-- DIFFERENTLY NAMED profile: it would stamp that profile's sentinel, so when
-- the loop later reached it, its own dead Private Aura keys would never be
-- cleaned. The toggle keeps its own resolution, in ensureRPToggle below.
--
-- STAGE-LOCAL SKIPS, NOT EARLY RETURNS. Three of these stages used to
-- short-circuit their own flag and return when they had nothing to do ("no
-- resolvable group list", "no containers"). Behind ONE sentinel that would
-- return from the whole half -- and both conditions are the common case, since
-- customFrameGroups is an AceDB default that a raw .profiles[name] read does not
-- see. The later stages CREATE customBuffContainers when absent and are the
-- entire Single Buffs population, so an early return there is an empty buff row
-- on 12.1. Every stage therefore guards only itself.
--
-- STAGE ORDER IS LOAD-BEARING. OneSpellContainers ends each split with
-- `assigns[sid] = "default"`, which makes its own output look exactly like a
-- DefaultCustomizations candidate; that stage's alreadyHeld guard is the only
-- thing preventing duplication, and the same relationship holds between
-- DefaultCustomizations and CuratedSpells. ContainersFollowSection runs BEFORE
-- RekeyGroupSettings: it wipes the groupSettings of every container whose
-- separateGroupConfig was off, so rekeying them first is wasted work. End state
-- is identical either way (the rekey early-returns on a nil table).
function BF:MigrateAurasUnified(profileName)
    profileName = profileName or (self.acDB and self.acDB.keys and self.acDB.keys.profile)
    if not profileName then return end

    local rp  = self.rpDB and self.rpDB.profiles and self.rpDB.profiles[profileName]
    local acp = self.acDB and self.acDB.profiles and self.acDB.profiles[profileName]
    local pp  = self.db   and self.db.profiles   and self.db.profiles[profileName]

    -- ── rpDB half (was migration 51) ─────────────────────────────────────
    if rp and not rp._aurasUnifiedV65 then
        self:_AuraMig_SplitPerLayoutToggle(rp)
        self:_AuraMig_RemoveDeadFeatures(rp, acp, pp)
        rp._aurasUnifiedV65 = true
    end

    if not acp then return end

    -- ── acDB half (was 52, 53, 54, 55, 57, 59) ───────────────────────────
    if not acp._aurasUnifiedV65 then
        -- Resolve OR CREATE the rpDB profile that owns perLayoutToggles.
        -- ContainersFollowSection's field wipe is unconditional and
        -- irreversible, so a profile that could not be paired used to lose
        -- separateGroupConfig without ever getting the toggle that replaces
        -- it -- its per-Layout container geometry then silently reverted to the
        -- shared top level, undiagnosable because the flag was already gone.
        -- Only called when something actually needs the toggle set.
        local function ensureRPToggle()
            local t = self.rpDB and self.rpDB.profiles and self.rpDB.profiles[profileName]
            if t then return t end
            if self.rpDB and self.acDB and self.acDB.keys
               and profileName == self.acDB.keys.profile then
                t = self.rpDB.profile
                if t then return t end
            end
            if not (self.rpDB and self.rpDB.profiles) then return nil end
            t = {}
            self.rpDB.profiles[profileName] = t
            return t
        end
        self:_AuraMig_ContainersFollowSection(acp, ensureRPToggle)

        -- Custom Frame Groups live in cfgDB. Paired by EXACT NAME only: the old
        -- fallback to the active cfgDB profile remapped POSITIONAL "cfGroup_N"
        -- keys against an unrelated group array, assigning per-group container
        -- overrides to arbitrary groups -- the exact corruption that migration
        -- exists to remove, and strictly worse than leaving the keys alone.
        local cfgp   = self.cfgDB and self.cfgDB.profiles and self.cfgDB.profiles[profileName]
        local groups = cfgp and cfgp.customFrameGroups
        if type(groups) == "table" then
            self:_AuraMig_RekeyGroupSettings(acp, groups)
        end

        self:_AuraMig_OneSpellContainers(acp)
        self:_AuraMig_SingleBuffVisuals(acp)
        self:_AuraMig_DefaultCustomizations(acp)
        self:_AuraMig_CuratedSpells(acp)

        acp._aurasUnifiedV65 = true
    end

    -- OUTSIDE the sentinel, deliberately. EnsureBuffsPresetsSeeded self-guards
    -- on its own flag, is order-free, and MUST reach profiles that an early
    -- return above would skip -- on 12.1 the preset list is the only thing that
    -- renders ordinary buffs, so a profile that misses it logs in to a
    -- completely empty buff row.
    self:_AuraMig_SeedBuffsPresets(acp)

end

-- ============================================================
-- EnsureAurasMigratedForProfile
-- ============================================================
-- The versioned dispatcher lives in RegisterDB and is gated on
-- db.profile.dbVersion -- a MAIN-db stamp. acDB profiles are created
-- INDEPENDENTLY of it, so a new, copied or reset acDB profile is never seen by
-- that dispatcher.
--
-- OnProfileReset is the damaging one: it clears the sentinel AND
-- customBuffContainers, and nothing ever re-runs. The profile is then left with
-- ZERO Single Buff entries and, because the Aura Customizations page is hidden
-- on 12.1, no way to configure any curated spell at all.
--
-- Idempotent -- MigrateAurasUnified is sentinel-guarded per profile, so this is
-- a cheap no-op on a profile that has already been through it.
-- Takes AceDB's callback signature: CallbackHandler invokes the method as
-- (self, event, db, profileName). OnNewProfile fires while the profile is being
-- CREATED, which is not necessarily the active one, so the name it passes is
-- used in preference to acDB.keys.profile. Called with no arguments from
-- OnACProfileChanged, where the active profile is the right answer.
function BF:EnsureAurasMigratedForProfile(_, _, profileName)
    if not (self.acDB and self.acDB.keys) then return end
    self:MigrateAurasUnified(profileName or self.acDB.keys.profile)
end

-- ============================================================
-- MigrateCrowdControlToContainer  (v69, dbVersion 62)
-- ============================================================
-- The dedicated Crowd Control feature (CrowdControlIcons indicator + the
-- auras.crowdControl sub-category settings) became a seeded custom DEBUFF
-- container holding the crowdControl preset (HARMFUL|CROWD_CONTROL, claim
-- |!CROWD_CONTROL). Owner rulings (2026-08-14):
--   * The container is created by default for EVERYONE, carrying the old
--     feature's look; c.enabled reflects the old showCrowdControl, so users
--     who had CC off keep it off (the container sits disabled in the list).
--   * Old look carried into container-OWN settings (the three inherit
--     toggles set false), EXCEPT duration text when globalAuraTextConfig is
--     on (the default): the old CC text was driven by the unified global
--     block then, and the container's Debuffs-baseline inherit is the same
--     thing, so it INHERITS instead of freezing a never-consumed subcat.
--   * Dropped, no container equivalent: crowdControlShowGlow, the CC-specific
--     tooltip toggles (containers follow the Debuffs tooltip settings), and
--     per-CFG-group CC visibility (cfgDB profiles pair with acDB profiles by
--     simultaneous activity, not by name — a migration cannot know the
--     pairing; those groups follow the container's global Enabled now).
--
-- Per-flat carrying (only while perLayoutToggles.aurasDebuffs == true): every
-- flat gets groupSettings[flatID].showForGroupType = its resolved
-- showCrowdControl (explicit for ALL flats — a flat without an override
-- resolves to the global, and leaving it unwritten would flip it to "shown"
-- whenever another flat forced enabled = true). Raw per-flat geometry/border
-- overrides carry into the same groupSettings entry under the container field
-- names. rawget throughout: on the ACTIVE profile the subcat tables carry live
-- __index metatables (RehydrateFlats), so plain reads would mistake inherited
-- globals for per-flat overrides.
--
-- Seeding core is shared with GetCustomDebuffContainers' accessor-side seed
-- (same dual-caller pattern as EnsureBuffsPresetsSeeded): new/copied/reset
-- acDB profiles never reach the version dispatcher. The accessor passes no
-- carry table and seeds the FACTORY CC look (size 18, CENTER, max 1),
-- disabled — matching what a fresh profile's old defaults showed (nothing).
local CC_MIG_GEO_MAP = {
    crowdControlSize          = "buffSize",
    crowdControlMaxIcons      = "maxBuffs",
    crowdControlIconsPerRow   = "buffsPerRow",
    crowdControlSpacing       = "spacing",
    crowdControlRowSpacing    = "rowSpacing",
    crowdControlAnchor        = "anchorPoint",
    crowdControlOffsetX       = "offsetX",
    crowdControlOffsetY       = "offsetY",
    crowdControlGrowDirection = "growDirection",
    crowdControlBorderStyle     = "borderStyle",
    crowdControlBorderColor     = "borderColor",
    crowdControlBorderThickness = "borderThickness",
}
local CC_MIG_DUR_MAP = {
    showCrowdControlDuration   = "showDuration",
    crowdControlAutoScale      = "autoScale",
    crowdControlTimerScale     = "timerScale",
    crowdControlFontSize       = "fontSize",
    crowdControlDurationFont   = "durationFont",
    crowdControlDurationBorder = "durationBorder",
    crowdControlFontColor      = "fontColor",
    disableCrowdControlSwipe   = "disableSwipe",
    disableCrowdControlSpark   = "disableSpark",
    reverseCrowdControlSwipe   = "reverseSwipe",
    crowdControlHideDurationAbove1Min = "hideDurationAbove1Min",
}
-- RP factory defaults for the crowdControl sub-categories (raw non-active
-- profiles have no metatable, so nil means these).
local CC_MIG_GEO_DEF = {
    showCrowdControl = false, crowdControlMaxIcons = 1, crowdControlSize = 18,
    crowdControlAnchor = "CENTER", crowdControlOffsetX = 0, crowdControlOffsetY = 0,
    crowdControlGrowDirection = "RIGHT_DOWN", crowdControlIconsPerRow = 5,
    crowdControlSpacing = 1, crowdControlRowSpacing = 1,
    crowdControlBorderColor = { r = 0, g = 0, b = 0, a = 0.8 },
    crowdControlBorderThickness = 2, crowdControlBorderStyle = "flat",
    crowdControlBlizzardBorders = false,
}
local CC_MIG_DUR_DEF = {
    showCrowdControlDuration = false, crowdControlAutoScale = false,
    crowdControlTimerScale = 1.0, crowdControlFontSize = 11,
    crowdControlDurationFont = "Interface\\AddOns\\BuzzardFrames\\Media\\Fonts\\RobotoCondensed-Bold.ttf",
    crowdControlDurationBorder = "OUTLINE",
    crowdControlFontColor = { r = 1.0, g = 1.0, b = 1.0 },
    reverseCrowdControlSwipe = false, disableCrowdControlSwipe = false,
    disableCrowdControlSpark = false, crowdControlHideDurationAbove1Min = false,
}
local function ccMigCopy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = x end  -- colors are flat {r,g,b,a}
    return t
end

-- Shared seeding core. `carry` nil = factory CC look, disabled (accessor
-- path); otherwise the table MigrateCrowdControlToContainer built. Self-guards
-- on acp._ccContainerSeededV69 (set FIRST, EnsureBuffsPresetsSeeded pattern).
function BF:SeedCrowdControlContainer(acp, carry)
    if type(acp) ~= "table" or acp._ccContainerSeededV69 then return end
    acp._ccContainerSeededV69 = true
    local arr = acp.customDebuffContainers
    if type(arr) ~= "table" then arr = {}; acp.customDebuffContainers = arr end
    -- A user-built container already holding the preset wins; do not add a
    -- second CC container next to it.
    for i = 1, #arr do
        local p = type(arr[i]) == "table" and arr[i].presets
        if type(p) == "table" and p.crowdControl then return end
    end
    local c = {
        name      = "Crowd Control",
        autoNamed = false,  -- keep the name through NextCustomContainerName
        presets   = { crowdControl = true },
        -- Factory CC look (overridden by carry below): the old feature's own
        -- geometry, not the Debuffs baseline, so enabling the container shows
        -- exactly what the old feature showed.
        containerUsesDebuffSettings = false,
        buffSize = 18, maxBuffs = 1, buffsPerRow = 5,
        spacing = 1, rowSpacing = 1,
        anchorPoint = "CENTER", offsetX = 0, offsetY = 0,
        growDirection = "RIGHT_DOWN",
        containerUsesDebuffBorder = false,
        borderStyle = "flat",
        borderColor = { r = 0, g = 0, b = 0, a = 0.8 },
        borderThickness = 2,
        -- Duration inherits the Debuffs baseline unless carry says otherwise.
        -- Threshold scaffolding mirrors CreateCustomDebuffContainer's seed.
        autoScale = true,
        fontColor = { r = 1, g = 1, b = 1 },
        colorAuraBorder = false,
        thresholdColorEnabled = false, thresholdColorThreshold = 8,
        thresholdColor = BF.DEFAULT_THRESHOLD_COLOR,
        threshold2ColorEnabled = false, threshold2ColorThreshold = 5,
        threshold2Color = BF.DEFAULT_THRESHOLD2_COLOR,
        enabled = false,
    }
    if type(carry) == "table" then
        for k, v in pairs(carry) do c[k] = v end
    end
    arr[#arr + 1] = c
end

function BF:MigrateCrowdControlToContainer(profileName)
    local rp  = self.rpDB and self.rpDB.profiles and self.rpDB.profiles[profileName]
    local acp = self.acDB and self.acDB.profiles and self.acDB.profiles[profileName]
    -- No acDB profile of this name yet: the accessor-side seed covers it when
    -- (if ever) one is created and read.
    if not acp or acp._ccContainerSeededV69 then return end

    -- Effective-value reader: on the active profile the stored subcat table's
    -- __index already resolves absent keys to the factory default; on raw
    -- profiles nil falls back to our static copy of the same defaults.
    -- NOT `type(t)=="table" and t[k]`: that expression is FALSE (not nil) when
    -- t is absent, which would skip the default fallback and seed every
    -- carried field as `false` — blank dropdowns / zero sliders in options
    -- (PTR-caught before anyone ran this migration).
    local function val(t, defs, k)
        local v
        if type(t) == "table" then v = t[k] end
        if v == nil then v = defs[k] end
        return v
    end
    local function rawsub(t, a, b)
        local x = type(t) == "table" and rawget(t, a)
        if type(x) ~= "table" then return nil end
        local y = rawget(x, b)
        if type(y) == "table" then return y end
        return nil
    end

    local ccG  = rawsub(rp, "auras", "crowdControl")
    local durG = rawsub(rp, "auraText", "crowdControl")

    local carry = { enabled = val(ccG, CC_MIG_GEO_DEF, "showCrowdControl") == true }
    -- Geometry + border: container-own, carried field by field.
    carry.containerUsesDebuffSettings = false
    carry.containerUsesDebuffBorder   = false
    for old, new in pairs(CC_MIG_GEO_MAP) do
        carry[new] = ccMigCopy(val(ccG, CC_MIG_GEO_DEF, old))
    end
    -- Pre-v67 profiles: no style key, only the blizzard flag.
    if carry.borderStyle == nil then
        carry.borderStyle = (val(ccG, CC_MIG_GEO_DEF, "crowdControlBlizzardBorders") == true)
            and "blizzard" or "flat"
    end
    -- Duration text: with the unified global block on (the default), the old
    -- CC text never read the crowdControl subcat — inherit the Debuffs
    -- baseline (which the same global block drives) instead of freezing
    -- values the user never saw.
    local atG = type(rp) == "table" and rawget(rp, "auraText")
    local globalCfg = type(atG) == "table" and rawget(atG, "globalAuraTextConfig")
    if globalCfg == nil then globalCfg = true end
    if globalCfg == false then
        carry.containerUsesDebuffDurationSettings = false
        for old, new in pairs(CC_MIG_DUR_MAP) do
            carry[new] = ccMigCopy(val(durG, CC_MIG_DUR_DEF, old))
        end
    end

    -- Per-flat visibility (+ raw per-flat geometry overrides) while the
    -- Debuffs per-Layout tier is on. Deterministic order: sorted flat IDs.
    local layouts = type(rp) == "table" and rawget(rp, "layouts")
    local toggles = type(layouts) == "table" and rawget(layouts, "perLayoutToggles")
    -- dbVersion 65 renamed this toggle: auras_debuffs is the POST-normalize
    -- key, aurasDebuffs the pre-normalize one. BOTH are accepted, because the
    -- rename is NOT ordered relative to this migration and can land on either
    -- side of it:
    --   * On a login upgrade, this dispatches at `ver < 62`, which runs BEFORE
    --     the `ver < 65` rename block -- so it sees the OLD key.
    --   * On a profile change, a flat copy or an import,
    --     BF:NormalizeAuraPerLayoutKeys has already run from RehydrateFlats --
    --     so it sees the NEW key.
    -- Reading only one of the two names would silently drop every upgrader's
    -- per-Layout Crowd Control visibility in whichever case it did not cover.
    local ccPerLayout = (type(toggles) == "table")
        and (toggles.auras_debuffs == true or toggles.aurasDebuffs == true)
    if ccPerLayout and type(layouts.flatLayouts) == "table" then
        local ids = {}
        for id, flat in pairs(layouts.flatLayouts) do
            if type(id) == "string" and type(flat) == "table" then ids[#ids + 1] = id end
        end
        table.sort(ids)
        local gs
        for _, id in ipairs(ids) do
            local flat = layouts.flatLayouts[id]
            local fcc = rawsub(flat, "auras", "crowdControl")
            local show = fcc and rawget(fcc, "showCrowdControl")
            if show == nil then show = val(ccG, CC_MIG_GEO_DEF, "showCrowdControl") end
            show = show == true
            if show then carry.enabled = true end
            gs = gs or {}
            gs[id] = { showForGroupType = show }
            if fcc then
                for old, new in pairs(CC_MIG_GEO_MAP) do
                    local v = rawget(fcc, old)
                    if v ~= nil then gs[id][new] = ccMigCopy(v) end
                end
            end
        end
        carry.groupSettings = gs
    end

    self:SeedCrowdControlContainer(acp, carry)
end

-- ============================================================
-- MigrateDebuffTypeModel  (v84, dbVersion 66 -- plan Stage 5 §9.10)
-- ============================================================
-- The Debuffs section's "Debuffs to Show" (debuffShowMode) and its four
-- Enlarge toggles become a composable model: a Base Filter for the residual
-- "other debuffs" flow, five debuff TYPES (Boss / Role / Crowd Control /
-- Priority / Dispellable) each with its own toggle + Relative Size + Order,
-- and an orderable "Show Other Debuffs".
--
-- OWNER RULING 2026-08-16: the type rows are a UNIFORM RESET, not a
-- translation. Every profile gets all five types ON at the new default sizes
-- and Orders regardless of what its Enlarge toggles said. That is why this
-- migration WRITES NOTHING for them: the keys are absent, and absent resolves
-- to the factory default through the same sparse-storage path every other aura
-- key uses. Writing the defaults in would turn them into per-Layout OVERRIDES
-- on every flat that happened to carry a show mode, which is the opposite of
-- what a reset means.
--
-- What IS translated is the show mode, onto Base Filter + Show Other Debuffs
-- (+ the Dispellable Mode):
--
--   all                         -> base None,     Other ON
--   blizzardRaid                -> base Blizzard, Other ON   (TOKEN DELTA:
--                                  RAID_IN_COMBAT, not RAID|INCLUDE_NAME_PLATE_ONLY
--                                  -- owner-specified, release-note it)
--   blizzardRaidPlusDispellable -> base Blizzard, Other ON,   Dispellable = All
--   allDispellable              -> Other OFF,                 Dispellable = All
--   dispellableByMe             -> Other OFF,                 Dispellable = By Me
--
-- Accepted deltas (release-note them): every profile gains the five type groups
-- at the new default sizes/Orders whatever its previous Enlarge configuration;
-- the two dispellable-only modes gain the boss/role/CC/priority type groups on
-- top of their dispellable view (Show Other stays OFF, so the base flow stays
-- hidden).
--
-- ONE table-level worker, applied to every place a debuffs sub-category can be
-- stored: the global pseudo-layout (rp.auras.debuffs), every per-Layout flat
-- (flat.auras.debuffs) and every Custom Frame Group flat (in cfgDB). rawget
-- throughout, so a pristine flat that inherits `auras` through its metatable is
-- never given a rawkey table just to be cleaned.
local DEBUFF_SHOWMODE_MAP = {
    all                         = { base = "none",     other = true  },
    blizzardRaid                = { base = "blizzard", other = true  },
    blizzardRaidPlusDispellable = { base = "blizzard", other = true,  dispel = "all" },
    allDispellable              = { base = "none",     other = false, dispel = "all" },
    dispellableByMe             = { base = "none",     other = false, dispel = "me"  },
}
local DEBUFF_DEAD_KEYS = {
    "debuffShowMode",
    "enlargeBossDebuffs", "enlargePriorityDebuffs",
    "enlargeRoleDebuffs", "enlargeCCDebuffs",
    -- v85: the legacy numeric "Sort By" key. It had been INERT for a long time
    -- (written to the aura cache, read by nothing) and its widget went with the
    -- §9.6 Sort Order dropdown that replaces it. Cleaned here rather than under
    -- its own dbVersion because nothing reads it either way — a profile already
    -- stamped at 66+ simply keeps an unread number.
    "debuffSortRule",
}

local function DebuffTypeModelTable(dbt)
    if type(dbt) ~= "table" then return end
    local mode = rawget(dbt, "debuffShowMode")
    local m = type(mode) == "string" and DEBUFF_SHOWMODE_MAP[mode]
    if m then
        dbt.debuffBaseFilter = m.base
        dbt.debuffShowOther  = m.other
        if m.dispel then dbt.debuffDispellableMode = m.dispel end
    end
    for i = 1, #DEBUFF_DEAD_KEYS do
        dbt[DEBUFF_DEAD_KEYS[i]] = nil
    end
end

local function DebuffTypeModelFlat(flat)
    if type(flat) ~= "table" then return end
    local fa = rawget(flat, "auras")
    if type(fa) ~= "table" then return end
    DebuffTypeModelTable(rawget(fa, "debuffs"))
end

-- rpDB half: the global sub-category plus every per-Layout flat.
-- Idempotent per profile (rp._debuffTypeModelV84).
function BF:MigrateDebuffTypeModel(profileName)
    local rp = self.rpDB and self.rpDB.profiles and self.rpDB.profiles[profileName]
    if type(rp) ~= "table" or rp._debuffTypeModelV84 then return end
    rp._debuffTypeModelV84 = true

    local auras = rawget(rp, "auras")
    if type(auras) == "table" then
        DebuffTypeModelTable(rawget(auras, "debuffs"))
    end
    local layouts = rawget(rp, "layouts")
    local fl = type(layouts) == "table" and rawget(layouts, "flatLayouts")
    if type(fl) == "table" then
        for _, flat in pairs(fl) do
            DebuffTypeModelFlat(flat)
        end
    end
end

-- Custom Frame Groups live in cfgDB, which has its OWN profile set, so this
-- walks cfgDB itself rather than being called per profile name -- the same
-- shape as MigrateSplitCFGOverrideAuras / MigrateSeedCFGOverrideFlags.
-- Idempotent per cfgDB profile (cfgp._debuffTypeModelV84).
function BF:MigrateDebuffTypeModelCFG()
    local cfgDB = self.cfgDB
    if not (cfgDB and cfgDB.profiles) then return end
    for _, cfgp in pairs(cfgDB.profiles) do
        if type(cfgp) == "table" and not cfgp._debuffTypeModelV84 then
            cfgp._debuffTypeModelV84 = true
            local groups = rawget(cfgp, "customFrameGroups")
            if type(groups) == "table" then
                for _, grp in pairs(groups) do
                    if type(grp) == "table" then
                        DebuffTypeModelFlat(rawget(grp, "flat"))
                    end
                end
            end
        end
    end
end

-- ============================================================
-- MigrateIconEffects  (v84, dbVersion 67 -- plan Stage 5 §9.9)
-- ============================================================
-- The per-spell "Icon Effects" subtab is rebuilt around ONE entry table,
-- acDB.profile.specSpellIconEffect[<kSpec>][<spellID>], replacing:
--
--   specSpellExpirationGlow  the v47 "Glow Border" (Show Glow + Glow Color on
--                            top of threshold / showMode / glowType). ROOT
--                            CAUSE of its long-standing "isn't working
--                            properly": the stored shape is THRESHOLD-driven
--                            (showMode = "threshold", threshold = 3s) but
--                            remaining duration is SECRET on 12.1, so the
--                            threshold can never be evaluated and v47 could
--                            only ever render a static always-on ring. The
--                            threshold behavior is not replicable by engine
--                            design; the engine-computed Pandemic Effect is
--                            the replacement for "glow when expiring".
--   specSpellVisualAlert     the v49 native 0-10 Marching Ants / Flash list,
--                            superseded by the addon-side Icon Effect (same
--                            ants/flash art, freely tintable).
--
-- Mapping:
--   glow  enabled (entry present and enabled ~= false)
--         -> effect = "glow", glowStyle = "steady" (the only thing v47 could
--            actually draw), color = the stored color. threshold / showMode /
--            glowType are DROPPED -- none of them was ever evaluable.
--   alert 1-5 -> effect = "ants";  6-10 -> effect = "flash"
--         The color variants bake into the effect color (Cyan / Red / Green
--         / Blue as the v49 table defined them); the two default variants
--         (1 and 6) take the new default {1, 0.82, 0.25, 1}.
--
-- Glow WINS when a spell somehow carries both, because it is the one the user
-- had to configure deliberately (the alert was a single dropdown pick), and a
-- spell can only have one Icon Effect.
--
-- Both source tables are then NILLED. specSpellBounce is left alone: it was
-- already retired in v66/v67 and is not part of this subtab's storage.
--
-- TWO STORAGE ROOTS, not one. This is the trap:
--
--   curated spec spell -> acDB.profile[family][<specID>][spellID]
--   SINGLE BUFF        -> container.sbVisuals[family]["sb"][spellID]
--
-- (AuraCustomizationHelpers.lua SBRoot/SBEntry). The single-buff store lives
-- INSIDE the container entry in acDB.profile.customBuffContainers, not under
-- the profile-level family table, so a migration that only walked the latter
-- would silently drop every single buff's Glow Border / Visual Alert: the old
-- families are never read again, and the new one would have no row. Both roots
-- are walked below, through the same row builder -- the migration never
-- interprets the key, it only re-homes the row.
--
-- Idempotent per acDB profile (acp._iconEffectsV84).
local ALERT_TO_EFFECT = {
    [1]  = { effect = "ants" },
    [2]  = { effect = "ants",  r = 0,    g = 1,    b = 1    },
    [3]  = { effect = "ants",  r = 1,    g = 0.25, b = 0.25 },
    [4]  = { effect = "ants",  r = 0.25, g = 1,    b = 0.25 },
    [5]  = { effect = "ants",  r = 0.35, g = 0.6,  b = 1    },
    [6]  = { effect = "flash" },
    [7]  = { effect = "flash", r = 0,    g = 1,    b = 1    },
    [8]  = { effect = "flash", r = 1,    g = 0.25, b = 0.25 },
    [9]  = { effect = "flash", r = 0.25, g = 1,    b = 0.25 },
    [10] = { effect = "flash", r = 0.35, g = 0.6,  b = 1    },
}

local function IconEffectRow(dst, kSpec, sid)
    if not dst[kSpec] then dst[kSpec] = {} end
    local e = dst[kSpec][sid]
    if not e then e = {}; dst[kSpec][sid] = e end
    return e
end

-- One acDB profile. `acp` is a RAW profile table (self.acDB.profiles[name]),
-- so every read is rawget-safe by construction: per-spell tables are created
-- dynamically and have no AceDB defaults behind them.
function BF:MigrateIconEffects(profileName)
    local acp = self.acDB and self.acDB.profiles and self.acDB.profiles[profileName]
    if type(acp) ~= "table" or acp._iconEffectsV84 then return end
    acp._iconEffectsV84 = true

    -- ONE root's worth of work: `src` is the table that owns the two retired
    -- families, `dst` the icon-effect table on the SAME root. Returns the dst
    -- table (or nil when it ended up empty) so the caller can store or drop it.
    local function MigrateOneRoot(src)
        if type(src) ~= "table" then return nil end
        local dst = src.specSpellIconEffect
        if type(dst) ~= "table" then dst = {} end

        -- Blizzard Visual Alert FIRST, so a spell carrying BOTH ends up with
        -- the deliberately-configured glow (applied second, overwriting
        -- `effect`) -- the alert was a single dropdown pick.
        local va = src.specSpellVisualAlert
        if type(va) == "table" then
            for kSpec, map in pairs(va) do
                if type(map) == "table" then
                    for sid, val in pairs(map) do
                        local m = type(val) == "number" and ALERT_TO_EFFECT[val]
                        if m then
                            local e = IconEffectRow(dst, kSpec, sid)
                            e.effect = m.effect
                            if m.r then
                                e.color = { r = m.r, g = m.g, b = m.b, a = 1 }
                            end
                        end
                    end
                end
            end
        end

        local eg = src.specSpellExpirationGlow
        if type(eg) == "table" then
            for kSpec, map in pairs(eg) do
                if type(map) == "table" then
                    for sid, entry in pairs(map) do
                        if type(entry) == "table" and entry.enabled ~= false then
                            local e = IconEffectRow(dst, kSpec, sid)
                            e.effect = "glow"
                            -- v47 could only draw a STATIC ring, so a migrated
                            -- profile keeps looking exactly as it did.
                            e.glowStyle = nil   -- nil == "steady"
                            local c = entry.color
                            if type(c) == "table" then
                                e.color = { r = c.r or 1, g = c.g or 0.2,
                                            b = c.b or 0.2, a = c.a or 1 }
                            end
                        end
                    end
                end
            end
        end

        -- Drop empty rows the two loops may have created for values that
        -- mapped to nothing, then retire the source tables on this root.
        for kSpec, map in pairs(dst) do
            for sid, e in pairs(map) do
                if type(e) ~= "table" or next(e) == nil then map[sid] = nil end
            end
            if next(map) == nil then dst[kSpec] = nil end
        end
        src.specSpellExpirationGlow = nil
        src.specSpellVisualAlert    = nil
        if next(dst) == nil then return nil end
        return dst
    end

    -- Root 1: the profile-level families (curated spec spells).
    acp.specSpellIconEffect = MigrateOneRoot(acp)

    -- Root 2: every SINGLE BUFF's own store. Single buffs live in
    -- customBuffContainers with singleBuff = true and keep their per-spell
    -- visuals under container.sbVisuals, keyed "sb" instead of by specID.
    -- Walked unconditionally rather than gated on singleBuffCustomized: SBRoot
    -- returns nil for an entry currently in "Show (Default Buff)" mode, but the
    -- stored table survives that mode and must still be re-homed, or switching
    -- back to Customized would resurrect settings the new options cannot read.
    local cbc = acp.customBuffContainers
    if type(cbc) == "table" then
        for _, c in pairs(cbc) do
            if type(c) == "table" and type(c.sbVisuals) == "table" then
                c.sbVisuals.specSpellIconEffect = MigrateOneRoot(c.sbVisuals)
            end
        end
    end
end

-- ============================================================
-- MigrateBorderOpacityToAlpha  (dbVersion 69)
--
-- The frame-border section used to carry a separate borderOpacity scalar
-- (0.1-1.0) alongside a no-alpha borderColor {r,g,b}. v69 folds the opacity
-- into borderColor.a so the one control (the color picker's alpha) drives both
-- -- and so the Raid/Party model matches the Unit Frames model, whose border
-- color already carries alpha. Container.lua now reads borderColor.a; the
-- borderOpacity key is retired.
--
-- Two companions, same as MigrateColorAuraBorderRP / *AC:
--   * this one walks the rpDB global `borders` section + every flatLayout's
--     `borders` (per rpDB profile, sentinel rp._borderOpacityFoldedV69).
--   * MigrateBorderOpacityToAlphaCFG (below) walks cfgDB's customFrameGroups
--     flats (per cfgDB profile, sentinel cfgp._borderOpacityFoldedV69).
--
-- Fold policy: seed borderColor.a from borderOpacity ONLY when borderColor
-- exists and its .a is still absent, so a re-run cannot stomp a value the user
-- set after upgrading. borderOpacity is nil'd unconditionally once seen. A
-- section that has borderOpacity but no borderColor table is left with a=nil,
-- which Container.lua reads as 1.0 (the old default when opacity was unset).
-- Idempotent; fresh installs are no-ops (stamped straight at DB_VERSION).
-- ============================================================
local function FoldBorderOpacity(borders)
    if type(borders) ~= "table" then return end
    local op = rawget(borders, "borderOpacity")
    if op == nil then return end
    local bc = rawget(borders, "borderColor")
    if type(bc) == "table" and bc.a == nil then
        bc.a = op
    end
    borders.borderOpacity = nil
end

function BF:MigrateBorderOpacityToAlpha(profileName)
    profileName = profileName or self.rpDB.keys.profile
    local rp = self.rpDB and self.rpDB.profiles and self.rpDB.profiles[profileName]
    if not rp then return end
    if rp._borderOpacityFoldedV69 then return end

    -- 1. Global pseudo-layout.
    FoldBorderOpacity(rawget(rp, "borders"))

    -- 2. Every per-flat cache (flat.borders).
    if rp.layouts and type(rp.layouts.flatLayouts) == "table" then
        for _, flat in pairs(rp.layouts.flatLayouts) do
            if type(flat) == "table" then
                FoldBorderOpacity(rawget(flat, "borders"))
            end
        end
    end

    rp._borderOpacityFoldedV69 = true
end

-- Companion for cfgDB (Custom Frame Groups). cfgDB has its own profile set, so
-- this walks cfgDB itself and is dispatched ONCE, outside the per-profile loop
-- -- same shape as MigrateSplitCFGOverrideAuras. Each group's border section
-- lives at group.flat.borders.
function BF:MigrateBorderOpacityToAlphaCFG()
    if not self.cfgDB then return end
    for _, cfgName in ipairs(self.cfgDB:GetProfiles()) do
        local cfgp = self.cfgDB.profiles and self.cfgDB.profiles[cfgName]
        if type(cfgp) == "table" and not cfgp._borderOpacityFoldedV69
           and type(cfgp.customFrameGroups) == "table" then
            for _, group in pairs(cfgp.customFrameGroups) do
                if type(group) == "table" then
                    FoldBorderOpacity(rawget(group, "flat") and rawget(group.flat, "borders"))
                end
            end
            cfgp._borderOpacityFoldedV69 = true
        end
    end
end

-- ── Migration 70: RAID Grow-from-Center CENTER-anchor → cross-axis EDGE.
-- RAID Grow-from-Center used to pin the layout by a full CENTER anchor, so the
-- stored anchorX/anchorY were the block's CENTER on both axes. It now pins by
-- the cross-axis EDGE derived from grow direction (DOWN→TOP, UP→BOTTOM,
-- RIGHT→LEFT, LEFT→RIGHT), centring only perpendicular to the grow axis. So
-- the stored GROW-AXIS coordinate must shift by half the block's grow-axis
-- full extent, keeping the block exactly where it is; the cross-axis
-- coordinate is unchanged (center == center there).
--
-- PARTY is NOT converted: a party is a single group and keeps the full CENTER
-- anchor, so its stored CENTER coordinate stays valid.
--
-- Directional shift (offsets are relative to UIParent CENTER; screen-up = +y):
--   grow DOWN  → anchor TOP    : anchorY += halfH   (top    = center + halfH)
--   grow UP    → anchor BOTTOM : anchorY -= halfH   (bottom = center - halfH)
--   grow RIGHT → anchor LEFT   : anchorX -= halfW   (left   = center - halfW)
--   grow LEFT  → anchor RIGHT  : anchorX += halfW   (right  = center + halfW)
--
-- Runs BEFORE RehydrateFlats: flats are sparse (default-equal fields are
-- rawget-nil, the __index fallback not yet wired), so every field read uses
-- the SAME defaults UpdateSize uses. ComputeHeaderScale is NOT safe here (it
-- needs live _resolvedProfile / UIParent scale), so the scale is taken from
-- the flat's own enableFrameScale/frameScale/scaleIndicators, matching the
-- addon's offline anchor-frame sizing (BFLayout.lua CFG/pet paths).
-- Sentinel-guarded (rp._growCenterEdgeV70), idempotent, fresh installs no-op.
function BF:MigrateGrowFromCenterAnchorV70(profileName)
    profileName = profileName or self.rpDB.keys.profile
    local rp = self.rpDB and self.rpDB.profiles and self.rpDB.profiles[profileName]
    if not rp then return end
    if rp._growCenterEdgeV70 then return end

    local flats = rp.layouts and rp.layouts.flatLayouts
    if type(flats) == "table" then
        -- sorting-section resolution (mirrors GetSectionProfile / migration 39):
        -- use the per-flat override only when the per-layout sorting toggle is on.
        local globalSort = rawget(rp, "sorting")
        local perLayout  = rp.layouts and rp.layouts.perLayoutToggles
                           and rp.layouts.perLayoutToggles.sorting

        for _, flat in pairs(flats) do
            if type(flat) == "table" then
                local ax, ay = rawget(flat, "anchorX"), rawget(flat, "anchorY")
                if ax and ay then
                    local sp = (perLayout and rawget(flat, "sorting")) or globalSort
                    local ftype = rawget(flat, "type")

                    -- RAID ONLY. Party grow-from-center keeps the full CENTER
                    -- anchor (a party is a single group — see GetLayoutAnchor),
                    -- so its stored CENTER coordinate needs no conversion. Only
                    -- raid moved CENTER → cross-axis edge and must be shifted.
                    local isRaid = ftype == "raid"
                    local onCenter, growDir, halfW, halfH

                    if isRaid then
                        onCenter = sp and sp.raidGrowFromCenter
                        growDir  = (sp and sp.raidGrowDirection) or "DOWN"
                        if onCenter then
                            local fw  = rawget(flat, "frameWidth")   or 70
                            local fh  = rawget(flat, "frameHeight")  or 40
                            local spH = rawget(flat, "frameSpacingH") or 0
                            local spV = rawget(flat, "frameSpacingV") or 0
                            local isGroup = sp and sp.sortingMode == "GROUP"
                            local upc = isGroup and 5 or ((sp and sp.unitsPerColumn) or 5)
                            local scale = 1.0
                            if rawget(flat, "enableFrameScale") and rawget(flat, "frameScale")
                               and rawget(flat, "scaleIndicators") ~= false then
                                scale = rawget(flat, "frameScale")
                            end
                            -- grow-axis extent = ONE column of `upc` frames.
                            local isH = (growDir == "RIGHT" or growDir == "LEFT")
                            if isH then
                                halfW = (upc * fw + math.max(0, upc - 1) * spH) * scale / 2
                            else
                                halfH = (upc * fh + math.max(0, upc - 1) * spV) * scale / 2
                            end
                        end
                    end

                    if onCenter then
                        if growDir == "DOWN" and halfH then
                            flat.anchorY = math.floor(ay + halfH + 0.5)
                        elseif growDir == "UP" and halfH then
                            flat.anchorY = math.floor(ay - halfH + 0.5)
                        elseif growDir == "RIGHT" and halfW then
                            flat.anchorX = math.floor(ax - halfW + 0.5)
                        elseif growDir == "LEFT" and halfW then
                            flat.anchorX = math.floor(ax + halfW + 0.5)
                        end
                    end
                end
            end
        end
    end

    rp._growCenterEdgeV70 = true
end

-- ============================================================
-- MigrateDebuffPriorityList  (v91, dbVersion 71 -- owner ruling 2026-08-17)
-- ============================================================
-- The Debuffs Preset/Filter tab's four per-type Order dropdowns, the "Order"
-- on Other Debuffs and the Dispellable Mode dropdown are replaced by ONE
-- reorderable PRIORITY LIST of seven rows carrying UNIQUE ranks 1..7 --
-- Boss, Role, CC, Dispellable by Me, Dispellable by Others, Priority, Other --
-- plus three Combine checkboxes. Behavior-preserving translation:
--
--   * RANKS: sort the six old items by (stored Order, canonical seq
--     Boss -> Role -> CC -> Priority -> Dispellable -> Other) and hand out
--     1..7 in that sequence. Dispellable's slot becomes DispMe then
--     DispOthers, adjacent, Me first -- so whatever sat after Dispellable
--     simply shifts down one.
--   * DISPELLABLE MODE "all" -> combineDispel = true, BOTH new Show toggles =
--     the old Dispellable toggle, BOTH new sizes = the old size (one row, same
--     content as the old "All Dispellable" group).
--     Mode "me"  -> combineDispel = false, DispMe takes the old toggle/size,
--     DispOthers Show = false (the old "by me" view showed nothing else).
--   * combineBossRole = true iff the retired same-size auto-merge would have
--     fired (both types on AND equal Relative Size) -- otherwise false.
--   * combinePriorityOther = false (the old model never merged them).
--   * Container presets: allDispellable -> othersDispellable, PLUS
--     meDispellable when no other container already holds it (a preset lives
--     in exactly one container). See MigrateDebuffPriorityListAC below.
--   * Old keys pruned: debuffOrder*, debuffOtherOrder, debuffDispellableMode,
--     debuffTypeDispellable, debuffSizeDispellable.
--
-- Unlike the v84 type-model migration this WRITES the resolved values rather
-- than leaving keys absent: the translation is per-profile behavior, not a
-- reset, so the numbers have to land where the old ones were stored. A table
-- carrying NONE of the old keys is skipped outright, so a pristine sparse flat
-- is never densified just to restate the factory defaults (which are exactly
-- what this translation produces for a default profile anyway).
--
-- ONE table-level worker applied to every place a debuffs sub-category can be
-- stored: rp.auras.debuffs, every flat.auras.debuffs, and every Custom Frame
-- Group flat in cfgDB -- the same shape as MigrateDebuffTypeModel.
local DEBUFF_OLD_ORDER_DEFAULT = {
    boss = 1, role = 1, cc = 2, priority = 3, dispellable = 4, other = 4,
}
-- Canonical sequence = the old tie-break rule, verbatim.
local DEBUFF_OLD_SEQ = {
    boss = 1, role = 2, cc = 3, priority = 4, dispellable = 5, other = 6,
}
local DEBUFF_OLD_ORDER_KEY = {
    boss = "debuffOrderBoss", role = "debuffOrderRole", cc = "debuffOrderCC",
    priority = "debuffOrderPriority", dispellable = "debuffOrderDispellable",
    other = "debuffOtherOrder",
}
-- Rank key per resolved item; `dispellable` expands into two (Me first).
local DEBUFF_NEW_RANK_KEY = {
    boss = "debuffRankBoss", role = "debuffRankRole", cc = "debuffRankCC",
    priority = "debuffRankPriority", other = "debuffRankOther",
}
local DEBUFF_PRIORITY_DEAD_KEYS = {
    "debuffOrderBoss", "debuffOrderRole", "debuffOrderCC",
    "debuffOrderPriority", "debuffOrderDispellable", "debuffOtherOrder",
    "debuffDispellableMode", "debuffTypeDispellable", "debuffSizeDispellable",
}
local DEBUFF_PRIORITY_ITEMS = {
    "boss", "role", "cc", "priority", "dispellable", "other",
}

local function DebuffPriorityHasOldKeys(dbt)
    for i = 1, #DEBUFF_PRIORITY_DEAD_KEYS do
        if rawget(dbt, DEBUFF_PRIORITY_DEAD_KEYS[i]) ~= nil then return true end
    end
    return false
end

local function DebuffPriorityListTable(dbt)
    if type(dbt) ~= "table" then return end
    if not DebuffPriorityHasOldKeys(dbt) then return end

    -- 1. Ranks. Sort by (stored Order or its old default, canonical seq).
    local items = {}
    for i = 1, #DEBUFF_PRIORITY_ITEMS do
        local id = DEBUFF_PRIORITY_ITEMS[i]
        local ord = rawget(dbt, DEBUFF_OLD_ORDER_KEY[id])
        if type(ord) ~= "number" then ord = DEBUFF_OLD_ORDER_DEFAULT[id] end
        items[i] = { id = id, ord = ord, seq = DEBUFF_OLD_SEQ[id] }
    end
    table.sort(items, function(a, b)
        if a.ord ~= b.ord then return a.ord < b.ord end
        return a.seq < b.seq
    end)
    local rank = 0
    for i = 1, #items do
        local id = items[i].id
        if id == "dispellable" then
            rank = rank + 1; dbt.debuffRankDispMe = rank
            rank = rank + 1; dbt.debuffRankDispOthers = rank
        else
            rank = rank + 1; dbt[DEBUFF_NEW_RANK_KEY[id]] = rank
        end
    end

    -- 2. The Dispellable split. Old toggle defaulted ON, old size 1.0.
    local oldShow = rawget(dbt, "debuffTypeDispellable") ~= false
    local oldSize = rawget(dbt, "debuffSizeDispellable") or 1.0
    if rawget(dbt, "debuffDispellableMode") == "me" then
        dbt.debuffCombineDispel   = false
        dbt.debuffTypeDispMe      = oldShow
        dbt.debuffSizeDispMe      = oldSize
        dbt.debuffTypeDispOthers  = false
        dbt.debuffSizeDispOthers  = oldSize
    else
        dbt.debuffCombineDispel   = true
        dbt.debuffTypeDispMe      = oldShow
        dbt.debuffSizeDispMe      = oldSize
        dbt.debuffTypeDispOthers  = oldShow
        dbt.debuffSizeDispOthers  = oldSize
    end

    -- 3. Combine flags. Boss+Role reproduces the retired auto-merge condition
    -- (both on, equal size); Priority+Other never merged before.
    local bossOn = rawget(dbt, "debuffTypeBoss") ~= false
    local roleOn = rawget(dbt, "debuffTypeRole") ~= false
    local bossSz = rawget(dbt, "debuffSizeBoss") or 1.4
    local roleSz = rawget(dbt, "debuffSizeRole") or 1.4
    dbt.debuffCombineBossRole      = bossOn and roleOn and bossSz == roleSz
    dbt.debuffCombinePriorityOther = false

    -- 4. Prune.
    for i = 1, #DEBUFF_PRIORITY_DEAD_KEYS do
        dbt[DEBUFF_PRIORITY_DEAD_KEYS[i]] = nil
    end
end

local function DebuffPriorityListFlat(flat)
    if type(flat) ~= "table" then return end
    local fa = rawget(flat, "auras")
    if type(fa) ~= "table" then return end
    DebuffPriorityListTable(rawget(fa, "debuffs"))
end

-- rpDB half: the global sub-category plus every per-Layout flat.
-- Idempotent per profile (rp._debuffPriorityListV91).
function BF:MigrateDebuffPriorityList(profileName)
    local rp = self.rpDB and self.rpDB.profiles and self.rpDB.profiles[profileName]
    if type(rp) ~= "table" or rp._debuffPriorityListV91 then return end
    rp._debuffPriorityListV91 = true

    local auras = rawget(rp, "auras")
    if type(auras) == "table" then
        DebuffPriorityListTable(rawget(auras, "debuffs"))
    end
    local layouts = rawget(rp, "layouts")
    local fl = type(layouts) == "table" and rawget(layouts, "flatLayouts")
    if type(fl) == "table" then
        for _, flat in pairs(fl) do
            DebuffPriorityListFlat(flat)
        end
    end
end

-- cfgDB companion (Custom Frame Groups), dispatched ONCE outside the
-- per-profile loop -- same shape as MigrateDebuffTypeModelCFG.
function BF:MigrateDebuffPriorityListCFG()
    local cfgDB = self.cfgDB
    if not (cfgDB and cfgDB.profiles) then return end
    for _, cfgp in pairs(cfgDB.profiles) do
        if type(cfgp) == "table" and not cfgp._debuffPriorityListV91 then
            cfgp._debuffPriorityListV91 = true
            local groups = rawget(cfgp, "customFrameGroups")
            if type(groups) == "table" then
                for _, grp in pairs(groups) do
                    if type(grp) == "table" then
                        DebuffPriorityListFlat(rawget(grp, "flat"))
                    end
                end
            end
        end
    end
end

-- acDB companion: the RETIRED allDispellable container preset. Walks EVERY
-- acDB profile (custom debuff containers live there, in their own profile
-- set), so a profile the user has not switched to is migrated too. The live
-- accessor (BF:GetCustomDebuffContainers) carries the identical rule for the
-- new/copied/reset profiles that never reach a dbVersion dispatcher; both are
-- idempotent, so whichever runs first wins and the other no-ops.
--
-- Rule (owner ruling 2026-08-17): the holder gains othersDispellable, plus
-- meDispellable if no other container already holds it. A preset lives in
-- exactly one container, so a meDispellable taken elsewhere leaves the holder
-- with only othersDispellable -- the by-me subset keeps rendering where it is.
function BF:MigrateDebuffPriorityListAC()
    local acDB = self.acDB
    if not (acDB and acDB.profiles) then return end
    for _, acp in pairs(acDB.profiles) do
        if type(acp) == "table" and not acp._debuffPriorityListV91 then
            acp._debuffPriorityListV91 = true
            local arr = rawget(acp, "customDebuffContainers")
            if type(arr) == "table" then
                local meTaken = false
                for i = 1, #arr do
                    local p = type(arr[i]) == "table" and arr[i].presets
                    if type(p) == "table" and p.meDispellable then
                        meTaken = true
                        break
                    end
                end
                for i = 1, #arr do
                    local c = arr[i]
                    local p = type(c) == "table" and c.presets
                    if type(p) == "table" and p.allDispellable then
                        p.othersDispellable = true
                        local rs = c.presetRelativeSize
                        local pct = rs and rs.allDispellable
                        if not meTaken then
                            p.meDispellable = true
                            meTaken = true
                            if pct and rs.meDispellable == nil then
                                rs.meDispellable = pct
                            end
                        end
                        if pct and rs.othersDispellable == nil then
                            rs.othersDispellable = pct
                        end
                        if rs then rs.allDispellable = nil end
                        p.allDispellable = nil
                    end
                end
            end
        end
    end
end

-- ============================================================
-- MIGRATION 72 (v92): STABLE MULTI-ICON CONTAINER KEYS
-- ============================================================
-- Every multi-icon custom BUFF container gains c.containerKey = "c_<n>", the
-- stable identity a Single Buff's flow anchor references ("C:<key>"). Without
-- it the only handle on a container is its array index ci, which shifts on
-- every delete -- RemoveCustomBuffContainer renumbers nothing by design, so an
-- index-based anchor would silently repoint at whatever entry inherited the
-- slot.
--
-- Walks EVERY acDB profile, the same shape as MigrateDebuffPriorityListAC
-- above: custom containers live in acDB's own profile set, so a profile the
-- user has not switched to is migrated too. Sentinel-guarded per profile
-- (_containerKeysV92) and idempotent -- entries that already carry a key are
-- left exactly as they are, so a re-run mints nothing and a fresh install (no
-- containers, or a profile stamped straight at DB_VERSION) is a no-op.
--
-- Single buffs are SKIPPED: they carry singleBuffKey, they are never a host,
-- and a containerKey on one would put them in the anchor dropdown as a target
-- for themselves.
--
-- Minting is BF:NewContainerKey against the WALKED array, never the live one.
-- Passing the array is why that function takes it as an argument and refuses to
-- fetch: a fetch would scan the active profile and hand out keys already taken
-- in the profile being migrated. Because the array grows keys as we go, each
-- mint sees the ones stamped by the previous iterations of the same walk.
--
-- No anchor values need translating: "BIGDEF" / "C:<key>" only ever exist after
-- v92 ships, and existing "BUFFS" entries are untouched.
function BF:MigrateContainerKeysAC()
    local acDB = self.acDB
    if not (acDB and acDB.profiles) then return end
    for _, acp in pairs(acDB.profiles) do
        if type(acp) == "table" and not acp._containerKeysV92 then
            acp._containerKeysV92 = true
            local arr = rawget(acp, "customBuffContainers")
            if type(arr) == "table" then
                for i = 1, #arr do
                    local c = arr[i]
                    if type(c) == "table" and not c.singleBuff
                        and c.containerKey == nil then
                        c.containerKey = self:NewContainerKey(arr)
                    end
                end
            end
        end
    end
end

-- ============================================================
-- MIGRATION 80: CONTAINER-ASSIGNED SPELLS BECOME BUFF LIST ENTRIES
-- ============================================================
-- Owner ruling 2026-09-14: on 12.1 a multi-icon buff container is a host of
-- Buff List entries anchored to it (plus its presets), the way the Buffs row
-- is -- a non-customized entry joins the container's own aura group and
-- draws with the container's settings. The per-spec assignment model
-- (acp.spellAssign[spec][sid] = "c:<i>", mirrored in c.selectedSpells) was
-- the Ace panel's way of putting a spell in a container; migrations 57/59
-- deliberately left those spells WITHOUT an entry so they would not render
-- twice. This carries them over and retires the model for buff containers:
-- BuildContainerRelevance and PreallocateContainerPools stopped reading it
-- in the same build.
--
-- ONE ENTRY PER (container, spell). Its Conditions are the ENTRY's, from the
-- Buff List's point of view: a Spec condition naming exactly the specs the
-- spell was assigned to that container under (dense over the spec universe,
-- as 57/59 write it), narrowed by the container's own old Spec condition
-- where it had one -- so nothing becomes visible that was not -- and the
-- container's Applied By, which is what its group filtered by. A spell filed
-- under three specs in one container is one entry with three specs on; the
-- same spell in two containers is two entries.
--
-- The entry: anchorPoint = "C:<containerKey>", singleBuffCustomized = false
-- (Show (Default Buff): no per-entry visuals, the host's settings), and
-- containerUsesBuffSettings = true, exactly as 57/59 create an in-row entry.
-- Its Order is the old specSpellOrdering[spec][sid] slot (the first spec,
-- sorted, that had one), written where BF:GetSingleBuffOrder reads it.
-- Nothing else is copied: per-spell visuals belonged to the Advanced
-- container type, which the panel no longer has.
--
-- THEN THE MODEL IS RETIRED on every multi-icon buff container in the
-- profile, not only the ones that held assignments: selectedSpells is
-- dropped, the assignments are released to "default" (the entry claims the
-- spell wherever its Spec condition is met -- GetClaimedSpells -- so the
-- regular row still stays off it), and the container-level Spec condition
-- (loadSpec / loadSpecTypes, the v64 widening) is dropped too: the runtime
-- no longer reads it on a multi-icon container, whose presence on a spec is
-- now derived from its entries.
--
-- Walks every acDB profile ONCE (the *AC shape), sentinel-guarded per
-- profile (_containerSpellsToBuffListV80) and idempotent: an entry already
-- anchored to the container for that spell is reused rather than minted
-- again. A container that somehow has no containerKey (migration 72 ran
-- first, so only a hand-edited profile) is given one here.
function BF:MigrateContainerSpellsToBuffList()
    local acDB = self.acDB
    if not (acDB and acDB.profiles) then return end
    for _, acp in pairs(acDB.profiles) do
        if type(acp) == "table" and not acp._containerSpellsToBuffListV80 then
            acp._containerSpellsToBuffListV80 = true
            local containers = rawget(acp, "customBuffContainers")
            local assign     = rawget(acp, "spellAssign")
            if type(containers) == "table" then
                local universe = singleBuffSpecUniverse(assign)

                -- (container index, spell) -> the specs that filed it there.
                -- Deterministic: sorted spec IDs, then sorted spell IDs, so
                -- keys are minted and entries appended in the same order on
                -- every run.
                local held, order = {}, {}
                if type(assign) == "table" then
                    local specIDs = {}
                    for specId, assigns in pairs(assign) do
                        if type(specId) == "number" and type(assigns) == "table" then
                            specIDs[#specIDs + 1] = specId
                        end
                    end
                    table.sort(specIDs)
                    for _, specId in ipairs(specIDs) do
                        local assigns = assign[specId]
                        local sids = {}
                        for sid, val in pairs(assigns) do
                            if type(sid) == "number" and type(val) == "string"
                               and val:match("^c:%d+$") then
                                sids[#sids + 1] = sid
                            end
                        end
                        table.sort(sids)
                        for _, sid in ipairs(sids) do
                            local ci = tonumber(assigns[sid]:match("^c:(%d+)$"))
                            local c  = containers[ci]
                            if type(c) == "table" and not c.singleBuff then
                                local h = held[ci]
                                if not h then
                                    h = { sids = {}, specs = {} }
                                    held[ci] = h
                                    order[#order + 1] = ci
                                end
                                if not h.specs[sid] then
                                    h.specs[sid] = {}
                                    h.sids[#h.sids + 1] = sid
                                end
                                h.specs[sid][specId] = true
                            end
                        end
                    end
                end
                table.sort(order)

                local ordering = rawget(acp, "specSpellOrdering")
                for _, ci in ipairs(order) do
                    local c = containers[ci]
                    if c.containerKey == nil and self.NewContainerKey then
                        c.containerKey = self:NewContainerKey(containers)
                    end
                    local anchor = c.containerKey and ("C:" .. c.containerKey)
                    local h = held[ci]
                    table.sort(h.sids)
                    for _, sid in ipairs(h.sids) do
                        local specSet = h.specs[sid]
                        -- Every spec that filed it, remembered BEFORE the
                        -- narrowing below: the assignment is released on all
                        -- of them, since the model is retired either way.
                        local filedUnder = {}
                        for specId in pairs(specSet) do filedUnder[#filedUnder + 1] = specId end
                        -- Narrowed by the container's own old Spec condition:
                        -- a spec the container never showed on stays off.
                        if c.loadSpec and type(c.loadSpecTypes) == "table" then
                            for specId in pairs(specSet) do
                                if c.loadSpecTypes[specId] == false then
                                    specSet[specId] = nil
                                end
                            end
                        end
                        if anchor and next(specSet) ~= nil then
                            -- Reuse an entry already anchored here for this
                            -- spell (a re-run, or one the user made by hand).
                            local entry
                            for i = 1, #containers do
                                local e = containers[i]
                                if type(e) == "table" and e.singleBuff
                                   and e.singleBuffSpellID == sid
                                   and e.anchorPoint == anchor then
                                    entry = e
                                    break
                                end
                            end
                            if not entry then
                                entry = {
                                    singleBuff        = true,
                                    maxBuffs          = 1,
                                    singleBuffSpellID = sid,
                                    singleBuffKey     = mintKey(containers, sid),
                                    selectedSpells    = {},
                                    name              = spellName(sid),
                                    autoNamed         = false,
                                    -- THE ENTRY'S CONDITIONS: the specs it was
                                    -- assigned under, and the container's
                                    -- Applied By.
                                    loadSpec          = true,
                                    loadSpecTypes     = onlySpecs(universe, specSet),
                                    containerCasterScope = c.containerCasterScope,
                                    -- Anchored to the container it lived in,
                                    -- as a Default (non-customized) buff that
                                    -- draws with the host's settings.
                                    anchorPoint       = anchor,
                                    sbRelativeOrder   = "BEFORE",
                                    singleBuffCustomized = false,
                                    containerUsesBuffSettings = true,
                                }
                                -- Its Order: the first spec (sorted) that had
                                -- a slot for it.
                                local slot
                                if type(ordering) == "table" then
                                    local specList = {}
                                    for specId in pairs(specSet) do specList[#specList + 1] = specId end
                                    table.sort(specList)
                                    for _, specId in ipairs(specList) do
                                        local m = ordering[specId]
                                        local e = type(m) == "table" and m[sid] or nil
                                        if type(e) == "number" then slot = e
                                        elseif type(e) == "table" and e.enabled ~= false then
                                            slot = e.slot
                                        end
                                        if slot then break end
                                    end
                                end
                                if slot and slot > 0 then
                                    entry.sbVisuals = { specSpellOrdering = {
                                        [BF.SINGLE_BUFF_VISUAL_KSPEC or "sb"] = {
                                            [sid] = { slot = slot } } } }
                                end
                                containers[#containers + 1] = entry
                            end
                        end
                        -- RELEASE the assignment on every spec that filed it.
                        for _, specId in ipairs(filedUnder) do
                            local assigns = assign[specId]
                            if type(assigns) == "table" then assigns[sid] = "default" end
                        end
                    end
                end

                -- RETIRE THE MODEL on every multi-icon buff container: the
                -- selectedSpells mirror and the container-level Spec
                -- condition go, held or not.
                for i = 1, #containers do
                    local c = containers[i]
                    if type(c) == "table" and not c.singleBuff then
                        c.selectedSpells = nil
                        c.loadSpec       = nil
                        c.loadSpecTypes  = nil
                    end
                end
            end
        end
    end
end

-- ============================================================
-- StripLegacyLayoutData  (Phase L, dbVersion 73)
--
-- Deletes the pre-flat named-layout data from one RaidPartyFrames
-- profile's SavedVariables. The flat model (dbVersion 19/20) replaced all
-- of it; nothing reads these keys any more (see
-- Docs/_PLAN_ExportStringSize.md §L.2 for the full reader audit).
--
-- MINE-FIRST GUARD: if either flat-model migration has not run for this
-- profile (sentinels absent -- e.g. a profile imported from a very old
-- SavedVariables backup), run them first so any user-diverged legacy
-- layout data is converted into flats BEFORE it is deleted. Both are
-- per-profile and sentinel-idempotent, so this is a no-op for every
-- profile the v19/v20 dispatcher blocks already handled.
--
-- The two sentinels themselves are deliberately KEPT: they are a few
-- bytes, and they permanently stop v19/v20 from ever re-running against
-- the now-empty table.
--
-- Idempotent by construction (deleting absent keys is a no-op).
-- ============================================================
-- Shared with Options_Profiles.lua (export-side exclusion and the
-- import-side strip of pre-Phase-L strings) as BF.LEGACY_LAYOUT_KEYS --
-- one list, three consumers, so the key set cannot drift.
local STRIP_LEGACY_LAYOUT_KEYS = {
    "layouts",              -- the named-layout tree (party/raid* tier tables)
    "activeLayout",
    "roleLayoutAssignment",
    "specLayoutAssignment",
    "specLayouts",
    "enableRoleLayouts",
    "enableSpecLayouts",
    "enableRaid20",
    "enableRaid30",
    "enableRaid40",
    "separateRaidBySize",
    "separateRaidAuras",
    "frameWidth",           -- pre-flat scalar trio ("Legacy" in old defaults)
    "frameHeight",
    "frameSpacing",
    -- 2026-08-24 dead-key sweep: stripped by the ver<49 migration but,
    -- since imports do not run migrations, a pre-v49 export string could
    -- reintroduce them -- so they join the strip list:
    "openWorldSolo",
    "openWorldRaid",
}

BF.LEGACY_LAYOUT_KEYS = STRIP_LEGACY_LAYOUT_KEYS

function BF:StripLegacyLayoutData(profileName)
    profileName = profileName or (self.rpDB and self.rpDB.keys.profile)
    local rp = self.rpDB and self.rpDB.profiles and self.rpDB.profiles[profileName]
    if not rp then return end          -- pure-defaults profile: nothing stored
    local rpl = rawget(rp, "layouts")
    if type(rpl) ~= "table" then return end

    -- Mine first (see header), but GUARD ON THE PRESENCE OF LEGACY DATA --
    -- not on sentinel-absence.
    --
    -- v93 HOTFIX. The sentinels are written ONLY by the ver<19 / ver<20
    -- dispatcher blocks, so "sentinel absent" has two opposite meanings:
    -- an unconverted legacy profile (mine it) OR a profile created at
    -- DB_VERSION >= 19, which never entered the dispatcher and has nothing
    -- to mine. Mining the second kind rebuilt flatLayouts from a tree that
    -- does not exist and wiped every Layout the user owned. Testing for the
    -- legacy tree itself separates the two cases exactly: only a profile
    -- that really carries layouts.layouts is mined; everyone else falls
    -- straight through to the key strip below, which is what they need.
    if type(rawget(rpl, "layouts")) == "table"
        and not (rpl._flatLayoutsMigrated and rpl._roleSpecOverridesMigrated) then
        if self.MigrateLayoutsByInstanceType  then self:MigrateLayoutsByInstanceType(profileName)  end
        if self.MigrateRoleSpecToFlatOverrides then self:MigrateRoleSpecToFlatOverrides(profileName) end
    end

    for _, key in ipairs(STRIP_LEGACY_LAYOUT_KEYS) do
        rpl[key] = nil
    end
end

-- ============================================================
-- PurgeDeadModuleKeysV74  (dead-key sweep, dbVersion 74)
--
-- One consolidated purge of every SavedVariables key the 2026-08-24
-- full-codebase sweep verified as reader-less (owner request: "one big
-- purge rather than having to go back and purge more later"). Only keys
-- NOT already nilled by an existing migration are listed here; the
-- already-covered ones (PA remnants, healerBuffFilter, acDB
-- missingRaidBuff* copies) are handled by their original migrations and
-- appear only on ProfileExport.lua's exclusion lists.
--
-- Walks every profile of every module DB directly (the *AC migration
-- shape). Idempotent by construction; no sentinel needed -- the
-- dispatcher's ver<74 gate runs it once per main-db profile, and
-- deleting absent keys is a no-op.
-- ============================================================
local PURGE74_AC = {
    "sotfGlowEnabled", "sotfGlowRejuv", "sotfGlowRegrowth", "sotfGlowType",
    "sotfRejuvColor", "sotfGerminationColor", "sotfRegrowthColor",
    "sotfConvokeAsEmpowered",          -- SotF runtime removed v80
    "specSpellBlizzardBorders",        -- zero references anywhere
}
local PURGE74_UF = {
    "iconIgnoreClickBindsOOC", "iconIgnoreClickBindsOOCOnly",
    "iconOverrideLeftClick", "iconOverrideRightClick",
    "customPowerColors",               -- tombstone; live copy is rpDB.healthPower
    "globalUseClassColor", "globalUseHostilityColor",
    "globalUseClassColorName", "globalUseHostilityColorName",
    "globalNpcClassificationColors", "globalUseHealthGradient",
    "oufAstralBarEnabled", "oufAstralBarUseTypeColor", "oufAstralBarColor",
    "oufAstralBarBgColor", "oufAstralBarBorderEnabled",
    "oufAstralBarBorderThickness", "oufAstralBarBorderColor",
    "oufAstralBarShowPct", "oufAstralBarShowVal", "oufAstralBarFontSize",
    "oufAstralBarPctPos", "oufAstralBarValPos",
    -- removed from Defaults_UnitFrames.lua the same day (zero readers):
    "auraFont", "bossCastBarAvoidAuras", "classIconPosition",
    "frameBorderEnabled", "frameBorderThickness",
    "nameDividerEnabled", "nameDividerThickness", "ptfFrameStyle",
}
local PURGE74_CFG_GROUP = {
    "overrideAuras",        -- superseded by the split Buffs/Debuffs flags
    "overrideSizeSpacing",  -- retired with the independent-flats conversion
    "anchorX", "anchorY",   -- group-level anchors; live storage is
                            -- customFrameGroupPositions + flat.anchorX/Y
}

function BF:PurgeDeadModuleKeysV74()
    local function purge(db, keys)
        if not (db and db.profiles) then return end
        for _, prof in pairs(db.profiles) do
            if type(prof) == "table" then
                for _, k in ipairs(keys) do prof[k] = nil end
            end
        end
    end
    purge(self.acDB, PURGE74_AC)
    purge(self.ufDB, PURGE74_UF)
    -- rpDB: one dead top-level key (a legacy migration WROTE it, a later
    -- one nils it -- pure dead work; this catches any stragglers).
    if self.rpDB and self.rpDB.profiles then
        for _, prof in pairs(self.rpDB.profiles) do
            if type(prof) == "table" then prof.privateAuraBorderScale = nil end
        end
    end
    -- cfgDB: per-GROUP fossils.
    if self.cfgDB and self.cfgDB.profiles then
        for _, prof in pairs(self.cfgDB.profiles) do
            local groups = type(prof) == "table" and rawget(prof, "customFrameGroups")
            if type(groups) == "table" then
                for _, grp in ipairs(groups) do
                    if type(grp) == "table" then
                        for _, k in ipairs(PURGE74_CFG_GROUP) do grp[k] = nil end
                    end
                end
            end
        end
    end
end

-- ============================================================
-- StripLegacyUFLayoutBuckets  (Phase L §L.6a, dbVersion 73)
--
-- Deletes the dead raid40/raid30/raid20 buckets from every ufLayouts
-- entry in every UnitFrames profile. They have been unreachable since
-- separateUFByGroupType was retired 2026-08-15 -- GetUFAnchor
-- (Core_UFLayout.lua) hardcodes the "party" bucket as the only live
-- path, and the position writers use the same resolution.
--
-- ufDB has its OWN profile set, so this walks itself ONCE (the same
-- shape as the *AC migrations). Idempotent by construction.
-- ============================================================
function BF:StripLegacyUFLayoutBuckets()
    local ufDB = self.ufDB
    if not (ufDB and ufDB.profiles) then return end
    for _, ufp in pairs(ufDB.profiles) do
        if type(ufp) == "table" then
            local layouts = rawget(ufp, "ufLayouts")
            if type(layouts) == "table" then
                for _, layout in pairs(layouts) do
                    if type(layout) == "table" then
                        layout.raid40 = nil
                        layout.raid30 = nil
                        layout.raid20 = nil
                    end
                end
            end
        end
    end
end

-- ── Migration 78: UF ROLE/SPEC OVERRIDES BECOME ENTRIES ────────
--
-- The Unit Frame Layouts section used to be two tabs -- three fixed role
-- dropdowns on one, an add/remove spec list on the other -- each gated by
-- its own enable switch. It is now one list of override ENTRIES, the same
-- shape the raid Layouts section uses, where the presence of an entry is
-- what makes an override exist. The switches are gone from the panel and
-- are maintained as derived state instead, so this pass has to decide, per
-- profile, which entries the old data amounts to.
--
-- ROLES have no presence table to read: ufRoleLayoutAssignment is an AceDB
-- default and so always carries all three roles, whether or not the user
-- ever looked at them. A role earns an entry when its assignment is
-- something other than "default" -- the only evidence in the data that a
-- choice was made. A role assigned "default" resolves to the Default layout
-- either way, so giving it no entry changes nothing about which layout
-- comes out.
--
-- SPECS already have one: ufSpecLayouts IS the presence table, so entries
-- carry across untouched.
--
-- AND IF THE SWITCH WAS OFF, none of it carries. Those assignments were
-- inert -- ApplyUFRoleSpecLayout skipped the whole branch -- and once
-- presence is the gate there is no way to say "an entry that does
-- nothing". Migrating them would silently start changing the reader's
-- layouts on login, so that side is cleared back to its default state
-- instead, which is what it behaved as. Cleared rather than left in place:
-- a stale assignment kept in the profile would come back the moment the
-- reader added that role or spec, wearing a value they never chose in the
-- panel they are looking at.
local UF_MIG78_ROLES = { "HEALER", "TANK", "DAMAGER" }

function BF:MigrateUFRoleSpecEntries()
    local ufDB = self.ufDB
    if not (ufDB and ufDB.profiles) then return end
    for _, ufp in pairs(ufDB.profiles) do
        if type(ufp) == "table" then
            -- rawget throughout: these are AceDB profiles, so a plain read
            -- falls through to the defaults table and would report keys
            -- this profile never stored -- which is the very distinction
            -- this migration turns on.
            local roleOn = rawget(ufp, "enableUFRoleLayouts") and true or false
            local specOn = rawget(ufp, "enableUFSpecLayouts") and true or false

            -- THE GLOBAL ENTRY. The layout the reader had selected becomes
            -- the layout they have assigned globally, which is what the
            -- picker was doing in every profile where no override applied.
            -- Seeded only if that layout still exists; the resolver used to
            -- write its own answer into this same field, so the value found
            -- here may be one an override put there rather than one the
            -- reader chose -- and either way it is the layout they were
            -- last looking at.
            if rawget(ufp, "ufGlobalLayout") == nil then
                local id = rawget(ufp, "activeUFLayout")
                local ls = rawget(ufp, "ufLayouts")
                ufp.ufGlobalLayout = (id and ls and ls[id]) and id or "default"
            end

            local present = {}
            local assign  = rawget(ufp, "ufRoleLayoutAssignment")
            if roleOn and type(assign) == "table" then
                for _, role in ipairs(UF_MIG78_ROLES) do
                    local id = assign[role]
                    if id and id ~= "default" then present[role] = true end
                end
            end
            ufp.ufRoleLayouts = present

            if not roleOn then
                -- Emptied, so a role added later starts on "use the global
                -- setting" rather than on a forgotten pick. Empty IS the
                -- shipped state now: an absent assignment is how deferring
                -- to Global is stored.
                ufp.ufRoleLayoutAssignment = {}
            end

            if not specOn then
                ufp.ufSpecLayouts          = {}
                ufp.ufSpecLayoutAssignment = {}
            end

            -- The switches are derived from here on: a kind is enabled
            -- exactly when it has at least one entry. Stated now so the
            -- resolver and the Ace panel agree with the tree on the very
            -- first login after the upgrade.
            local anyRole = false
            for _ in pairs(ufp.ufRoleLayouts or {}) do anyRole = true break end
            local anySpec = false
            for _ in pairs(rawget(ufp, "ufSpecLayouts") or {}) do anySpec = true break end
            ufp.enableUFRoleLayouts = anyRole
            ufp.enableUFSpecLayouts = anySpec
        end
    end
end

-- Perf plan §L5.1 load-time mark: 261 KB, the single largest file (.toc 58).
if BuzzardFrames then BuzzardFrames:LoadMark("chunk:coreMigrations") end
