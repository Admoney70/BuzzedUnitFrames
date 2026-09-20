-- ============================================================
-- BuzzardFrames: SingleBuffAPI.lua
-- The single-buff / curated-spell helpers the runtime and the options
-- panel (BuzzardFramesOptions) share: the healer spec table, curated
-- icon and class lookups, spell-input resolution, the "which spells sit
-- in container N" scan, single-buff creation, and the spec-condition
-- predicates the Buff List and its preview both ask.
--
-- Loads after AuraCustomizations\TrackedAuras.lua (BF.SPEC_SPELLS, read at
-- file scope below) and AuraCustomizations\AuraCustomizations.lua (the
-- container CRUD CreateSingleBuffContainer calls at runtime).
-- ============================================================
local BF = _G["BuzzardFrames"]
-- The addon private table, for the curated buff list (ns.SpellData, built by
-- SpellSearch\SpellData_Buffs.lua). Read lazily at call time.
local _addonName, ns = ...


-- ── Healer specs ─────────────────────────────────────────────────────────
-- classColor: WoW class color hex (RRGGBB, no alpha prefix) for the spec name label
local HEALER_SPECS = {
    { id = 256,  name = "Discipline Priest",   tabName = "Discipline Priest",    classColor = "c2c2c2", tabPad = "   " },
    { id = 257,  name = "Holy Priest",         tabName = "Holy Priest",          classColor = "c2c2c2", tabPad = "       " },
    { id = 65,   name = "Holy Paladin",        tabName = "Holy Paladin",         classColor = "f48cba", tabPad = "      " },
    { id = 270,  name = "Mistweaver Monk",     tabName = "Mistweaver Monk",      classColor = "00ff98", tabPad = "    " },
    { id = 1473, name = "Augmentation Evoker", tabName = "Augmentation Evoker",  classColor = "33937f" },
    { id = 1468, name = "Preservation Evoker", tabName = "Preservation Evoker",  classColor = "33937f" },
    { id = 105,  name = "Restoration Druid",   tabName = "Resto Druid",          classColor = "ff7c0a" },
    { id = 264,  name = "Restoration Shaman",  tabName = "Resto Shaman",         classColor = "0070dd" },
}

-- Expose spec order for ShowDummyContainerAuras fallback
BF.HEALER_SPEC_ORDER = HEALER_SPECS

-- ── Spell list and untracked defaults: read from BF.SPEC_SPELLS (defined in CustomAuras.lua)
local SPEC_SPELLS = BF.SPEC_SPELLS

-- v70: spec-INDEPENDENT spell icon. C_Spell.GetSpellTexture follows the
-- player's live spell overrides (spec/talent replacements), so asking it
-- for Power Word: Shield while a Holy priest returned the OVERRIDE's art
-- (Prayer of Mending) — labels changed with the player's spec. Prefer the
-- curated list's BAKED icon; only spells outside every curated list fall
-- back to the live API (nothing better exists for them, and hand-typed
-- IDs rarely carry overrides). Cached: curated data is static.
local _curatedIconCache = {}
local function CuratedSpellIcon(sid)
    if not sid then return nil end
    local hit = _curatedIconCache[sid]
    if hit ~= nil then return hit or nil end
    for specId, list in pairs(SPEC_SPELLS or {}) do
        for i = 1, #list do
            if list[i].id == sid and list[i].icon then
                _curatedIconCache[sid] = list[i].icon
                return list[i].icon
            end
        end
    end
    _curatedIconCache[sid] = false
    return nil
end

local DEFAULT_UNTRACKED = {}
for specId, spells in pairs(SPEC_SPELLS) do
    for _, s in ipairs(spells) do
        if s.untracked then
            if not DEFAULT_UNTRACKED[specId] then DEFAULT_UNTRACKED[specId] = {} end
            DEFAULT_UNTRACKED[specId][s.id] = true
        end
    end
end

local function getAssignedContainerForSpell(sid, specId)
    local p = BF.acDB and BF.acDB.profile
    local assign = p and p.spellAssign and p.spellAssign[specId] and p.spellAssign[specId][sid]
    if assign == "untracked" then return -1 end
    if assign == "default"   then return 0  end
    if assign then
        -- "c:N" format
        local n = tonumber(assign:match("^c:(%d+)$"))
        if n then return n end
    end
    -- Not set by user: DEFAULT_UNTRACKED spells show as Untracked by default
    local defaultUntracked = DEFAULT_UNTRACKED[specId]
    if defaultUntracked and defaultUntracked[sid] then return -1 end
    return 0
end

-- ── v65: class color for a spell label ───────────────────────────────────
-- The curated buff list knows which class each spell belongs to:
-- ns.SpellData.BYID[sid] = { id, class, cat }, where `class` is the token
-- ("PRIEST"). Read at CALL time -- SpellData_Buffs.lua loads long before this
-- file (.toc 61 vs 148), but the guard costs nothing and keeps this file
-- loadable on its own, matching how ns.SpellData is reached elsewhere here.
--
-- Returns the label UNCHANGED when the spell has no class: anything the user
-- typed in by ID, and the neutral buffs. Those keep the default color rather
-- than being given an invented one.
--
-- Deliberately does NOT edit SpellData_Buffs.lua, which the .toc marks as a
-- verbatim copy of the Buzzard Auras file.
-- v70: class token for spells the SpellSearch dataset does not carry —
-- hidden detection auras (Sense Power) never made it into the generated
-- buff-search data, so BYID has no entry and the label stayed uncolored.
-- Reads the curated row's own EXPLICIT `class` field only (opt-in per
-- row; deriving from which spec's list holds the spell would guess wrong
-- for any future cross-class entry). Cached: curated data is static.
local _curatedClassCache = {}
local function CuratedSpellClass(sid)
    if not sid then return nil end
    local hit = _curatedClassCache[sid]
    if hit ~= nil then return hit or nil end
    for _, list in pairs(BF.SPEC_SPELLS or {}) do
        for i = 1, #list do
            if list[i].id == sid and list[i].class then
                _curatedClassCache[sid] = list[i].class
                return list[i].class
            end
        end
    end
    _curatedClassCache[sid] = false
    return nil
end

local function classColorSpellName(spellID, label)
    if not (spellID and label) then return label end
    local sd = ns and ns.SpellData
    local e  = sd and sd.BYID and sd.BYID[spellID]
    local cls = (e and e.class) or CuratedSpellClass(spellID)
    if not cls or cls == "" then return label end
    local cc = RAID_CLASS_COLORS and RAID_CLASS_COLORS[cls]
    if not (cc and cc.colorStr) then return label end
    return "|c" .. cc.colorStr .. label .. "|r"
end

-- Exposed for BuzzardFramesOptions, whose Buff List draws the same rows this
-- file's tree did: the spell name in its class's color, and the BAKED
-- curated icon rather than GetSpellTexture -- which is override-sensitive and
-- changes a row's art with the player's spec. Thin wrappers over the locals
-- above rather than a second copy of either rule: the two surfaces must not
-- drift, and the curated class cache is here.
function BF.ClassColorSpellName(spellID, label)
    return classColorSpellName(spellID, label)
end

function BF.CuratedSpellIcon(spellID)
    return CuratedSpellIcon(spellID)
end

-- ── v65: spec icon + class color for a "Filter by Spec" dropdown row ─────
-- The spec icon from BF.specByID, then the name in the spec's classColor.
-- Minus the tabPad, which only exists to space a tab strip.
--
-- Shared by every Filter by Spec dropdown in the options panel (the Buff
-- List one and the container's assignedSpecFilter) so they cannot drift.
--
-- Everything degrades: no icon, no color, or an unknown spec each fall back a
-- step rather than erroring, because this feeds a purely presentational filter.
function BF.SpecFilterLabel(specEntry)
    if type(specEntry) ~= "table" then return "" end
    local label = specEntry.tabName or specEntry.name or tostring(specEntry.id or "?")
    local color = specEntry.classColor
    if color and color ~= "" then
        label = "|cff" .. color .. label .. "|r"
    end
    local sd   = BF.specByID and specEntry.id and BF.specByID[specEntry.id]
    local icon = sd and sd.icon
    if icon then
        return "|T" .. icon .. ":14:14:0:0|t " .. label
    end
    return label
end

-- Resolve free text to a spell. Accepts a numeric spell ID or a spell NAME
-- (C_Spell.GetSpellInfo takes either and returns the canonical ID).
-- Returns spellID, spellName -- or nil plus a message to show the user.

local function resolveSpellInput(text)
    -- The setter's value can arrive as a number, not a string (an editbox
    -- whose OnEnterPressed fires from a non-typed path), so normalize first.
    text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return nil, "Enter a spell name or spell ID." end
    local sid = tonumber(text)
    if not sid then
        local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(text)
        sid = type(info) == "table" and info.spellID or nil
    end
    local name = sid and C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(sid)
    if not (sid and name) then
        return nil, "No spell found for \"" .. text .. "\"."
    end
    return sid, name
end
-- Exported for the options panel's Add boxes. One resolver, so "42" and
-- "Rejuvenation" behave identically wherever the user types them.
BF.ResolveSpellInput = resolveSpellInput

-- v64: the ONE enumerator for "which curated spells are assigned to container
-- N". Five inline `"c:"..N` scans used to do this independently (the
-- Assigned Spells empty-state, the per-spec has-spells test, the separator
-- predicate, each spell button's hidden(), and the delete-confirm text).
--
-- Built on getAssignedContainerForSpell rather than matching the stored string
-- directly, which matters: a raw `"c:"` match silently misses the
-- DEFAULT_UNTRACKED fallback above, so the two disagreed for any spell the
-- user had never explicitly assigned.
--
-- `out` is an optional reusable array -- the options panel rebuilds this per
-- container per host and has no reason to allocate. Returns it, wiped and
-- refilled, sorted by spell name so callers do not each re-sort.
local _spellsInContainerScratch = {}
local _sicSeen = {}
local function spellsInContainer(globalIndex, out)
    out = out or _spellsInContainerScratch
    table.wipe(out)
    table.wipe(_sicSeen)
    local p = BF.acDB and BF.acDB.profile
    for _, spec in ipairs(HEALER_SPECS) do
        local specId = spec.id
        -- Pass 1: the curated list. Has to run even though pass 2 walks the
        -- stored assignments, because a curated spell can resolve to this
        -- container through the DEFAULT_UNTRACKED fallback with NO spellAssign
        -- entry of its own -- pass 2 would never see it.
        for si, spell in ipairs(SPEC_SPELLS[specId] or {}) do
            if getAssignedContainerForSpell(spell.id, specId) == globalIndex
                and not _sicSeen[spell.id] then
                _sicSeen[spell.id] = true
                out[#out + 1] = {
                    specId = specId, spec = spec, curated = true,
                    si = si, sid = spell.id, spell = spell,
                    name = spell.name or tostring(spell.id),
                }
            end
        end
        -- Pass 2: stored assignments, which is where a spell the user typed
        -- into the Add box by ID lands. Without this the spell renders in game
        -- -- EnsureFetchBuffSettings routes straight off selectedSpells and
        -- never consults SPEC_SPELLS -- but has no list row, so it cannot be
        -- seen, ordered or removed. An orphan.
        local assigns = p and p.spellAssign and p.spellAssign[specId]
        if assigns then
            for sid, val in pairs(assigns) do
                if type(sid) == "number" and not _sicSeen[sid]
                    and type(val) == "string"
                    and tonumber(val:match("^c:(%d+)$")) == globalIndex then
                    _sicSeen[sid] = true
                    out[#out + 1] = {
                        specId = specId, spec = spec, curated = false,
                        si = nil, sid = sid, spell = { id = sid },
                        name = (C_Spell and C_Spell.GetSpellName
                                and C_Spell.GetSpellName(sid)) or tostring(sid),
                    }
                end
            end
        end
    end
    table.sort(out, function(a, b)
        local an, bn = a.name:lower(), b.name:lower()
        if an ~= bn then return an < bn end
        return a.sid < b.sid   -- stable: two specs can curate one spell
    end)
    return out
end
BF.SpellsInContainer = spellsInContainer

-- Should a newly created single buff for this spell default to "Own only"?
--
-- Yes for the categories in the curated buff list that describe an aura you
-- put on YOURSELF -- "Healer Buff", "Personal Buff" and "Personal Defensive".
-- Those are the ones where seeing someone else's copy on your frames is noise.
-- Everything else (raid buffs, EXTERNAL defensives, bloodlust, movement, and
-- every uncurated spell ID typed in by hand) defaults to off, because the
-- interesting question for those is usually "does anyone have this", not "did
-- I cast it".
--
-- Note the deliberate asymmetry between the two defensive categories: a
-- Personal Defensive is self-cast by definition, while an External Defensive
-- is cast BY someone else ON the unit, so own-only would hide every instance
-- of it that matters.
--
-- Only a DEFAULT. The entry's Conditions tab can change it afterwards, and
-- nothing re-derives it later.
local OWN_ONLY_CATEGORIES = {
    ["Healer Buff"]        = true,
    ["Personal Buff"]      = true,
    ["Personal Defensive"] = true,
}
local function defaultOwnOnlyFor(sid)
    local sd = ns and ns.SpellData
    local e  = sd and sd.BYID and sd.BYID[sid]
    return (e and e.cat and OWN_ONLY_CATEGORIES[e.cat]) and true or false
end

-- Create a Single Buff container holding one spell.
-- Returns newIndex, spellName, singleBuffKey -- or nil, errorMessage.
--
-- onlyMine: optional override. Omitted (the normal path) means "derive it from
-- the curated buff list category" -- see defaultOwnOnlyFor. Pass false to force
-- the buff to show from ANY caster.
-- v65: `blacklist` seeds Display Type = Blacklist instead of Show (Default
-- Buff), which is what files the new entry under the Blacklist heading. Passed
-- in rather than set by the caller afterwards so the entry is never briefly in
-- the wrong section, and so the create path stays the one place a single
-- buff's starting state is defined.
function BF:CreateSingleBuffContainer(text, onlyMine, blacklist)
    if InCombatLockdown() then return nil, "Not available in combat." end
    local sid, resolved = resolveSpellInput(text)
    if not sid then return nil, resolved end
    if onlyMine == nil then onlyMine = defaultOwnOnlyFor(sid) end
    -- v62: the "specialization is not known yet" bail is gone with the
    -- spellAssign write it existed to protect. A single buff has no per-spec
    -- assignment at all; it shows on every spec until its own Spec condition
    -- says otherwise, so creating one no longer needs a resolved spec.
    -- Seed, not a second creator (plan 3.65): every other creation-time field
    -- (the auraText inheritance in particular) has to stay identical for both
    -- container kinds. autoNamed = false keeps the delete-renumbering loop in
    -- RemoveCustomBuffContainer from overwriting the spell-derived name.
    --
    -- v62 (plan 3.67): the spell is stamped ON the container
    -- (singleBuffSpellID) together with its stable per-entry identity
    -- (singleBuffKey, minted first-unused-slot by BF:NewSingleBuffKey). No
    -- spellAssign / selectedSpells write happens at all -- see the block
    -- comment on BF:GetSingleBuffSpellID for why single buffs left that
    -- mechanism instead of trying to make it many-to-many.
    -- Minted into a local so it can be RETURNED: the key is the entry's args
    -- key in the Single Buffs tree ("single_"..key), which is what the caller
    -- needs to deep-link to the thing it just made. Reading it back off the
    -- container by index would work today but goes stale the moment a delete
    -- renumbers the array between the create and the navigation.
    local singleBuffKey = BF:NewSingleBuffKey(sid)
    local _, newIndex = BF:CreateCustomBuffContainer({
        singleBuff                = true,
        maxBuffs                  = 1,
        -- v65: INHERIT the Buffs icon size. A new entry is Buffs-anchored (see
        -- below), so it flows in the regular buff row -- giving it its own size
        -- would make it the one odd icon in that row the moment it is created.
        -- This was `false` while a new entry was a free-floating container.
        containerUsesBuffSettings = true,
        -- v64: writes the three-state field, not the retired containerAnyCaster
        -- boolean. onlyMine is still a two-state derivation from the curated
        -- buff list's category (defaultOwnOnlyFor), so it only ever seeds
        -- "any" or the default; "notme" is a deliberate user choice and is
        -- never a default. "mine" stores nothing, keeping the field sparse.
        containerCasterScope      = (onlyMine == false) and "any" or nil,
        -- v65: through BF.SpellDisplayName so an ambiguous spell (the Pres
        -- Evoker Echo copies, whose API name is the BASE spell's) is stored
        -- disambiguated, exactly as migration 59 stamps it.
        name                      = (BF.SpellDisplayName
                                     and BF.SpellDisplayName(sid, resolved))
                                    or resolved,
        autoNamed                 = false,
        singleBuffSpellID         = sid,
        singleBuffKey             = singleBuffKey,
        -- ── v65: the defaults a new entry starts at ───────────────────────
        -- Anchor Point = Buffs and Display Type = Show (Default Buff), i.e. it
        -- appears in the regular buff row drawn exactly like an ordinary buff.
        -- Adding a spell should put it somewhere visible and unsurprising; the
        -- user then moves or customizes it. Matches what migrations 57 and 59
        -- create, so a hand-added entry and a migrated one start identical.
        --
        -- singleBuffCustomized = false, NOT nil: nil means "Show (Customized
        -- Buff)" -- see the Display Type setter, where only an explicit false
        -- selects Default, and SBRoot, which only nils the visual store on an
        -- explicit false.
        anchorPoint               = "BUFFS",
        sbRelativeOrder           = "BEFORE",
        singleBuffCustomized      = false,
        -- v65: Mode = Blacklist. `or nil` keeps the field sparse -- the whole
        -- codebase tests singleBuffHidden for truth, and singleBuffDisplayType
        -- reads a stored `false` as "not hidden" just as it reads absent.
        singleBuffHidden          = blacklist or nil,
    })
    -- v62: the specSpellCustomized raise that used to live here is GONE.
    --
    -- It existed for exactly one reason: a curated spell of the current spec
    -- only reached spellToContainer while its master customize flag was set, so
    -- without the raise the freshly-assigned single buff rendered nothing. A
    -- single buff no longer uses spellToContainer, so that gate cannot apply to
    -- it and the raise buys nothing.
    --
    -- Keeping it would actively hurt: the flag is what routes a spell into its
    -- own per-spell aura group, and with the container no longer resolvable
    -- through spellToContainer that group would be built against the GENERAL
    -- buffs group instead -- a duplicate icon in the wrong place. It also flips
    -- a user-visible master toggle in Aura Customizations (with its own frame
    -- effects / glow / bounce consequences) for a spell the user only ever
    -- asked to see as a single buff. GetContainerBuffConfig now suppresses that
    -- stray per-spell group via _fbsSingleBuffHeld, so a flag raised for other
    -- reasons is harmless either way.
    BF:RefreshAllCustomContainersWithRebuild()
    -- 3rd return (v63): the tree-entry key, so the caller can deep-link to the
    -- new entry. Appended, never inserted -- the failure path above returns
    -- (nil, errorMessage) and callers test the FIRST value, so both existing
    -- two-value call sites are unaffected.
    return newIndex, resolved, singleBuffKey
end

local SB_KSPEC = "sb"
BF.SINGLE_BUFF_VISUAL_KSPEC = SB_KSPEC

-- v66: the BF.specData entry for the one spec a container is restricted to, or
-- nil when it is restricted to none, to more than one, or not restricted at all.
-- Presentational only -- the runtime gate is BF:IsSingleBuffSpecMet.
--
-- Namespaced on BF for the options panel (Buff List row labels and the
-- Conditions card).
--
-- Bails at the second hit: this runs once per Buff List row per redraw
-- (~48 rows over a ~40-entry spec table), so the common "restricted to a
-- whole class" case costs a handful of comparisons instead of a full sweep.
function BF.GetSingleEnabledSpec(c)
    if not (c and c.loadSpec) then return nil end
    local t = c.loadSpecTypes
    -- Storage convention (do NOT invert): an absent TABLE means every spec is
    -- on, which is by definition not a single spec.
    if type(t) ~= "table" then return nil end
    local specList = BF.specData or {}
    local found
    for i = 1, #specList do
        local s = specList[i]
        -- Absent KEY also means on, hence `~= false` and not a truth test.
        if t[s.id] ~= false then
            if found then return nil end
            found = s
        end
    end
    return found
end

-- v92: TRUE when the entry's Spec condition is enabled with NOTHING ticked --
-- the state the specToggle setter's first-enable seed produces (every spec
-- explicitly false). The entry can then never show in game. Consumers:
--   * the Buff List tree row appends a "!" warning mark,
--   * its Conditions tab shows a red note,
--   * the Buff List spec filter keeps the entry visible under EVERY selection
--     (BF:SingleBuffMatchesSpecFilter below) so the user can finish ticking
--     specs -- Buzzard Auras' Spec Filter rule for incomplete configs.
-- Same storage convention as GetSingleEnabledSpec above: absent table = all
-- ON; absent key = ON; only explicit false is OFF.
function BF.SingleBuffSpecConditionEmpty(c)
    if not (c and c.loadSpec) then return false end
    local t = c.loadSpecTypes
    if type(t) ~= "table" then return false end
    local specList = BF.specData or {}
    for i = 1, #specList do
        if t[specList[i].id] ~= false then return false end
    end
    return #specList > 0
end

-- ── Pseudo Buff List entries ──────────────────────────────────────────────
-- A pseudo entry is a Buff List row that configures a FEATURE rather than an
-- aura. It lives in customBuffContainers alongside the real single buffs (so
-- it sorts, searches and exports like one) but carries `pseudoKind`, which
-- makes BF:GetSingleBuffSpellID return nil -- the one choke point that keeps
-- it out of the aura engine entirely: no group, no slot, no claim/exclude set,
-- no icon pool, no preview, no Order.
--
-- `singleBuffSpellID` is still stored: it is the row's FACE (icon, name, key
-- mint, export round-trip), read through BF:GetSingleBuffDisplaySpellID.
--
-- Adding another: add a builder here and seed an entry in Core_Migrations.

-- Fixed spec pin, shown on the row and used by the tree's spec filter. These
-- are features with a hard runtime spec gate (Swiftmendable's lives in the
-- cfg build: `specId2 == 105`), so the pin is descriptive, not editable --
-- which is why a pseudo entry gets no Conditions tab.
-- `color` is the row label's color code. A pseudo entry is NOT class-colored
-- like a real single buff: its face spell's class says nothing about what the
-- row configures (Swiftmend is a Druid spell, so the row would read as Druid
-- orange). Swiftmendable takes 66d9ff -- the feature's own default Name Color
-- (0.4, 0.85, 1.0), so the row matches what it paints on the frames.
local PSEUDO_ENTRY_SPEC = {
    swiftmendable = { spec = 105, color = "ff66d9ff" },  -- Restoration Druid
}
BF.PSEUDO_ENTRY_SPEC = PSEUDO_ENTRY_SPEC

-- Which spec's curated list a spell belongs to. Feeds the tree's spec filter,
-- which is PRESENTATIONAL ONLY -- it never changes what an edit writes, and a
-- spell in no curated list is simply only reachable under "All".
function BF:SingleBuffSpellInSpecList(sid, specId)
    local list = SPEC_SPELLS and SPEC_SPELLS[specId]
    if not list then return false end
    for i = 1, #list do
        if list[i].id == sid then return true end
    end
    return false
end

-- ── Buff List spec filter ────────────────────────────────────────────────
-- A container context is open, but not a single container: says "a container
-- surface is showing" without claiming to be container N. Exported so the
-- preview painter can VALIDATE the buffList mode rather than trust that every
-- exit from that subtab remembered to clear it. See the self-expiry gate in
-- DummyAuras.lua (_BuffListPreviewActive).
BF.SINGLE_BUFF_SUBTAB_SENTINEL = -1

-- Does entry `c` belong under spec filter `f` (0 = "All")? The SPEC half only,
-- as a positive test. The Buff List tree and the Buff List preview painter
-- (DummyAuras.lua) both ask this, which is the whole point: the preview must
-- show exactly the entries the list is showing.
--
-- Rules, in order:
--   * "All" matches everything.
--   * An entry with no display spell matches nothing (the `false` placeholder).
--   * An entry whose Spec condition is on with NOTHING ticked is an INCOMPLETE
--     config, not a deliberate scope -- you get it the moment you click Spec to
--     start setting one up -- so it stays visible under every selection.
--   * A Spec condition with a table decides by that table (absent key = on).
--   * Otherwise curated-list membership: the spec's list holds the spell.
function BF:SingleBuffMatchesSpecFilter(c, f)
    if type(c) ~= "table" then return false end
    f = tonumber(f) or 0
    if f == 0 then return true end
    local sid = BF.GetSingleBuffDisplaySpellID and BF:GetSingleBuffDisplaySpellID(c) or nil
    if not sid then return false end
    if c.loadSpec then
        local t = c.loadSpecTypes
        if t ~= nil then
            if BF.SingleBuffSpecConditionEmpty(c) then return true end
            return t[f] ~= false
        end
        return true  -- condition on, no table: every spec ON (fail-open)
    end
    return BF:SingleBuffSpellInSpecList(sid, f)
end

-- Perf plan §L5.1 load-time mark.
if BuzzardFrames then BuzzardFrames:LoadMark("chunk:postSingleBuffAPI") end
