-- ============================================================
-- BuzzardFrames: Options_PreviewData.lua
--
-- Dummy data rendering for preview frames. Each ApplyPreview*
-- function mirrors the corresponding real indicator's Update
-- method but uses fake data instead of live unit info.
--
-- Look here when a specific indicator looks wrong on preview frames.
--
-- IMPORTANT: When changing how a setting renders on real frames,
-- the corresponding ApplyPreview* function here must be updated
-- to match.
-- ============================================================
local BF = _G["BuzzardFrames"]

-- rpDB sub-table accessors (live reads, safe in any scope)
local function _rpDB() return BF.rpDB and BF.rpDB.profile or {} end
-- _rp_borders / _rp_healthPower / _rp_absorbs / _rp_icons / _rp_text are
-- defined below alongside the _currentPreviewFlat module-local so per-flat
-- routing works (v29: borders joined the set).

-- ────────────────────────────────────────────────────────────────────
-- Per-preview-frame section-profile routing.
--
-- Each preview frame represents a specific flat (identified by `tier` in
-- the Apply* function signatures -- the name is a holdover from the old
-- tier-based model). When per-layout is ON for a section (text, icons,
-- etc.), each flat has its own flat[section] sub-table; reads must route
-- through GetSectionProfile so the preview shows settings for THIS
-- frame's flat, not the global.
--
-- Pattern: every Apply* that reads _rp_text() / _rp_icons() /
-- _rp_absorbs() / _rp_healthPower() calls _setPreviewFlat(tier) at its
-- top. The routed accessors then read via the module-local
-- _currentPreviewFlat. For CF previews (tier = "cf1".."cf4") the
-- flatLayouts lookup returns nil, and GetSectionProfile(section, nil)
-- falls back to the global -- which is the correct behaviour since CF
-- frames aren't per-flat.
--
-- AdjustPreviewNameForHiddenRole inherits whatever flat its caller
-- (ApplyPreviewRoleIcon) set, so no setter call is needed inside it.
-- ────────────────────────────────────────────────────────────────────
local _currentPreviewFlat
local _currentPreviewFrame
-- Set the flat + frame context for per-section routed accessors.
-- For RP previews: pass a flatID string (e.g. "flat_1") → looks up in flatLayouts.
-- For CF previews: pass a flatID string + the frame; if the frame has
-- _cfgFlat stamped, that flat is used directly and _currentPreviewFrame
-- is stored so the routed accessors can call GetSectionProfileForFrame
-- which respects CFG override flags.
local function _setPreviewFlat(tier, frame)
    _currentPreviewFrame = frame
    if frame and frame._cfgFlat then
        _currentPreviewFlat = frame._cfgFlat
        return
    end
    local lp = BF.rpDB and BF.rpDB.profile and BF.rpDB.profile.layouts
    _currentPreviewFlat = lp and lp.flatLayouts and tier and lp.flatLayouts[tier] or nil
end
-- Routed section accessor: uses GetSectionProfileForFrame when a CFG
-- preview frame is active (so override flags are respected), otherwise
-- falls back to GetSectionProfile for RP preview frames.
local function _rp_section(section)
    if _currentPreviewFrame and _currentPreviewFrame._cfgFlat then
        return BF:GetSectionProfileForFrame(section, _currentPreviewFrame) or {}
    end
    return BF:GetSectionProfile(section, _currentPreviewFlat) or {}
end
local function _rp_text()
    return _rp_section("text")
end
-- v26: routed through GetSectionProfile so per-layout Icons overrides
-- show in the options preview. Pre-v26 read rpDB.profile.icons directly
-- (global only), so per-layout Icons edits were invisible in the preview.
local function _rp_icons()
    return _rp_section("icons")
end
-- v27: same routing for absorbs. Pre-v27 read rpDB.profile.absorbs
-- directly, so per-layout Absorbs edits were invisible on preview frames.
local function _rp_absorbs()
    return _rp_section("absorbs")
end
-- v28: same routing for healthPower. Pre-v28 read rpDB.profile.healthPower
-- directly, so per-layout Health/Power edits were invisible on preview frames.
local function _rp_healthPower()
    return _rp_section("healthPower")
end
-- Global colors accessor. NOT per-layout -- reads rpDB.profile.colors
-- directly (gradient colors, class colors, etc. are shared globally).
local function _rp_colors()
    return BF.rpDB and BF.rpDB.profile and BF.rpDB.profile.colors or {}
end
-- v29: same routing for borders. Pre-v29 read rpDB.profile.borders
-- directly, so per-layout Borders edits were invisible on preview frames.
local function _rp_borders()
    return _rp_section("borders")
end
-- v35: dispel indicator sub-category. Resolves the auras section then
-- indexes the dispelIndicator sub-table. Used by ApplyPreviewHighlights
-- for the debuff border/overlay keys that migrated from borders to
-- auras.dispelIndicator in v35.
local function _rp_dispelIndicator()
    local ap = _rp_section("auras")
    return ap.dispelIndicator or {}
end

local MAX_CF_PREVIEWS = 4
local CF_FAKE_UNIT_DEFAULTS = {
    { name = "CFBuzzard1", class = "PALADIN",     hp = 0.90, role = "TANK"    },
    { name = "CFBuzzard2", class = "DRUID",        hp = 0.65, role = "HEALER"  },
    { name = "CFBuzzard3", class = "ROGUE",        hp = 0.45, role = "DAMAGER" },
    { name = "CFBuzzard4", class = "DEATHKNIGHT",  hp = 0.30, role = "TANK"    },
}

-- FAKE UNIT DATA
-- Defaults are used when no profile overrides exist.
-- Users can customize class, role, and health % per flat via the
-- Preview Units tab. Storage: p._previewUnitsByFlat[flatID].
-- ============================================================
-- Per-preview-slot defaults. The Preview Units section renders one
-- entry per active preview flat in a stable display order (computed
-- by ComputeActivePreviewSet in Options_PreviewSystem.lua). The Nth
-- entry in that display order gets PREVIEW_UNIT_DEFAULTS[((N-1) % 10) + 1]
-- as its baseline (class / role / hp / name), so the first ten flats
-- each see a distinct preset and the pattern repeats if there are
-- more than ten. The user can still override class / role / hp
-- per flat; name is always taken from this table.
--
-- TYPE_DEFAULTS is kept as a legacy export for any caller that still
-- looks it up by type. Callers in this addon now go through
-- GetFlatTypeDefault, which indexes PREVIEW_UNIT_DEFAULTS by preview
-- order instead.
local PREVIEW_UNIT_DEFAULTS = {
    { name = "Partybuzzard", class = "WARRIOR",     role = "TANK",    hp = 0.75 },
    { name = "Buzzardsham",  class = "SHAMAN",      role = "DAMAGER", hp = 0.20 },
    { name = "Holybuzzard",  class = "PRIEST",      role = "HEALER",  hp = 0.40 },
    { name = "Buzzardk",     class = "DEATHKNIGHT", role = "TANK",    hp = 0.53 },
    { name = "Bluzzard",     class = "MAGE",        role = "DAMAGER", hp = 0.65 },
    { name = "Buzzweaver",   class = "MONK",        role = "HEALER",  hp = 0.82 },
    { name = "Buzzlightyr",  class = "PALADIN",     role = "TANK",    hp = 0.13 },
    { name = "Demobuzzard",  class = "WARLOCK",     role = "DAMAGER", hp = 0.44 },
    { name = "Buzzardragon", class = "EVOKER",      role = "HEALER",  hp = 0.74 },
    { name = "Buzzilidan",   class = "DEMONHUNTER", role = "TANK",    hp = 0.50 },
}
local PREVIEW_UNIT_DEFAULTS_COUNT = #PREVIEW_UNIT_DEFAULTS

-- Legacy: preserved so any out-of-tree caller that still imports
-- TYPE_DEFAULTS keeps working. Values point at the first two entries
-- of PREVIEW_UNIT_DEFAULTS so the semantics ("party baseline is
-- warrior-tank, raid baseline is shaman-dps") are preserved for that
-- legacy surface.
local TYPE_DEFAULTS = {
    party = PREVIEW_UNIT_DEFAULTS[1],
    raid  = PREVIEW_UNIT_DEFAULTS[2],
}

local function GetCFFakeUnit(cfIndex)
    local def = CF_FAKE_UNIT_DEFAULTS[cfIndex] or CF_FAKE_UNIT_DEFAULTS[1]
    local tierKey = "cf" .. cfIndex
    local p = BF.db and BF.db.profile
    local ov = p and p.previewUnits and p.previewUnits[tierKey]
    if not ov then return def end
    return {
        name  = def.name,
        class = ov.class or def.class,
        hp    = ov.hp    or def.hp,
        role  = ov.role  or def.role,
    }
end

-- Resolve a flat's default by its position in the preview-unit display
-- order. Walks PREVIEW_UNIT_DEFAULTS with wrap-around at 10 entries so
-- the 11th preview flat reuses entry 1, the 12th reuses entry 2, etc.
--
-- Display order is owned by ComputeActivePreviewSet in
-- Options_PreviewSystem.lua (seeded flats first in fixed order, then
-- user flats alphabetically). We resolve it lazily at call time via
-- BF._preview.ComputeActivePreviewSet because that module loads AFTER
-- this one -- at addon load the export doesn't exist yet, but every
-- call to GetFlatTypeDefault happens at UI build / preview render
-- time, long after both modules have loaded.
--
-- Fallbacks:
--   * ComputeActivePreviewSet not exported yet (shouldn't happen in
--     practice): return entry 1 as a safe baseline.
--   * flatID not present in the active preview order (unpinned, or
--     not yet registered): return entry 1 as a safe baseline. The
--     user can still override class / role / hp for that flat via
--     the Preview Units tab; name falls back to entry 1's.
local function GetFlatTypeDefault(flatID)
    if not flatID then return PREVIEW_UNIT_DEFAULTS[1] end
    local compute = BF._preview and BF._preview.ComputeActivePreviewSet
    if type(compute) ~= "function" then
        return PREVIEW_UNIT_DEFAULTS[1]
    end
    local order = compute()
    for i = 1, #order do
        if order[i] == flatID then
            local idx = ((i - 1) % PREVIEW_UNIT_DEFAULTS_COUNT) + 1
            return PREVIEW_UNIT_DEFAULTS[idx]
        end
    end
    return PREVIEW_UNIT_DEFAULTS[1]
end

-- flatID is the preview key. CF preview frames use "cf1".."cf4";
-- flat previews use flat IDs (e.g. "flat_party", "flat_raid40",
-- or any user-created flat ID).
local function GetFakeUnit(flatID)
    -- Custom frame group tiers: "cf1", "cf2", etc.
    local cfIndex = flatID and flatID:match("^cf(%d+)$")
    if cfIndex then return GetCFFakeUnit(tonumber(cfIndex)) end

    local def = GetFlatTypeDefault(flatID)
    local p   = BF.rpDB and BF.rpDB.profile
    local ov  = p and p._previewUnitsByFlat and p._previewUnitsByFlat[flatID]
    if not ov then return def end
    return {
        name  = def.name,
        class = ov.class or def.class,
        hp    = ov.hp    or def.hp,
        role  = ov.role  or def.role,
    }
end

local function GetFakeClassColor(tier)
    local unit = GetFakeUnit(tier)
    return BF.classColors and BF.classColors[unit.class]
end

-- Returns up to MAX_CF_PREVIEWS enabled custom frame groups as
-- { { index=i, group=cfTable }, ... }
local function EnabledCFGroups()
    local cfgp = BF.cfgDB and BF.cfgDB.profile
    if not cfgp or cfgp.customFramesEnabled == false then return {} end
    local groups = cfgp.customFrameGroups
    if not groups then return {} end
    local result = {}
    for i, g in ipairs(groups) do
        if g.enabled ~= false then
            result[#result + 1] = { index = i, group = g }
            if #result >= MAX_CF_PREVIEWS then break end
        end
    end
    return result
end

-- ============================================================
-- GRADIENT INTERPOLATION (preview frames can't use UnitHealthPercent)
-- ============================================================
-- Smooth linear interpolation between 3 color points at 0, 0.5, 1
-- matching the Grid2/BFStatus color curve (0=low, 0.5=mid, 1=high).
local function LerpGradientColor(hp, lowColor, midColor, highColor)
    if hp <= 0 then
        return lowColor.r, lowColor.g, lowColor.b
    elseif hp >= 1 then
        return highColor.r, highColor.g, highColor.b
    elseif hp <= 0.5 then
        local t = hp / 0.5
        return lowColor.r + (midColor.r - lowColor.r) * t,
               lowColor.g + (midColor.g - lowColor.g) * t,
               lowColor.b + (midColor.b - lowColor.b) * t
    else
        local t = (hp - 0.5) / 0.5
        return midColor.r + (highColor.r - midColor.r) * t,
               midColor.g + (highColor.g - midColor.g) * t,
               midColor.b + (highColor.b - midColor.b) * t
    end
end

-- ============================================================
-- DUMMY DATA FUNCTIONS
-- ============================================================

-- Legacy stub: module-level flags have been replaced by per-section
-- overrides routed through GetSectionProfileForFrame. Always returns
-- true so existing preview callsites continue to work unchanged.
local function CFModuleFlag(frame, flagName)
    return true
end

local function ApplyPreviewHealthBar(frame, isRaid, p, tier)
    _setPreviewFlat(tier, frame)
    if not frame.healthBar then return end
    local unit = GetFakeUnit(tier or (isRaid and "raid40" or "party"))
    local fakeClassColor = GetFakeClassColor(tier or (isRaid and "raid40" or "party"))
    -- Texture and bg anchors are set by HealthBar:Layout, called from
    -- LayoutPreviewFrame during the initial RefreshPreview. We only set
    -- fake color+value here, matching what HealthBar:Update does on real frames.
    local r, g, b
    if _rp_healthPower().useCustomHealthColor then
        if _rp_healthPower().useHealthGradient then
            r, g, b = LerpGradientColor(unit.hp,
                _rp_colors().healthGradientLow, _rp_colors().healthGradientMid, _rp_colors().healthGradientHigh)
        else
            local c = _rp_healthPower().healthColor
            r, g, b = c.r, c.g, c.b
        end
    elseif fakeClassColor then
        local hasTex = _rp_healthPower().useCustomHealthBarTexture
        r, g, b = BF:GetClassHealthColor(fakeClassColor.r, fakeClassColor.g, fakeClassColor.b, hasTex)
    elseif isRaid then
        local hasTex = _rp_healthPower().useCustomHealthBarTexture
        r, g, b = BF:GetClassHealthColor(0.0, 0.44, 1.0, hasTex)
    else
        local hasTex = _rp_healthPower().useCustomHealthBarTexture
        r, g, b = BF:GetClassHealthColor(0.0, 0.65, 0.0, hasTex)
    end
    -- Apply fill opacity via vertex color alpha, matching HealthBar:Update on real frames.
    local fillAlpha = _rp_healthPower().healthBarOpacity or 1
    frame.healthBar:SetStatusBarColor(r, g, b, fillAlpha)
    frame.healthBar:SetMinMaxValues(0, 1)
    frame.healthBar:SetValue(unit.hp)
    -- Background gradient: smooth interpolation based on fake health %.
    if frame.healthBar.bg and _rp_healthPower().useCustomBackgroundColor and _rp_healthPower().useBgGradient then
        local br, bg_, bb = LerpGradientColor(unit.hp,
            _rp_colors().bgGradientLow, _rp_colors().bgGradientMid, _rp_colors().bgGradientHigh)
        frame.healthBar.bg:SetColorTexture(br, bg_, bb, 1)
    end
    if frame.statusOverlay then frame.statusOverlay:Hide() end
    if frame.statusText    then frame.statusText:Hide()    end
end

-- Resets a preview frame's health bar to its default class color.
-- Called by ShowSingleSpellPreview before conditionally applying a
-- spell-specific health tint, so stale tints from other spells
-- don't persist when navigating between spell pages.
function BF:ResetPreviewHealthColor(frame)
    if not frame or not frame.healthBar or not frame._previewTier then return end
    local p = self.db and self.db.profile
    if not p then return end
    local tier = frame._previewTier
    -- v28: set the preview flat so _rp_healthPower() resolves per-flat.
    -- Prefer frame._flatID (flat previews); fall back to _previewTier
    -- (legacy/CF previews).
    _setPreviewFlat(frame._flatID or tier)
    local isRaid = (tier ~= "party")
    local fakeClassColor = GetFakeClassColor(tier)
    local unit = GetFakeUnit(tier)
    local r, g, b
    if _rp_healthPower().useCustomHealthColor then
        if _rp_healthPower().useHealthGradient then
            r, g, b = LerpGradientColor(unit.hp,
                _rp_colors().healthGradientLow, _rp_colors().healthGradientMid, _rp_colors().healthGradientHigh)
        else
            local c = _rp_healthPower().healthColor
            r, g, b = c.r, c.g, c.b
        end
    elseif fakeClassColor then
        local hasTex = _rp_healthPower().useCustomHealthBarTexture
        r, g, b = self:GetClassHealthColor(fakeClassColor.r, fakeClassColor.g, fakeClassColor.b, hasTex)
    elseif isRaid then
        local hasTex = _rp_healthPower().useCustomHealthBarTexture
        r, g, b = self:GetClassHealthColor(0.0, 0.44, 1.0, hasTex)
    else
        local hasTex = _rp_healthPower().useCustomHealthBarTexture
        r, g, b = self:GetClassHealthColor(0.0, 0.65, 0.0, hasTex)
    end
    local fillAlpha = _rp_healthPower().healthBarOpacity or 1
    frame.healthBar:SetStatusBarColor(r, g, b, fillAlpha)
end

local function ApplyPreviewName(frame, isRaid, p, tier)
    _setPreviewFlat(tier, frame)
    if not frame.nameText then return end
    if not _rp_text().showName then frame.nameText:Hide(); return end
    local t = tier or (isRaid and "raid40" or "party")
    local unit = GetFakeUnit(t)
    local fakeClassColor = GetFakeClassColor(t)
    local name = unit.name
    -- Test Cyrillic Names: replace with Cyrillic test string.
    -- Mirrors NameText:Update Cyrillic handling block.
    if BF.db.global.testCyrillicNames then
        -- "Привет" in Lua 5.1 decimal escapes (no \x support)
        name = "\208\159\209\128\208\184\208\178\208\181\209\130"
    end
    -- Cyrillic font handling (mirrors NameText:Update)
    if BF.HasCyrillic and BF:HasCyrillic(name) then
        if _rp_text().transliterateCyrillicNames and BF.TransliterateCyrillic then
            name = BF:TransliterateCyrillic(name)
            -- Transliteration produces Latin chars; restore configured font
            if frame._nameFontPath then
                frame.nameText:SetFont(frame._nameFontPath, frame._nameFontSize or _rp_text().nameFontSize or 10, frame._nameFontFlags or "")
            end
        else
            -- Use Cyrillic fallback font
            local fallback = BF.cyrillicFont or BF.font
            frame.nameText:SetFont(fallback, frame._nameFontSize or _rp_text().nameFontSize or 10, frame._nameFontFlags or "")
        end
    elseif frame._nameFontPath then
        -- No Cyrillic: restore configured font (in case testCyrillicNames was just toggled off)
        frame.nameText:SetFont(frame._nameFontPath, frame._nameFontSize or _rp_text().nameFontSize or 10, frame._nameFontFlags or "")
    end
    if _rp_text().abbreviateNames and #name > _rp_text().maxNameChars then
        name = name:sub(1, _rp_text().maxNameChars)
    end
    if _rp_text().capitalizeNames then name = name:upper() end
    frame.nameText:SetText(name)
    frame.nameText:SetAlpha(1)
    if _rp_text().adjustNameColors then
        if _rp_text().classColorNames and fakeClassColor then
            frame.nameText:SetTextColor(fakeClassColor.r, fakeClassColor.g, fakeClassColor.b)
        else
            local nc = _rp_text().nameColor or { r=1, g=1, b=1 }
            frame.nameText:SetTextColor(nc.r, nc.g, nc.b)
        end
    else
        frame.nameText:SetTextColor(1, 1, 1)
    end
    frame.nameText:Show()
end

-- Fake current/max health values per tier for current/deficit display
-- Derived from GetFakeUnit(tier).hp so health text matches the bar.
local function GetFakeHealth(tier)
    local unit = GetFakeUnit(tier)
    local maxHP = 500
    local current = math.floor(unit.hp * maxHP + 0.5)
    return { current = current, max = maxHP }
end

local function ApplyPreviewHealthText(frame, isRaid, p, tier)
    _setPreviewFlat(tier, frame)
    if not frame.healthText then return end
    if not _rp_text().showHealthText or not CFModuleFlag(frame, "moduleShowHealthText") then frame.healthText:Hide(); return end
    local t = tier or (isRaid and "raid40" or "party")
    local unit = GetFakeUnit(t)
    local fakeClassColor = GetFakeClassColor(t)
    local hdata = GetFakeHealth(t)
    if _rp_text().adjustHealthTextColor then
        if _rp_text().classColorHealthText and fakeClassColor then
            frame.healthText:SetTextColor(fakeClassColor.r, fakeClassColor.g, fakeClassColor.b)
        else
            local c = _rp_text().healthTextColor or { r=1, g=1, b=1 }
            frame.healthText:SetTextColor(c.r, c.g, c.b)
        end
    else
        frame.healthText:SetTextColor(1, 1, 1)
    end
    local fmt = _rp_text().healthTextFormat or "percent"
    local pct = math.floor(unit.hp * 100 + 0.5)
    local deficit = hdata.max - hdata.current
    if     fmt == "percent" then frame.healthText:SetText(pct .. "%")
    elseif fmt == "current" then frame.healthText:SetText(hdata.current .. "k")
    elseif fmt == "deficit" then frame.healthText:SetText("-" .. deficit .. "k")
    else                         frame.healthText:SetText(pct .. "%") end
    frame.healthText:Show()
end

-- Power bar type per class
local CLASS_POWER_TYPE = {
    WARRIOR = 1,  -- rage
    SHAMAN  = 0,  -- mana
    MAGE    = 0,  -- mana
    PRIEST  = 0,  -- mana
}

local function ApplyPreviewPowerBar(frame, isRaid, p, tier)
    _setPreviewFlat(tier, frame)
    if not frame.powerBar then return end
    local t = tier or (isRaid and "raid40" or "party")
    local unit = GetFakeUnit(t)
    -- Mirror ShouldShowPowerBar logic using the fake unit's role and class.
    local showPower = false
    if _rp_healthPower().showAllPowerBars then
        showPower = true
    else
        if _rp_healthPower().showPowerBarHealers and unit.role == "HEALER" then showPower = true end
        if _rp_healthPower().showPowerBarBloodDK and unit.class == "DEATHKNIGHT" and unit.role == "TANK" then showPower = true end
    end
    -- Container and health bar must be re-anchored based on power bar visibility
    -- because preview frames have no unit, so Container:Layout always sets
    -- effectivePowerH=0. We replicate the container offset manually here.
    if showPower then
        local powerH = BF:Scale(_rp_healthPower().powerBarHeight or 4)
        -- Apply bar texture from profile
        local pbTex = _rp_healthPower().useCustomPowerBarTexture and BF:ResolveBarTexture(_rp_healthPower().powerBarTexture) or "Interface\\Buttons\\WHITE8X8"
        frame.powerBar:SetStatusBarTexture(pbTex)
        local powerToken = ({ WARRIOR="RAGE", SHAMAN="MANA", MAGE="MANA", PRIEST="MANA" })[unit.class] or "MANA"
        local c = BF.PowerTypeColors and BF.PowerTypeColors[powerToken]
        if c then frame.powerBar:SetStatusBarColor(c.r, c.g, c.b) end
        frame.powerBar:SetMinMaxValues(0, 1)
        -- Mage/Priest: high mana; Warrior: low rage; Shaman: moderate mana
        local powerVal = ({ MAGE=0.90, PRIEST=0.80, SHAMAN=0.60, WARRIOR=0.15 })[unit.class] or 0.6
        frame.powerBar:SetValue(powerVal)
        if frame.powerBar.bg then
            local bgA = (_rp_healthPower().powerBarBgOpacity ~= nil) and _rp_healthPower().powerBarBgOpacity or 1.0
            if _rp_healthPower().useCustomPowerBarBgColor then
                local c = _rp_healthPower().powerBarBgColor or { r=0.08, g=0.08, b=0.08 }
                frame.powerBar.bg:SetColorTexture(c.r, c.g, c.b, bgA)
            else
                frame.powerBar.bg:SetColorTexture(0.08, 0.08, 0.08, bgA)
            end
        end
        frame.powerBar:Show()
        if frame.powerBar.bgFrame then frame.powerBar.bgFrame:Show() end
        -- Shrink container to make room for power bar
        if frame.container then
            frame.container:ClearAllPoints()
            frame.container:SetPoint("TOPLEFT",     frame, "TOPLEFT",      0, 0)
            frame.container:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0,  powerH)
        end
    else
        frame.powerBar:Hide()
        if frame.powerBar.bgFrame then frame.powerBar.bgFrame:Hide() end
        -- Expand container to fill the full frame (no power bar space)
        if frame.container then
            frame.container:ClearAllPoints()
            frame.container:SetPoint("TOPLEFT",     frame, "TOPLEFT",      0, 0)
            frame.container:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0,  0)
        end
    end
end

local HIDDEN_ROLE_NAME_INSET = 3

local function AdjustPreviewNameForHiddenRole(frame, p)
    if not frame.nameText or not _rp_text().namePosition then return end
    if _rp_text().linkNameAndRole then return end
    local np = _rp_text().namePosition
    local rp = _rp_icons().roleIconPosition or { point = "TOPLEFT", x = 2, y = -2 }
    if np.point ~= rp.point then return end

    local nameX = np.x or 0
    local nameY = np.y or 0
    if np.point:find("LEFT") then
        nameX = nameX + HIDDEN_ROLE_NAME_INSET
    elseif np.point:find("RIGHT") then
        nameX = nameX - HIDDEN_ROLE_NAME_INSET
    end

    local anchorPoint = np.point or "CENTER"
    local vAnchor
    if anchorPoint:find("TOP") then vAnchor = "TOP"
    elseif anchorPoint:find("BOTTOM") then vAnchor = "BOTTOM"
    else vAnchor = "" end
    local pinPoint = vAnchor ~= "" and (vAnchor .. "LEFT") or "LEFT"
    local anchor = frame.container or frame.healthBar or frame
    frame.nameText:ClearAllPoints()
    frame.nameText:SetPoint(pinPoint, anchor, pinPoint, nameX, nameY)
end

local function ApplyPreviewRoleIcon(frame, isRaid, p, tier)
    _setPreviewFlat(tier, frame)
    if not frame.roleIcon then return end
    local cfShowRole = CFModuleFlag(frame, "moduleShowRoleIcons")
    if not _rp_icons().showRoleIcons or not cfShowRole then
        frame.roleIcon:Hide()
        AdjustPreviewNameForHiddenRole(frame, p)
        return
    end
    local t = tier or (isRaid and "raid40" or "party")
    local role  = GetFakeUnit(t).role
    -- Per-role visibility filter (matches RoleIcon:Update)
    if role == "TANK" and not _rp_icons().showRoleIconTank then
        frame.roleIcon:Hide()
        AdjustPreviewNameForHiddenRole(frame, p)
        return
    elseif role == "HEALER" and not _rp_icons().showRoleIconHealer then
        frame.roleIcon:Hide()
        AdjustPreviewNameForHiddenRole(frame, p)
        return
    elseif role == "DAMAGER" and not _rp_icons().showRoleIconDPS then
        frame.roleIcon:Hide()
        AdjustPreviewNameForHiddenRole(frame, p)
        return
    end
    local style = _rp_icons().roleIconStyle or "MODERN"
    local tex = frame.roleIcon.texture
    if style == "TINY" then
        tex:SetTexture(nil); tex:SetTexCoord(0,1,0,1)
        local atlas = role == "TANK" and "roleicon-tiny-tank"
                   or role == "HEALER" and "roleicon-tiny-healer"
                   or "roleicon-tiny-dps"
        tex:SetAtlas(atlas, false)
    elseif style == "MODERN" then
        tex:SetTexture(nil); tex:SetTexCoord(0,1,0,1)
        local atlas = role == "TANK" and "UI-LFG-RoleIcon-Tank-Micro-GroupFinder"
                   or role == "HEALER" and "UI-LFG-RoleIcon-Healer-Micro-GroupFinder"
                   or "UI-LFG-RoleIcon-DPS-Micro-GroupFinder"
        tex:SetAtlas(atlas, false)
    else
        local roleTex = "Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES"
        tex:SetTexture(roleTex)
        if role == "TANK" then
            tex:SetTexCoord(0, 19/64, 22/64, 41/64)
        elseif role == "HEALER" then
            tex:SetTexCoord(20/64, 39/64, 1/64, 20/64)
        else
            tex:SetTexCoord(20/64, 39/64, 22/64, 41/64)
        end
    end
    frame.roleIcon:Show()
end

local function ApplyPreviewAggro(frame, isRaid, p, tier)
    _setPreviewFlat(tier, frame)
    if not frame.aggroHighlight then return end
    local a = frame.aggroHighlight
    if _rp_borders().aggroEnabled and BF.db.global.testAggroHighlight and CFModuleFlag(frame, "moduleShowAggroHighlight") then
        local alpha = _rp_borders().aggroScale or 0.6
        local style = _rp_borders().aggroStyle or "border"
        -- Resolve threat color by test level selection
        local testLevel = BF.db.global.testAggroLevel or 3
        local bp = _rp_borders()
        local pc
        if testLevel >= 3 then
            pc = bp.aggroColor3 or { r=1, g=0.306, b=0 }
        elseif testLevel >= 2 then
            pc = bp.aggroColor2 or { r=1, g=0.5, b=0 }
        else
            pc = bp.aggroColor1 or { r=1, g=0.94, b=0 }
        end
        BF:SetBorderColor(a, pc.r, pc.g, pc.b, style == "border" and alpha or 0)
        if a.blizzardBorder then
            a.blizzardBorder:SetVertexColor(pc.r, pc.g, pc.b)
            a.blizzardBorder:SetAlpha(style == "blizzard" and alpha or 0)
        end
        if a.cornersTex then
            if style == "corners" then
                local scale = bp.aggroCornersScale or "lg"
                a.cornersTex:SetTexture("Interface\\AddOns\\BuzzardFrames\\Media\\aggro_corners_" .. scale)
                a.cornersTex:SetVertexColor(pc.r, pc.g, pc.b)
                a.cornersTex:SetAlpha(alpha)
            else
                a.cornersTex:SetAlpha(0)
            end
        end
        if a.arrowTex then
            if style == "arrow" or style == "arrowSingle" then
                local dir = bp.aggroArrowDirection or "right"
                local sz  = bp.aggroArrowSize or 16
                local pos = bp.aggroArrowPosition or "LEFT"
                local offX = bp.aggroArrowOffsetX or 0
                local offY = bp.aggroArrowOffsetY or 0
                local texName = (style == "arrowSingle") and "aggro_arrow_single" or "aggro_arrow"
                a.arrowTex:SetTexture("Interface\\AddOns\\BuzzardFrames\\Media\\" .. texName)
                local dirRad = dir == "right" and 0
                             or dir == "down"  and math.pi * 0.5
                             or dir == "left"  and math.pi
                             or dir == "up"    and math.pi * 1.5
                             or 0
                a.arrowTex:SetRotation(dirRad)
                local aspect = (style == "arrowSingle") and (87 / 112) or 1
                if dir == "up" or dir == "down" then
                    a.arrowTex:SetSize(sz, sz * aspect)
                else
                    a.arrowTex:SetSize(sz * aspect, sz)
                end
                a.arrowTex:ClearAllPoints()
                a.arrowTex:SetPoint(pos, frame, pos, offX, offY)
                a.arrowTex:SetVertexColor(pc.r, pc.g, pc.b)
                a.arrowTex:SetAlpha(1)
            else
                a.arrowTex:SetAlpha(0)
            end
        end
    else
        BF:SetBorderColor(a, 0, 0, 0, 0)
        if a.blizzardBorder then a.blizzardBorder:SetAlpha(0) end
        if a.cornersTex     then a.cornersTex:SetAlpha(0) end
        if a.arrowTex       then a.arrowTex:SetAlpha(0) end
    end
end

local function ApplyPreviewHighlights(frame, isRaid, p, tier)
    _setPreviewFlat(tier, frame)
    ApplyPreviewAggro(frame, isRaid, p, tier)
    if frame.targetHighlight then BF:SetBorderColor(frame.targetHighlight, 0, 0, 0, 0) end
    -- v35: debuff border/overlay keys moved from borders → auras.dispelIndicator.
    -- Resolve the sub-category once here instead of calling _rp_dispelIndicator()
    -- on every key access.
    local diP = _rp_dispelIndicator()
    -- v36: when blizzard-native mode is selected and simulateDispellableDebuff
    -- is on, the preview simulates the native Blizzard 3px dispel border so the
    -- user can see what that mode actually looks like (the Blizzard container
    -- renders a 3px border we can't hook into on preview frames, so we fake it
    -- here on our own debuffHighlight widget). The simulation overrides the
    -- normal "enableDebuffBorder + testDebuffBorder" gate — it fires purely
    -- from the master dropdown + simulateDispellableDebuff toggle. _ShowDummy
    -- DispelBorders runs AFTER this function and also paints the border in
    -- blizzard mode; both sites must agree so whichever runs last produces the
    -- same visual.
    local blizzardActive = diP.dispelIndicatorOverlayMode == "blizzard"
    local simDispel      = BF.db.global.simulateDispellableDebuff ~= false
    if frame.dispelDebuffBorder then
        if blizzardActive and simDispel and CFModuleFlag(frame, "moduleShowDebuffBorder") then
            -- Blizzard-native border simulation: fixed 3px, magic-purple, ignoring
            -- the user's custom debuffBorderWidth (which only applies in custom
            -- mode) and the testDebuffBorder toggle (which gates the custom path).
            local thickness = BF:PixelsToUI(3)
            local dh = frame.dispelDebuffBorder
            if dh.top    then dh.top:SetHeight(thickness)    end
            if dh.bottom then dh.bottom:SetHeight(thickness) end
            if dh.left   then dh.left:SetWidth(thickness)    end
            if dh.right  then dh.right:SetWidth(thickness)   end
            BF:SetBorderColor(dh, 0.20, 0.60, 1.00, 1)
        elseif diP.enableDebuffBorder and BF.db.global.testDebuffBorder and CFModuleFlag(frame, "moduleShowDebuffBorder") then
            local thickness = BF:PixelsToUI(diP.debuffBorderWidth or 2)
            local dh = frame.dispelDebuffBorder
            if dh.top    then dh.top:SetHeight(thickness)    end
            if dh.bottom then dh.bottom:SetHeight(thickness) end
            if dh.left   then dh.left:SetWidth(thickness)    end
            if dh.right  then dh.right:SetWidth(thickness)   end
            BF:SetBorderColor(dh, 0.20, 0.60, 1.00, 1)
        else
            BF:SetBorderColor(frame.dispelDebuffBorder, 0, 0, 0, 0)
        end
    end
    if frame.dispelDebuffOverlay then
        if diP.enableDebuffOverlay and BF.db.global.testDebuffOverlay and CFModuleFlag(frame, "moduleShowDebuffOverlay") then
            local alpha = diP.debuffOverlayAlpha or 0.5
            local heightFrac = diP.debuffOverlayHeight or 0.7
            frame.dispelDebuffOverlay:SetVertexColor(0.20, 0.60, 1.00, 1)
            frame.dispelDebuffOverlay:SetAlpha(alpha)
            if frame.healthBar then
                local hFill = frame.healthBar:GetStatusBarTexture()
                frame.dispelDebuffOverlay:ClearAllPoints()
                if diP.debuffOverlayFillOnly and hFill then
                    frame.dispelDebuffOverlay:SetPoint("TOPLEFT",  hFill, "TOPLEFT",  0, 0)
                    frame.dispelDebuffOverlay:SetPoint("TOPRIGHT", hFill, "TOPRIGHT", 0, 0)
                else
                    frame.dispelDebuffOverlay:SetPoint("TOPLEFT",  frame.healthBar, "TOPLEFT",  0, 0)
                    frame.dispelDebuffOverlay:SetPoint("TOPRIGHT", frame.healthBar, "TOPRIGHT", 0, 0)
                end
                frame.dispelDebuffOverlay:SetHeight(frame.healthBar:GetHeight() * heightFrac)
            end
            frame.dispelDebuffOverlay:Show()
        else
            frame.dispelDebuffOverlay:Hide()
        end
    end
end

local function ApplyPreviewStatus(frame, isRaid, p, tier)
    _setPreviewFlat(tier, frame)
    local status = BF._previewStatus
    local cfShowStatus = CFModuleFlag(frame, "moduleShowStatusText")

    -- If the CF group has status text disabled, treat as alive (no status overlay)
    if not cfShowStatus then status = nil end

    local function applyOORAlpha(isOffline)
        if not BF._previewOOR then
            frame:SetAlpha(1.0)
            BF:DarkenPreviewFrame(frame, 0)
            return
        end
        local fadeAlpha = _rp_healthPower().rangeFadeAlpha or 0.4
        if _rp_healthPower().enableRangeFade then
            frame:SetAlpha((isOffline and not _rp_text().fadeOfflineFrames) and 1.0 or fadeAlpha)
        else
            frame:SetAlpha(1.0)
        end
        if _rp_healthPower().enableRangeDesaturate then
            BF:DarkenPreviewFrame(frame, _rp_healthPower().rangeDesaturation or 1.0)
        else
            BF:DarkenPreviewFrame(frame, 0)
        end
    end

    if not status then
        if frame.statusOverlay  then frame.statusOverlay:Hide()  end
        if frame.statusText     then frame.statusText:Hide()     end
        if frame.rezPendingIcon and not BF.db.global.testResurrectPending then frame.rezPendingIcon:Hide() end
        ApplyPreviewHealthBar(frame, isRaid, p, tier)
        ApplyPreviewName(frame, isRaid, p, tier)
        ApplyPreviewHealthText(frame, isRaid, p, tier)
        applyOORAlpha(false)
        return
    end

    local t = tier or (isRaid and "raid40" or "party")
    local fakeClassColor = GetFakeClassColor(t)
    local fakeName = GetFakeUnit(t).name
    if _rp_text().abbreviateNames and #fakeName > _rp_text().maxNameChars then
        fakeName = fakeName:sub(1, _rp_text().maxNameChars)
    end
    if _rp_text().capitalizeNames then fakeName = fakeName:upper() end

    local function appendedName(baseName, label)
        label = _rp_text().capitalizeStatusText and label:upper() or label
        if _rp_text().abbreviateStatusNames and #baseName > (_rp_text().maxStatusNameChars or 9) then
            baseName = baseName:sub(1, _rp_text().maxStatusNameChars or 9)
        end
        local sep    = _rp_text().statusAppendSeparator or "PAREN"
        local before = _rp_text().statusBeforeName
        if sep == "PAREN_NOSPACE" then
            return before and ("("..label..")"..baseName) or (baseName.."("..label..")")
        elseif sep == "BRACKET" then
            return before and ("["..label.."] "..baseName) or (baseName.." ["..label.."]")
        elseif sep == "BRACKET_NOSPACE" then
            return before and ("["..label.."]"..baseName) or (baseName.."["..label.."]")
        elseif sep == "NAME_DASH_STATUS" then
            return before and (label.." - "..baseName) or (baseName.." - "..label)
        elseif sep == "NAME_NODASH" then
            return before and (label.."-"..baseName) or (baseName.."-"..label)
        elseif sep == "NAME_COMMA" then
            return before and (label..", "..baseName) or (baseName..", "..label)
        elseif sep == "NAME_COMMA_NOSPACE" then
            return before and (label..","..baseName) or (baseName..","..label)
        else
            return before and ("("..label..") "..baseName) or (baseName.." ("..label..")")
        end
    end

    if status == "offline" then
        frame.healthBar:SetMinMaxValues(0, 1)
        frame.healthBar:SetValue(0)
        if _rp_healthPower().useCustomOfflineColor then
            local c = _rp_text().offlineBackgroundColor or { r=0.3, g=0.3, b=0.3 }
            frame.healthBar:SetStatusBarColor(c.r, c.g, c.b)
            frame.healthBar:SetMinMaxValues(0, 1)
            frame.healthBar:SetValue(1)
            if frame.statusOverlay then frame.statusOverlay:Hide() end
        else
            if frame.statusOverlay then
                frame.statusOverlay:SetColorTexture(0.1, 0.1, 0.1, 0.7)
                frame.statusOverlay:Show()
            end
        end
        local classColor = _rp_text().offlineColorUseClassColor and fakeClassColor
        local tc = classColor or _rp_text().offlineColor or { r=0.5, g=0.5, b=0.5 }
        if frame.healthText then frame.healthText:Hide() end
        if _rp_text().appendStatusTextToNames then
            if frame.statusText then frame.statusText:Hide() end
            if frame.nameText and _rp_text().showName then
                local label = _rp_text().abbreviateOffline and "Off" or "Offline"
                frame.nameText:SetText(_rp_text().showOfflineStatus ~= false and appendedName(fakeName, label) or fakeName)
                frame.nameText:SetTextColor(tc.r, tc.g, tc.b)
                frame.nameText:Show()
            end
        else
            if _rp_text().showOfflineStatus ~= false and frame.statusText then
                local label = _rp_text().abbreviateOffline and "Off" or "Offline"
                frame.statusText:SetText(_rp_text().capitalizeStatusText and label:upper() or label)
                frame.statusText:SetTextColor(tc.r, tc.g, tc.b)
                frame.statusText:Show()
            end
            if frame.nameText and _rp_text().applyStatusColorsToNames then
                frame.nameText:SetTextColor(tc.r, tc.g, tc.b)
            end
        end
        applyOORAlpha(true)

    elseif status == "dead" then
        local classColor = _rp_text().deadColorUseClassColor and fakeClassColor
        local tc = classColor or (_rp_healthPower().useCustomDeadColor and _rp_text().deadColor) or { r=0.8, g=0.1, b=0.1 }
        frame.healthBar:SetMinMaxValues(0, 1)
        frame.healthBar:SetValue(0)
        local deadBarColor   = (_rp_healthPower().useCustomDeadColor and _rp_text().deadBackgroundColor) or { r=0.1, g=0.1, b=0.1 }
        local deadBarOpacity = _rp_healthPower().useCustomDeadColor and (_rp_text().deadBackgroundOpacity ~= nil and _rp_text().deadBackgroundOpacity or 0.7) or 0.7
        if frame.statusOverlay then
            frame.statusOverlay:SetColorTexture(deadBarColor.r, deadBarColor.g, deadBarColor.b, deadBarOpacity)
            frame.statusOverlay:Show()
        end
        if frame.healthText then frame.healthText:Hide() end
        if frame.rezPendingIcon then
            if (BF._previewResurrect or BF.db.global.testResurrectPending) and _rp_icons().showResurrectPending then
                local style = _rp_icons().resurrectPendingIconStyle or "blizzard"
                if style == "buzzard" then
                    frame.rezPendingIcon:SetAtlas(nil)
                    frame.rezPendingIcon:SetTexture("Interface\\AddOns\\BuzzardFrames\\Media\\buzzardRes")
                    frame.rezPendingIcon:SetTexCoord(0, 1, 0, 1)
                else
                    frame.rezPendingIcon:SetTexture(nil)
                    frame.rezPendingIcon:SetTexCoord(0, 1, 0, 1)
                    frame.rezPendingIcon:SetAtlas("RaidFrame-Icon-Rez")
                end
                frame.rezPendingIcon:Show()
            else
                frame.rezPendingIcon:Hide()
            end
        end
        local deadLabel = BF._previewGhost and "Ghost" or "Dead"
        if BF._previewOOR then
            local f = _rp_text().deadColorOORFactor; if f == nil then f = 0.5 end
            local grey = (tc.r + tc.g + tc.b) / 3
            tc = { r = tc.r*f + grey*(1-f), g = tc.g*f + grey*(1-f), b = tc.b*f + grey*(1-f) }
        end
        if _rp_text().appendStatusTextToNames then
            if frame.statusText then frame.statusText:Hide() end
            if frame.nameText and _rp_text().showName then
                frame.nameText:SetText(_rp_text().showDeadStatus ~= false and appendedName(fakeName, deadLabel) or fakeName)
                frame.nameText:SetTextColor(tc.r, tc.g, tc.b)
                frame.nameText:Show()
            end
        else
            if _rp_text().showDeadStatus ~= false and frame.statusText then
                frame.statusText:SetText(_rp_text().capitalizeStatusText and deadLabel:upper() or deadLabel)
                frame.statusText:SetTextColor(tc.r, tc.g, tc.b)
                frame.statusText:Show()
            end
            if frame.nameText and _rp_text().applyStatusColorsToNames then
                frame.nameText:SetTextColor(tc.r, tc.g, tc.b)
            end
        end
        applyOORAlpha(false)

    elseif status == "afk" then
        if frame.statusOverlay then frame.statusOverlay:Hide() end
        local classColor = _rp_text().afkColorUseClassColor and fakeClassColor
        local tc = classColor or _rp_text().afkColor or { r=0.8, g=0.6, b=0.0 }
        if _rp_text().appendStatusTextToNames then
            if frame.statusText then frame.statusText:Hide() end
            if frame.nameText and _rp_text().showName then
                frame.nameText:SetText(_rp_text().showAFKStatus and appendedName(fakeName, "AFK") or fakeName)
                frame.nameText:SetTextColor(tc.r, tc.g, tc.b)
                frame.nameText:Show()
            end
        else
            if _rp_text().showAFKStatus and frame.statusText then
                frame.statusText:SetText("AFK")
                frame.statusText:SetTextColor(tc.r, tc.g, tc.b)
                frame.statusText:Show()
            end
            if frame.nameText and _rp_text().applyStatusColorsToNames then
                frame.nameText:SetTextColor(tc.r, tc.g, tc.b)
            end
        end
        applyOORAlpha(false)
    end
end

local function ApplyPreviewStatusIcons(frame, isRaid, p, tier)
    if BF.UpdateReadyCheck       then BF:UpdateReadyCheck(frame)       end
    if BF.UpdatePhased           then BF:UpdatePhased(frame)           end
    if BF.UpdateSummonPending    then BF:UpdateSummonPending(frame)    end
    if BF.UpdateResurrectPending then BF:UpdateResurrectPending(frame) end
    if BF.UpdateVehicle          then BF:UpdateVehicle(frame)          end
end

local function ApplyPreviewAbsorbOverlay(frame, isRaid, p, tier)
    _setPreviewFlat(tier, frame)
    -- Hide everything first
    if frame.absorbMissingHealth then frame.absorbMissingHealth:Hide() end
    if frame.absorbOverflow then frame.absorbOverflow:SetAlpha(0) end
    if frame.absorbOvershield then frame.absorbOvershield:Hide() end
    if frame.overshieldGlow then frame.overshieldGlow:SetAlpha(0) end

    if not BF.db.global.testAbsorb or not CFModuleFlag(frame, "moduleShowAbsorbs") then return end

    local sizeMap    = { small = 0.10, medium = 0.40, large = 0.80, massive = 1.20 }
    local frac       = sizeMap[BF.db.global.testAbsorbSize or "medium"] or 0.40
    local maxHealth  = 100
    local totalAbsorbs = frac * 100
    local hpFrac = 0.75
    if frame.healthBar then
        local lo, hi = frame.healthBar:GetMinMaxValues()
        local val    = frame.healthBar:GetValue()
        if hi and hi > 0 then hpFrac = val / hi end
    end
    local missingHP  = math.floor((1 - hpFrac) * maxHealth + 0.5)
    local absorbed   = math.min(totalAbsorbs, missingHP)
    local r2         = totalAbsorbs > missingHP

    local hBar  = frame.healthBar
    local hFill = hBar and hBar:GetStatusBarTexture()

    -- absorbMissingHealth bar
    local ovAnchor = _rp_absorbs().overshieldAnchor or "RIGHT"
    local showMissingHealthAbsorb = _rp_absorbs().showAbsorbsMissingHealth ~= false
    local overshieldActive = BF:IsOvershieldActive(_rp_absorbs())
    if frame.absorbMissingHealth and hFill then
        if not showMissingHealthAbsorb then
            frame.absorbMissingHealth:Hide()
        -- In Overlay LEFT mode, hide missing health absorb (overshield covers everything)
        elseif _rp_absorbs().overshieldStyle ~= "Glow" and overshieldActive and ovAnchor == "LEFT" then
            frame.absorbMissingHealth:Hide()
        else
            frame.absorbMissingHealth:ClearAllPoints()
            frame.absorbMissingHealth:SetPoint("TOPLEFT",    hFill, "TOPRIGHT")
            frame.absorbMissingHealth:SetPoint("BOTTOMLEFT", hFill, "BOTTOMRIGHT")
            frame.absorbMissingHealth:SetWidth(hBar:GetWidth())
            frame.absorbMissingHealth:SetMinMaxValues(0, maxHealth)
            frame.absorbMissingHealth:SetValue(absorbed)
            frame.absorbMissingHealth:Show()
            -- Apply absorb texture from profile
            local arTex = frame.absorbMissingHealth:GetStatusBarTexture()
            if arTex then
                if _rp_absorbs().useCustomAbsorbBarTexture and _rp_absorbs().absorbBarTexture then
                    local path = BF:ResolveBarTexture(_rp_absorbs().absorbBarTexture)
                    arTex:SetTexture(path)
                    arTex:SetHorizTile(false)
                    arTex:SetVertTile(false)
                    if frame.absorbMissingHealth.overlay then frame.absorbMissingHealth.overlay:Hide() end
                else
                    arTex:SetTexture(7539076, "REPEAT", "REPEAT")
                    arTex:SetHorizTile(true)
                    arTex:SetVertTile(true)
                    if frame.absorbMissingHealth.overlay then frame.absorbMissingHealth.overlay:Show() end
                end
            end
            -- Apply colors
            if _rp_absorbs().useCustomAbsorbColor then
                local bc = _rp_absorbs().absorbBaseColor
                if bc then
                    frame.absorbMissingHealth:SetStatusBarColor(bc.r, bc.g, bc.b, bc.a or 1)
                else
                    frame.absorbMissingHealth:SetStatusBarColor(0.941, 0.941, 0.937, 1.0)
                end
            else
                frame.absorbMissingHealth:SetStatusBarColor(0.941, 0.941, 0.937, 1.0) -- #f0f0ef @ 100%
            end
            if frame.absorbMissingHealth.overlay then
                if _rp_absorbs().useCustomAbsorbColor then
                    local oc = _rp_absorbs().absorbOverlayColor
                    if oc then
                        frame.absorbMissingHealth.overlay:SetVertexColor(oc.r, oc.g, oc.b, oc.a or 1)
                    else
                        frame.absorbMissingHealth.overlay:SetVertexColor(1, 1, 1, 0.66)
                    end
                else
                    frame.absorbMissingHealth.overlay:SetVertexColor(1, 1, 1, 0.66) -- #ffffff @ 66%
                end
            end
            -- Background: covers absorbOvershield underneath the absorb texture
            if frame.absorbMissingHealth.bg then
                if _rp_healthPower().useCustomBackgroundColor then
                    local bgc = _rp_healthPower().backgroundColor or { r = 0, g = 0, b = 0 }
                    frame.absorbMissingHealth.bg:SetColorTexture(bgc.r, bgc.g, bgc.b, 1)
                else
                    frame.absorbMissingHealth.bg:SetColorTexture(0, 0, 0, 1)
                end
            end
        end
    end

    -- Overshield
    if not overshieldActive then
        if frame.absorbOvershield then frame.absorbOvershield:Hide() end
        if frame.overshieldGlow then frame.overshieldGlow:SetAlpha(0) end
        return
    end

    if _rp_absorbs().overshieldStyle == "Glow" then
        if frame.absorbOvershield then frame.absorbOvershield:Hide() end
        if frame.overshieldGlow then
            local anchor   = _rp_absorbs().overshieldAnchor or "RIGHT"
            local glowH    = math.floor(frame:GetHeight() * 0.9 + 0.5)
            frame.overshieldGlow:ClearAllPoints()
            frame.overshieldGlow:SetPoint("RIGHT", hBar, "RIGHT", 0, 0)
            frame.overshieldGlow:SetSize(3, glowH)
            if frame.overshieldGlowTex then
                frame.overshieldGlowTex:SetTexture("Interface\\RaidFrame\\Shield-Overshield")
                frame.overshieldGlowTex:SetBlendMode("ADD")
                frame.overshieldGlowTex:SetVertexColor(1, 1, 1, 1)
            end
            frame.overshieldGlow:SetAlpha(r2 and 1 or 0)
        end
    else
        -- Overlay: absorbOvershield grows left from right edge
        if frame.overshieldGlow then frame.overshieldGlow:SetAlpha(0) end
        if frame.absorbOvershield then
            local anchor = _rp_absorbs().overshieldAnchor or "RIGHT"
            frame.absorbOvershield:SetReverseFill(anchor == "RIGHT")
            frame.absorbOvershield:Show()
            if anchor == "LEFT" then
                frame.absorbOvershield:SetAlpha(1)
            else
                frame.absorbOvershield:SetAlpha(r2 and 1 or 0)
            end
            frame.absorbOvershield:SetMinMaxValues(0, maxHealth)
            frame.absorbOvershield:SetValue(totalAbsorbs)
            -- Apply overshield texture from profile
            local otTex = frame.absorbOvershield:GetStatusBarTexture()
            if otTex then
                if _rp_absorbs().useCustomOvershieldBarTexture and _rp_absorbs().overshieldBarTexture then
                    local path = BF:ResolveBarTexture(_rp_absorbs().overshieldBarTexture)
                    otTex:SetTexture(path)
                    otTex:SetHorizTile(false)
                    otTex:SetVertTile(false)
                    if frame.absorbOvershield.overlay then frame.absorbOvershield.overlay:Hide() end
                else
                    otTex:SetTexture(7539076, "REPEAT", "REPEAT")
                    otTex:SetHorizTile(true)
                    otTex:SetVertTile(true)
                    if frame.absorbOvershield.overlay then frame.absorbOvershield.overlay:Show() end
                end
            end
            -- Apply overshield colors
            if _rp_absorbs().useCustomOvershieldColor then
                local obc = _rp_absorbs().overshieldBaseColor
                if obc then
                    frame.absorbOvershield:SetStatusBarColor(obc.r, obc.g, obc.b, obc.a or 1)
                else
                    frame.absorbOvershield:SetStatusBarColor(0.937, 0.941, 0.855, 0.36)
                end
            else
                frame.absorbOvershield:SetStatusBarColor(0.937, 0.941, 0.855, 0.36) -- #eff0da @ 36%
            end
            if frame.absorbOvershield.overlay then
                if _rp_absorbs().useCustomOvershieldColor then
                    local ooc = _rp_absorbs().overshieldOverlayColor
                    if ooc then
                        frame.absorbOvershield.overlay:SetVertexColor(ooc.r, ooc.g, ooc.b, ooc.a or 1)
                    else
                        frame.absorbOvershield.overlay:SetVertexColor(1, 1, 1, 0.66)
                    end
                else
                    frame.absorbOvershield.overlay:SetVertexColor(1, 1, 1, 0.66) -- #ffffff @ 66%
                end
            end
        end
    end
end

local function ApplyPreviewHealPrediction(frame, isRaid, p, tier)
    _setPreviewFlat(tier, frame)
    if not frame.healPrediction then return end
    if not _rp_absorbs().showHealPrediction or not BF.db.global.testHealPrediction or not CFModuleFlag(frame, "moduleShowAbsorbs") then
        frame.healPrediction:SetAlpha(0)
        return
    end
    local hBar  = frame.healthBar
    local hFill = hBar and hBar:GetStatusBarTexture()
    local anchor = _rp_absorbs().healPredictionAnchor or "RIGHT"
    if hBar then
        frame.healPrediction:ClearAllPoints()
        if anchor == "LEFT" then
            -- Left: overlay on top of the health fill from the left edge.
            frame.healPrediction:SetParent(hBar)
            frame.healPrediction:SetPoint("TOPLEFT",    hBar, "TOPLEFT")
            frame.healPrediction:SetPoint("BOTTOMLEFT", hBar, "BOTTOMLEFT")
            frame.healPrediction:SetFrameLevel(hBar:GetFrameLevel() + 2)
        elseif hFill then
            -- Right (Blizzard Style): grow into the missing health area.
            if frame.frameClip then
                frame.healPrediction:SetParent(frame.frameClip)
            end
            frame.healPrediction:SetPoint("TOPLEFT",    hFill, "TOPRIGHT")
            frame.healPrediction:SetPoint("BOTTOMLEFT", hFill, "BOTTOMRIGHT")
            frame.healPrediction:SetFrameLevel(hBar:GetFrameLevel() + 2)
        end
        frame.healPrediction:SetWidth(hBar:GetWidth())
    end
    -- Apply color
    local c = _rp_absorbs().healPredictionColor
    if c then
        frame.healPrediction:SetStatusBarColor(c.r, c.g, c.b, c.a or 0.6)
    else
        frame.healPrediction:SetStatusBarColor(0, 0.7, 0, 0.6)
    end
    -- Apply texture
    if _rp_absorbs().useCustomHealPredictionTexture then
        local path = BF:ResolveBarTexture(_rp_absorbs().healPredictionTexture or "Solid")
        frame.healPrediction:SetStatusBarTexture(path)
    else
        frame.healPrediction:SetStatusBarTexture("Interface\\RaidFrame\\Raid-Bar-Hp-Fill")
    end
    frame.healPrediction:SetMinMaxValues(0, 100)
    frame.healPrediction:SetValue(10)
    frame.healPrediction:SetAlpha(1)
end

local function ApplyPreviewHealAbsorb(frame, isRaid, p, tier)
    _setPreviewFlat(tier, frame)
    if frame.healAbsorb    then frame.healAbsorb:SetAlpha(0)    end
    if frame.healAbsorbBar then frame.healAbsorbBar:SetAlpha(0) end
    if frame.healAbsorbOverlay     then frame.healAbsorbOverlay:Hide()     end
    if frame.healAbsorbRightShadow then frame.healAbsorbRightShadow:Hide() end

    if not _rp_absorbs().showHealAbsorb or not BF.db.global.testHealAbsorb or not CFModuleFlag(frame, "moduleShowAbsorbs") then return end

    local maxHealth  = 100
    local healAbsorb = 50
    local style = _rp_absorbs().healAbsorbStyle or "Overlay"
    local hFill = frame.healthBar and frame.healthBar:GetStatusBarTexture()

    if style == "Bar" or style == "BarBlizzard" then
        if frame.healAbsorbBar and frame.healthBar then
            local tex = frame.healAbsorbBar:GetStatusBarTexture()
            if style == "BarBlizzard" then
                if tex then
                    tex:SetTexture(7539017)
                    if tex.SetSnapToPixelGrid then
                        tex:SetSnapToPixelGrid(false)
                        tex:SetTexelSnappingBias(0)
                    end
                    tex:SetBlendMode("BLEND")
                end
                local c = _rp_absorbs().healAbsorbColor
                if c then
                    frame.healAbsorbBar:SetStatusBarColor(c.r, c.g, c.b, c.a or 1)
                else
                    frame.healAbsorbBar:SetStatusBarColor(1, 1, 1, 1)
                end
                if frame.healAbsorbBar._overlay then frame.healAbsorbBar._overlay:Show() end
            else
                if tex then
                    tex:SetTexture("Interface\\Buttons\\WHITE8x8")
                    if tex.SetSnapToPixelGrid then
                        tex:SetSnapToPixelGrid(false)
                        tex:SetTexelSnappingBias(0)
                    end
                    tex:SetBlendMode("BLEND")
                end
                local c = _rp_absorbs().healAbsorbColor
                if c then
                    frame.healAbsorbBar:SetStatusBarColor(c.r, c.g, c.b, c.a or 0.5)
                else
                    frame.healAbsorbBar:SetStatusBarColor(1, 0, 0, 0.5)
                end
                if frame.healAbsorbBar._overlay then frame.healAbsorbBar._overlay:Hide() end
            end
            local barH = math.min(_rp_absorbs().healAbsorbBarHeight or 3, _rp_healthPower().frameHeight or 40)
            frame.healAbsorbBar:ClearAllPoints()
            local anchor = (frame.healthBar.clipFrame) or frame.container or frame.healthBar
            frame.healAbsorbBar:SetPoint("TOPLEFT",  anchor, "TOPLEFT",  0, 0)
            frame.healAbsorbBar:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", 0, 0)
            frame.healAbsorbBar:SetHeight(math.max(barH, 1))
            frame.healAbsorbBar:SetFrameLevel(frame.healthBar:GetFrameLevel() + 5)
            frame.healAbsorbBar:SetMinMaxValues(0, maxHealth)
            frame.healAbsorbBar:SetValue(healAbsorb)
            frame.healAbsorbBar:SetAlpha(1)
        end
    else
        if frame.healAbsorb then
            local tex = frame.healAbsorb:GetStatusBarTexture()
            if style == "OverlayBlizzard" then
                -- Blizzard Style: base fill (7539017) + plus symbols overlay (7539063) + right shadow (898248)
                tex:SetTexture(7539017)
                if tex.SetSnapToPixelGrid then
                    tex:SetSnapToPixelGrid(false)
                    tex:SetTexelSnappingBias(0)
                end
                tex:SetBlendMode("BLEND")
                local c = _rp_absorbs().healAbsorbColor
                if c then
                    frame.healAbsorb:SetStatusBarColor(c.r, c.g, c.b, c.a or 1)
                else
                    frame.healAbsorb:SetStatusBarColor(1, 1, 1, 1)
                end
                if frame.healAbsorbOverlay then frame.healAbsorbOverlay:Show() end
                if frame.healAbsorbRightShadow and tex then
                    frame.healAbsorbRightShadow:ClearAllPoints()
                    frame.healAbsorbRightShadow:SetAllPoints(tex)
                    frame.healAbsorbRightShadow:Show()
                end
            else
                -- Overlay: base fill (7539017) + right shadow (898248), no plus symbols
                tex:SetTexture(7539017)
                if tex.SetSnapToPixelGrid then
                    tex:SetSnapToPixelGrid(false)
                    tex:SetTexelSnappingBias(0)
                end
                tex:SetBlendMode("BLEND")
                local c = _rp_absorbs().healAbsorbColor
                if c then
                    frame.healAbsorb:SetStatusBarColor(c.r, c.g, c.b, c.a or 1)
                else
                    frame.healAbsorb:SetStatusBarColor(1, 1, 1, 1)
                end
                if frame.healAbsorbOverlay then frame.healAbsorbOverlay:Hide() end
                if frame.healAbsorbRightShadow and tex then
                    frame.healAbsorbRightShadow:ClearAllPoints()
                    frame.healAbsorbRightShadow:SetAllPoints(tex)
                    frame.healAbsorbRightShadow:Show()
                end
            end
            if hFill then
                frame.healAbsorb:ClearAllPoints()
                frame.healAbsorb:SetPoint("TOPRIGHT",    hFill, "TOPRIGHT")
                frame.healAbsorb:SetPoint("BOTTOMRIGHT", hFill, "BOTTOMRIGHT")
                frame.healAbsorb:SetWidth(frame.healthBar:GetWidth())
            end
            frame.healAbsorb:SetMinMaxValues(0, maxHealth)
            frame.healAbsorb:SetValue(healAbsorb)
            frame.healAbsorb:SetAlpha(1)
        end
    end
end

local function ApplyPreviewReducedMaxHealth(frame, isRaid, p, tier)
    _setPreviewFlat(tier, frame)
    local bar = frame.reducedMaxHealthBar
    if not bar then return end

    if not _rp_absorbs().showReducedMaxHealth or not BF.db.global.testReducedMaxHealth then
        bar:Hide()
        frame._reducedMaxPct = nil
        -- Hide text indicator
        if frame.reducedMaxHealthText then
            frame.reducedMaxHealthText:SetText("")
            frame.reducedMaxHealthText:Hide()
        end
        -- Restore health bar anchors if they were modified
        if frame._reducedMaxHealthActive then
            local hBar = frame.healthBar
            local container = frame.container
            if hBar and container then
                local clip = hBar.clipFrame
                if clip then
                    clip:ClearAllPoints()
                    clip:SetAllPoints(container)
                    hBar:ClearAllPoints()
                    hBar:SetAllPoints(clip)
                else
                    hBar:ClearAllPoints()
                    hBar:SetAllPoints(container)
                end
            end
            frame._reducedMaxHealthActive = nil
        end
        return
    end

    local pct = 0.5  -- test at 50%

    -- Texture
    if _rp_absorbs().useCustomReducedMaxTexture then
        local path = BF:ResolveBarTexture(_rp_absorbs().reducedMaxHealthTexture or "Solid")
        bar:SetStatusBarTexture(path)
        local c = _rp_absorbs().reducedMaxHealthColor
        if c then
            bar:SetStatusBarColor(c.r, c.g, c.b, c.a or 0.8)
        else
            bar:SetStatusBarColor(0.3, 0.3, 0.3, 0.8)
        end
    else
        bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
        local tex = bar:GetStatusBarTexture()
        if tex then tex:SetAtlas("Raid Frame") end
        bar:SetStatusBarColor(1, 1, 1, 1)
    end

    bar:SetMinMaxValues(0, 1)
    bar:SetValue(pct)
    bar:Show()

    frame._reducedMaxPct = pct
    -- Update text indicator directly (preview frames have no real unit)
    if _rp_absorbs().showReducedMaxHealthText then
        local remainPct = math.floor((1 - pct) * 100 + 0.5)
        local suffix = string.format(" (%d%%)", remainPct)
        if _rp_absorbs().appendReducedMaxText then
            -- Append to health text or name text
            local target = _rp_absorbs().appendReducedMaxTarget or "health"
            local targetFs = (target == "name") and frame.nameText or frame.healthText
            if targetFs then
                local existing = targetFs:GetText() or ""
                targetFs:SetText(existing .. suffix)
                local c = _rp_absorbs().reducedMaxHealthTextColor
                if c then targetFs:SetTextColor(c.r, c.g, c.b) end
            end
            -- Hide standalone text
            if frame.reducedMaxHealthText then
                frame.reducedMaxHealthText:SetText("")
                frame.reducedMaxHealthText:Hide()
            end
        else
            -- Standalone text
            local textInd = BF:GetIndicatorByName("reducedMaxHealthText")
            if textInd then textInd:Layout(frame) end
            local fs = frame.reducedMaxHealthText
            if fs then
                fs:SetFormattedText("(%d%%)", remainPct)
                fs:Show()
            end
        end
    elseif frame.reducedMaxHealthText then
        frame.reducedMaxHealthText:SetText("")
        frame.reducedMaxHealthText:Hide()
    end

    -- Resize health bar
    local hBar = frame.healthBar
    local container = frame.container
    local reducedTex = bar:GetStatusBarTexture()
    if hBar and container and reducedTex then
        local clip = hBar.clipFrame
        if clip then
            clip:ClearAllPoints()
            clip:SetPoint("TOPLEFT", container, "TOPLEFT")
            clip:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT")
            clip:SetPoint("TOPRIGHT", reducedTex, "TOPLEFT")
            clip:SetPoint("BOTTOMRIGHT", reducedTex, "BOTTOMLEFT")
            hBar:ClearAllPoints()
            hBar:SetAllPoints(clip)
        else
            hBar:ClearAllPoints()
            hBar:SetPoint("TOPLEFT", container, "TOPLEFT")
            hBar:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT")
            hBar:SetPoint("TOPRIGHT", reducedTex, "TOPLEFT")
            hBar:SetPoint("BOTTOMRIGHT", reducedTex, "BOTTOMLEFT")
        end
        frame._reducedMaxHealthActive = true
    end
end

local function ApplyAllPreviewDummyData(frame, isRaid, p, tier)
    ApplyPreviewHealthBar(frame, isRaid, p, tier)
    ApplyPreviewName(frame, isRaid, p, tier)
    ApplyPreviewHealthText(frame, isRaid, p, tier)
    ApplyPreviewPowerBar(frame, isRaid, p, tier)
    ApplyPreviewRoleIcon(frame, isRaid, p, tier)
    ApplyPreviewHighlights(frame, isRaid, p, tier)
    ApplyPreviewStatusIcons(frame, isRaid, p, tier)
    ApplyPreviewStatus(frame, isRaid, p, tier)
    ApplyPreviewHealPrediction(frame, isRaid, p, tier)
    ApplyPreviewHealAbsorb(frame, isRaid, p, tier)
    ApplyPreviewAbsorbOverlay(frame, isRaid, p, tier)
    ApplyPreviewReducedMaxHealth(frame, isRaid, p, tier)
end


-- ============================================================
-- Exports: expose local functions for Options_PreviewSystem.lua
-- ============================================================
BF._preview = BF._preview or {}
BF._preview.EnabledCFGroups              = EnabledCFGroups
BF._preview.GetFakeUnit                  = GetFakeUnit
BF._preview.GetFakeClassColor            = GetFakeClassColor
BF._preview.ApplyPreviewHealthBar        = ApplyPreviewHealthBar
BF._preview.ApplyPreviewName             = ApplyPreviewName
BF._preview.ApplyPreviewHealthText       = ApplyPreviewHealthText
BF._preview.ApplyPreviewPowerBar         = ApplyPreviewPowerBar
BF._preview.ApplyPreviewRoleIcon         = ApplyPreviewRoleIcon
BF._preview.ApplyPreviewHighlights       = ApplyPreviewHighlights
BF._preview.ApplyPreviewAggro            = ApplyPreviewAggro
BF._preview.ApplyPreviewStatus           = ApplyPreviewStatus
BF._preview.ApplyPreviewStatusIcons      = ApplyPreviewStatusIcons
BF._preview.ApplyPreviewAbsorbOverlay    = ApplyPreviewAbsorbOverlay
BF._preview.ApplyPreviewHealPrediction   = ApplyPreviewHealPrediction
BF._preview.ApplyPreviewHealAbsorb       = ApplyPreviewHealAbsorb
BF._preview.ApplyPreviewReducedMaxHealth = ApplyPreviewReducedMaxHealth
BF._preview.ApplyAllPreviewDummyData     = ApplyAllPreviewDummyData
BF._preview.TYPE_DEFAULTS                = TYPE_DEFAULTS
BF._preview.CF_FAKE_UNIT_DEFAULTS        = CF_FAKE_UNIT_DEFAULTS
BF._preview.GetFlatTypeDefault           = GetFlatTypeDefault
BF._preview.MAX_CF_PREVIEWS              = MAX_CF_PREVIEWS
