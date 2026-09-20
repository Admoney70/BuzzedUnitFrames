--[[
BuzzardFrames: Core_FlatDefaults.lua

Sparse flat storage + metatable __index fallback.

Problem:
  AceDB strips default-equal values from SavedVariables on logout, so any
  flat whose defaults were fully materialized in the defaults table would
  come back on next login missing those keys. That caused crashes on reads
  like rpDB.profile.layouts.flatLayouts.flat_party.showGroup[i] and wrong
  values on reads like flat.frameHeight (nil -> 0).

Solution:
  Each flat stores only the keys the user has actually customized, plus
  four invariants that are kept as real keys: name, type, anchorX, anchorY.
  Every other key falls through to a per-flat template via __index.

  The template is produced by CreateRaidProfile(anchorX, anchorY) or
  CreatePartyProfile() and is fresh per flat (raid templates bake the flat
  anchor coordinates into their defaults, so templates cannot be shared
  across flats).

  AceDB's logout walker uses pairs() which does NOT follow __index, so
  template keys never leak into SavedVariables — storage stays sparse.

Entry points:
  BF:WireFlatDefaults(flat)  — attach the metatable to a single flat.
  BF:RehydrateFlats()        — seed flat_party/flat_raid40 if missing,
                               repair invariants on all existing flats,
                               and wire every flat.
]]

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

-- ============================================================
-- BF:WireFlatDefaults(flat)
--
-- Attach a fresh CreateRaidProfile / CreatePartyProfile template as the
-- flat's __index metatable. Any raw read that misses in the flat itself
-- falls through to the template.
--
-- Idempotent: re-wiring a flat just replaces its metatable with a fresh
-- template. That's what we want when anchorX/anchorY change (template
-- needs to bake the new anchor values into raid defaults).
-- ============================================================
function BF:WireFlatDefaults(flat)
    if type(flat) ~= "table" then return end

    local template
    if flat.type == "raid" then
        template = self:CreateRaidProfile(flat.anchorX, flat.anchorY)
    elseif flat.type == "party" then
        template = self:CreatePartyProfile()
    else
        -- Unknown type — leave unwired. Caller set flat.type wrong.
        return
    end

    -- Raid-style twin scale, one per twin, default 1. These live on the
    -- TEMPLATE like frameWidth does, so an untouched flat stores nothing
    -- and a right-click "Reset to default" in either options panel finds
    -- a shipped value to answer with. Seeded here rather than in
    -- CreateRaidProfile / CreatePartyProfile because both templates want
    -- the same four keys with the same default and neither type differs.
    if template.twinScalePlayer == nil then template.twinScalePlayer = 1 end
    if template.twinScaleTarget == nil then template.twinScaleTarget = 1 end
    if template.twinScaleFocus  == nil then template.twinScaleFocus  = 1 end
    if template.twinScaleBoss   == nil then template.twinScaleBoss   = 1 end

    -- Remove the invariants from the template so they cannot shadow the
    -- flat's own raw values if the user deletes them. These four keys
    -- must always live as rawkeys on the flat itself.
    template.name    = nil
    template.type    = nil
    template.anchorX = nil
    template.anchorY = nil

    setmetatable(flat, { __index = template })
end

-- ============================================================
-- BF:RehydrateFlats()
--
-- Called after DB load, after profile change/copy/reset, and after
-- profile import. Responsibilities:
--   1. Ensure the flatLayouts container exists.
--   2. Seed flat_party and flat_raid40 if missing (fresh-install path
--      and after v23 migration on profiles that never had them).
--   3. REPAIR invariants on existing flats — any flat whose type/name/
--      anchor fields were lost (AceDB SV strip, corrupt migration, etc.)
--      is restored. This is critical because WireFlatDefaults uses
--      flat.type to pick the template and silently returns on unknown
--      type, which would leave the flat un-wired and crash later reads.
--   4. Wire every flat with the __index metatable template.
--
-- The repair logic infers type from the flat ID: flat_party → party,
-- flat_raid20/30/40 → raid. For user-created flats (flat_1, flat_N,
-- flat_migrated_N) we cannot infer type from the ID so we leave the
-- repair to the user (the flat is broken beyond what we can guess).
-- Those still get wired by WireFlatDefaults as long as their type
-- rawkey survived.
-- ============================================================
function BF:RehydrateFlats()
    -- dbVersion 65: translate any retired per-Layout aura toggle key (auras /
    -- aurasBuffs / aurasDebuffs) onto the four auras_<subcat> keys before
    -- anything reads them, then nil it. This one hook covers every entry
    -- point that can introduce the old names -- login (Core_DB), profile
    -- change (Core_ProfileLifecycle), post-import (Options_Profiles) and
    -- post-flat-copy (Options_Layouts) all call RehydrateFlats already, and
    -- the import path is the one a dbVersion block cannot reach at all.
    -- Idempotent and seed-only-when-nil; see BF:NormalizeAuraPerLayoutKeys.
    -- Only the ACTIVE rpDB profile is in scope here, which is the same scope
    -- as the rest of this function.
    if self.NormalizeAuraPerLayoutKeys then
        self:NormalizeAuraPerLayoutKeys(self.rpDB and self.rpDB.profile)
    end
    -- 2026-08-24: same hook, same rationale, for the five per-subtab
    -- sections (text/icons/borders/healthPower/absorbs) -- translates a
    -- retired whole-section toggle key onto all its subtab keys. See
    -- BF:NormalizeSectionPerLayoutKeys and
    -- Docs/_PLAN_PerLayoutSubtabToggles.md.
    if self.NormalizeSectionPerLayoutKeys then
        self:NormalizeSectionPerLayoutKeys(self.rpDB and self.rpDB.profile)
    end

    local rpl = self.rpDB and self.rpDB.profile and self.rpDB.profile.layouts
    if not rpl then return end

    rpl.flatLayouts = rpl.flatLayouts or {}

    if not rpl.flatLayouts.flat_party then
        rpl.flatLayouts.flat_party = {
            name    = "Party",
            type    = "party",
            anchorX = -260,
            anchorY = -200,
        }
    end
    if not rpl.flatLayouts.flat_raid40 then
        rpl.flatLayouts.flat_raid40 = {
            name    = "Raid",
            type    = "raid",
            anchorX = -260,
            anchorY = -200,
        }
        -- Fresh-install seed: default the Dispel Indicator overlay mode to
        -- "blizzard" on the default raid flat only. Existing users (who
        -- already have flat_raid40) skip this block so their setting is
        -- untouched. Party flats fall through to the global "custom"
        -- default via the section-fallback metatable chain.
        if self.GetOrCreateAurasSubCategory then
            local di = self:GetOrCreateAurasSubCategory(rpl.flatLayouts.flat_raid40, "dispelIndicator")
            if di then di.dispelIndicatorOverlayMode = "blizzard" end
        end
    end

    -- ── Repair pass ────────────────────────────────────────────────
    -- For each flat, ensure the four invariants are set. Infer type
    -- and name from the ID for seeded flats. Raid anchors default to
    -- (-260, -200) matching CreateFlatRaidLayout's seed; party anchors
    -- default to (-260, -200) matching CreatePartyProfile's default.
    local SEEDED = {
        flat_party  = { type = "party", name = "Party",      anchorX = -260, anchorY = -200 },
        flat_raid20 = { type = "raid",  name = "Raid (20)",  anchorX = -260, anchorY = -200 },
        flat_raid30 = { type = "raid",  name = "Raid (30)",  anchorX = -260, anchorY = -200 },
        flat_raid40 = { type = "raid",  name = "Raid",       anchorX = -260, anchorY = -200 },
    }
    for id, flat in pairs(rpl.flatLayouts) do
        if type(flat) == "table" then
            local seed = SEEDED[id]
            if seed then
                -- Seeded flat: fill any missing invariant from the seed table.
                if flat.type    == nil then flat.type    = seed.type    end
                if flat.name    == nil then flat.name    = seed.name    end
                if flat.anchorX      == nil then flat.anchorX      = seed.anchorX end
                if flat.anchorY      == nil then flat.anchorY      = seed.anchorY end
                if flat.type == "party" then
                    if flat.partyLayoutAnchor == nil then flat.partyLayoutAnchor = "TOPLEFT" end
                else
                    if flat.raidLayoutAnchor == nil then flat.raidLayoutAnchor = "TOPLEFT" end
                end
            else
                -- User flat: we can't guess type/name, but we can supply
                -- anchors so raid-typed flats don't end up with nil
                -- anchorX/Y passed into CreateRaidProfile.
                if flat.anchorX == nil then flat.anchorX = -260 end
                if flat.anchorY == nil then flat.anchorY = -200 end
                if flat.type == "party" then
                    if flat.partyLayoutAnchor == nil then flat.partyLayoutAnchor = "TOPLEFT" end
                else
                    if flat.raidLayoutAnchor == nil then flat.raidLayoutAnchor = "TOPLEFT" end
                end
                if flat.name         == nil then flat.name         = id         end
            end
        end
    end

    for _, flat in pairs(rpl.flatLayouts) do
        self:WireFlatDefaults(flat)
    end

    -- ── Section fallback wiring ────────────────────────────────────
    -- For every flat, attach the section-fallback metatable to every
    -- per-layout section sub-table that exists on the flat. This makes
    -- missing keys (e.g. a newly-added default added after the flat was
    -- seeded) fall through to rpDB.profile[section] transparently.
    -- Idempotent — WireSectionFallback early-returns when already wired.
    local sections = self._perLayoutSections
    if sections then
        for _, flat in pairs(rpl.flatLayouts) do
            if type(flat) == "table" then
                for i = 1, #sections do
                    self:WireSectionFallback(flat, sections[i])
                end
            end
        end
    end

    -- ── Auras sub-category fallback wiring (v27) ──────────────────
    -- The auras section is nested one level deeper than the other
    -- per-layout sections: under toggle-ON, flat.auras is sparse at
    -- the top level AND each flat.auras.<subcat> is sparse too. The
    -- first-tier fallback (wired above) covers reads like
    -- aurasP.buffs when flat.auras has no rawkey for `buffs`. The
    -- second tier, wired here, covers reads like aurasP.buffs.buffSize
    -- when flat.auras.buffs exists as a sparse rawkey table (user
    -- customized at least one buff key). Without this second tier,
    -- un-customized keys inside a sparse sub-category would return
    -- nil instead of the global default.
    --
    -- Idempotent — WireAurasSubCategoryFallbacks only re-wires
    -- metatables whose __index doesn't already point at the correct
    -- global sub-table.
    for _, flat in pairs(rpl.flatLayouts) do
        if type(flat) == "table" and type(rawget(flat, "auras")) == "table" then
            self:WireAurasSubCategoryFallbacks(flat.auras)
        end
    end

    -- Second-tier fallbacks for auraText sub-categories (v30). Same
    -- reasoning as the auras block above: under the per-layout toggle,
    -- auraText is nested two levels deep (flat.auraText -> global.auraText,
    -- and each flat.auraText.<subcat> -> global.auraText.<subcat>).
    -- The first-tier fallback is wired by WireSectionFallback in the
    -- _perLayoutSections loop earlier in this function. This second tier
    -- covers reads like atP.buffs.buffSize when flat.auraText.buffs
    -- exists as a sparse rawkey table. Idempotent.
    for _, flat in pairs(rpl.flatLayouts) do
        if type(flat) == "table" and type(rawget(flat, "auraText")) == "table" then
            self:WireAuraTextSubCategoryFallbacks(flat.auraText)
        end
    end
end

-- Sections that support per-CFG override toggles.
-- Each entry: { section = "flat sub-table key", flag = "group.overrideX field" }
--
-- v60: "auras" is deliberately NOT listed here. A single section-level flag
-- cannot express the aura case any more: the Buffs and Debuffs halves of the
-- auras table have independent per-Layout toggles, so a Custom Frame Group
-- needs an independent override answer for each half. Those live in
-- BF.AURAS_GROUP_CFG_FLAG below and are consulted per sub-category by
-- ResolveCFGAurasSubcat (Auras/AuraConfig.lua). The old single
-- group.overrideAuras field is migrated onto both new flags and then nilled.
BF.CFG_OVERRIDABLE_SECTIONS = {
    { section = "tooltips",    flag = "overrideTooltips" },
    { section = "text",        flag = "overrideText" },
    { section = "healthPower", flag = "overrideHealthPower" },
    { section = "borders",     flag = "overrideBorders" },
    { section = "absorbs",     flag = "overrideAbsorbs" },
    { section = "icons",       flag = "overrideIcons" },
    { section = "auraText",    flag = "overrideAuraText" },
    { section = "castBar",     flag = "overrideCastBar" },
}

-- Reverse lookup: section name → override flag name.
-- Used by GetSectionProfileForFrame to check CFG override toggles.
BF.CFG_SECTION_TO_FLAG = {}
for _, entry in ipairs(BF.CFG_OVERRIDABLE_SECTIONS) do
    BF.CFG_SECTION_TO_FLAG[entry.section] = entry.flag
end

-- v60: per-CFG override flags for the two aura per-Layout groups. The auras
-- section has one flag PER GROUP rather than one for the section, because the
-- groups' per-Layout toggles are independent: with both toggles OFF, a Custom
-- Frame Group must be able to keep its own Buffs settings while still using the
-- global Debuffs settings (or vice versa), which a single flag cannot express.
--
-- Consulted by ResolveCFGAurasSubcat (Auras/AuraConfig.lua) via
-- BF.AURAS_SUBCAT_GROUP[subcat], and written by the override toggle on each of
-- the two CFG aura pages (Options_CustomFrameAuras.lua).
BF.AURAS_GROUP_CFG_FLAG = {
    aurasBuffs   = "overrideAurasBuffs",
    aurasDebuffs = "overrideAurasDebuffs",
}

-- ============================================================
-- BF:RehydrateCFGFlats()
--
-- Analogous to RehydrateFlats but for Custom Frame Group flats.
-- Each CFG stores its own fully independent flat at group.flat
-- (in cfgDB), using the same structure as raid flats in
-- rpDB.profile.layouts.flatLayouts.
--
-- Called after DB load, after CFG profile change, and after profile
-- import/copy/reset. Responsibilities:
--   1. For each group, ensure group.flat exists with invariants
--      (name, type, anchorX, anchorY).
--   2. Wire each flat with WireFlatDefaults (metatable -> CreateRaidProfile).
--   3. Wire section fallbacks pointing at rpDB.profile globals.
--   4. Wire aura sub-category fallbacks so sparse sub-category
--      tables fall through to rpDB.profile.auras.<subcat>.
-- ============================================================
function BF:RehydrateCFGFlats()
    if not self.cfgDB then return end
    -- dbVersion 65 (§6.3/§7.5 pt 3): seed the per-CFG override flags for any
    -- cfgDB profile that has not been through the v65 seed yet. The dispatcher
    -- block runs this too, but it cannot reach an IMPORTED profile: dbVersion
    -- lives on the main db.profile and is not imported, and the AceDB profile
    -- callbacks fire before the imported data lands. RehydrateCFGFlats is one
    -- of the few things that runs AFTER an import, so it is where the hole
    -- closes. The migration's own per-profile sentinel makes this a no-op for
    -- every profile the dispatcher already handled.
    if self.MigrateSeedCFGOverrideFlags then
        self:MigrateSeedCFGOverrideFlags()
    end
    local cfgp = self.cfgDB.profile
    if not cfgp or not cfgp.customFrameGroups then return end

    local sections = self._perLayoutSections

    for _, group in pairs(cfgp.customFrameGroups) do
        if type(group) == "table" then
            -- Ensure flat exists with invariants
            if not group.flat then
                group.flat = {
                    name    = group.name or "Custom",
                    type    = "raid",
                    anchorX = -260,
                    anchorY = -200,
                }
            end
            local flat = group.flat
            if flat.type == nil then flat.type = "raid" end
            if flat.name == nil then flat.name = group.name or "Custom" end
            if flat.anchorX == nil then flat.anchorX = -260 end
            if flat.anchorY == nil then flat.anchorY = -200 end
            if flat.raidLayoutAnchor == nil then flat.raidLayoutAnchor = "TOPLEFT" end

            -- Ensure sorting and auras sub-tables exist before wiring
            -- so fallback metatables have something to attach to.
            if not rawget(flat, "sorting") then
                flat.sorting = {}
            end
            if not rawget(flat, "auras") then
                flat.auras = {}
            end
            -- Cast bars are NEVER enabled for a Custom Frame Group (owner
            -- rule 2026-08-13; the CFG Cast Bars options tab was removed, so
            -- there is no legitimate way for a user to have turned it on).
            -- This is the single chokepoint every CFG passes through after
            -- load / profile change / import / copy / reset, so forcing the
            -- rawkey OFF here defends against ALL of those paths at once:
            --   * legacy CFGs with no castBar rawkey would otherwise inherit
            --     a global enabled=true through the section fallback
            --     (per-layout ON = CFGs always use their own data);
            --   * a base-layout deep-copy or profile import could carry a
            --     stale enabled=true rawkey in.
            -- Unconditional (not materialize-if-missing): a truthy rawkey can
            -- now only be stale data, so it is stamped back to false rather
            -- than preserved. The other castBar keys (style, colors, etc.)
            -- are left untouched — only `enabled` gates the feature.
            do
                local cb = rawget(flat, "castBar")
                if type(cb) ~= "table" then
                    cb = {}
                    flat.castBar = cb
                end
                cb.enabled = false
            end

            -- 2026-09-13: per-subtab override flags (group.overrides, keyed
            -- by the generated <section>_<subtab> toggle keys; only `false`
            -- is stored). A key whose subtab no longer exists -- a retired
            -- id, or a section that stopped splitting -- is dropped here,
            -- the way NormalizeSectionPerLayoutKeys retires the Raid/Party
            -- ones, and an emptied table goes away so the record stays
            -- sparse. See BF:GetCFGSectionProfile.
            local ov = group.overrides
            if type(ov) == "table" then
                for key in pairs(ov) do
                    local sec = BF.TOGGLE_STORAGE_SECTION and BF.TOGGLE_STORAGE_SECTION[key]
                    if not (sec and BF.SECTION_SUBTAB_TOGGLE and BF.SECTION_SUBTAB_TOGGLE[sec]
                            and BF.CFG_SECTION_TO_FLAG[sec]) then
                        ov[key] = nil
                    end
                end
                if next(ov) == nil then group.overrides = nil end
            elseif ov ~= nil then
                group.overrides = nil
            end

            -- Wire directly to CreateRaidProfile template and rpDB globals.
            -- CFG flats are fully independent deep-copies; no base layout
            -- metatable chain needed.
            self:WireFlatDefaults(flat)
            if sections then
                for i = 1, #sections do
                    self:WireSectionFallback(flat, sections[i])
                end
            end
            if type(rawget(flat, "auras")) == "table" then
                self:WireAurasSubCategoryFallbacks(flat.auras)
            end
        end
    end
end
