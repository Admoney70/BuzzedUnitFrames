-- ============================================================
-- BuzzardFrames: Defaults_RaidPartyFrames.lua
-- Default values for the Raid/Party Frames module.
--
-- Grid2 pattern: RegisterNamespace creates a child database
-- stored in BuzzardFramesDB.namespaces.RaidPartyFrames.
-- The namespace automatically follows profile switches, copies,
-- and resets. Access via BF.rpDB.profile.
--
-- Sub-tables map 1:1 to Options panel tabs under Raid/Party Frames.
-- Per-layout-per-tier keys (frame dimensions, aura positions, etc.)
-- live inside layouts[id][tier] -- NOT in these sub-tables.
--
-- Must be loaded before Core.lua (see .toc).
-- ============================================================
local BF = _G["BuzzardFrames"]

BF.raidPartyFrameDefaults = {
    profile = {

        -- ================================================================
        -- layouts -- Options_Layouts.lua
        -- The layouts table itself (containing per-layout per-tier data)
        -- plus all layout system / architectural settings.
        -- ================================================================
        layouts = {
            -- (Phase L: the pre-flat named-layout tree -- layouts.layouts
            -- with its per-tier party/raid40/30/20 profiles -- and
            -- activeLayout are GONE. Flats (flatLayouts below) are the only
            -- layout storage. Do not reintroduce: AceDB materialised the
            -- whole default tree into every profile on every login, which
            -- was the single biggest block of dead weight in exports.)

            -- ── Flat layouts ──────────────────────────────────────
            -- IMPORTANT: do NOT populate this here. AceDB's logout
            -- default-stripping compares saved flats key-by-key against
            -- the default, removing every rawkey that matches -- which
            -- produced the v22 "missing showGroup / frameHeight = 0"
            -- bug. Instead, flats are seeded and wired at runtime by
            -- BF:RehydrateFlats (Core_FlatDefaults.lua), which runs at
            -- the end of RegisterDB and on every profile change/copy/
            -- reset. Flats use a metatable __index fallback to a
            -- fresh CreateRaidProfile / CreatePartyProfile template,
            -- so unmodified keys fall through instead of being stored
            -- default-equal and stripped.
            flatLayouts = {},

            -- Assignment of each instance type to a flat layout ID.
            -- Value is either a flatLayouts key, or the literal string
            -- "none" (only valid for solo -- means frames are hidden).
            instanceLayoutAssignment = {
                solo           = "flat_party",
                openWorldParty = "flat_party",
                dungeon        = "flat_party",
                delve          = "flat_party",
                raidOpen       = "flat_raid40",
                raid20         = "flat_raid40",
                raid25         = "flat_raid40",
                raid30         = "flat_raid40",
                raid40         = "flat_raid40",
                arena          = "flat_party",
                bg15           = "flat_raid40",
                bg40           = "flat_raid40",
            },

            -- ── Per-role / per-spec slot overrides (Phase 2 of
            -- "Layouts by Instance Type") ──
            -- Sparse maps: role or specID -> { [slotKey] = flatID }.
            -- Any slot absent here falls through to
            -- instanceLayoutAssignment[slot] (the global). Presence in
            -- these tables is the sole enable gate. Spec takes
            -- precedence over role. See BF:ResolveActiveFlat.
            roleOverrides = {
                HEALER  = {},
                TANK    = {},
                DAMAGER = {},
            },
            specOverrides = {},       -- specID (string) -> { slotKey = flatID }

            -- (Phase L: the pre-flat role/spec named-layout keys
            -- (enableRoleLayouts, enableSpecLayouts, specLayouts,
            -- specLayoutAssignment, roleLayoutAssignment) and the tier
            -- toggles (separateRaidBySize, enableRaid20/30/40) are GONE.
            -- Role/spec switching is roleOverrides/specOverrides above;
            -- tier resolution is GetCapacityTier + the instance slots.)
            scaleRaidToFit     = false,
            scaleRaidToFitMaxWidth = 80,

            -- Open world
            showLayoutAnnounce = true,

            -- Per-section "Separate configuration per Layout" toggles.
            -- Keyed by section key (e.g. "icons", "sorting"). When true, each
            -- flat stores its own copy of that section's keys under
            -- flat[section]; when false/absent, the global pseudo-layout at
            -- rpDB.profile[section] is shared by all flats.
            --
            -- The auras section is the exception: v65 gave each of its four
            -- subtabs its own toggle (auras_buffs, auras_bigDef, auras_debuffs,
            -- auras_dispelIndicator -- BF.AURAS_SUBCAT_TOGGLE), and the DATA for
            -- all four still lives in the one shared "auras" table, so those
            -- keys name a toggle rather than a storage section. There is no
            -- perLayoutToggles.auras key any more; BF:NormalizeAuraPerLayoutKeys
            -- translates the retired auras / aurasBuffs / aurasDebuffs keys at
            -- load.
            perLayoutToggles = {},

        },

        -- ================================================================
        -- sorting -- Options_Frames_Sorting.lua
        -- Global pseudo-layout for the Frames - Sorting section.
        -- When layouts.perLayoutToggles.sorting is true, each flat stores
        -- its own flat.sorting sub-table; otherwise these globals are used.
        -- ================================================================
        sorting = {
            -- Party Layout
            hideSelf            = false,
            growDirection       = "RIGHT",
            -- Party: pin the layout box by its CENTER instead of the
            -- grow-direction corner (Grid2 "Layout Anchor = Center").
            growFromCenter      = false,
            groupOrderingMode   = "TANK_HEALER_DPS",

            -- Raid Layout (architectural -- some require reload)
            sortingMode                 = "GROUP",
            strictGroupLayout           = true,
            strictGroupSortBy           = nil,       -- nil = INDEX
            unitsPerColumn              = 5,
            raidGrowDirection           = "DOWN",
            -- Raid: pin the layout box by its CENTER instead of the
            -- grow-direction corner (Grid2 "Layout Anchor = Center").
            raidGrowFromCenter          = false,
            raidSecondaryGrowDirection  = nil,       -- nil = default perpendicular
        },

        -- ================================================================
        -- auras -- Options_Auras.lua
        -- Aura display keys for the four live sub-categories: buffs, bigDef
        -- (Buffs nav section) and debuffs, dispelIndicator (Debuffs nav
        -- section). important went in v64, privateAuras in v67, crowdControl
        -- in v69.
        --
        -- This is the global pseudo-layout for the auras section. v60 split the
        -- per-Layout toggle in two; v65 split it again, one toggle per
        -- SUB-CATEGORY (layouts.perLayoutToggles.auras_<subcat> --
        -- BF.AURAS_SUBCAT_TOGGLE). When a sub-category's toggle is true, each
        -- flat stores its own flat.auras.<subcat>; otherwise these globals are
        -- shared by all flats. Reads route per sub-category via
        -- BF:GetAurasSubcatProfile.
        --
        -- Default values seeded from CreateRaidProfile (raid40). The party
        -- and raid profiles share identical aura defaults aside from sizes;
        -- the raid40 values are canonical here and the global pseudo-layout
        -- serves both contexts via the section fallback metatable.
        --
        -- NOT included here (other sections own these):
        --   • auraText keys (showBuffDuration, *TimerScale, reverse*Swipe,
        --     disable*Swipe/Spark, etc.) — live in rpDB.profile.auraText.
        --   • suppressPrivateAuraTooltip — lives in rpDB.profile.tooltips.
        --   • customBuffContainers — AuraCustomizations territory, stays
        --     on the flat root and is not relocated.
        -- ================================================================
        auras = {
            -- ── Buffs ─────────────────────────────────────────────────────
            buffs = {
                showBuffs          = true,
                buffSize           = 12,
                buffsPerRow        = 3,
                maxBuffs           = 6,
                buffGrowDirection  = "LEFT_UP",     -- v34 two-axis; BOTTOMRIGHT anchor default
                buffAnchorPoint    = "BOTTOMRIGHT",
                buffOffsetX        = 0,
                buffOffsetY        = 0,
                buffSpacing        = 1,
                buffRowSpacing     = 0,
                buffBorderColor     = { r = 0, g = 0, b = 0, a = 0.8 },
                buffBorderThickness = 2,
                -- v67: the *BorderStyle keys are now seeded. "flat" is the
                -- literal for the Square option (BORDER_STYLE_VALUES in
                -- Options_Auras.lua maps flat -> "Square"); do NOT write
                -- "square" here, that value has no entry in the dropdown.
                -- The legacy *BlizzardBorders flag stays as the companion
                -- the setter keeps in sync, and AuraBorderStyle still ORs
                -- it so an existing Blizzard-border profile is unaffected.
                buffBorderStyle     = "flat",
                buffBlizzardBorders = false,
            },

            -- ── Debuffs ───────────────────────────────────────────────────
            debuffs = {
                showDebuffs         = true,
                debuffSize          = 12,
                debuffsPerRow       = 3,
                maxDebuffs          = 3,
                debuffGrowDirection = "RIGHT_UP", -- v34 two-axis; fill right, wrap up (owner default — debuffs anchor bottom-left)
                -- v65: BOTTOMLEFT, matching party. Note the grow direction
                -- above needs no engine split: it was already RIGHT_UP, which
                -- is BOTTOMLEFT's default pairing, and its own comment already
                -- described the anchor as bottom-left.
                -- v67: 12.0.7 branch removed (addon is 12.1-only).
                debuffAnchorPoint   = "BOTTOMLEFT",
                debuffOffsetX       = 0,
                debuffOffsetY       = 0,
                debuffSpacing       = 1,
                debuffRowSpacing    = 0,
                -- ── v84 (Stage 5 §9.6 + §9.10): the debuff TYPE model ──────
                -- Replaces debuffShowMode + the four enlarge*Debuffs toggles.
                -- Base Filter governs only the residual "other debuffs" flow;
                -- the five type groups are independent of it.
                -- v93: new profiles default to excluding debuffs the player
                -- or the player's pet applied. Existing saved profiles keep
                -- whatever they already store -- there is no migration, on
                -- purpose: silently changing what someone already sees is
                -- worse than letting them opt in.
                debuffBaseFilter    = "noplayer",
                debuffShowOther     = true,
                debuffSortOrder     = "recentLast",
                -- ── v95 SIMPLE MODE (owner-approved plan 2026-08-25) ───────
                -- The per-Layout toggle that swaps the seven-category model
                -- for the default raid frames' one: ONE Debuffs group in the
                -- engine's own priority order, Dispellable by Me beside it,
                -- Boss/Role optionally split out. Ships OFF -- normal mode is
                -- unchanged for every existing and new profile -- and its
                -- combine box ships ON (Boss/Role inside the Debuffs group,
                -- which is what the default frames do). No migration: every
                -- other key the mode uses (ranks, sizes, caps) already exists
                -- and is shared with normal mode, which is what keeps the
                -- ordering coherent across a mode flip.
                debuffSimpleMode        = false,
                debuffSimpleSeparateBoss = false,
                -- 2026-08-25 (owner request): Simple Mode's own copy of the
                -- "noplayer" Base Filter rule. Ships OFF, so Simple Mode is
                -- byte-for-byte what it was for every existing profile.
                debuffSimpleExcludeFriendly = false,
                -- ── v91 (owner ruling 2026-08-17): the PRIORITY LIST ────────
                -- SEVEN rows with UNIQUE ranks 1..7 -- Boss 1, Role 2, CC 3,
                -- Dispellable by Me 4, Dispellable by Others 5, Priority 6,
                -- Other 7 -- plus three Combine checkboxes in the mockup's
                -- state (Boss+Role ✓, Dispel ✗, Priority+Other ✓). Uniqueness
                -- is an INVARIANT: the list arrows SWAP ranks, the migration
                -- assigns 1..7, and these defaults are 1..7. A tie would make
                -- the negation chain non-total.
                --
                -- Sizes carry over from the v84 defaults: 140% for Boss / Role
                -- / Crowd Control / Priority, 100% for both dispel rows. All
                -- rows ON out of the box.
                debuffTypeBoss         = true,
                debuffSizeBoss         = 1.4,
                debuffRankBoss         = 1,
                debuffMaxBoss          = 3,
                debuffTypeRole         = true,
                debuffSizeRole         = 1.4,
                debuffRankRole         = 2,
                debuffMaxRole          = 3,
                debuffTypeCC           = true,
                debuffSizeCC           = 1.4,
                debuffRankCC           = 3,
                debuffMaxCC            = 3,
                debuffTypeDispMe       = true,
                debuffSizeDispMe       = 1.0,
                debuffRankDispMe       = 4,
                debuffMaxDispMe        = 3,
                debuffTypeDispOthers   = true,
                debuffSizeDispOthers   = 1.0,
                debuffRankDispOthers   = 5,
                debuffMaxDispOthers    = 3,
                debuffTypePriority     = true,
                debuffSizePriority     = 1.4,
                debuffRankPriority     = 6,
                debuffMaxPriority      = 3,
                debuffRankOther        = 7,
                -- 2026-08-25: Simple Mode's OWN ranks -- the two modes do not
                -- share a priority list (BF:DebuffRankOf). Same canonical
                -- 1..7; dbVersion 78 seeds an EXISTING profile's from its
                -- normal ranks so no one's Simple Mode order moves on upgrade.
                debuffSimpleRankBoss       = 1,
                debuffSimpleRankRole       = 2,
                debuffSimpleRankCC         = 3,
                debuffSimpleRankDispMe     = 4,
                debuffSimpleRankDispOthers = 5,
                debuffSimpleRankPriority   = 6,
                debuffSimpleRankOther      = 7,
                -- v93: per-type icon caps, all 3 out of the box.
                debuffMaxOther         = 3,
                debuffCombineBossRole      = true,
                debuffCombineDispel        = false,
                debuffCombinePriorityOther = true,
                -- BF:MyDispelTypes governors on the "Dispellable by Me" row.
                debuffDispMeTalented   = true,
                debuffDispMeLongCd     = false,
                debuffBorderColor     = { r = 0, g = 0, b = 0, a = 0.8 },
                debuffDispelBorderThickness = 2,
                debuffColorBorderByDispel   = true,
                showDebuffDispelTypeIcon    = false,
                debuffDispelTypeIconScale   = 40,
                debuffBorderThickness = 2,
                debuffBorderStyle     = "flat",   -- v67, see buffs above
                debuffBlizzardBorders = false,
            },

            -- ── Private Auras ─────────────────────────────────────────────
            -- ── Big Defensive ─────────────────────────────────────────────
            bigDef = {
                showBigDef          = true,
                bigDefSize          = 18,
                bigDefAnchor        = "CENTER",
                bigDefOffsetX       = 0,
                bigDefOffsetY       = 0,
                bigDefMaxCount      = 1,
                bigDefGrowDirection = "RIGHT_DOWN", -- v34 two-axis; CENTER anchor default
                bigDefIconsPerRow   = 5,
                bigDefSpacing       = 1,
                bigDefRowSpacing    = 1,
                bigDefShowGlow      = false,
                -- Glow Color / Glow Style (owner): mirrors the Buff List Icon
                -- Effects glow. White keeps the IconAlert ring art's native
                -- gold, i.e. the pre-option appearance.
                bigDefGlowColor     = { r = 1, g = 1, b = 1, a = 1 },
                bigDefGlowStyle     = "steady",   -- "steady" | "pulse"
                bigDefBorderColor     = { r = 0, g = 0, b = 0, a = 0.8 },
                bigDefBorderThickness = 2,
                bigDefBorderStyle     = "flat",   -- v67, see buffs above
                bigDefBlizzardBorders = false,
            },

            -- v64: the `important` sub-table was removed with the Important
            -- feature (its keys are also gone from AURAS_SUBCATEGORIES and
            -- AURAS_SUBCATEGORY_OF in Core_ProfileAPI.lua).

            -- v69: the `crowdControl` sub-table was removed with the Crowd
            -- Control feature (it became a seeded custom debuff container).
            -- The default HAD to go in the same build as the load-time purge
            -- of auras.crowdControl: AceDB's copyDefaults physically rawsets
            -- declared defaults back into every profile, so purging a key that
            -- is still declared here is a no-op that silently reverts on the
            -- next login. The static CC_MIG_GEO_DEF table in Core_Migrations
            -- is now the sole default source for migration 62, which is what
            -- it was always documented to be.

            -- ── Dispel Indicator ──────────────────────────────────────────
            dispelIndicator = {
                showDispelIndicator          = true,
                dispelIndicatorSize          = 14,
                dispelIndicatorPosition      = "TOPRIGHT",
                dispelIndicatorOffsetX       = 0,
                dispelIndicatorOffsetY       = 0,
                dispelIndicatorStyle         = "icon",
                dispelIndicatorMaxIcons      = 1,
                dispelIndicatorMode          = "dispellable",
                dispelIndicatorOnlyIfReady   = false,
                -- 2026-08-25 (owner request): the dispel visuals resolve
                -- "dispellable by me" through their OWN governors now. Same
                -- shipped answers as the debuff-icon pair on the Debuff
                -- Preset/Filter subtab (talented ON, long-cd OFF), so a fresh
                -- profile behaves exactly as before the split.
                dispelVisualDispMeTalented   = true,
                dispelVisualDispMeLongCd     = false,

                -- ── v35: migrated from borders ─────────────────────────
                -- Debuff border
                enableDebuffBorder   = true,
                debuffBorderMode     = "dispellable",
                debuffBorderWidth    = 2,

                -- Debuff overlay
                enableDebuffOverlay   = true,
                debuffOverlayAlpha    = 0.8,
                debuffOverlayHeight   = 0.7,
                debuffOverlayMode     = "dispellable",
                debuffOverlayFillOnly = true,
                -- debuffOverlayStyle removed in v35 follow-up (was custom|blizzard).
                -- The Blizzard path is now driven by the unified
                -- dispelIndicatorOverlayMode dropdown further down, which also
                -- hides the Debuff Color Overlay section entirely when on.

                -- Dispel cooldown gating for border/overlay
                dispelBorderOnlyIfReady  = false,
                dispelOverlayOnlyIfReady = false,

                -- Debuff Health Color Change (owner): dispellable-debuff-
                -- triggered health bar tint, same render as the per-spell buff
                -- Change Health Color effect (dispelHealthColor kind of the
                -- merged dispel-visual slot). OFF by default. The color is
                -- the dispel TYPE's (engine-applied); the user sets only the
                -- opacity.
                enableDebuffHealthColor      = false,
                debuffHealthColorMode        = "dispellable",
                debuffHealthColorAlpha       = 0.7,
                dispelHealthColorOnlyIfReady = false,

                -- Blizzard-style dispel overlay mode. Renamed from
                -- privateAuraDispelOverlayMode in v35 because under the new
                -- UI this drives the Blizzard debuff overlay shown in the
                -- Dispel Indicator tab, not a private-aura-specific setting.
                -- Integer value passed to the Blizzard container as
                -- dispel-indicator-option: 1 = Dispellable By Me, 2 = All
                -- Dispellable.
                blizzardDispelOverlayMode = 2,
                -- v34 (12.1 Blizzard_PrivateAurasUI overlay contract):
                blizzardDispelOverlayColorMode = "debuffColor",  -- "debuffColor" | "black"
                blizzardDispelOverlayFlash     = false,
                blizzardDispelShowIcons        = true,
                blizzardDispelOrgType          = "topRight",  -- "topRight" | "bottomLeft" | "topLeft" (aura-organization-type)
                blizzardDispelShowOverlay      = true,

                -- v36: Master toggle for the Blizzard-native dispel indicator
                -- icons + overlay (rendered by Blizzard's isContainer=true
                -- private-aura anchor in PrivateAuras.lua SetupDispelOverlay).
                -- Replaced the v35-era boolean showBlizzardDispelIndicator with
                -- a two-option select so future expansion (e.g. a third mode)
                -- stays open. Values:
                --   "blizzard" - Blizzard's container renders dispel type icons
                --                (up to dispelIndicatorMaxIcons) AND the gradient
                --                dispel overlay. The addon's own DispelIndicator
                --                and DebuffHighlight widgets are forced off via
                --                the AuraCache hoist in AuraConfig.lua.
                --   "custom"   - Neither Blizzard's icons nor its overlay are
                --                drawn; attribute writes are skipped. The addon's
                --                own DispelIndicator / DebuffHighlight widgets
                --                remain the out-of-the-box visual. Default.
                dispelIndicatorOverlayMode = "custom",
                blizzardDispelOverlayOpacity = 1,
                -- v67: blizzardDispelPrivateOnly and
                -- showBlizzardPrivateAuraDispel removed. Both were dead --
                -- no widget emitted either (the showBlizzardPrivateAuraDispel
                -- toggle was deleted, see Options_Auras.lua) and nothing read
                -- them at runtime, but they were still being serialized into
                -- every captured theme snapshot. Their AURAS_SUBCATEGORY_OF
                -- entries are gone too, so nothing may reintroduce a widget
                -- under either name.
            },

            -- v60: the blizzardDebuffs sub-table (experimental Blizzard-native
            -- debuff container) was removed along with PrivateAuraDebuffs.lua.
            -- Saved values are nilled by _AuraMig_RemoveDeadFeatures.

            -- Swap toggles (pvpSwapDebuffsPrivateBattleground and
            -- pvpSwapDebuffsPrivateParty) were relocated into the
            -- privateAuras sub-category above. See Docs/PHASE_3_PLAN.md
            -- §17.10 and §17.11 for the rationale and runtime rules.
        },

        -- v60: privateAuraBorderScale removed. The "Icon Border Scale" widget
        -- it backed (Raid/Party Frames → Private Auras) had no live consumer
        -- once the Private Aura Customizations module was killswitched off, and
        -- both are now deleted. Saved values are nilled by
        -- _AuraMig_RemoveDeadFeatures.

        -- ================================================================
        -- auraText -- Options_AuraText.lua
        --
        -- Nested sub-categories matching the Options UI subtabs (v30, mirrors
        -- the auras v27 structure). globalAuraTextConfig lives at the top
        -- level and gates which subtabs are visible in the UI: when true,
        -- the unified "Duration Text" subtab (reading auraText.global) is
        -- shown; when false, per-type subtabs (buffs/debuffs/bigDef) are
        -- shown -- important went in v64, privateAuras in v67 and
        -- crowdControl in v69. The stackText subtab is always visible.
        --
        -- When layouts.perLayoutToggles.auraText is true, each flat stores
        -- its own flat.auraText sub-table with the same nested shape, and
        -- reads route via GetSectionProfile("auraText", flat) + two-tier
        -- metatable fallback (flat.auraText -> global.auraText, and each
        -- flat.auraText.<subcat> -> global.auraText.<subcat>).
        -- ================================================================
        auraText = {
            -- Meta toggle: governs which subtabs are visible and which
            -- sub-category's keys are consumed at runtime. Lives at the
            -- top of auraText (NOT inside any sub-category) so it can be
            -- read independently of per-sub-category resolution.
            globalAuraTextConfig = true,

            -- ── Stack text (always-visible subtab) ─────────────────────────
            stackText = {
                showStackText   = true,
                stackAutoScale  = false,
                stackTimerScale = 1.0,
                stackTextFont   = "Interface\\AddOns\\BuzzardFrames\\Media\\Fonts\\RobotoCondensed-Bold.ttf",
                stackTextBorder = "OUTLINE",
                stackTextSize   = 9,
                stackTextAnchor = "BOTTOMRIGHT",
                stackTextX      = 4,
                stackTextY      = -3,
            },

            -- ── Global unified config (visible when globalAuraTextConfig ON) ─
            global = {
                globalDurationShow              = true,
                globalAutoScale                 = false,
                globalTimerScale                = 1.0,
                globalFontSize                  = 11,
                globalDurationFont              = "Interface\\AddOns\\BuzzardFrames\\Media\\Fonts\\RobotoCondensed-Bold.ttf",
                globalDurationBorder            = "OUTLINE",
                globalFontColor                 = { r = 1.0, g = 1.0, b = 1.0 },
                globalColorAuraBorder           = false,
                globalReverseSwipe              = true,
                globalDisableSwipe              = false,
                globalDisableSpark              = false,
                globalDebuffDurationDispelColor = false,
                globalHideDurationAbove1Min     = false,
                globalThresholdColorEnabled     = false,
                globalThresholdColorThreshold   = 8,
                globalThresholdColor            = { r = 1.0, g = 0.5, b = 0.0 },
                globalThreshold2ColorEnabled    = false,
                globalThreshold2ColorThreshold  = 4,
                globalThreshold2Color           = { r = 1.0, g = 0.0, b = 0.0 },
            },

            -- ── Buff duration text ────────────────────────────────────────
            buffs = {
                showBuffDuration             = true,
                buffAutoScale                = false,
                buffTimerScale               = 1.0,
                buffFontSize                 = 11,
                buffDurationFont             = "Interface\\AddOns\\BuzzardFrames\\Media\\Fonts\\RobotoCondensed-Bold.ttf",
                buffDurationBorder           = "OUTLINE",
                buffFontColor                = { r = 1.0, g = 1.0, b = 1.0 },
                buffColorAuraBorder          = false,
                reverseBuffSwipe             = false,
                disableBuffSwipe             = false,
                disableBuffSpark             = false,
                buffHideDurationAbove1Min    = false,
                buffThresholdColorEnabled    = false,
                buffThresholdColorThreshold  = 8,
                buffThresholdColor           = { r = 1.0, g = 0.5, b = 0.0 },
                buffThreshold2ColorEnabled   = false,
                buffThreshold2ColorThreshold = 4,
                buffThreshold2Color          = { r = 1.0, g = 0.0, b = 0.0 },
            },

            -- ── Debuff duration text ──────────────────────────────────────
            debuffs = {
                showDebuffDuration             = true,
                debuffAutoScale                = false,
                debuffTimerScale               = 1.0,
                debuffFontSize                 = 11,
                debuffDurationFont             = "Interface\\AddOns\\BuzzardFrames\\Media\\Fonts\\RobotoCondensed-Bold.ttf",
                debuffDurationBorder           = "OUTLINE",
                debuffFontColor                = { r = 1.0, g = 1.0, b = 1.0 },
                reverseDebuffSwipe             = false,
                disableDebuffSwipe             = false,
                disableDebuffSpark             = false,
                debuffDurationDispelColor      = false,
                debuffHideDurationAbove1Min    = false,
                debuffThresholdColorEnabled    = false,
                debuffThresholdColorThreshold  = 8,
                debuffThresholdColor           = { r = 1.0, g = 0.5, b = 0.0 },
                debuffThresholdBorderEnabled   = false,
                debuffThreshold2ColorEnabled   = false,
                debuffThreshold2ColorThreshold = 4,
                debuffThreshold2Color          = { r = 1.0, g = 0.0, b = 0.0 },
                debuffThreshold2BorderEnabled  = false,
            },

            -- ── Big Defensive duration text ───────────────────────────────
            bigDef = {
                showBigDefDuration             = false,
                bigDefAutoScale                = false,
                bigDefTimerScale               = 1.0,
                bigDefFontSize                 = 11,
                bigDefDurationFont             = "Interface\\AddOns\\BuzzardFrames\\Media\\Fonts\\RobotoCondensed-Bold.ttf",
                bigDefDurationBorder           = "OUTLINE",
                bigDefFontColor                = { r = 1.0, g = 1.0, b = 1.0 },
                bigDefColorAuraBorder          = false,
                reverseBigDefSwipe             = false,
                disableBigDefSwipe             = false,
                disableBigDefSpark             = false,
                bigDefHideDurationAbove1Min    = false,
                bigDefThresholdColorEnabled    = false,
                bigDefThresholdColorThreshold  = 8,
                bigDefThresholdColor           = { r = 1.0, g = 0.5, b = 0.0 },
                bigDefThreshold2ColorEnabled   = false,
                bigDefThreshold2ColorThreshold = 4,
                bigDefThreshold2Color          = { r = 1.0, g = 0.0, b = 0.0 },
            },

            -- v64: the `important` duration-text sub-table was removed with
            -- the Important feature.

            -- v69: the `crowdControl` duration-text sub-table was removed with
            -- the Crowd Control feature. Removed in the same build as the
            -- load-time purge of auraText.crowdControl -- see the note on the
            -- auras half above for why the default cannot outlive the purge.
            -- CC_MIG_DUR_DEF in Core_Migrations is migration 62's default
            -- source.

            -- ── Private Aura duration text ────────────────────────────────
        },

        -- ================================================================
        -- borders -- Options_Borders.lua
        -- Frame border, aggro, highlights, debuff border/overlay, dispel gating.
        -- ================================================================
        borders = {
            -- Frame border
            enableBorder    = true,
            -- "square" (flat 4-edge, thickness slider applies) |
            -- "rounded" | "rounded_thick" (nine-slice ring + content
            -- mask, fixed 2/3px art thickness).
            borderStyle     = "square",
            -- v69: opacity folded into the color's alpha (the separate
            -- borderOpacity key was removed). a=1 == the old default.
            borderColor     = { r = 0, g = 0, b = 0, a = 1 },
            borderThickness = 1,

            -- Aggro
            aggroEnabled    = true,
            aggroStyle      = "blizzard",
            aggroScale      = 0.8,
            aggroBorderWidth = 2,
            aggroColor1 = { r = 1.0, g = 0.94, b = 0.0 },  -- high threat, not tanking
            aggroColor2 = { r = 1.0, g = 0.5,  b = 0.0 },  -- has aggro, low threat
            aggroColor3 = { r = 1.0, g = 0.306, b = 0.0 },  -- has aggro, high threat (#FF4E00)
            aggroArrowDirection = "right",
            aggroArrowPosition  = "LEFT",
            aggroArrowOffsetX   = 0,
            aggroArrowOffsetY   = 0,
            aggroArrowSize      = 16,

            -- Mouseover highlight
            enableMouseoverHighlight  = false,
            mouseoverHighlightColor   = { r = 1.0, g = 1.0, b = 1.0 },
            mouseoverHighlightOpacity = 0.1,

            -- Target highlight
            enableTargetHighlight  = true,
            targetHighlightColor   = { r = 1.0, g = 1.0, b = 1.0 },
            targetHighlightOpacity = 1.0,
            targetHighlightWidth   = 2,

            -- Debuff border, overlay, dispel cooldown gating, and Blizzard
            -- dispel overlay mode have been migrated to the auras.dispelIndicator
            -- sub-category as of v35. See Defaults_RaidPartyFrames.lua's
            -- auras.dispelIndicator block for the current defaults. The
            -- following keys used to live here:
            --   enableDebuffBorder / debuffBorderMode / debuffBorderWidth
            --   enableDebuffOverlay / debuffOverlayStyle / debuffOverlayMode
            --   debuffOverlayAlpha / debuffOverlayHeight / debuffOverlayFillOnly
            --   dispelBorderOnlyIfReady / dispelOverlayOnlyIfReady
            --   privateAuraDispelOverlayMode (renamed blizzardDispelOverlayMode)

            -- Blizzard dispel overlay (12.0.5+ isContainer): these two stayed
            -- in borders because they are not exposed in the UI migration.
            -- enablePrivateAuraDispelOverlay and blizzardDispelOverlayDirection
            -- are dead defaults (never read at runtime) but kept here so the
            -- keys round-trip through SavedVariables cleanly.
            enablePrivateAuraDispelOverlay = true,
            blizzardDispelOverlayDirection = 0,
            -- privateAuraDispelOverlayShowIcons: removed, now driven by
            -- dispelIndicatorStyle == "icon" in the auras.dispelIndicator section.
        },

        -- ================================================================
        -- healthPower -- Options_HealthPower.lua
        -- Health bar colors/textures, power bar, range, aurasAbovePowerBar.
        -- ================================================================
        healthPower = {
            -- Health bar colors
            useCustomHealthColor    = false,
            healthColor             = { r = 0.24, g = 0.78, b = 0.24 },
            useHealthGradient       = false,

            -- Health bar texture
            useCustomHealthBarTexture = false,
            healthBarTexture          = "Blizzard Raid Bar",

            -- Background
            useCustomBackgroundColor = false,
            backgroundColor          = { r = 0.08, g = 0.08, b = 0.08 },
            backgroundAlpha          = 1.0,
            useBgGradient            = false,
            useBgClass               = false,
            bgClassDarken            = 0,

            -- Special health colors
            useCustomOfflineColor    = false,
            offlineBackgroundColor   = { r = 0.1, g = 0.1, b = 0.1 },
            offlineBackgroundOpacity = 0.7,
            fadeOfflineFrames        = true,
            useCustomDeadColor       = false,
            deadBackgroundColor      = { r = 0.1, g = 0.1, b = 0.1 },
            deadBackgroundOpacity    = 0.7,
            deadColorOORFactor       = 0.5,
            useCustomHostileColor    = true,
            hostileColor             = { r = 0.624, g = 0.027, b = 0.043 },
            performanceMode          = false,

            -- Power bar
            showPowerBar        = false,   -- legacy, kept for backward compat
            showAllPowerBars    = false,
            showPowerBarHealers = false,
            showPowerBarBloodDK = false,
            powerBarHeight      = 4,
            useCustomPowerBarTexture = false,
            powerBarTexture     = "Blizzard Raid Bar",
            useCustomPowerBarBgColor = false,
            powerBarBgColor     = { r = 0.08, g = 0.08, b = 0.08, a = 1.0 },
            powerBarBgOpacity   = 1.0,
            useCustomPowerColors = false,
            customPowerColors    = {},

            -- Range
            enableRangeFade      = true,
            rangeFadeAlpha       = 0.4,
            enableRangeDesaturate = false,
            rangeDesaturation    = 0.5,

            -- Auras above power bar
            aurasAbovePowerBar = false,
        },

        -- ================================================================
        -- absorbs -- Options_Absorbs.lua
        -- Heal prediction, absorb shields, overshield, heal absorb,
        -- reduced max health.
        -- ================================================================
        absorbs = {
            -- Heal prediction
            showHealPrediction           = true,
            healPredictionAnchor         = "RIGHT",
            healPredictionColor          = { r = 0, g = 0.7, b = 0, a = 0.6 },
            useCustomHealPredictionTexture = false,
            healPredictionTexture        = "Solid",

            -- Overshield
            showOvershield    = true,
            overshieldStyle   = "Overlay",
            overshieldAnchor  = "RIGHT",

            -- Heal absorb
            showHealAbsorb      = true,
            healAbsorbStyle     = "OverlayBlizzard",
            healAbsorbBarHeight = 12,
            healAbsorbColor     = { r = 1.0, g = 0.0, b = 0.0, a = 0.5 },
            -- v93: custom fill texture for the heal absorb visual. Applies to
            -- every healAbsorbStyle (Overlay / Bar and their Blizzard
            -- variants); replaces only the base fill, never the plus-symbol
            -- overlay or the right shadow.
            useCustomHealAbsorbTexture = false,
            healAbsorbTexture   = "Solid",
            -- v93: tint for the Blizzard plus-symbols overlay (the two
            -- "(Blizzard Style)" heal absorb variants). Opt-in: with the
            -- toggle off the renderers use the white-at-0.2 that used to be
            -- hard-coded at texture creation, so an untouched profile looks
            -- exactly as before.
            useCustomHealAbsorbSymbolColor = false,
            healAbsorbSymbolColor = { r = 1, g = 1, b = 1, a = 0.2 },

            -- Absorb colors
            absorbAnchorPos      = "RIGHT",
            absorbBaseColor      = { r = 0.941, g = 0.941, b = 0.937, a = 1.0 },
            absorbOverlayColor   = { r = 1.0, g = 1.0, b = 1.0, a = 0.66 },
            -- Absorb left shadow (Blizzard TotalAbsorbLeftShadow): the seam
            -- where the shield meets the health bar. Independent of the
            -- custom-texture toggle so it can ride any bar texture.
            showAbsorbShadow     = true,
            absorbShadowColor    = { r = 1.0, g = 1.0, b = 1.0, a = 1.0 },
            overshieldBaseColor  = { r = 0.937, g = 0.941, b = 0.855, a = 0.36 },
            overshieldOverlayColor = { r = 1.0, g = 1.0, b = 1.0, a = 0.66 },
            useCustomAbsorbColor         = false,
            useCustomAbsorbBarTexture    = false,
            absorbBarTexture             = "Solid",
            useCustomOvershieldColor     = false,
            useCustomOvershieldBarTexture = false,
            overshieldBarTexture         = "Solid",

            -- Reduced max health
            showReducedMaxHealth         = true,
            reducedMaxHealthColor        = { r = 0.3, g = 0.3, b = 0.3, a = 0.8 },
            useCustomReducedMaxTexture   = false,
            reducedMaxHealthTexture      = "Solid",
            showReducedMaxHealthText     = false,
            appendReducedMaxText         = false,
            appendReducedMaxTarget       = "health",
            reducedMaxHealthTextPosition = "BOTTOMRIGHT",
            reducedMaxHealthTextX        = -2,
            reducedMaxHealthTextY        = 2,
            reducedMaxHealthTextColor    = { r = 1, g = 0.8, b = 0.2 },
            reducedMaxHealthFont         = nil,
            reducedMaxHealthFontSize     = 9,
            reducedMaxHealthFontBorder   = "",
        },

        -- ================================================================
        -- castBar -- Options_CastBar.lua
        -- Per-unit cast bars on the party/raid frames.
        --
        -- 12.1 engine rules that constrain these keys:
        --  * Progress is engine-driven (StatusBar:SetTimerDuration with the
        --    opaque DurationObject). startTime/endTime are SECRET for any
        --    unit with secret identity, so there is no Lua-side progress
        --    math and no OnUpdate.
        --  * Interruptibility is deliberately NOT shown -- these frames
        --    only display friendly group members and their pets, whose
        --    casts nobody interrupts. No notInterruptible key here.
        --  * There is no API for the CURRENT empower stage, so pips are
        --    static decoration only.
        -- ================================================================
        castBar = {
            -- Master
            enabled              = false,   -- opt-in; costs nothing while off
            -- Context gates. Applied in BF:RebindCastBarStatus, so a
            -- disqualifying context means the UNIT_SPELLCAST_* events are
            -- never registered -- the gate costs exactly what enabled=false
            -- costs (zero) rather than filtering per cast.
            partyOnly            = true,    -- only in a party group (not a raid)
            pvpOnly              = false,   -- only in a PvP instance (arena / battleground)
            showPlayer           = true,
            showPets             = false,
            healersOnly          = false,   -- only show on frames whose unit is a healer

            -- Placement. The cast bar is always an overlay -- it never
            -- reserves layout space, so a cast costs zero layout work.
            -- TOP_INSIDE | TOP_OUTSIDE | CENTER | BOTTOM_INSIDE | BOTTOM_OUTSIDE
            -- ("inside" = over the health area; BOTTOM_INSIDE therefore sits
            -- above the power bar, since the content rect excludes it.)
            overlayAnchor        = "BOTTOM_INSIDE",
            overlayHeightPct     = 0.35,      -- fraction of the health area's height
            overlayYOffset       = 0,
            -- "belowAuras" (offset 223 -- above every text and icon frame,
            -- below every aura icon) | "aboveAuras" (offset 230).
            frameLevel           = "belowAuras",

            -- Bar
            useCustomTexture     = false,
            texture              = "Solid",
            color                = { r = 1.0,  g = 0.7,  b = 0.0,  a = 1.0 },
            useCustomBgColor     = false,
            bgColor              = { r = 0.08, g = 0.08, b = 0.08, a = 1.0 },
            bgOpacity            = 1.0,
            -- Bar opacity is now the alpha channel of `color` (a) -- the
            -- standalone opacity slider was removed in favour of the color
            -- picker's alpha. See CastBar:Layout.

            -- Border. "square" = four 1px edge textures; the two rounded
            -- styles use the shared nine-sliced ring + mask kit
            -- (BF:ApplyUFBarRoundBorder), where the band weight is baked
            -- into the art, so borderThickness does not apply to them.
            showBorder           = false,
            borderStyle          = "square",  -- square | rounded | rounded_thick
            borderColor          = { r = 0, g = 0, b = 0, a = 1 },
            borderThickness      = 1,         -- square style only

            -- Icon. The icon sits OUTSIDE the bar; the bar insets its own
            -- anchor on that side by (icon width + iconGap) so the pair
            -- together spans exactly the frame width.
            showIcon             = true,
            iconSide             = "LEFT",    -- LEFT | RIGHT
            iconSizePct          = 1.0,       -- of bar height
            iconGap              = 2,         -- px between icon and bar
            iconXOffset          = 0,
            iconYOffset          = 0,

            -- Text
            showSpellName        = true,
            showTimer            = true,
            nameAlign            = "LEFT",
            timerAlign           = "RIGHT",
            nameFont             = "PT Sans Narrow",
            nameFontSize         = 9,
            nameFontBorder       = "",
            timerFont            = "PT Sans Narrow",
            timerFontSize        = 9,
            timerFontBorder      = "",
            -- v70: split the single textColor into per-section pickers.
            -- Cast Name reads nameColor, Cast Time reads timerColor. Both
            -- seeded to the old textColor default so existing bars look
            -- unchanged. The legacy textColor key is no longer read.
            nameColor            = { r = 1, g = 1, b = 1, a = 1 },
            timerColor           = { r = 1, g = 1, b = 1, a = 1 },

            -- Empowered casts
            showEmpowerPips      = true,
            pipColor             = { r = 1, g = 1, b = 1, a = 0.8 },
            pipWidth             = 1,

            -- Behavior
            holdTime             = 0.5,       -- linger after fail/interrupt (s)
        },

        -- ================================================================
        -- icons -- Options_Icons.lua
        -- Role icons, status icons, raid target, leader/assistant,
        -- missing raid buff.
        -- ================================================================
        icons = {
            -- Role icons
            showRoleIcons      = true,
            showRoleIconTank   = true,
            showRoleIconHealer = true,
            showRoleIconDPS    = true,
            roleIconSize       = 14,
            roleIconStyle      = "MODERN",
            roleIconPosition   = { point = "TOPLEFT", x = 1, y = -1 },

            -- Status icons
            showReadyCheck       = true,
            showPhased           = true,
            showSummonPending    = true,
            showResurrectPending = true,
            resurrectPendingIconStyle = "buzzard",
            showVehicleIcon      = true,
            statusIconSize       = 24,
            statusIconPosition   = { point = "CENTER", x = 0, y = 0 },

            -- Raid target marker
            showRaidTargetIcon     = true,
            raidTargetIconSize     = 16,
            raidTargetIconPosition = { point = "CENTER", x = 0, y = 0 },

            -- Ping indicator (mirrored from the default UI's compact-frame
            -- ping receivers; see Indicators/PingIndicator.lua)
            showPingIndicator     = true,
            pingIndicatorSize     = 24,
            pingIndicatorPosition = { point = "CENTER", x = 0, y = 0 },

            -- Leader / assistant icons
            showLeaderIcon        = true,
            showAssistantIcon     = true,
            leaderIconSize        = 12,
            leaderIconPosition    = { point = "TOPRIGHT", x = -2, y = 3 },
            assistantIconSize     = 12,
            assistantIconPosition = { point = "TOPRIGHT", x = -2, y = 3 },

            -- Missing raid buff icons
            -- NOTE: These need to be moved back from acDB in the migration.
            showMissingRaidBuff        = false,
            showMissingRaidBuffInCombat = false,
            showMissingSymbiotic       = false,
            missingRaidBuffAnchor      = "CENTER",
            missingRaidBuffOffsetX     = 0,
            missingRaidBuffOffsetY     = 0,
            missingRaidBuffSize        = 12,
            missingRaidBuffShowGlow    = false,
        },

        -- ================================================================
        -- text -- Options_Text.lua
        -- Name, health, status, vehicle, group labels.
        -- ================================================================
        text = {
            -- ── Name text ─────────────────────────────────────────────────
            showName                   = true,
            nameFontSize               = 10,
            abbreviateNames            = false,
            scaleNameToFit             = true,
            maxNameChars               = 9,
            capitalizeNames            = false,
            adjustNameColors           = false,
            classColorNames            = false,
            transliterateCyrillicNames = false,
            nameColor                  = { r = 1, g = 1, b = 1 },
            adjustNameFont             = true,
            nameFont                   = "PT Sans Narrow",
            nameFontBorder             = "",
            namePosition               = { point = "TOPLEFT", x = 0, y = -2 },
            linkNameAndRole            = false,

            -- ── Health text ───────────────────────────────────────────────
            showHealthText       = false,
            healthTextFormat     = "percent",
            healthTextPctSymbol  = true,
            adjustHealthFont     = true,
            healthFont           = "PT Sans Narrow",
            healthFontBorder     = "",
            healthFontSize       = 10,
            healthTextPosition   = "CENTER",
            healthTextX          = 0,
            healthTextY          = 0,
            adjustHealthTextColor = false,
            classColorHealthText = false,
            healthTextColor      = { r = 0.5, g = 0.5, b = 0.5 },

            -- ── Level text ────────────────────────────────────────────────
            showLevelText           = false,
            hideLevelTextAtMaxLevel = true,
            levelTextPosition       = "TOPRIGHT",
            levelTextX              = -2,
            levelTextY              = -2,
            adjustLevelFont         = false,
            levelFont               = "PT Sans Narrow",
            levelFontBorder         = "",
            levelFontSize           = 10,
            adjustLevelTextColor    = false,
            classColorLevelText     = false,
            levelTextColor          = { r = 1, g = 0.82, b = 0 },

            -- ── Status text ───────────────────────────────────────────────
            adjustStatusFont         = true,
            appendStatusTextToNames  = false,
            capitalizeStatusText     = false,
            applyStatusColorsToNames = false,
            statusAppendSeparator    = "PAREN",
            statusBeforeName         = false,
            abbreviateStatusNames    = false,
            maxStatusNameChars       = 9,
            fadeOfflineNameText      = false,
            abbreviateOffline        = false,
            showDeadStatus           = true,
            showOfflineStatus        = true,
            statusTextPosition       = "CENTER",
            statusTextX              = 0,
            statusTextY              = 0,
            statusFont               = "PT Sans Narrow",
            statusFontBorder         = "",
            statusFontSize           = 10,
            showAFKStatus            = true,
            afkColorUseClassColor    = false,
            afkColor                 = { r = 0.8, g = 0.6, b = 0.0 },
            deadColor                = { r = 0.8, g = 0.1, b = 0.1 },
            deadColorUseClassColor   = false,
            offlineColor             = { r = 0.5, g = 0.5, b = 0.5 },
            offlineColorUseClassColor = false,
            -- Note: offlineBackgroundColor, offlineBackgroundOpacity,
            -- fadeOfflineFrames, deadBackgroundColor, deadBackgroundOpacity,
            -- and deadColorOORFactor live in the healthPower section (the
            -- widgets are rendered in the Health & Power tab, so they obey
            -- that section's per-layout toggle). See MigrateOfflineDeadColorsToHealthPower.

            -- ── Vehicle name text ─────────────────────────────────────────
            showVehicleName        = true,
            vehicleNamePosition    = { point = "CENTER", x = 0, y = 0 },
            adjustVehicleFont      = true,
            vehicleFont            = "PT Sans Narrow",
            vehicleFontBorder      = "",
            vehicleFontSize        = 10,
            abbreviateVehicleNames = true,
            maxVehicleNameChars    = 10,

            -- ── Group labels ──────────────────────────────────────────────
            showGroupLabels      = false,
            groupLabelFontSize   = 11,
            groupLabelYOffset    = 0,
            groupLabelColor      = { r = 1, g = 1, b = 1 },
            groupLabelNumberOnly = false,
            adjustGroupLabelFont = true,
            groupLabelFont       = "PT Sans Narrow",
            groupLabelFontBorder = "",
        },

        -- ================================================================
        -- tooltips -- Options_Tooltips.lua
        -- ================================================================
        tooltips = {
            showUnitTooltip              = true,
            showUnitTooltipInCombat      = false,
            unitTooltipPosition          = "default",
            showBuffTooltip              = true,
            showBuffTooltipInCombat      = false,
            buffTooltipPosition          = "default",
            showDebuffTooltip            = true,
            showDebuffTooltipInCombat    = true,
            debuffTooltipPosition        = "default",
            showBigDefTooltip            = false,
            showBigDefTooltipInCombat    = false,
            bigDefTooltipPosition        = "default",
            -- v69: the three Crowd Control tooltip keys were removed with the
            -- feature -- containers follow the Debuffs tooltip settings, which
            -- is why MigrateCrowdControlToContainer explicitly drops them.
            -- Removed here in the same build as the load-time purge, for the
            -- AceDB copyDefaults reason noted on auras.crowdControl above.
            -- Private aura tooltip. `true` = suppress (hide) the tooltip.
            -- Pre-v24 this lived on each flat's root (flat.suppressPrivateAuraTooltip);
            -- v24 moves it here so it sits alongside the other tooltip keys and
            -- follows the per-layout tooltips toggle via GetSectionProfile.
        },

        -- ================================================================
        -- colors -- Options_Colors.lua
        -- Top-level "Colors" nav section. Houses GLOBAL color settings that
        -- are shared across all Layouts and across the Raid/Party frames +
        -- the oUF Unit Frames (e.g. class colors drive both the raid/party
        -- health bars via BFStatus Health:GetColor and the oUF health bars
        -- via _GetOUFHealthColor). These are NOT per-layout by design.
        --
        -- useCustomClassColors: when true, BF.classColors is overlaid with
        -- customClassColors on top of the RAID_CLASS_COLORS baseline, and
        -- BFStatus Health:GetColor routes class-color reads through
        -- BF.classColors. When false, behavior is unchanged: BF.classColors
        -- is a straight copy of RAID_CLASS_COLORS, and Health:GetColor reads
        -- CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS live (so external
        -- class-color addons like phanxClassColors keep working).
        --
        -- customClassColors stays nil until the user sets something --
        -- same sparse-storage pattern as customPowerColors.
        -- ================================================================
        colors = {
            useCustomClassColors = false,
            -- customClassColors = { WARRIOR = {r,g,b}, ... }  -- nil default

            -- Health gradient colors (global -- shared across all layouts).
            -- The useHealthGradient / useBgGradient toggles remain per-layout
            -- in healthPower; only the color values live here.
            healthGradientHigh      = { r = 0.0, g = 0.8, b = 0.0 },
            healthGradientMid       = { r = 0.9, g = 0.6, b = 0.0 },
            healthGradientLow       = { r = 0.8, g = 0.0, b = 0.0 },

            -- Background health gradient colors (global).
            bgGradientHigh          = { r = 0.0, g = 0.3, b = 0.0 },
            bgGradientMid           = { r = 0.3, g = 0.2, b = 0.0 },
            bgGradientLow           = { r = 0.3, g = 0.0, b = 0.0 },
        },
    },
}
