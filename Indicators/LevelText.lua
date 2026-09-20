--[[
BuzzardFrames: Indicators/LevelText.lua
Level text indicator — shows the unit's level on each raid/party frame.

Grid2 has no analogous indicator. This mirrors HealthText.lua's structure
(Create/Layout/Update + Grid2 unconditional-overwrite Update pattern).

Driven by the "level" status (Statuses/Level.lua), which fires
UNIT_LEVEL / PLAYER_LEVEL_UP. The initial render on unit-join is handled
by the framework's frame:UpdateIndicators() path (BFLayout.lua:OnUnitChanged).
]]

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local UnitLevel          = UnitLevel
local UnitEffectiveLevel = UnitEffectiveLevel
local UnitExists         = UnitExists

-- Resolve max level once at file load. Same approach as oUF_Shared.lua:995.
-- GetMaxLevelForPlayerExpansion is the live cap; MAX_PLAYER_LEVEL is the
-- static fallback. The "or 80" guard matches oUF_Shared's pattern.
local function GetMaxLevel()
    if GetMaxLevelForPlayerExpansion then return GetMaxLevelForPlayerExpansion() end
    return MAX_PLAYER_LEVEL or 80
end

local LevelText = BF.indicatorPrototype:new("levelText")

-- ============================================================
-- Create
-- ============================================================
function LevelText:Create(parent)
    if parent.levelText then
        parent[self.name] = parent.levelText
        return
    end

    local textFrame = parent.textFrame
    if not textFrame then
        textFrame = CreateFrame("Frame", nil, parent)
        textFrame:SetAllPoints(parent)
        textFrame:SetFrameLevel(parent:GetFrameLevel() + 216)
        textFrame:EnableMouse(false)
        parent.textFrame = textFrame
    end

    local fs = textFrame:CreateFontString(nil, "OVERLAY")
    fs:SetFontObject(GameFontNormalSmall)
    local font, size, flags = fs:GetFont()
    font  = font  or BF.font or "Fonts\\FRIZQT__.TTF"
    size  = size  or 10
    flags = flags or ""
    fs.SF_defaultFont  = font
    fs.SF_defaultSize  = size
    fs.SF_defaultFlags = flags
    fs:SetShadowOffset(1, -1)
    fs:SetShadowColor(0, 0, 0, 1)
    fs:SetJustifyH("CENTER")

    local hBar = parent.healthBar
    local tpInit = BF:GetSectionProfile("text", nil)
    local pos = (tpInit and tpInit.levelTextPosition) or "TOPRIGHT"
    local anchor = parent.container or hBar or parent
    fs:SetPoint(pos, anchor, pos, 0, 0)

    local c = (tpInit and tpInit.levelTextColor) or { r = 1, g = 0.82, b = 0 }
    fs:SetTextColor(c.r, c.g, c.b)

    parent[self.name] = fs
    parent.levelText  = fs  -- alias for parity with parent.healthText
end

-- ============================================================
-- Layout
-- ============================================================
function LevelText:Layout(parent)
    local fs = parent[self.name]
    if not fs then return end

    local tp = BF:GetSectionProfileForFrame("text", parent)
    if not tp then return end

    local origFont  = fs.SF_defaultFont  or "Fonts\\FRIZQT__.TTF"
    local origSize  = fs.SF_defaultSize  or 10
    local origFlags = fs.SF_defaultFlags or ""
    if tp.adjustLevelFont then
        local fontPath = BF:ResolveFontPath(tp.levelFont)
        fs:SetFont(fontPath, tp.levelFontSize, tp.levelFontBorder or "")
    else
        fs:SetFont(origFont, origSize, origFlags)
    end

    local hBar = parent.healthBar
    local ltPos = tp.levelTextPosition or "TOPRIGHT"
    fs:ClearAllPoints()
    local anchor = parent.container or hBar or parent
    fs:SetPoint(ltPos, anchor, ltPos, tp.levelTextX or 0, tp.levelTextY or 0)

    -- Static color (class color is applied per-unit in Update)
    if tp.adjustLevelTextColor and not tp.classColorLevelText then
        local c = tp.levelTextColor or { r = 1, g = 0.82, b = 0 }
        fs:SetTextColor(c.r, c.g, c.b)
    elseif not tp.adjustLevelTextColor then
        fs:SetTextColor(1, 0.82, 0)
    end
end

-- ============================================================
-- Update: unconditionally overwrite (Grid2 pattern)
-- ============================================================
function LevelText:Update(parent, unit)
    local fs = parent[self.name]
    if not fs then return end

    local tp = BF:GetCachedSection("text", parent)

    if not tp or not tp.showLevelText or not unit or not UnitExists(unit) then
        fs:SetText("")
        fs:Hide()
        return
    end

    local level = UnitEffectiveLevel and UnitEffectiveLevel(unit) or UnitLevel(unit)

    -- Boss / unknown-level (level == -1) → show "??"
    local displayText
    if level == -1 then
        displayText = "??"
    else
        if tp.hideLevelTextAtMaxLevel and level and level >= GetMaxLevel() then
            fs:SetText("")
            fs:Hide()
            return
        end
        if not level or level <= 0 then
            fs:SetText("")
            fs:Hide()
            return
        end
        displayText = tostring(level)
    end

    -- Color: mirror HealthText pattern. Class color is read from the health
    -- status (same source HealthText uses) so the class lookup path is shared.
    if tp.adjustLevelTextColor and tp.classColorLevelText then
        local healthStatus = BF.statuses and BF.statuses.health
        local className = healthStatus and healthStatus:GetClass(unit)
        if className and BF.classColors and BF.classColors[className] then
            local c = BF.classColors[className]
            fs:SetTextColor(c.r, c.g, c.b)
        else
            local c = tp.levelTextColor or { r = 1, g = 0.82, b = 0 }
            fs:SetTextColor(c.r, c.g, c.b)
        end
    elseif tp.adjustLevelTextColor then
        local c = tp.levelTextColor or { r = 1, g = 0.82, b = 0 }
        fs:SetTextColor(c.r, c.g, c.b)
    else
        fs:SetTextColor(1, 0.82, 0)
    end

    fs:SetText(displayText)
    fs:Show()
end

BF:RegisterIndicator(LevelText)
