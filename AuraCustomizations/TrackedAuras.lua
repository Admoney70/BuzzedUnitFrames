local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

-- Spell IDs for aura filtering
BF.SATED_SPELL_IDS = {
    [57723]  = true,  -- Exhaustion (Shaman)
    [57724]  = true,  -- Sated (Mage)
    [80354]  = true,  -- Temporal Displacement (Mage)
    [95809]  = true,  -- Insanity (Hunter pet)
    [160455] = true,  -- Fatigued (Hunter pet)
    [264689] = true,  -- Fatigued (Hunter pet)
    [390435] = true,  -- Exhaustion (Evoker)
}
BF.DESERTER_SPELL_IDS = {
    [26013]  = true,  -- Deserter (BG)
    [71041]  = true,  -- Dungeon Deserter
}
BF.SKYRIDING_SPELL_IDS = {
    [427490] = true,  -- Ride Along Available
    [447959] = true,  -- Ride Along Active
    [447960] = true,  -- Ride Along Inactive
}
BF.ARCANE_EMPOWERMENT_SPELL_IDS = {
    [1254550] = true,  -- Arcane Empowerment
}
BF.TIME_TRIAL_SPELL_IDS = {
    [308312]  = true,  -- Time Trial Practice
}
-- (DEBUFF_BLACKLIST removed: its only entry, Challenger's Burden, no
-- longer exists in Midnight, and the table had no remaining consumers.)
-- Raid buff spell IDs per class, used for the "missing buff" indicator.
-- Keyed by UnitClassBase() return value (uppercase English class name).
-- Each entry is either a single spell ID (number) or a set of IDs (table)
-- for classes like Evoker whose buff lands as a class-specific variant on each unit.
BF.CLASS_RAID_BUFF = {
    ["DRUID"]   = 1126,    -- Mark of the Wild
    ["PRIEST"]  = 21562,   -- Power Word: Fortitude
    ["WARRIOR"] = 6673,    -- Battle Shout
    ["SHAMAN"]  = 462854,  -- Skyfury
    ["MAGE"]    = 1459,    -- Arcane Intellect
    -- Evoker: Blessing of the Bronze lands as a class-specific variant on each unit
    ["EVOKER"]  = {
        [381732] = true,   -- Blessing of the Bronze: Death Knight
        [381741] = true,   -- Blessing of the Bronze: Demon Hunter
        [381746] = true,   -- Blessing of the Bronze: Druid
        [381748] = true,   -- Blessing of the Bronze: Evoker
        [381749] = true,   -- Blessing of the Bronze: Hunter
        [381750] = true,   -- Blessing of the Bronze: Mage
        [381751] = true,   -- Blessing of the Bronze: Monk
        [381752] = true,   -- Blessing of the Bronze: Paladin
        [381753] = true,   -- Blessing of the Bronze: Priest
        [381754] = true,   -- Blessing of the Bronze: Rogue
        [381756] = true,   -- Blessing of the Bronze: Shaman
        [381757] = true,   -- Blessing of the Bronze: Warlock
        [381758] = true,   -- Blessing of the Bronze: Warrior
    },
}

-- Reverse lookup for Evoker: unit class -> the specific Blessing of the Bronze variant
-- that lands on units of that class. Allows a single GetAuraDataBySpellID call
-- instead of iterating all 13 variants.
BF.EVOKER_BUFF_BY_CLASS = {
    ["DEATHKNIGHT"] = 381732,
    ["DEMONHUNTER"] = 381741,
    ["DRUID"]       = 381746,
    ["EVOKER"]      = 381748,
    ["HUNTER"]      = 381749,
    ["MAGE"]        = 381750,
    ["MONK"]        = 381751,
    ["PALADIN"]     = 381752,
    ["PRIEST"]      = 381753,
    ["ROGUE"]       = 381754,
    ["SHAMAN"]      = 381756,
    ["WARLOCK"]     = 381757,
    ["WARRIOR"]     = 381758,
}

-- Per-spec raid buff spell IDs to show out of combat when the Raid Buffs setting is on.
-- Only list spells that are actually cast by that spec.
BF.SPEC_RAID_BUFF_IDS = {
    -- Shaman
    [264] = { [462854] = true },   -- Resto: Skyfury
    [262] = { [462854] = true },   -- Elemental: Skyfury
    [263] = { [462854] = true },   -- Enhancement: Skyfury
    -- Druid
    [105] = { [1126] = true },     -- Restoration: Mark of the Wild
    [102] = { [1126] = true },     -- Balance: Mark of the Wild
    [103] = { [1126] = true },     -- Feral: Mark of the Wild
    [104] = { [1126] = true },     -- Guardian: Mark of the Wild
    -- Priest
    [256] = { [21562] = true },    -- Discipline: Power Word: Fortitude
    [257] = { [21562] = true },    -- Holy: Power Word: Fortitude
    [258] = { [21562] = true },    -- Shadow: Power Word: Fortitude
    -- Warrior
    [71]  = { [6673] = true },     -- Arms: Battle Shout
    [72]  = { [6673] = true },     -- Fury: Battle Shout
    [73]  = { [6673] = true },     -- Protection: Battle Shout
    -- Evoker (Blessing of the Bronze, all class variants)
    [1473] = {
        [381732] = true,   -- Blessing of the Bronze: Death Knight
        [381741] = true,   -- Blessing of the Bronze: Demon Hunter
        [381746] = true,   -- Blessing of the Bronze: Druid
        [381748] = true,   -- Blessing of the Bronze: Evoker
        [381749] = true,   -- Blessing of the Bronze: Hunter
        [381750] = true,   -- Blessing of the Bronze: Mage
        [381751] = true,   -- Blessing of the Bronze: Monk
        [381752] = true,   -- Blessing of the Bronze: Paladin
        [381753] = true,   -- Blessing of the Bronze: Priest
        [381754] = true,   -- Blessing of the Bronze: Rogue
        [381756] = true,   -- Blessing of the Bronze: Shaman
        [381757] = true,   -- Blessing of the Bronze: Warlock
        [381758] = true,   -- Blessing of the Bronze: Warrior
    },
    [1468] = {
        [381732] = true,   -- Blessing of the Bronze: Death Knight
        [381741] = true,   -- Blessing of the Bronze: Demon Hunter
        [381746] = true,   -- Blessing of the Bronze: Druid
        [381748] = true,   -- Blessing of the Bronze: Evoker
        [381749] = true,   -- Blessing of the Bronze: Hunter
        [381750] = true,   -- Blessing of the Bronze: Mage
        [381751] = true,   -- Blessing of the Bronze: Monk
        [381752] = true,   -- Blessing of the Bronze: Paladin
        [381753] = true,   -- Blessing of the Bronze: Priest
        [381754] = true,   -- Blessing of the Bronze: Rogue
        [381756] = true,   -- Blessing of the Bronze: Shaman
        [381757] = true,   -- Blessing of the Bronze: Warlock
        [381758] = true,   -- Blessing of the Bronze: Warrior
    },
    -- v59 FIX: this key was a SECOND [1473], so Lua's table constructor
    -- silently kept only the last one and DEVASTATION (1467) had no entry
    -- at all. A Devastation Evoker's Blessing of the Bronze therefore
    -- never matched ShouldFilterBuff, so "Show Long-Term Buffs Out of
    -- Combat (Raid Buffs)" did nothing for them.
    [1467] = {
        [381732] = true,   -- Blessing of the Bronze: Death Knight
        [381741] = true,   -- Blessing of the Bronze: Demon Hunter
        [381746] = true,   -- Blessing of the Bronze: Druid
        [381748] = true,   -- Blessing of the Bronze: Evoker
        [381749] = true,   -- Blessing of the Bronze: Hunter
        [381750] = true,   -- Blessing of the Bronze: Mage
        [381751] = true,   -- Blessing of the Bronze: Monk
        [381752] = true,   -- Blessing of the Bronze: Paladin
        [381753] = true,   -- Blessing of the Bronze: Priest
        [381754] = true,   -- Blessing of the Bronze: Rogue
        [381756] = true,   -- Blessing of the Bronze: Shaman
        [381757] = true,   -- Blessing of the Bronze: Warlock
        [381758] = true,   -- Blessing of the Bronze: Warrior
    },
    -- Mage
    [62]  = { [1459] = true },     -- Arcane: Arcane Intellect
    [63]  = { [1459] = true },     -- Fire: Arcane Intellect
    [64]  = { [1459] = true },     -- Frost: Arcane Intellect
}

-- ============================================================
-- MASTER SPELL TABLE
--
-- Single source of truth for all tracked spells, shared with
-- Options_CustomAuras.lua via BF.SPEC_SPELLS.
--
-- Each entry: { id=spellID, name="Spell Name", untracked=true|nil }
--   untracked=true  -> hidden by default; user can promote to Default or a container
--   untracked=nil   -> shown in regular buffFrames by default
--
-- profile.spellAssign[specId][sid]:
--   nil         = not added by user (untracked spells are suppressed)
--   "default"   = show in regular buffFrames
--   "untracked" = suppress entirely
--   "c:N"       = assigned to container index N
-- ============================================================
BF.SPEC_SPELLS = {
    [256] = {
        { id = 194384,   name = "Atonement"          },
        { id = 17,       name = "Power Word: Shield", icon = "Interface/Icons/Spell_Holy_PowerWordShield" },
        { id = 41635,    name = "Prayer of Mending"  },
        { id = 1253593,  name = "Void Shield"        },
        { id = 10060,    name = "Power Infusion" },
    },
    [65] = {
        { id = 156910,   name = "Beacon of Faith",      noDuration = true },
        { id = 53563,    name = "Beacon of Light",      noDuration = true },
        { id = 1244893,  name = "Beacon of the Savior", noDuration = true },
        { id = 200025,   name = "Beacon of Virtue"     },
        { id = 156322,   name = "Eternal Flame"        },
        -- v70: plain spell-ID rows. These were "secret detection" entries
        -- (elimination-by-fingerprint, hero-tree resolution, Holy Bulwark
        -- aliased onto Holy Armaments) — 12.0.7-era machinery for auras
        -- whose spellId was secret. On 12.1 they match by spell ID like
        -- every other aura, so the flags, the alias, and the hero-tree
        -- split are gone; Sacred Weapon and Holy Bulwark are ordinary
        -- separate rows now.
        -- class: these auras are absent from the SpellSearch dataset
        -- (ns.SpellData.BYID) that normally supplies the class token for
        -- list coloring — stated explicitly instead (classColorSpellName's
        -- curated fallback).
        { id = 1044,     name = "Blessing of Freedom", class = "PALADIN" },
        { id = 431381,   name = "Dawnlight",           class = "PALADIN" },
        { id = 432502,   name = "Sacred Weapon",       class = "PALADIN" },
        { id = 432496,   name = "Holy Bulwark",        class = "PALADIN" },
    },
    [257] = {
        { id = 41635,    name = "Prayer of Mending" },
        { id = 139,      name = "Renew"             },
        { id = 77489,    name = "Echo of Light",    untracked = true },
        { id = 10060,    name = "Power Infusion" },
    },
    [105] = {
        { id = 33763,    name = "Lifebloom"        },
        { id = 8936,     name = "Regrowth"         },
        { id = 774,      name = "Rejuvenation"     },
        { id = 155777,   name = "Rejuvenation (Germination)" },
        { id = 439530,   name = "Symbiotic Blooms", untracked = true },
        { id = 48438,    name = "Wild Growth"      },
    },
    [270] = {
        { id = 124682,   name = "Enveloping Mist"   },
        { id = 119611,   name = "Renewing Mist"     },
        { id = 115175,   name = "Soothing Mist"     },
        { id = 450769,   name = "Aspect of Harmony", untracked = true },
    },
    [1473] = {
        { id = 360827,   name = "Blistering Scales"  },
        { id = 395152,   name = "Ebon Might"         },
        { id = 410263,   name = "Inferno's Blessing" },
        { id = 410089,   name = "Prescience"         },
        { id = 413984,   name = "Shifting Sands"     },
        { id = 410686,   name = "Symbiotic Bloom"    },
        { id = 369459,   name = "Source of Magic", untracked = true },
        -- class: absent from the SpellSearch buff dataset (ns.SpellData.BYID)
        -- that normally supplies the class token for list coloring — stated
        -- here explicitly instead (classColorSpellName falls back to the
        -- curated row's own class). v70: plain spell-ID row (was a 12.0.7-era
        -- "secret detection" entry; on 12.1 it matches by ID like any aura).
        { id = 361022,   name = "Sense Power", class = "EVOKER" },
    },
    [1468] = {
        { id = 355941,   name = "Dream Breath"      },
        { id = 363502,   name = "Dream Flight"      },
        { id = 364343,   name = "Echo"              },
        { id = 376788,   name = "Echo Dream Breath" },
        { id = 367364,   name = "Echo Reversion"    },
        { id = 373267,   name = "Lifebind"          },
        { id = 366155,   name = "Reversion"         },
    },
    [264] = {
        { id = 974,      name = "Earth Shield"       },
        { id = 383648,   name = "Earth Shield (Self)" },
        { id = 61295,    name = "Riptide"             },
        { id = 207400,   name = "Ancestral Vigor",    untracked = true },
        { id = 382024,   name = "Earthliving Weapon", untracked = true },
        { id = 444490,   name = "Hydrobubble",        untracked = true },
    },
}

-- ── v65: DISPLAY NAME OVERRIDES ───────────────────────────────────────────
-- Some spells share a name with another spell in the same list, so the name
-- the game returns cannot tell them apart.
--
-- Preservation Evoker's Echo duplicates a HoT as a SEPARATE aura with its own
-- spell ID -- and C_Spell.GetSpellName returns the BASE spell's name for it.
-- So "Dream Breath" appears twice in the Single Buffs list with nothing to
-- distinguish the copies, and the same for Reversion.
--
-- The curated table above already carries distinguishing names ("Echo Dream
-- Breath"), but every list is built from the API name, because that is the
-- localized one. This overrides only where the API is ambiguous, in the
-- "<base> (Echo)" form so the two sort together and read as a pair.
--
-- Add an entry here whenever two curated spells collide on name; nothing else
-- needs changing.
BF.SPELL_DISPLAY_NAME_OVERRIDES = {
    [376788] = "Dream Breath (Echo)",   -- Echo copy of 355941 Dream Breath
    [367364] = "Reversion (Echo)",      -- Echo copy of 366155 Reversion
    [383648] = "Earth Shield (Self)",   -- self-cast copy of 974 Earth Shield
}

-- The name to show for a spell: the override when one exists, else the game's
-- own name, else the id. `fallback` lets a caller supply a name it already has
-- (the curated table's, say) for when the API has not cached the spell yet.
function BF.SpellDisplayName(spellID, fallback)
    if type(spellID) ~= "number" then return fallback end
    local o = BF.SPELL_DISPLAY_NAME_OVERRIDES[spellID]
    if o then return o end
    return (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID))
        or fallback or tostring(spellID)
end