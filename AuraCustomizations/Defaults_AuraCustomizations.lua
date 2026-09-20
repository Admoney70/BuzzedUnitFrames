-- ============================================================
-- BuzzardFrames: Auras/Defaults_AuraCustomizations.lua
-- Default values for the Aura Customizations module.
--
-- Grid2 pattern: RegisterNamespace creates a child database
-- stored in BuzzardFramesDB.namespaces.AuraCustomizations.
-- The namespace automatically follows profile switches, copies,
-- and resets. Access via BF.acDB.profile.
--
-- Must be loaded before Core.lua (see .toc).
-- ============================================================
local BF = _G["BuzzardFrames"]

BF.auraCustomizationDefaults = {
    profile = {
        -- ── Spell assignment (per-spec, per-spell) ────────────────────────
        -- Created dynamically: spellAssign[specID][spellID] = "assignment"
        -- No default needed; AceDB returns nil for unset keys.

        -- ── Custom buff containers ────────────────────────────────────────
        customBuffContainers = {},

        -- ── Custom debuff containers (separate, preset-only, HARMFUL) ──────
        customDebuffContainers = {},
        -- v92 EFFECTS group (per debuff container, flat fields on the container
        -- entry; nil-based sparse storage like every other container field, and
        -- per-Layout overridable through groupSettings[<layout>] exactly like
        -- borderStyle et al). Resolved ONLY through BF:ResolveContainerIconEffect
        -- / BF:ResolveContainerFrameEffect in AuraCustomizations.lua -- nothing
        -- reads these fields directly.
        --
        -- Icon Effect (per-container mirror of the per-spell specSpellIconEffect
        -- model below; the resolver returns the SAME shape
        -- BF.ApplyIconEffectToSpec consumes):
        --   containerIconEffect          = "none"|"glow"|"ants"|"flash"
        --                                  (nil == none -> resolver returns nil)
        --   containerIconEffectGlowStyle = "steady"|"pulse"  -- glow only;
        --                                  nil == steady
        --   containerIconEffectColor     = {r,g,b,a}  -- nil == {1, 0.82, 0.25, 1}
        --   containerIconEffectPandemic  = bool
        --   containerIconEffectPandemicColor = {r,g,b,a}
        --                                  -- nil == {0.239216, 1, 0.254902, 0.15}
        --   (desaturate / recolor are per-spell only and have no container twin.)
        --
        -- Frame Effect (whole-frame counterpart, one Effect Color):
        --   containerFrameEffect       = "none"|"healthColor"|"border"|"overlay"
        --                                (nil == none -> resolver returns nil)
        --   containerFrameEffectColor  = {r,g,b,a}  -- nil == {1, 0, 0, 0.5}, plain
        --                                red: a container has no dispel TYPE, so
        --                                there is no dispel color to inherit.
        --   containerFrameEffectBorderWidth   = number  -- nil == the dispel
        --                                section's debuffBorderWidth (default 2)
        --   containerFrameEffectOverlayHeight = 0..1    -- nil == the dispel
        --                                section's debuffOverlayHeight (default 0.7)
        --   containerFrameEffectOverlayFillOnly = bool  -- nil == false
        --                                (deliberately does NOT inherit the dispel
        --                                section's debuffOverlayFillOnly, which
        --                                ships true)

        -- ── Filter modes ──────────────────────────────────────────────────
        -- healerBuffFilter removed: it had no reader left.
        -- specBuffFilter removed 2026-08-15: v67 deleted its last reader when
        -- the Buffs preset system replaced per-spec Filter Modes. Its job is
        -- now done by the seeded Buffs preset overrides -- HEALER role and
        -- Augmentation Evoker both default to the "none" preset, which makes
        -- the Whitelist the source of truth for those specs. See
        -- EnsureBuffsPresetsSeeded in AuraCustomizations.lua.
        -- nonHealerBuffFilter removed 2026-08-15 (v79): its last reader was the
        -- unreachable fallback in EnsureFetchBuffSettings, deleted along with
        -- _fbsFilterMode / _fbsAuraFilter / cfg.filter / cfg.filterMode. The
        -- Buffs preset list is the only filter source now -- see
        -- Docs/Buffs_Row_Architecture.md §5. The two Core_Migrations.lua entries
        -- that nil it out of old profiles STAY: they clean saved data, they are
        -- not readers.
        debuffFilter        = "HARMFUL",

        -- ── Show/hide toggles ─────────────────────────────────────────────
        showSatedDebuffs     = false,
        showDeserterDebuffs  = true,
        showSkyridingDebuffs = true,
        showArcaneEmpowermentDebuffs = false,
        showTimeTrialDebuffs         = false,
        showRaidBuffs        = false,

        -- ── Missing raid buff icons (MIGRATED to rpDB.profile.icons) ─────
        -- These keys were moved from acDB to rpDB in dbVersion 15.
        -- MigrateRaidPartyFramesProfile handles the data migration.

        -- ── Per-raid tier separation ──────────────────────────────────────
        -- separateRaidAuraCustomizations: created dynamically (default nil = false)

        -- v60: the Private Aura override defaults were removed with the
        -- Private Aura Customizations feature (enablePrivateAuraCustomizations,
        -- enableGlobalPAOverrides, globalPASettings, encounterPASettings,
        -- dungeonPASettings). Saved values are nilled by
        -- _AuraMig_RemoveDeadFeatures.

        -- ── Per-spec spell customization tables ───────────────────────────
        -- All created dynamically (default nil):
        -- spellAssign, specSpellColors, specSpellBorders, specSpellBorderColors,
        -- specSpellOverlays, specSpellSolidIcons, specSpellOrdering,
        -- specBuffsBorder, specBuffsBorderColor, specBuffsOverlay, specBuffsSolidIcon,
        -- specSpellIconEffect (v84, Stage 5 §9.9 — Icon Effects per-spell
        --   config, ONE row per (spec-or-single-buff key, spell):
        --   { effect="none"|"glow"|"ants"|"flash",
        --     glowStyle="steady"|"pulse",   -- glow only; nil == steady
        --     color={r,g,b,a},              -- Effect Color
        --     pandemic=bool, pandemicColor={r,g,b,a},
        --     desaturate=bool,
        --     recolor=bool, recolorColor={r,g,b,a} }
        --   Defaults: effect none, color {1, 0.82, 0.25, 1}, pandemic color
        --   {0.239216, 1, 0.254902, 0.15}, recolor tint {1, 1, 1, 0.5}.)
        -- specSpellExpirationGlow (RETIRED v84 — the threshold-driven "Glow
        --   Border"; 12.1 keeps remaining duration secret, so its threshold
        --   could never be evaluated. Nilled by the dbVersion-67 migration.)
        -- specSpellVisualAlert (RETIRED v84 — the native 0-10 Marching Ants /
        --   Flash list, superseded by the tintable addon-side Icon Effect.
        --   Nilled by the dbVersion-67 migration.)
        -- specSpellBounce (Icon Effects → Bounce per-spell config:
        --   { enabled?, threshold=<secs>, showMode="always"|"threshold" })
        -- specSpellCustomized (v43 master customize flag:
        --   [specID][spellID] = true. Gates EVERY per-spell customization
        --   read; seeded once per profile from pre-existing entries by
        --   EnsureSpellCustomizedSeeded, guarded by spellCustomizedSeeded.)

        -- v60: the Private Aura Frame Border defaults were removed with the
        -- Private Aura Customizations feature's Frame Border subtab
        -- (privateAuraBorderAutoScale / privateAuraBorderWidthRatio /
        -- privateAuraBorderFrameLevel and their Raid/Party variants, plus
        -- privateAuraFrameBorderScaleRaid / ...Party). Saved values are
        -- nilled by _AuraMig_RemoveDeadFeatures.
    },
}
