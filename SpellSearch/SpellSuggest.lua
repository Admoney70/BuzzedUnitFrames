-- ============================================================
-- BuzzardFrames: SpellSearch\SpellSuggest.lua
-- Curated buff suggestions, as a plain function on the addon table.
--
-- The options panel lives in its own addon (BuzzardFramesOptions), which
-- cannot see this addon's private `ns`; its text control asks a function
-- for rows instead. This is that function.
--
-- Deliberately NOT written into SpellData_Buffs.lua, which is a verbatim
-- copy of the Buzzard Auras file of the same name and has to stay
-- diff-clean against it.
--
-- Rules: rows come only from the curated table (there is no API to
-- classify an arbitrary spell ID), the "Debuff" category is excluded
-- because this is the BUFF list, a name matches on PREFIX, and a numeric
-- entry previews whatever ID was typed whether it is curated or not.
--
-- COMBAT: never runs there. The fields that call it are `disabled = "combat"`,
-- and the panel does not build a disabled field's suggestions.
-- ============================================================
-- Perf plan §L5.1 load-time mark: closes the SpellData_Buffs parse.
if BuzzardFrames then BuzzardFrames:LoadMark("chunk:spellData") end

local BF = _G["BuzzardFrames"]
local _addonName, ns = ...

local GetSpellName    = C_Spell and C_Spell.GetSpellName
local GetSpellTexture = C_Spell and C_Spell.GetSpellTexture

local DEBUFF_CAT = "Debuff"
local FALLBACK_ICON = 134400

-- Colored class suffixes, built once, on first use rather than at load:
-- LOCALIZED_CLASS_NAMES_MALE is populated by the client, and this file is
-- read long before anybody opens the options.
local classNames
local function BuildClassNames()
    if classNames then return end
    classNames = { [""] = "" }
    for class, translation in pairs(LOCALIZED_CLASS_NAMES_MALE or {}) do
        local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
        if c then
            classNames[class] = (", |cff%.2x%.2x%.2x%s|r"):format(
                c.r * 255, c.g * 255, c.b * 255, translation)
        else
            classNames[class] = ", " .. translation
        end
    end
end

-- Icon, name, class, category, ID -- the row the Ace predictor drew, so the
-- two lists read identically to anyone who used the old panel.
local function RowText(id, name, class, cat)
    local catText = cat and (", |cffffd100%s|r"):format(cat) or ""
    return ("|T%s:14|t %s%s%s |cff888888(%d)|r"):format(
        (GetSpellTexture and GetSpellTexture(id)) or FALLBACK_ICON, name,
        (class and classNames[class]) or "", catText, id)
end

-- text  what is in the box
-- max   how many rows the caller will draw (nil = 15)
--
-- Returns an ARRAY of { value = <spellID>, text = <row> }, or nil when there
-- is nothing to offer -- an empty box, no curated data, or no match. `value`
-- is the ID, which is what the box takes when a row is picked: the add path
-- resolves an ID exactly, where a localised name it has to look up again is
-- a second chance to get a different spell.
function BF.SpellSuggestions(text, max)
    local sd   = ns and ns.SpellData
    local flat = sd and sd.FLAT
    if not (flat and GetSpellName) then return nil end

    text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return nil end

    BuildClassNames()
    local out = {}

    -- A number is not a search. It is the reader telling us the ID, so the
    -- one row is a preview of what that ID actually is -- curated or not,
    -- category or not -- which is how a paste is checked before Enter.
    local num = text:match("^%d+$") and tonumber(text)
    if num then
        local name = GetSpellName(num)
        if not name then return nil end
        local known = sd.BYID and sd.BYID[num]
        out[1] = { value = num,
                   text = RowText(num, name, known and known.class,
                                  known and known.cat) }
        return out
    end

    local l    = text:lower()
    local seen = {}
    local room = max or 15
    for i = 1, #flat do
        local e = flat[i]
        if e.cat ~= DEBUFF_CAT and not seen[e.id] then
            local name = GetSpellName(e.id)
            if name and name:lower():find(l, 1, true) == 1 then
                seen[e.id] = true
                out[#out + 1] = { value = e.id, text = RowText(e.id, name, e.class, e.cat) }
                if #out >= room then break end
            end
        end
    end

    if #out == 0 then return nil end
    return out
end
