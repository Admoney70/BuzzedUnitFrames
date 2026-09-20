-- ============================================================
-- BuzzardFrames: DummyAuras.lua
-- Setup/test mode dummy aura display.
-- Split from Auras.lua — loaded after Auras.lua exposes shared state.
--
-- Architecture:
--   * BF:ShowDummyAuras  — monolithic entry point: resolves shared
--     state (profiles, offsets, backdrop, fakeNow/fakeDur, ApplyDummyIcon
--     closure, dispelDebuffBorderOnly/customAurasOnly flags), installs the
--     30s dummy-cooldown restart timer, and invokes every _ShowDummy<Type>
--     helper in order. Also runs the custom-container + nameRoleHealth
--     tail block.
--   * _ShowDummy<Type> helpers — per-aura-type paint passes. Each takes
--     (self, frame, s) where s is the shared-state bundle built by the
--     entry point. These helpers contain verbatim copies of the blocks
--     that used to live inline in ShowDummyAuras; there are no behavior
--     changes between the monolith and the split.
--   * BF:ShowDummy<Type> public wrappers — single-type entry points for
--     the Options aura-text setters. Each resolves the same shared state
--     as BF:ShowDummyAuras (minus the 30s timer, which is owned solely
--     by BF:ShowDummyAuras) and calls the matching _ShowDummy<Type>.
--     Used by BF:RefreshPreviewDummy<Type> in Options_PreviewSystem.lua
--     so per-subcategory aura-text edits (font, color, threshold, swipe,
--     spark, etc.) repaint ONLY the affected dummy icon type on the
--     preview frames instead of rebuilding every dummy aura.
--
-- If you add a new aura type: add a _ShowDummy<Type> helper + a public
-- BF:ShowDummy<Type> wrapper, plug the helper into BF:ShowDummyAuras's
-- call sequence, and add a matching BF:RefreshPreviewDummy<Type> in
-- Options_PreviewSystem.lua. Keep behavior of BF:ShowDummyAuras
-- byte-identical to the pre-split version so existing callers
-- (Options_PreviewSystem.lua ApplyPreviewDummyAuras, the 30s restart
-- timer, setup-mode test frames) are unaffected.
-- ============================================================
local BF  = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

-- Standard Lua/WoW upvalues
local ipairs  = ipairs
local C_Timer = C_Timer

-- Upvalue shared state/helpers from Auras.lua
local MAX_BUFFS        = BF.MAX_BUFFS
local MAX_DEBUFFS      = BF.MAX_DEBUFFS
-- 2026-08-25: the DUMMY pool ceiling, distinct from BF.MAX_DEBUFFS (8), which
-- is the LIVE row's engine cap and is unchanged. The preview counts per GROUP
-- now, so seven groups at the Preview Debuffs slider's maximum of 8 is 56
-- icons. This is a runaway guard, not a target -- no real configuration
-- approaches it; the pool only ever grows to what a pass actually asks for.
BF.MAX_PREVIEW_DEBUFFS = 56
local MAX_PREVIEW_DEBUFFS = BF.MAX_PREVIEW_DEBUFFS
local PixelPerfectSize = BF.PixelPerfectSize
local AnchorNudge      = BF.AnchorNudge
local CalcAuraOffsets   = BF.CalcAuraOffsets
local GetBackdropTable  = BF.GetBackdropTable
local SetFrameBackdrop  = BF.SetFrameBackdrop
local BuildAuraIconFrame = BF.BuildAuraIconFrame

-- ============================================================
-- v70: PREVIEW MODE
-- The old two toggles (db.global.showPreviewAuras on/off +
-- simulateDispellableDebuff) are replaced by a per-tab "Preview" dropdown.
-- Two account-wide values: previewModeBuffs (Buffs tab) and
-- previewModeDebuffs (Debuffs tab). BF:GetActivePreviewMode resolves which
-- tab is currently showing (via BF._currentAurasSubcat) and returns the
-- three booleans below. These gates apply ONLY to preview frames
-- (frame._isPreviewFrame); setup-mode test frames keep the old
-- showDummyBuffs/showDummyDebuffs/showDummyBigDef booleans untouched.
--
--   value           showBuffs  showDebuffs  simDispel
--   "all"           yes        yes          no
--   "allDispel"     yes        yes          YES
--   "buffs"         yes        no           no
--   "debuffs"       no         yes          no
--   "debuffsDispel" no         yes          YES
--
-- showBuffs governs the Buffs tab's whole side: default buffs, Big Defensive
-- (a Buffs-tab subcat) and buff containers. showDebuffs governs default
-- debuffs, the dispel border/overlay/indicator simulation and debuff
-- containers. simDispel is the former simulateDispellableDebuff.
-- ============================================================
BF.PREVIEW_MODE_MAP = {
    all           = { buffs = true,  debuffs = true,  simDispel = false },
    allDispel     = { buffs = true,  debuffs = true,  simDispel = true  },
    buffs         = { buffs = true,  debuffs = false, simDispel = false },
    debuffs       = { buffs = false, debuffs = true,  simDispel = false },
    debuffsDispel = { buffs = false, debuffs = true,  simDispel = true  },
}

-- Which db.global key holds the dropdown value for a given active aura subcat.
-- bigDef rides the Buffs tab; dispelIndicator rides the Debuffs tab.
local PREVIEW_SUBCAT_TAB = {
    buffs           = "previewModeBuffs",
    bigDef          = "previewModeBuffs",
    debuffs         = "previewModeDebuffs",
    dispelIndicator = "previewModeDebuffs",
}

-- The Aura Cooldown Text section has a dropdown and a key of its own
-- (previewModeAuraText), read whenever that section is current -- the
-- Raid/Party one or the Custom Frame Groups one -- since it carries no aura
-- subcat to resolve by.
local PREVIEW_AURATEXT_SECTIONS = {
    auraText            = true,
    customFrameAuraText = true,
}

-- Resolve the active tab's preview mode. Returns (modeString, showBuffs,
-- showDebuffs, simDispel). Aura Cooldown Text reads its own key; otherwise
-- the current aura subcat decides. Fallback when neither applies (Dispel
-- Highlight, CFG, etc.): the Buffs tab value, so a non-aura section still
-- previews something sensible. Never errors on an unknown/nil stored value
-- — falls back to "all".
function BF:GetActivePreviewMode()
    local g = self.db and self.db.global or {}
    local subcat = BF._currentAurasSubcat
    local key
    if PREVIEW_AURATEXT_SECTIONS[BF._currentSection] then
        key = "previewModeAuraText"
    else
        key = (subcat and PREVIEW_SUBCAT_TAB[subcat]) or "previewModeBuffs"
    end
    local mode = g[key] or "all"
    local m = BF.PREVIEW_MODE_MAP[mode] or BF.PREVIEW_MODE_MAP.all
    return mode, m.buffs, m.debuffs, m.simDispel
end

-- ============================================================
-- SETUP MODE / PREVIEW TOOLTIP HELPER
-- Attaches a simple informational tooltip to a dummy icon frame.
-- Calling with text=nil removes the tooltip.
--
-- Prefix rewrite: text of the form "Setup Mode: <label>" becomes
-- "Preview: <label>" at hover time when the icon's owning frame is a
-- preview frame (marked with `_isPreviewFrame = true` on the unit
-- frame, set by MakePreviewFrame in Options_PreviewSystem.lua).
-- Setup-mode test frames have no such marker and keep the original
-- "Setup Mode: " label.
--
-- Tooltip labels passed from external callers (e.g. AuraCustomizations
-- container icons) that do NOT start with "Setup Mode: " are rendered
-- verbatim, so custom labels like "Preview: Rejuvenation" are unaffected.
-- ============================================================
local SETUP_PREFIX = "Setup Mode: "
local PREVIEW_PREFIX = "Preview: "

-- Walk up the parent chain looking for a frame marked as a preview
-- frame. Bounded to a small number of hops (icons sit at most ~2
-- levels deep under the preview unit frame in practice).
local function _OwnerIsPreview(frame)
    local f = frame
    for _ = 1, 4 do
        if not f then return false end
        if f._isPreviewFrame then return true end
        f = f:GetParent()
    end
    return false
end

local function SetDummyTooltip(frame, text)
    if not frame then return end
    if text then
        frame:EnableMouse(true)
        frame:SetScript("OnEnter", function(self)
            local shown = text
            if _OwnerIsPreview(self) and shown:sub(1, #SETUP_PREFIX) == SETUP_PREFIX then
                shown = PREVIEW_PREFIX .. shown:sub(#SETUP_PREFIX + 1)
            end
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            GameTooltip:SetText("|cffffd700" .. shown .. "|r", 1, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        frame:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
    else
        frame:EnableMouse(false)
        frame:SetScript("OnEnter", nil)
        frame:SetScript("OnLeave", nil)
    end
end
BF.SetDummyTooltip = SetDummyTooltip  -- exposed for CustomAuras.lua container icons

-- ============================================================
-- AURA PREVIEW: populate a dummy frame with fake auras
-- Respects all current aura settings (size, per-row, timer
-- visibility, debuff color, bigdef, etc.) for the active tab.
-- Called by RefreshAuraTestMode whenever settings change.
-- ============================================================

-- A small set of recognizable icons to use as fake auras so the
-- preview looks plausible rather than blank or random.
local DUMMY_BUFF_ICONS = {
    "Interface\\Icons\\Spell_Holy_WordFortitude",        -- Power Word: Fortitude
    "Interface\\Icons\\Spell_Nature_Rejuvenation",       -- Rejuvenation
    "Interface\\Icons\\Spell_Holy_Renew",                -- Renew
    "Interface\\Icons\\Spell_Holy_PowerWordShield",       -- Power Word: Shield
}
local DUMMY_BIGDEF_ICON = "Interface\\Icons\\Spell_Holy_PainSupression"

-- ── v92 §B7.1: ONE record per preview debuff ───────────────────────────────
-- The old pair of positional tables (DUMMY_DEBUFF_ICONS + DUMMY_DEBUFF_COLORS,
-- read by two separate modulo lookups that had to stay in lockstep) is one
-- record table now, because the row is no longer uniform: each dummy resolves
-- its OWN rank, size mult and dispellability the way the live row does.
--
--   category    "boss" | "dispellable" | "other" -- which main-row TYPE this
--               dummy stands for, and therefore which rank/size keys it reads.
--   dispellable per-RECORD (was row-global): the boss dummy is undispellable
--               regardless of the Preview dropdown's simDispel bit, matching
--               real boss auras and letting the row show a MIXED dispel state.
--   atlas/typeAtlas  only meaningful while the record renders dispellable.
--
-- Order IS the tiebreak for equal ranks, and previewDebuffCount's default of 3
-- selects Poison / Curse / Boss. Counts above #records cycle (modulo), exactly
-- as the two old tables did.
local DUMMY_DEBUFFS = {
    { tex = "Interface\\Icons\\Ability_Creature_Poison_06",  -- Poison (green)
      r = 0.00, g = 0.60, b = 0.00,
      atlas = "ui-debuff-border-poison-noicon", typeAtlas = "RaidFrame-Icon-DebuffPoison",
      category = "dispellable", dispellable = true },
    { tex = "Interface\\Icons\\Spell_Shadow_CurseOfTounges", -- Curse (purple)
      r = 0.60, g = 0.00, b = 1.00,
      atlas = "ui-debuff-border-curse-noicon", typeAtlas = "RaidFrame-Icon-DebuffCurse",
      category = "dispellable", dispellable = true },
    -- The boss preset's own previewIcon (AuraCustomizations.lua), so the row
    -- dummy and a Boss-preset container icon read as the same class of aura.
    { tex = "Interface\\Icons\\Achievement_Boss_Lichking",   -- Boss
      r = 0.80, g = 0.00, b = 0.00,
      category = "boss" },
    { tex = "Interface\\Icons\\Spell_Frost_FrostBolt02",     -- Magic (Frost)
      r = 0.20, g = 0.60, b = 1.00,
      atlas = "ui-debuff-border-magic-noicon", typeAtlas = "RaidFrame-Icon-DebuffMagic",
      category = "dispellable", dispellable = true },
    -- 2026-08-25: Role, Crowd Control and Priority. Until now the preview had
    -- no record that read as any of them, which is why those three groups
    -- could not appear at all. Role and CC reuse their debuff container
    -- preset's own previewIcon (AuraCustomizations.lua), for the same reason
    -- the Boss record does: a row dummy and a container icon of the same
    -- category should read as the same class of aura.
    --
    -- ORDER IS LOAD-BEARING: DUMMY_GROUP_RECORDS below indexes this table by
    -- position (role 5, cc 6, priority 7). Inserting a record anywhere but the
    -- end silently repoints those cycles.
    { tex = "Interface\\Icons\\Spell_Shadow_Shadowbolt",     -- 5: Role
      r = 0.80, g = 0.30, b = 0.10,
      category = "role" },
    { tex = "Interface\\Icons\\Spell_Nature_Polymorph",      -- 6: Crowd Control
      r = 0.90, g = 0.70, b = 0.20,
      category = "cc" },
    -- Priority: FORBEARANCE (owner request). Carried as a SPELL ID, not a
    -- texture path -- the Priority preset's own art is the same Poison texture
    -- a dispellable record already uses, and the game is a better authority on
    -- this icon's file name than a hardcoded guess would be.
    { spellID = 25771,                                       -- 7: Priority (Forbearance)
      r = 0.90, g = 0.80, b = 0.50,
      category = "priority" },
}
-- Texture for a record: its literal path, or its spell's own icon resolved
-- once and cached back onto the record (C_Spell is not guaranteed at parse
-- time, so this cannot happen in the table above). Falls back to the Poison
-- art if the lookup fails, so a paint can never hand SetTexture a nil.
local function DummyRecordTexture(rec)
    if rec.tex then return rec.tex end
    local t = rec.spellID and C_Spell and C_Spell.GetSpellTexture
        and C_Spell.GetSpellTexture(rec.spellID)
    rec.tex = t or "Interface\\Icons\\Ability_Creature_Poison_06"
    return rec.tex
end
-- 2026-08-25: which DUMMY_DEBUFFS records stand for each debuff GROUP, now
-- that the preview row is built group-by-group rather than by cycling the
-- record table. Values are indices into DUMMY_DEBUFFS above; a group needing
-- more icons than its cycle has records repeats the cycle.
--   boss        -- one piece of boss art, repeated
--   dispMe      -- the three dispellable records
--   dispOthers  -- the same three, OFFSET, so the two dispel arms do not read
--                  as one group when both are live
--   other       -- the dispellable records too: a residual debuff in the
--                  preview keeps its dispel-type badge exactly as it did
--                  before this change (the badge is per record, and the
--                  painter still gates it on ac.showDebuffDispelTypeIcon)
-- Role, CC and Priority have NO entry, which is why they cannot appear in the
-- preview yet -- there is no record that reads as any of them.
local DUMMY_GROUP_RECORDS = {
    boss       = { 3 },
    -- 2026-08-25 (owner request): Magic leads the By-Me cycle -- it is the
    -- dispel type nearly every healer has, so the first dispellable icon in
    -- the preview is the one most users will recognize as theirs.
    dispMe     = { 4, 1, 2 },
    dispOthers = { 2, 4, 1 },
    other      = { 1, 2, 4 },
    -- 2026-08-25: one record apiece -- these three have a single piece of art
    -- each, repeated if the group asks for more than one icon.
    role       = { 5 },
    cc         = { 6 },
    priority   = { 7 },
}
-- 2026-08-25 (owner report): every row dummy used to claim the same
-- "Setup Mode: Debuffs" tooltip, so a category flowing in the regular row was
-- indistinguishable from any other -- while the same category rendered INSIDE
-- a container correctly named itself. Names are the debuff container presets'
-- own (AuraCustomizations.lua), so a row icon and a flowed container icon of
-- one category read identically.
local DUMMY_GROUP_LABEL = {
    boss       = "Boss Auras",
    role       = "Role Auras",
    cc         = "Crowd Control",
    dispMe     = "Dispellable by Me",
    dispOthers = "Dispellable by Others",
    priority   = "Priority Auras",
    other      = "Other Debuffs",
}
-- Simple Mode overrides: `boss` is the Boss/Role PAIR there (the mode forces
-- them combined), so it takes the pair label the options list uses.
local DUMMY_GROUP_LABEL_SIMPLE = {
    boss = "Boss/Role Debuffs",
}

-- v67: DUMMY_PA_ICONS removed with the Private Auras feature.

-- ============================================================
-- MakeApplyDummyIcon(fakeNow, fakeDur)
-- Builds the ApplyDummyIcon closure with fakeNow/fakeDur captured.
-- Factored out so both the monolithic BF:ShowDummyAuras and each
-- per-type public wrapper can share one implementation.
--
-- The closure writes _bf_* fields directly; callers pre-compute
-- bfSize/bfScale from AuraCache exactly as the aura indicators do,
-- so no font/scale logic lives here.
-- dispelColor (optional): when non-nil AND BF.AuraCache.debuffDurationDispelColor
-- is on, the timer text is painted this color instead of the Font Color —
-- mirrors the real-path behavior in applyDebuffDurColors (Auras.lua).
-- Setting _bf_dispelColorActive before SetCooldown prevents the SetCooldown
-- hook from overwriting the text with Font Color; we then stamp the dispel
-- color directly. When the flag was previously set but dispelColor is now
-- nil (or the feature is off), clear the flag so the hook resumes painting
-- Font Color.
-- ============================================================
-- v62: preview border-style resolution — same rules as ContainerFactory
-- BorderStyleOf: explicit rounded styles win, else the legacy blizzard
-- flag, else flat. Callers pass the result as the (former blizzMode) arg.
local function DummyBorderStyle(styleKey, blizzFlag)
    if styleKey == "rounded" or styleKey == "rounded_thick" then return styleKey end
    if styleKey == "blizzard" or blizzFlag then return "blizzard" end
    return "flat"
end

local DUMMY_ROUND_RING = "Interface\\AddOns\\BuzzardFrames\\Media\\IconBorder"
local DUMMY_ROUND_RING_THICK = "Interface\\AddOns\\BuzzardFrames\\Media\\IconBorderThick"
local DUMMY_ROUND_MASK = "Interface\\AddOns\\BuzzardFrames\\Media\\IconMask"
-- v68: swipe uses the dedicated hardened/dilated asset, not the mask — the
-- mask's AA corner alpha left the ring's corner arc under-darkened under
-- mipmap filtering. See ROUND_SWIPE_TEX in Auras/ContainerFactory.lua.
local DUMMY_ROUND_SWIPE = "Interface\\AddOns\\BuzzardFrames\\Media\\IconSwipe"

local function MakeApplyDummyIcon(fakeNow, fakeDur)
    return function(icon, texPath, borderR, borderG, borderB, size, showDuration, swipeDisabled, sparkDisabled, reverseSwipe, bfFont, bfSize, bfBorder, bfScale, borderA, bfColor, dispelColor, expiringCurve, borderThickness, styleArg, blizzAtlas)
        if not icon then return end
        icon:SetSize(size, size)
        -- v62: styleArg is a style string from DummyBorderStyle (older
        -- callers' boolean still accepted: true = blizzard).
        local style = styleArg
        if style == true then style = "blizzard" elseif not style then style = "flat" end
        local blizzMode = style == "blizzard"
        local isRounded = style == "rounded" or style == "rounded_thick"
        if blizzMode or isRounded then
            -- v34 Blizzard-style borders preview parity: no flat backdrop,
            -- uncropped full-bleed icon, rounded Blizzard border atlas on
            -- harmful types (blizzAtlas), borderless helpful types.
            -- v62: the Rounded styles also drop the flat backdrop (the
            -- ring + mask replace it, mirroring the container path).
            if icon._bf_bdrPx ~= "blizz" then
                icon._bf_bdrPx = "blizz"
                SetFrameBackdrop(icon, nil)
            end
        elseif borderThickness == 0 then
            -- v94: thickness 0 means NO BORDER, and it must not go through
            -- GetBackdropTable. That table's edgeFile is WHITE8x8 with
            -- edgeSize = 0, and a degenerate edgeSize makes the client draw
            -- the four edge bars at a DEFAULT size -- on screen, a giant
            -- square with a cross through it (owner-reported the moment the
            -- Square icon type's "Show Border" toggle started resolving to 0).
            --
            -- The live path never reaches this shape: it guards
            -- `(spec.borderThickness or 1) > 0` and HIDES its edge textures at
            -- zero (ContainerFactory.lua). Clearing the backdrop is the
            -- preview's equivalent.
            --
            -- Note the trap this sits on: `borderThickness or 1` below cannot
            -- catch 0, because 0 is TRUTHY in Lua. So the fallback that looks
            -- like it handles a missing thickness silently passed a real zero
            -- straight through -- a latent bug for any caller that resolves 0
            -- (ac.buffBorderThickness can be 0 too), not only for the Square.
            if icon._bf_bdrPx ~= "none" then
                icon._bf_bdrPx = "none"
                SetFrameBackdrop(icon, nil)
            end
        else
            -- Border thickness (v34 Border settings): re-stamp the backdrop
            -- when the pixel-perfect edge size changes (also covers UI-scale
            -- changes — the guard keys on the computed UI-unit value). Must
            -- run BEFORE SetIconBorderColor: SetBackdrop resets border color.
            local bpx = BF:PixelsToUI(borderThickness or 1)
            if icon._bf_bdrPx ~= bpx then
                icon._bf_bdrPx = bpx
                SetFrameBackdrop(icon, GetBackdropTable(bpx))
            end
        end
        -- v94: UN-STICK the Buff List preview's Square (Color by Duration)
        -- state before anything else paints. These pools are shared, and the
        -- caller that set this is not necessarily the caller that gets the slot
        -- next: the square hides the engine countdown numbers, shows a glyph
        -- FontString of its own, and re-points the threshold curve at it. Reset
        -- HERE, in the one painter every dummy path goes through, so no caller
        -- has to remember; the square re-applies its own state after this
        -- returns (it runs later in _PaintSingleBuffDummy).
        --
        -- The curve pointer in particular must go back BEFORE the curve block
        -- below re-binds it, or a slot that stops being a square would keep
        -- coloring a hidden FontString instead of its visible one.
        if icon._bf_sbSquareText then
            if icon._bf_sbSquareGlyph then icon._bf_sbSquareGlyph:Hide() end
            local sqcd = icon.cooldown
            if sqcd and sqcd.SetHideCountdownNumbers then
                sqcd:SetHideCountdownNumbers(false)
            end
            if sqcd and icon.colorCurveText == icon._bf_sbSquareGlyph then
                icon.colorCurveText = sqcd.timerText
            end
            icon._bf_sbSquareText = nil
        end
        if icon.Icon then
            icon.Icon:SetTexture(texPath)
            -- v94: RESET the icon region every paint. The Buff List preview's
            -- Square (Color by Duration) path alpha-0s it so only the glyph
            -- shows, and these pools are shared -- a base dummy, a container
            -- icon or a differently-typed entry landing on that slot next pass
            -- would otherwise render as an invisible icon with a border round
            -- it. Reset HERE, in the one painter every path goes through, so
            -- no caller has to remember; the square re-applies its own alpha
            -- after this returns.
            icon.Icon:SetAlpha(1)
            icon.Icon:SetVertexColor(1, 1, 1)
            -- Do NOT call icon.Icon:SetSize here: the texture is anchored to
            -- TOPLEFT and BOTTOMRIGHT with pixel-perfect insets set by
            -- CreateAuraIcon. An explicit SetSize overrides those anchors,
            -- making the texture fill the entire frame and covering the border.
            -- Full-bleed anchors for blizzard AND rounded (rounded keeps
            -- the cropped texcoords — flat-family, container-path parity).
            local wantFull = (blizzMode or isRounded) and true or false
            -- Flat: inset the icon texture by the ACTUAL border thickness so a
            -- thicker Border Thickness reveals a thicker border band (mirrors
            -- ApplyBorderInsets on real buttons). Was hardcoded to PixelsToUI(1)
            -- and only re-anchored on the full-bleed toggle, so changing Border
            -- Thickness moved the backdrop edge but not the icon — the border
            -- looked unchanged. Guard on wantFull + the inset value so a
            -- thickness change re-anchors.
            local flatInset = wantFull and 0 or BF:PixelsToUI(borderThickness or 1)
            if wantFull ~= (icon._bf_iconFull or false) or (not wantFull and icon._bf_iconInset ~= flatInset) then
                icon._bf_iconFull = wantFull
                icon._bf_iconInset = flatInset
                icon.Icon:ClearAllPoints()
                if wantFull then
                    icon.Icon:SetAllPoints(icon)
                else
                    icon.Icon:SetPoint("TOPLEFT", flatInset, -flatInset)
                    icon.Icon:SetPoint("BOTTOMRIGHT", -flatInset, flatInset)
                end
            end
            if blizzMode then
                icon.Icon:SetTexCoord(0, 1, 0, 1)
            else
                icon.Icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
            end
            icon.Icon:Show()
        end
        -- v62: rounded ring + icon mask (preview mirror of ContainerFactory
        -- ApplyBorderInsets/EnsureSlotRing). Created lazily; masking is
        -- Show/Hide (hidden mask = off). Ring rides the count holder frame
        -- (cooldown level +2) so it renders ABOVE the swipe — v57 parity,
        -- which also lets the swipe rect run 1px past the icon (below).
        if isRounded then
            local thick = style == "rounded_thick"
            local ring = icon._bf_prevRing
            if not ring then
                -- v59: on the ICON FRAME itself, which puts the ring BELOW
                -- the cooldown — cd is a CHILD frame and children render
                -- above the parent's own regions, so the swipe darkens the
                -- border band as it passes. It used to ride the count
                -- holder (cd + 2, above the swipe) back when the swipe
                -- overhung the icon and the ring was hiding that overhang.
                local host = icon
                ring = BF.Texture(host, nil, "OVERLAY")
                icon._bf_prevRing = ring
                local mask = BF.MaskTexture(icon)
                if mask.SetBlockingLoadsRequested then
                    mask:SetBlockingLoadsRequested(true)
                end
                mask:SetTexture(DUMMY_ROUND_MASK,
                    "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
                mask:SetAllPoints(icon)
                if icon.Icon then icon.Icon:AddMaskTexture(mask) end
                icon._bf_prevMask = mask
            end
            -- Geometry/art change-guarded on style (offset o: v59 — thick
            -- 1, thin 0.5; ring art carries the band).
            if icon._bf_prevRoundStyle ~= style then
                icon._bf_prevRoundStyle = style
                local o = thick and 1 or 0.5
                ring:SetTexture(thick and DUMMY_ROUND_RING_THICK or DUMMY_ROUND_RING)
                ring:ClearAllPoints()
                ring:SetPoint("TOPLEFT", icon, "TOPLEFT", -o, o)
                ring:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", o, -o)
            end
            ring:Show()
            icon._bf_prevMask:Show()
            icon._bf_prevRoundOn = true
            if icon.cooldown and not icon._bf_prevSwipeRound then
                icon.cooldown:SetSwipeTexture(DUMMY_ROUND_SWIPE)
                icon._bf_prevSwipeRound = true
            end
        else
            icon._bf_prevRoundOn = nil
            icon._bf_prevRoundStyle = nil
            if icon._bf_prevRing then icon._bf_prevRing:Hide() end
            if icon._bf_prevMask then icon._bf_prevMask:Hide() end
            if icon._bf_prevSwipeRound then
                icon.cooldown:SetSwipeTexture("Interface\\Buttons\\WHITE8x8")
                icon._bf_prevSwipeRound = nil
            end
        end
        if not blizzMode then
            -- Rounded: routed to the ring via the SetIconBorderColor
            -- abstraction (the _bf_prevRoundOn flag set above).
            BF.SetIconBorderColor(icon, borderR, borderG, borderB, borderA or 0.8)
        end
        -- Rounded Blizzard border atlas (blizzard mode, harmful types).
        if blizzMode and blizzAtlas then
            local bb = icon._bf_blizzB
            if not bb then
                bb = BF.Texture(icon, nil, "OVERLAY")
                icon._bf_blizzB = bb
            end
            -- v49: oversize so the ring hugs the aura edges (the atlas
            -- art carries transparent padding — see ApplyBorderInsets).
            if icon._bf_blizzBPad ~= size then
                icon._bf_blizzBPad = size
                local pad = size * 0.12
                bb:ClearAllPoints()
                bb:SetPoint("TOPLEFT", icon, "TOPLEFT", -pad, pad)
                bb:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", pad, -pad)
            end
            bb:SetAtlas(blizzAtlas)
            bb:Show()
        elseif icon._bf_blizzB then
            icon._bf_blizzB:Hide()
        end
        if icon.count then icon.count:Hide() end
        if icon.cooldown then
            -- Swipe geometry parity with ApplyBorderInsets on real
            -- container buttons: the swipe covers the border band EXACTLY
            -- and never extends past its outer edge.
            --   blizzard : SQUARE swipe inset so its corners stay inside
            --              the rounded atlas outline (unchanged — the
            --              atlas radius isn't knowable from Lua).
            --   rounded  : swipe rect == RING rect (icon expanded by `o`).
            --              The swipe texture is the mask asset, whose outer
            --              contour is pixel-identical to the ring art's, so
            --              the two outer edges coincide exactly. Uses raw
            --              `o` — the same units the ring is anchored with
            --              (the old PixelsToUI(1) mixed unit systems).
            --   flat     : full-bleed; the backdrop border's outer edge is
            --              the icon rect and both shapes are square.
            -- Change-guarded on mode+size.
            local cdKey = blizzMode and ("b" .. size) or (isRounded and style) or "flat"
            if icon._bf_cdInset ~= cdKey then
                icon._bf_cdInset = cdKey
                icon.cooldown:ClearAllPoints()
                if blizzMode then
                    local inset = size * 0.04
                    icon.cooldown:SetPoint("TOPLEFT", icon, "TOPLEFT", inset, -inset)
                    icon.cooldown:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", -inset, inset)
                elseif isRounded then
                    -- Anchored TO THE RING (already positioned above), not
                    -- to the icon with matching numbers: a FRAME and a
                    -- TEXTURE round their rects independently and `o` is a
                    -- half unit for plain Rounded — that mismatch was the
                    -- intermittent 1px corner overshoot.
                    local ring = icon._bf_prevRing
                    if ring then
                        icon.cooldown:SetAllPoints(ring)
                    else
                        local o = (style == "rounded_thick") and 1 or 0.5
                        icon.cooldown:SetPoint("TOPLEFT", icon, "TOPLEFT", -o, o)
                        icon.cooldown:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", o, -o)
                    end
                else
                    icon.cooldown:SetAllPoints(icon)
                end
            end
            icon.cooldown:SetHideCountdownNumbers(not showDuration)
            icon.cooldown:SetDrawSwipe(not swipeDisabled)
            icon.cooldown:SetDrawEdge(not sparkDisabled)
            icon.cooldown:SetReverse(reverseSwipe or false)
            if showDuration then
                icon.cooldown._bf_font   = bfFont
                icon.cooldown._bf_size   = bfSize
                icon.cooldown._bf_border = bfBorder
                icon.cooldown._bf_scale  = bfScale
                if bfColor then
                    icon.cooldown._bf_textR = bfColor.r or 1
                    icon.cooldown._bf_textG = bfColor.g or 1
                    icon.cooldown._bf_textB = bfColor.b or 1
                    icon.cooldown._bf_textA = bfColor.a or 1
                end
            end
            -- Resolve whether the dispel-color branch should be active for this
            -- render pass. Only active when the feature is on AND the caller
            -- passed a dispel color. If not active, clear any stale flag so the
            -- SetCooldown hook can paint Font Color normally.
            local parentFrame = icon:GetParent()
            local iconAC = parentFrame and BF:GetAuraCacheForFrame(parentFrame) or BF.AuraCache
            local dispelActive = dispelColor and iconAC.debuffDurationDispelColor
            if dispelActive then
                -- Setting the flag BEFORE SetCooldown prevents the SetCooldown
                -- hook (in CreateAuraIcon) from stamping Font Color over the
                -- dispel color.
                icon.cooldown._bf_dispelColorActive = true
            else
                icon.cooldown._bf_dispelColorActive = nil
            end
            icon.cooldown:SetCooldown(fakeNow, fakeDur)
            -- After SetCooldown, paint the dispel color directly. Done here
            -- (not in the hook) because the dispel color is a plain Lua table
            -- in the dummy path, not a secret ColorMixin like the real path.
            if dispelActive and icon.cooldown.timerText then
                icon.cooldown.timerText:SetTextColor(dispelColor.r, dispelColor.g, dispelColor.b, 1)
            end
            -- Apply the stamped font/scale/color to the countdown FontString.
            -- The _bf_* stamps above are dead data unless something applies
            -- them: the live legacy path applies at render time
            -- (RenderContainerIcons inline) and custom-container icons have a
            -- SetCooldown hook (CustomAuras.lua:1141) — but BuildAuraIconFrame
            -- pool icons have NO hook (the one this comment block references
            -- was lost in the CreateAuraIcon→BuildAuraIconFrame refactor), so
            -- dummy repaints stamped new font/scale that never reached the
            -- text (preview kept creation-time font; auto-scale never tracked
            -- resizes). Preview-only path — no combat cost.
            if showDuration and icon.cooldown.timerText then
                local tt = icon.cooldown.timerText
                tt:SetFont(bfFont or "Interface\\AddOns\\BuzzardFrames\\Media\\Fonts\\RobotoCondensed-Bold.ttf",
                    bfSize or 11, bfBorder or "OUTLINE")
                tt:SetScale(bfScale or 1.0)
                if not dispelActive and bfColor then
                    tt:SetTextColor(bfColor.r or 1, bfColor.g or 1, bfColor.b or 1, bfColor.a or 1)
                end
            end
            -- Threshold color curve: stamp FRESH curve config every repaint
            -- (the legacy Layout stamps go stale here — threshold slider
            -- edits repaint via ShowDummy*, not via indicator Layout) and
            -- register with the threshold poll using a persistent duration
            -- object wound to the fake cooldown. Without this the preview
            -- never showed threshold text colors: UpdateIconColorCurve is
            -- only called from the live render path.
            -- colorCurveBorder stays nil: <f>ColorAuraBorder is removed, and
            -- debuff borders are dispel-owned — matches real-frame behavior.
            icon.colorCurveBorder = nil
            if showDuration and expiringCurve and icon.cooldown.timerText
               and C_DurationUtil and BF.UpdateIconColorCurve then
                icon.colorCurveObject = expiringCurve
                icon.colorCurveText = icon.cooldown.timerText
                -- Dispel-color interplay (debuffs): mirror DebuffIcons:Layout —
                -- dispel color owns the text unless the curve hides it.
                local curveHides = dispelColor and iconAC.curveHidesDebuff
                icon._bf_useDispelColor = (dispelActive and not curveHides) and true or nil
                icon._bf_curveOverridesDispel = (dispelColor and curveHides) and true or nil
                local durObj = icon._bf_dummyDurObj
                if not durObj then
                    durObj = C_DurationUtil.CreateDuration()
                    icon._bf_dummyDurObj = durObj
                end
                durObj:SetTimeFromEnd(fakeNow + fakeDur, fakeDur)
                BF.UpdateIconColorCurve(icon, durObj)
            else
                -- No curve (threshold disabled) or no duration text: clear
                -- stale curve config and deregister from the poll.
                icon.colorCurveObject = nil
                icon.colorCurveText = nil
                icon._bf_useDispelColor = nil
                icon._bf_curveOverridesDispel = nil
                if BF.RemoveIconColorCurve then BF.RemoveIconColorCurve(icon) end
            end
            icon.cooldown:Show()
        end
        icon:Show()
    end
end

-- ============================================================
-- EnsureSlotsAndBackdrop(self, frame, s)
-- Lazy aura slot creation + pixel-perfect backdrop re-stamp. Run
-- once per ShowDummy* entry point so per-type calls on freshly-
-- created preview frames don't skip slot creation.
-- ============================================================
local function EnsureSlotsAndBackdrop(self, frame, s)
    if not frame._auraSlotsReady then
        -- Preview frames: build raw aura icons without indicator dispatch.
        -- Preview frames aren't in BF.activatedFrames, so no tooltips or
        -- live update wiring. DummyAuras has _ShowDummyBuffs,
        -- _ShowDummyDebuffs and _ShowDummyBigDef.
        -- Each silently bails if its pool is nil. Allocate the pools
        -- DummyAuras actually renders. NO _ShowDummyMissingRaidBuff exists
        -- (verified by grep), so missingRaidBuffIcon is not allocated.
        frame.buffFrames     = frame.buffFrames     or {}
        frame.debuffFrames   = frame.debuffFrames   or {}
        frame.bigDefIcons    = frame.bigDefIcons    or {}
        local level = frame:GetFrameLevel() + 223
        for i = 1, BF.MAX_BUFFS do
            if not frame.buffFrames[i] then
                frame.buffFrames[i] = BuildAuraIconFrame(frame, level)
            end
        end
        for i = 1, BF.MAX_DEBUFFS do
            if not frame.debuffFrames[i] then
                frame.debuffFrames[i] = BuildAuraIconFrame(frame, level)
            end
        end
        for i = 1, BF.MAX_BIG_DEF do
            if not frame.bigDefIcons[i] then
                local icon = BuildAuraIconFrame(frame, level + 1)
                if icon.Icon then icon.Icon:SetDrawLayer("OVERLAY", 1) end
                frame.bigDefIcons[i] = icon
            end
        end
        frame._auraSlotsReady = true
    end
    -- v34: backdrop (border thickness) stamping moved into ApplyDummyIcon
    -- (per-feature Border Thickness setting, change-guarded on the
    -- pixel-perfect value — also covers UI-scale changes). Only sizes are
    -- stamped here.
    local bSize  = s.bSize
    local bdSize = s.bdSize
    if frame.buffFrames then
        for _, b in ipairs(frame.buffFrames) do b:SetSize(bSize, bSize) end
    end
    -- v92 §B7.1: the blanket debuff-slot SetSize(dSize) stamp is GONE. The
    -- Debuffs row is mixed-size now (an enlarged boss dummy, inline container
    -- icons at their own §B4 size) and _ShowDummyDebuffs sizes every slot it
    -- paints. Keeping the stamp would silently shrink the enlarged icons back
    -- to dSize on any OTHER type's targeted refresh (ShowDummyBuffs /
    -- ShowDummyBigDef / ShowDummyStackText all run this helper first) with no
    -- debuff repaint to restore them. Slots the row does not paint are hidden,
    -- so their size is irrelevant.
    -- Resize ALL big-def slots, not just slot 1 (latent bug fix vs.
    -- pre-refactor which only touched slot 1 via the deleted
    -- frame.bigDefIcon singular alias).
    -- v94: SKIPPED while the Buff List preview owns bigDef slots, for exactly
    -- the reason the debuff arm above was descoped. BIGDEF-anchored entries
    -- are painted at their OWN size, and one of them may be a Square (Color by
    -- Duration) -- a SetScale'd FontString whose scale is an ABSOLUTE number
    -- computed from the size at paint time. Restamping bdSize here on some
    -- other type's targeted refresh, with no bigDef repaint to follow, leaves
    -- that square visibly larger or smaller than the button it is. Live guards
    -- the same case (ContainerFactory.lua, the durationSquare size walk).
    -- Slots the pass does not paint are hidden, so their size is irrelevant.
    if frame.bigDefIcons
       and not (BF.IsPreviewingBuffList and BF:IsPreviewingBuffList()) then
        for _, b in ipairs(frame.bigDefIcons) do b:SetSize(bdSize, bdSize) end
    end
end

-- ============================================================
-- BuildSharedState(self, frame, isRaid, raidProfile, overridePartyProfile, fakeNow, fakeDur)
-- Centralised resolution of every piece of state the _ShowDummy<Type>
-- helpers need. Returns a table `s` with fields:
--   db, isRaid, activeFlat, atp,
--   buffsP, debuffsP, bdP, diP,   -- v67: paP removed with Private Auras
--   bSize, dSize, bdSize,
--   buffOffsets, buffAnchor, debuffAnchor,
--   debuffsPerRow, debuffGrowDir, debuffSpacing, debuffRowSpacing,
--   buffOffX, buffOffY, debuffOffX, debuffOffY,
--   fakeNow, fakeDur,
--   customAurasOnly, dispelDebuffBorderOnly,
--   ApplyDummyIcon (closure),
--   raidProfile, overridePartyProfile (for restart-timer reuse)
-- ============================================================
local function BuildSharedState(self, frame, isRaid, raidProfile, overridePartyProfile, fakeNow, fakeDur)
    local db = self.db.profile
    raidProfile = raidProfile or self:GetRaidProfile()
    -- Always fetch the active party profile (used for party frames; harmless for raid)
    local pp = overridePartyProfile or self:GetActivePartyProfile()

    -- v27: resolve the auras section view against the selected flat.
    -- Callers (Options_PreviewSystem.lua ApplyPreviewDummyAuras) pass the
    -- target flat directly, so activeFlat IS the flat being previewed.
    -- GetSectionProfile returns flat.auras when per-layout is ON, else the
    -- global rpDB.profile.auras. Same fallback chain as UpdateAuraSizeCache.
    local activeFlat = isRaid and raidProfile or pp
    -- v60: resolved per aura sub-category, not by resolving the whole
    -- auras table and indexing it. The Buffs and Debuffs per-layout
    -- toggles are independent, so a flat's auras table can carry stale
    -- rawkeys for whichever group is currently OFF.
    local buffsP   = self:GetAurasSubcatProfile("buffs",           activeFlat) or {}
    local debuffsP = self:GetAurasSubcatProfile("debuffs",         activeFlat) or {}
    -- v67: the privateAuras subcat view was removed with the Private Auras feature.
    local bdP      = self:GetAurasSubcatProfile("bigDef",          activeFlat) or {}
    local diP      = self:GetAurasSubcatProfile("dispelIndicator", activeFlat) or {}

    -- Sizes from explicit profile
    local bSize  = BF:PixelRound(buffsP.buffSize  or 12)
    local dSize  = BF:PixelRound(debuffsP.debuffSize or 12)
    local bdSize = BF:PixelRound(bdP.bigDefSize or 24)

    local buffsPerRow    = buffsP.buffsPerRow        or 3
    local debuffsPerRow  = debuffsP.debuffsPerRow    or 3
    local buffGrowDir    = buffsP.buffGrowDirection  or "LEFT"
    local debuffGrowDir  = debuffsP.debuffGrowDirection or "RIGHT"
    local buffAnchor     = buffsP.buffAnchorPoint    or "BOTTOMRIGHT"
    local debuffAnchor   = debuffsP.debuffAnchorPoint or "BOTTOMLEFT"
    local buffOffX       = buffsP.buffOffsetX        or 0
    local buffOffY       = buffsP.buffOffsetY        or 0
    local debuffOffX     = debuffsP.debuffOffsetX    or 0
    local debuffOffY     = debuffsP.debuffOffsetY    or 0
    local buffSpacing    = buffsP.buffSpacing        or 1
    local buffRowSpacing = buffsP.buffRowSpacing     or 1
    local debuffSpacing    = debuffsP.debuffSpacing      or 1
    local debuffRowSpacing = debuffsP.debuffRowSpacing   or 1

    -- Offsets for this profile (same CalcAuraOffsets logic used by real auras' RebuildAuraCacheScope)
    -- v92 §B7.1: the DEBUFF offsets table is gone. It advanced every slot by
    -- exactly size + spacing, which cannot express the mixed-size row
    -- _ShowDummyDebuffs builds now (enlarged boss dummy, inline container
    -- icons at their own §B4 size). That helper runs its own cursor
    -- accumulator over the four raw inputs exported below instead. Buffs keep
    -- the uniform grid -- nothing there is mixed-size.
    local buffOffsets   = CalcAuraOffsets(bSize, buffSpacing,   buffRowSpacing,   buffsPerRow,   buffGrowDir,   buffAnchor)

    -- When on the Debuff Highlight subtab, only show the dispel border/overlay,
    -- not the full set of aura icons.
    -- When on the Aura Customizations tab, only show custom container auras.
    local dispelDebuffBorderOnly = (BF._currentSection == "dispelDebuffBorder")
    local customAurasOnly     = (BF._currentSection == "customAuras")

    -- v70: active preview-mode gates. Resolved ONLY for preview frames; setup-
    -- mode test frames (not _isPreviewFrame) keep the legacy showDummy* booleans,
    -- so pvIsPreview is the flag the helpers branch on. When it's false the
    -- pv* booleans are left permissive (true) so any accidental read is a no-op.
    local pvIsPreview = frame._isPreviewFrame == true
    local pvShowBuffs, pvShowDebuffs, pvSimDispel = true, true, false
    if pvIsPreview then
        local _
        _, pvShowBuffs, pvShowDebuffs, pvSimDispel = self:GetActivePreviewMode()
    end

    -- 2026-09-15 (owner ruling): two Buffs-side subtabs narrow the preview to
    -- their own subject. A buff container's tab shows only the buffs assigned
    -- to that container -- not the regular Buffs row, not Big Defensive, not
    -- the other buff containers -- and the Big Defensive subtab shows big
    -- defensives without the regular Buffs row. Both are read off stamps the
    -- entry paths already maintain: the container tab IS the containerMgmt
    -- preview mode that arrival stamps (SetContainerPreview) and every
    -- sibling subtab clears on the way out, and the Big Defensive subtab is
    -- the aura sub-category its route observer stamps. Neither is a section:
    -- the container tabs deliberately report the section their sibling
    -- subtabs report, so customAurasOnly above cannot tell them apart. Preview
    -- frames only, like the pv* gates; setup-mode test frames never narrow.
    local containerTabOnly = false
    local bigDefTabOnly    = false
    if pvIsPreview then
        containerTabOnly = (self.IsPreviewingContainerMgmt and self:IsPreviewingContainerMgmt()
            and self.GetPreviewContainerIndex and self:GetPreviewContainerIndex() ~= nil)
            or false
        bigDefTabOnly = (BF._currentAurasSubcat == "bigDef")
    end

    return {
        db                   = db,
        isRaid               = isRaid,
        raidProfile          = raidProfile,
        overridePartyProfile = overridePartyProfile,
        pp                   = pp,
        activeFlat           = activeFlat,
        -- v60: the whole-table `aurasP` field was removed along with the
        -- single GetSectionProfile("auras") resolution it came from. It had
        -- no readers; the per-subcat views below are what consumers use.
        buffsP               = buffsP,
        debuffsP             = debuffsP,
        -- v67: the `paP` field was removed with the Private Auras feature.
        bdP                  = bdP,
        diP                  = diP,
        bSize                = bSize,
        dSize                = dSize,
        bdSize               = bdSize,
        buffOffsets          = buffOffsets,
        -- v94: the same four raw inputs for the BUFFS row. The uniform
        -- buffOffsets grid above is still what an ordinary preview uses and is
        -- unchanged; these are for the Buff List pass, where merged single
        -- buffs make the row mixed-size and the grid cannot express it.
        buffsPerRow          = buffsPerRow,
        buffGrowDir          = buffGrowDir,
        buffSpacing          = buffSpacing,
        buffRowSpacing       = buffRowSpacing,
        -- v92 §B7.1: the four raw inputs the retired debuffOffsets table was
        -- baked from -- _ShowDummyDebuffs re-derives its own wrapping from
        -- them because the row is mixed-size now.
        debuffsPerRow        = debuffsPerRow,
        debuffGrowDir        = debuffGrowDir,
        debuffSpacing        = debuffSpacing,
        debuffRowSpacing     = debuffRowSpacing,
        buffAnchor           = buffAnchor,
        debuffAnchor         = debuffAnchor,
        buffOffX             = buffOffX,
        buffOffY             = buffOffY,
        debuffOffX           = debuffOffX,
        debuffOffY           = debuffOffY,
        fakeNow              = fakeNow,
        fakeDur              = fakeDur,
        customAurasOnly      = customAurasOnly,
        dispelDebuffBorderOnly  = dispelDebuffBorderOnly,
        -- v70: preview-mode gates (see GetActivePreviewMode). pvIsPreview marks
        -- a real preview frame; the three booleans are only meaningful then.
        pvIsPreview          = pvIsPreview,
        pvShowBuffs          = pvShowBuffs,
        pvShowDebuffs        = pvShowDebuffs,
        pvSimDispel          = pvSimDispel,
        -- The two subtab narrowings above; false on every other pass.
        containerTabOnly     = containerTabOnly,
        bigDefTabOnly        = bigDefTabOnly,
        ApplyDummyIcon       = MakeApplyDummyIcon(fakeNow, fakeDur),
    }
end

-- ============================================================
-- _ShowDummyStackText(self, frame, s)
-- Paints the stack-count FontString on the first preview debuff
-- icon. Called from _ShowDummyDebuffs (same idx==1 gate as before)
-- and directly from BF:ShowDummyStackText for targeted refresh
-- from the Aura Text → Stack Text setters.
-- Requires: debuffs visible AND frame.debuffFrames[1] shown.
-- Reads stack-text settings from auraText.stackText sub-category.
-- ============================================================
local function _ShowDummyStackText(self, frame, s)
    if not frame.debuffFrames then return end
    local icon = frame.debuffFrames[1]
    if not icon or not icon.count then return end
    if not icon:IsShown() then return end
    local ac = BF:GetAuraCacheForFrame(frame)
    if ac.showStackText == false then
        icon.count:Hide()
        return
    end
    -- v30: stack text settings live in rpDB.profile.auraText.stackText,
    -- NOT in db.profile. Route through the active flat via the same
    -- GetSectionProfile path used by ApplyStackTextStyle and
    -- CreateAuraIcon, so the preview reflects the user's actual
    -- Aura Text → Stack Text settings.
    local atp = BF:GetSectionProfile("auraText", s.activeFlat) or {}
    local stP = atp.stackText or {}
    local stFont = BF:ResolveFontPathOr(stP.stackTextFont, "Interface\\AddOns\\BuzzardFrames\\Media\\Fonts\\RobotoCondensed-Bold.ttf")
    local stSize = stP.stackTextSize or 9
    local stBorder = stP.stackTextBorder or "OUTLINE"
    icon.count:SetFont(stFont, stSize, stBorder)
    icon.count:ClearAllPoints()
    local stAnchor = stP.stackTextAnchor or "BOTTOMRIGHT"
    local stX = stP.stackTextX or 4
    local stY = stP.stackTextY or -3
    icon.count:SetPoint(stAnchor, icon.count.tframe or icon, stAnchor, stX, stY)
    icon.count:SetText("3")
    if ac.stackAutoScale then
        -- v92 §B7.1: the host icon is no longer guaranteed to be dSize -- pool
        -- index 1 is whichever dummy SORTED first, and that may be the enlarged
        -- boss one. _ShowDummyDebuffs stamps the size it painted; s.dSize is the
        -- fallback for a stack-text-only refresh that ran before any row pass.
        local hostSize = icon._bf_dummySize or s.dSize
        icon.count:SetScale(hostSize / 12 * (ac.stackTimerScale or 1.0))
    else
        icon.count:SetScale(1.0)
    end
    icon.count:Show()
end

-- ============================================================
-- _ShowDummyBuffs(self, frame, s)
-- Paint the dummy buff icons on a preview/test frame.
-- ============================================================
-- ============================================================
-- v94: BUFF LIST PREVIEW -- forward declarations.
--
-- Defined below next to the general-container preview helpers, because the
-- collector needs _ensurePreviewContainerIcon for the container-anchored and
-- free-floating buckets. Declared as LOCALS here (and ASSIGNED, not
-- re-declared, below) so _ShowDummyBuffs can reach them: a plain global would
-- be nil when this function's body is compiled.
--
-- _SingleBuffPreviewItems is THE entry set. Every merge site calls it and
-- reads one bucket; nothing re-derives which entries are in the preview.
-- ============================================================
local _SingleBuffPreviewItems, _PaintSingleBuffDummy

local function _ShowDummyBuffs(self, frame, s)
    if not frame.buffFrames then return end
    local db, buffsP = s.db, s.buffsP
    local showBuffs = buffsP.showBuffs ~= false
    if s.dispelDebuffBorderOnly or s.customAurasOnly then showBuffs = false end
    -- v70: preview frames gate on the active Preview dropdown (Buffs side);
    -- setup-mode test frames keep the old showDummyBuffs toggle.
    -- 2026-09-15: and on the two subtabs that are not about this row -- a
    -- buff container's tab and Big Defensive -- the row stays hidden however
    -- the dropdown is set (BuildSharedState's containerTabOnly / bigDefTabOnly).
    if s.pvIsPreview then
        if not s.pvShowBuffs then showBuffs = false end
        if s.containerTabOnly or s.bigDefTabOnly then showBuffs = false end
    elseif showBuffs and BF.db.global.showDummyBuffs == false then
        showBuffs = false
    end
    if not showBuffs then
        for i = 1, MAX_BUFFS do
            local icon = frame.buffFrames[i]; if icon and icon:IsShown() then icon:Hide() end
        end
        return
    end
    local ac            = BF:GetAuraCacheForFrame(frame)
    local bSize         = s.bSize
    local showDuration  = ac.showBuffDuration
    local swipeDisabled = ac.disableBuffSwipe or false
    local sparkDisabled = ac.disableBuffSpark or false
    local reverseSwipe  = ac.reverseBuffSwipe == true
    local autoScale     = ac.buffAutoScale
    local bfFont        = ac.buffDurationFont
    local bfSize        = autoScale and 11 or (ac.buffFontSize or 11)
    local bfBorder      = ac.buffDurationBorder or "OUTLINE"
    local bfScale       = autoScale and (bSize / 12 * (ac.buffTimerScale or 1.0)) or 1.0
    local numToShow     = math.min(#DUMMY_BUFF_ICONS, ac.maxBuffs or MAX_BUFFS)
    if frame._isPreviewFrame then
        -- Account-wide (db.global), matching where the default is declared
        -- (Defaults.lua, previewBuffCount = 6) and where MigrateGlobalSettings
        -- hoists the key. This read and the slider both used db.profile until
        -- the 2026-08-15 fix, so the hoisted value was never seen; the inline
        -- `or 4` that masked the missing declared default went with it.
        numToShow = math.min(BF.db.global.previewBuffCount, ac.maxBuffs or MAX_BUFFS)
    end

    -- v33: border color resolves via GetDefaultBorderColorFor so the
    -- "Also Color Aura Border" toggle (buffColorAuraBorder) paints the
    -- border in Font Color instead of black. Matches the real-path branch
    -- in the aura indicator.
    local bR, bG, bB, bA = BF.GetDefaultBorderColorFor("buff", ac)
    local ApplyDummyIcon = s.ApplyDummyIcon
    local buffAnchor, buffOffX, buffOffY = s.buffAnchor, s.buffOffX, s.buffOffY
    local buffOffsets = s.buffOffsets

    -- ── v94: BUFF LIST MERGE ──────────────────────────────────────────────
    -- Buffs-anchored single buffs flow in THIS row (matrix rows 1-2, 4-5), so
    -- this function is the row's single assembler while the Buff List is open
    -- -- the same split v92 made for the Debuffs row. Returns nil on every
    -- other pass, and then nothing below this block changes.
    local groupTypeKey = frame._bf_containerGroupTypeKey or self:ResolveGroupTypeKey(frame)
    local sbSet   = _SingleBuffPreviewItems(self, frame, ac, groupTypeKey)
    local sbItems = sbSet and sbSet.buffs

    -- v94 (owner ruling, 2026-08-30): while an entry set exists, the row shows
    -- THOSE ENTRIES AND NOTHING ELSE -- the generic dummies are suppressed.
    -- Filtering to a spec is a request to look at that spec's buffs, and four
    -- stand-in icons of unrelated spells in the middle of them defeat it.
    --
    -- Gated on the SET, not on this bucket: a spec whose entries all anchor to
    -- Big Defensive or to a container leaves `sbItems` empty, and falling back
    -- to the generic dummies there would make the row's contents depend on
    -- where the entries happen to be anchored.
    --
    -- The set is nil only when nothing is being previewed at all (Filter by
    -- Spec = All with no selection). The uniform grid below then runs
    -- unchanged, so the pane still shows the ordinary buff row -- its size,
    -- spacing and position -- exactly as every other subtab does.
    if sbSet then
        -- MIXED-SIZE CURSOR. The uniform offsets grid advances every slot by
        -- exactly size + spacing, which cannot express a single buff drawn at
        -- its own size. Accumulate each icon's OWN extent along the grow axis
        -- instead, wrap by Icons Per Row, and step the cross axis by the
        -- completed row's tallest icon -- the preview twin of the live row's
        -- lineSizeSlack semantics, and the same cursor _ShowDummyDebuffs runs.
        local perRow = s.buffsPerRow or 3
        if perRow < 1 then perRow = 1 end
        local spacing = BF:PixelRound(s.buffSpacing or 1)
        local rowSp   = BF:PixelRound(s.buffRowSpacing or 1)
        local dir = (BF.NormalizeGrowDirection
            and BF.NormalizeGrowDirection(s.buffGrowDir or "LEFT", buffAnchor)) or "LEFT_DOWN"
        local prim, sec = dir:match("^(%u+)_(%u+)$")
        if not prim then prim, sec = "LEFT", "DOWN" end
        local pvx = (prim == "RIGHT" and 1) or (prim == "LEFT" and -1) or 0
        local pvy = (prim == "UP"    and 1) or (prim == "DOWN" and -1) or 0
        local wvx = (sec  == "RIGHT" and 1) or (sec  == "LEFT" and -1) or 0
        local wvy = (sec  == "UP"    and 1) or (sec  == "DOWN" and -1) or 0
        local nx, ny = AnchorNudge(buffAnchor)
        local anchorParent = frame
        if db.aurasAbovePowerBar and frame.powerBar and frame.powerBar:IsShown() and frame.healthBar
           and (buffAnchor == "BOTTOM" or buffAnchor == "BOTTOMLEFT" or buffAnchor == "BOTTOMRIGHT") then
            anchorParent = frame.healthBar
        end

        -- The row: Before band, then After band. Band 2 -- the host's own
        -- content, i.e. the generic dummies -- is deliberately EMPTY here (see
        -- the ruling above), so the two bands sit next to each other. The
        -- entries are already sorted within each band by _SBItemLess, so this
        -- is a straight partition. Truncated to the pool rather than grown --
        -- the pool is already sized for the live maximum.
        local seq, nSeq = {}, 0
        if sbItems then
            for i = 1, #sbItems do
                if sbItems[i].band == 1 then nSeq = nSeq + 1; seq[nSeq] = sbItems[i] end
            end
            for i = 1, #sbItems do
                if sbItems[i].band ~= 1 then nSeq = nSeq + 1; seq[nSeq] = sbItems[i] end
            end
        end
        if nSeq > MAX_BUFFS then nSeq = MAX_BUFFS end

        local primC, secC, rowMax, col = 0, 0, 0, 0
        local slot = 0
        for i = 1, nSeq do
            local it = seq[i]
            if col >= perRow then
                secC = secC + rowMax + rowSp
                primC, rowMax, col = 0, 0, 0
            end
            -- Every element of `seq` is an entry now (band 2 is empty), so
            -- there is no base-dummy arm below any more.
            local isz = BF:PixelRound(
                self:ResolveContainerGeometry(it.c, groupTypeKey, ac, nil) or bSize)
            local px = (primC * pvx) + (secC * wvx) + buffOffX + nx
            local py = (primC * pvy) + (secC * wvy) + buffOffY + ny
            local icon = frame.buffFrames[slot + 1]
            local painted = false
            if icon then
                painted = _PaintSingleBuffDummy(self, frame, icon, it, isz, ac,
                    groupTypeKey, ApplyDummyIcon, bR, bG, bB, bA,
                    "Setup Mode: " .. (it.c.name or tostring(it.sid)))
                if painted then
                    slot = slot + 1
                    icon:ClearAllPoints()
                    icon:SetPoint(buffAnchor, anchorParent, buffAnchor, px, py)
                    icon.SF_LastIndex = slot
                else
                    -- Unresolvable icon texture (no art for the spell ID). The
                    -- slot is NOT consumed and the cursor does NOT advance, so
                    -- the next entry takes this position -- an entry that
                    -- cannot draw must not leave a hole in the flow. Cleared
                    -- because the trailing sweep starts past `slot` and would
                    -- otherwise skip an icon this pass left shown.
                    if BF.ClearPreviewIconEffectFx then BF.ClearPreviewIconEffectFx(icon) end
                    icon:Hide()
                end
            end
            if painted then
                primC = primC + isz + spacing
                if isz > rowMax then rowMax = isz end
                col = col + 1
            end
        end
        for idx = slot + 1, MAX_BUFFS do
            local icon = frame.buffFrames[idx]
            if icon and icon:IsShown() then
                if BF.ClearPreviewIconEffectFx then BF.ClearPreviewIconEffectFx(icon) end
                icon:Hide()
            end
        end
        return
    end
    -- ── end BUFF LIST MERGE; the uniform grid below is unchanged ──────────

    for idx = 1, numToShow do
        local icon = frame.buffFrames[idx]
        if icon then
            ApplyDummyIcon(icon, DUMMY_BUFF_ICONS[((idx - 1) % #DUMMY_BUFF_ICONS) + 1], bR, bG, bB, bSize, showDuration, swipeDisabled, sparkDisabled, reverseSwipe, bfFont, bfSize, bfBorder, bfScale, bA, ac.buffFontColor, nil, ac.expiringCurveBuff, ac.buffBorderThickness, DummyBorderStyle(ac.buffBorderStyle, ac.buffBlizzardBorders), nil)
            -- v94: a plain dummy must not inherit icon-effect fx a single buff
            -- left on this pool slot. Reachable WITHOUT any mode change -- an
            -- entry re-anchored away from Buffs, blacklisted, or disabled empties
            -- the merge bucket and drops the row straight back onto this path,
            -- with no PreviewIconEffects_ClearAll in between.
            if BF.ClearPreviewIconEffectFx then BF.ClearPreviewIconEffectFx(icon) end
            icon:ClearAllPoints()
            local off = buffOffsets[idx]
            if off then
                local anchorParent = frame
                -- BOTTOM-anchor gate: lifting above the power bar only makes
                -- sense when icons grow from the bottom edge of the health bar.
                if db.aurasAbovePowerBar and frame.powerBar and frame.powerBar:IsShown() and frame.healthBar
                   and (buffAnchor == "BOTTOM" or buffAnchor == "BOTTOMLEFT" or buffAnchor == "BOTTOMRIGHT") then
                    anchorParent = frame.healthBar
                end
                icon:SetPoint(buffAnchor, anchorParent, buffAnchor, off.x + buffOffX, off.y + buffOffY)
            end
            SetDummyTooltip(icon, "Setup Mode: Buffs")
            icon.SF_LastIndex = idx
        end
    end
    for idx = numToShow + 1, MAX_BUFFS do
        local icon = frame.buffFrames[idx]
        if icon and icon:IsShown() then
            if BF.ClearPreviewIconEffectFx then BF.ClearPreviewIconEffectFx(icon) end
            icon:Hide()
        end
    end
end

-- ============================================================
-- v92 §B7.2: forward declarations for the general-container preview
-- helpers, which are defined ~600 lines below next to the rest of that
-- painter. _ShowDummyDebuffs is the SINGLE assembler for the Debuffs row
-- now -- base dummies PLUS one inline icon per preset of every
-- DEBUFFS-anchored debuff container, merged at Debuff Category Priority
-- rank positions in ONE cursor pass -- so it has to reach that pool from
-- up here. It must live here and not in the container painter, because
-- RefreshPreviewDummyDebuffs repaints the row in isolation; inline icons
-- owned by the container pass would desync on a debuffs-only refresh.
--
-- Declared as LOCALS (and assigned, not re-declared, below): a plain
-- global would be nil at the time this function's body is compiled.
-- ============================================================
local _ensurePreviewContainerIcon, _hidePreviewContainerSlots
local _paintPreviewContainerIcon, _debuffPresetPreviewList

-- ============================================================
-- v94: BUFF LIST PREVIEW (_PLAN_BuffListPreview.md)
--
-- The Buff List subtab previews the entries the LIST is showing, each at the
-- position its own anchor names. This is a preview-only painter like every
-- other _ShowDummy* helper: ordinary frames from BuildAuraIconFrame, painted
-- by ApplyDummyIcon, reading settings through the same resolvers the live
-- path reads. It creates no engine container, no aura group and no candidate
-- filter, and it never runs on a live frame.
--
-- WHY THE ENTRIES MERGE INTO THE EXISTING ROWS rather than getting a painter
-- of their own: the Buff List reports BF._currentSection == "auras" (both
-- aura sections do), so customAurasOnly is FALSE here and the normal buffs
-- row, Big Defensive dummy, debuff row and dispel simulation are all still on
-- screen. A separate painter would have to fight them for the same slots. So
-- _ShowDummyBuffs and _ShowDummyBigDef become the single assemblers for their
-- rows, exactly as _ShowDummyDebuffs became for the debuff row in v92.
-- ============================================================

-- Sort key for one bucket: Before band, then the host's own content, then
-- After. Mirrors the layoutIndex bands the live path emits (Buffs_Row_Target_
-- Matrix.md rows 2 / 13 / 14 -- Before 1..499, host content in the middle,
-- After 2500+) without reproducing the numbers, because the preview needs the
-- resulting SEQUENCE and nothing else.
--
-- An entry with no Order sorts after the ordered ones within its own band
-- (matrix row 4's `order = 99` rule), with the entry key as the stable
-- tiebreak so two unordered entries never swap places between repaints.
local function _SBItemLess(a, b)
    if a.band  ~= b.band  then return a.band  < b.band  end
    if a.order ~= b.order then return a.order < b.order end
    return a.key < b.key
end

-- Collect the single buffs this preview pass should draw, bucketed by anchor
-- host and sorted within each bucket.
--
-- Returns nil when there is nothing to draw -- which is the common case (every
-- frame, every subtab but this one) and must therefore cost almost nothing:
-- the mode check is the first thing that runs.
--
-- Buckets: `buffs`, `bigDef`, `byCI[ci]`, `floating`. Callers read the one
-- bucket they own.
-- Is the Buff List preview mode BOTH set and still valid?
--
-- v94 review finding: "set" alone is not enough. The mode is stamped by the
-- Buff List's tracker, but not every way out of that subtab clears it -- the
-- Aura Cooldown Text section moves BF._currentSection without touching the
-- container index, and a custom DEBUFF container's tab moves the container
-- index while only clearing a containerMgmt preview. Either exit used to be
-- harmless because the tracker cleared unconditionally; with a mode that
-- SURVIVES, a stale one keeps painting single buffs (and one entry's frame
-- effects) on a pane that has nothing to do with them.
--
-- So the mode self-expires against the two flags the Buff List stamps on every
-- feed and other trackers move on arrival: the section, and the "many
-- containers" sentinel it puts in BF._currentContainerIndex. Both are already
-- maintained; this only reads them. A tracker that forgets to clear can
-- therefore only ever fail SAFE.
local function _BuffListPreviewActive(self)
    if not (self.IsPreviewingBuffList and self:IsPreviewingBuffList()) then return false end
    -- Against the section the Buff List STAMPED, never a literal: the subtab is
    -- built once per host, so its section is "auras" on Raid/Party and
    -- "customFrameAuras" on Custom Frame Groups (Options_Auras.lua:775-777).
    -- Hard-coding "auras" here disabled the whole feature on the CFG page.
    if BF._buffListSection == nil then return false end
    if BF._currentSection ~= BF._buffListSection then return false end
    local sentinel = BF.SINGLE_BUFF_SUBTAB_SENTINEL
    if sentinel ~= nil and BF._currentContainerIndex ~= sentinel then return false end
    return true
end

_SingleBuffPreviewItems = function(self, frame, ac, groupTypeKey)
    -- Preview frames only. Setup-mode test frames show the plain dummies and
    -- must be untouched by anything the options tree is doing.
    if not frame._isPreviewFrame then return nil end
    if not _BuffListPreviewActive(self) then return nil end

    local filter = self:GetBuffListPreviewFilter()
    local selKey = self:GetBuffListPreviewKey()
    -- Filter by Spec = All. "Every whitelisted buff at once" is not a preview,
    -- so All draws only the selected entry -- and nothing when there is no
    -- selection (plan §1.1, owner ruling).
    local onlySel = (filter == 0)
    if onlySel and not selKey then return nil end

    -- The CACHED accessor, which is what _paintContainerKind is handed -- it is
    -- a memo of GetCustomBuffContainers, so it is the same array with the same
    -- indices. That identity is load-bearing: the `ci` recorded here is looked
    -- up against the painter's own loop index.
    local all = self.GetActiveCustomBuffContainers and self:GetActiveCustomBuffContainers() or nil
    if not all then return nil end

    local out, n = nil, 0
    for ci = 1, #all do
        local c = all[ci]
        local take = c and c.singleBuff and type(c.singleBuffKey) == "string"
        -- Blacklisted entries render nothing in game, so they preview nothing.
        if take and c.singleBuffHidden then take = false end
        -- A globally disabled entry is off everywhere.
        if take and c.enabled == false then take = false end
        if take and onlySel and c.singleBuffKey ~= selKey then take = false end
        if take and not onlySel then
            take = (self.SingleBuffMatchesSpecFilter
                and self:SingleBuffMatchesSpecFilter(c, filter)) or false
        end
        -- Pseudo entries (a Buff List row hosting a feature's settings) report
        -- no spell to the aura engine on purpose, so there is nothing to draw.
        local sid = take and self.GetSingleBuffSpellID and self:GetSingleBuffSpellID(c) or nil
        if take and sid then
            local rel  = self:GetSingleBuffRelativeOrder(c, groupTypeKey)
            local ord  = self:GetSingleBuffOrder(c)
            local item = {
                c = c, ci = ci, sid = sid, key = c.singleBuffKey,
                sel = (c.singleBuffKey == selKey),
                -- Band 1 = Before, 3 = After. The host's own content is band 2,
                -- which no single buff occupies -- it is what they straddle.
                band = (rel == "AFTER") and 3 or 1,
                -- No Order sorts last within its band.
                order = ord or math.huge,
            }
            -- The anchor decides the bucket. Resolved through the SAME helper
            -- the live path uses -- never by reading c.anchorPoint here, which
            -- would miss the per-Layout tier. The descriptor is interned and
            -- re-pointed per call, so its fields are read immediately.
            local host = self.GetSingleBuffAnchorHost and self:GetSingleBuffAnchorHost(c, groupTypeKey)
            local bucket
            if host then
                if host.kind == "buffs" then bucket = "buffs"
                elseif host.kind == "bigDef" then bucket = "bigDef"
                elseif host.kind == "bfc" then bucket = host.ci end
            end
            -- No flow host = a real frame point: the entry floats at its own
            -- configured position and gets an icon of its own.
            if bucket == nil then bucket = "floating" end
            out = out or { buffs = {}, bigDef = {}, floating = {}, byCI = {} }
            local list
            if type(bucket) == "number" then
                list = out.byCI[bucket]
                if not list then list = {}; out.byCI[bucket] = list end
            else
                list = out[bucket]
            end
            list[#list + 1] = item
            n = n + 1
        end
    end
    if not out then return nil end
    if n > 1 then
        table.sort(out.buffs,    _SBItemLess)
        table.sort(out.bigDef,   _SBItemLess)
        table.sort(out.floating, _SBItemLess)
        for _, list in pairs(out.byCI) do table.sort(list, _SBItemLess) end
    end
    return out
end

-- ── 2026-09-14 (owner ruling): THE CONTAINER TAB'S PREVIEW ────────────────
-- While a buff container's own tab is open (containerMgmt preview mode, the
-- index stamped on arrival), THAT container previews the buffs anchored to
-- it: at most CONTAINER_PREVIEW_MAX of them, the current spec's first --
-- entries whose Spec condition is met on the player's spec, then the rest,
-- each run in the row's own Before/Order/After sequence. The assignment
-- model this preview used to read (spellAssign "c:<i>") is retired; the
-- anchored entries ARE the container's content now.
--
-- Its own collector rather than a mode inside _SingleBuffPreviewItems: the
-- buffs-row assembler merges THAT function's `buffs` bucket into the Buffs
-- row, and a container tab has no entries for that row -- as of 2026-09-15
-- the row itself is hidden there (BuildSharedState's containerTabOnly), and
-- the container tab previews the viewed container alone. Only
-- _paintContainerKind asks this one, and it answers a set of the same shape
-- (byCI / floating) with just the one container's bucket filled.
local CONTAINER_PREVIEW_MAX = 4

local function _ContainerTabPreviewItems(self, frame, ac, groupTypeKey)
    if not frame._isPreviewFrame then return nil end
    if not (self.IsPreviewingContainerMgmt and self:IsPreviewingContainerMgmt()) then
        return nil
    end
    local cmCI = self.GetPreviewContainerIndex and self:GetPreviewContainerIndex()
    if not cmCI then return nil end
    local all = self.GetActiveCustomBuffContainers and self:GetActiveCustomBuffContainers() or nil
    local host = all and all[cmCI]
    if not (type(host) == "table" and not host.singleBuff) then return nil end

    local list = nil
    for ci = 1, #all do
        local c = all[ci]
        local take = c and c.singleBuff and type(c.singleBuffKey) == "string"
            and not c.singleBuffHidden and c.enabled ~= false
        local sid = take and self.GetSingleBuffSpellID and self:GetSingleBuffSpellID(c) or nil
        if take and sid then
            -- The SAME resolver the live path uses, so the per-Layout tier
            -- of the anchor is honored; the descriptor is interned, so its
            -- fields are read at once.
            local h = self.GetSingleBuffAnchorHost and self:GetSingleBuffAnchorHost(c, groupTypeKey)
            if h and h.kind == "bfc" and h.ci == cmCI then
                local rel = self:GetSingleBuffRelativeOrder(c, groupTypeKey)
                local ord = self:GetSingleBuffOrder(c)
                list = list or {}
                list[#list + 1] = {
                    c = c, ci = ci, sid = sid, key = c.singleBuffKey,
                    sel = false,
                    band  = (rel == "AFTER") and 3 or 1,
                    order = ord or math.huge,
                    -- The current spec's entries come first.
                    specMet = self:IsSingleBuffSpecMet(c) and 0 or 1,
                }
            end
        end
    end
    if not list then return nil end
    table.sort(list, function(a, b)
        if a.specMet ~= b.specMet then return a.specMet < b.specMet end
        return _SBItemLess(a, b)
    end)
    for i = #list, CONTAINER_PREVIEW_MAX + 1, -1 do list[i] = nil end
    -- Back in the row's own sequence for the run that survived the cap.
    table.sort(list, _SBItemLess)
    return { buffs = {}, bigDef = {}, floating = {}, byCI = { [cmCI] = list } }
end

-- Paint ONE single-buff entry onto a preview icon at the given size.
--
-- The icon-level visual resolvers are already single-buff aware: every one of
-- them takes an optional `sbC` container and reads that entry's own store
-- instead of the curated acDB tables (AuraCustomizationHelpers.lua header).
-- So this is a mapping from those resolvers onto ApplyDummyIcon's argument
-- list -- the single-buff twin of what _paintPreviewContainerIcon does with
-- the BF:ResolveContainer* family -- and NOT a second interpretation of the
-- settings.
--
-- An entry in "Show (Default Buff)" mode needs no branch: SBRoot returns nil
-- for it, so every resolver below yields nil and the row's own defaults apply,
-- which is exactly what that mode does in game.
_PaintSingleBuffDummy = function(self, frame, icon, item, size, ac, groupTypeKey,
                                ApplyDummyIcon, defR, defG, defB, defA, tooltip)
    local c, sid = item.c, item.sid

    -- ── ICON TYPE ─────────────────────────────────────────────────────────
    -- Same read-time legacy mapping DeriveSpellButtonSpec does: the retired
    -- "BorderedSquare" type is Square + border forced on, "SquareDuration" is
    -- Square (its glyph path re-activates from thresholdEnabled).
    local ity = self.GetSpellIconType and self.GetSpellIconType(sid, c)
    local legacyBordered = (ity == "BorderedSquare")
    if legacyBordered or ity == "SquareDuration" then ity = "Square" end
    local isSquare = (ity == "Square")

    local solid = self.GetSolidIconColor and self.GetSolidIconColor(sid, c)
    -- The Square type's two RENDER PATHS, read exactly as DeriveSpellButtonSpec
    -- reads them (same accessor, same fallback entry):
    --   thresholdEnabled OFF -> a static solid fill; cooldown text sits on top.
    --   thresholdEnabled ON  -> "Change color based on remaining time": the
    --                           square IS the duration display, drawn as the
    --                           duration text in an all-square glyph font and
    --                           colored by the solid-icon curve, over an
    --                           alpha-0 icon region.
    -- The second is why durationSquare has to suppress the cooldown text below:
    -- a separate number painted on top is a second timer the live path never
    -- draws, and the Cooldown Text subtab is hidden for this type precisely
    -- because its settings do not apply.
    local squareEntry = solid or { r = 0, g = 0.7, b = 1, a = 1 }
    local durationSquare = isSquare and squareEntry.thresholdEnabled and true or false
    local tex
    if isSquare then
        -- The Square type draws a flat fill, not the spell art.
        tex = "Interface\\Buttons\\WHITE8x8"
    else
        tex = C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(sid)
    end
    if not tex then return false end

    -- ── BORDER ────────────────────────────────────────────────────────────
    -- Mirrors ResolveSpellButtonBorder (Indicators/BuffsAndContainers.lua),
    -- which is file-local there and so cannot be called: same inputs, same
    -- order, same fallbacks. The BASE is the row's own resolved default
    -- (passed in by the caller, from GetDefaultBorderColorFor) rather than a
    -- second read of ac.buffBorderColor, so an inheriting entry matches the
    -- dummies beside it exactly.
    local sh = self.GetSpellBorderShape and self.GetSpellBorderShape(sid, c)
    local perSpellColor = self.GetSpellBorderColor and self.GetSpellBorderColor(sid, c)
    local bStyle, bThick
    local bR, bG, bB, bA = defR, defG, defB, defA
    local inherit = (not legacyBordered)
        and self.UseBuffsBorderOn and self.UseBuffsBorderOn(sh, isSquare)
    if inherit then
        bStyle = DummyBorderStyle(ac.buffBorderStyle, ac.buffBlizzardBorders)
        bThick = ac.buffBorderThickness
    else
        -- showBorder: Square has the toggle; an opted-out Icon always draws
        -- its own border (v87), so it is implicitly true there.
        local showBorder = legacyBordered or (not isSquare) or (sh and sh.showBorder) or false
        if not showBorder then
            bStyle, bThick = "flat", 0
        else
            bStyle = DummyBorderStyle(sh and sh.borderStyle, false)
            bThick = (sh and sh.borderThickness) or ac.buffBorderThickness
        end
        if perSpellColor then
            bR, bG, bB = perSpellColor.r or bR, perSpellColor.g or bG, perSpellColor.b or bB
            bA = perSpellColor.a or bA
        end
    end

    -- ── COOLDOWN TEXT ─────────────────────────────────────────────────────
    -- Through the shared per-spell resolver, which already takes sbC. Field
    -- names are its own (showDur / durationFont / durationBorder / ...), and
    -- the unpack mirrors the container arm's ResolveContainerDuration read so
    -- the two cannot drift.
    local showDuration = ac.showBuffDuration
    local autoScale    = ac.buffAutoScale
    local dFont        = ac.buffDurationFont
    local dFontSize    = ac.buffFontSize or 11
    local dBorder      = ac.buffDurationBorder or "OUTLINE"
    local dTimerScale  = ac.buffTimerScale or 1.0
    local dFontColor   = ac.buffFontColor
    local dSwipe       = ac.disableBuffSwipe or false
    local dSpark       = ac.disableBuffSpark or false
    local dRev         = ac.reverseBuffSwipe == true
    local dCurve       = ac.expiringCurveBuff
    local ct = self.ResolveSpellCooldownText
        and self.ResolveSpellCooldownText(sid, groupTypeKey, ac, c)
    if ct then
        showDuration, autoScale = ct.showDur, ct.autoScale
        dFont, dFontSize = ct.durationFont, ct.fontSize or 11
        dBorder, dTimerScale = ct.durationBorder or "OUTLINE", ct.timerScale or 1.0
        dFontColor, dSwipe, dSpark = ct.fontColor, ct.swipeDis, ct.sparkDis
        dRev, dCurve = ct.revSwipe, ct.expCurve
    end
    local bfSize  = autoScale and 11 or dFontSize
    local bfScale = autoScale and (size / 12 * (dTimerScale or 1.0)) or 1.0

    -- ── SQUARE (COLOR BY DURATION) ────────────────────────────────────────
    -- Reproduced, not approximated. The live path draws this square as the
    -- DURATION TEXT in an all-square glyph font over an alpha-0 icon region,
    -- colored by the solid-icon threshold curve -- and a color curve binds
    -- to a FontString, so a tinted texture (what this painter drew before)
    -- could never carry one. Wearing the same font is what lets the preview
    -- run the SAME curve machinery the ordinary duration text already uses
    -- here: ApplyDummyIcon winds a fake C_DurationUtil duration and hands it
    -- to BF.UpdateIconColorCurve, so the square colors by remaining time
    -- exactly as it does live.
    --
    -- THE GLYPH GETS ITS OWN FONTSTRING, with CONSTANT text. It must not
    -- borrow the engine countdown string (cd:GetCountdownFontString), which is
    -- what an earlier cut did: the engine writes the literal remaining time,
    -- so "30" is TWO characters and drew TWO squares, collapsing to one at
    -- "9". (Owner-reported as "shows multiple times above the first
    -- threshold" -- the threshold was a coincidence, the variable is DIGIT
    -- COUNT, and the two happen to change at about the same second.)
    --
    -- This is exactly why the live path never uses the countdown either: it
    -- drives its own FontString through SetDurationText with
    -- DURATION_RULE_FORMATTER_SQUARE, whose only breakpoint is
    -- { threshold = 0, format = "#" } -- one character at EVERY duration. A
    -- constant string here is the same guarantee by simpler means, and it does
    -- not care how many digits the number has.
    --
    -- Threshold coloring still works because BF.UpdateIconColorCurve colors
    -- whatever icon.colorCurveText points at, in Lua (AuraConfig.lua,
    -- ApplyColors) -- so the pointer is moved to this FontString below.
    --
    -- This block WINS over every cooldown-text setting resolved above, the
    -- same precedence and for the same reason as DeriveSpellButtonSpec's
    -- durationSquare block: inherited or stale Cooldown Text settings must not
    -- restyle or blank a square that is itself the timer.
    local squareScale
    if durationSquare then
        local roundedBorder = (bStyle == "rounded" or bStyle == "rounded_thick")
        dFont = (roundedBorder and BF.SQUARE_GLYPH_FONT_ROUND) or BF.SQUARE_GLYPH_FONT
        bfSize = BF.SQUARE_GLYPH_FONT_BASE or 12
        dBorder = ""                          -- an outline would fatten the square
        showDuration = true                   -- hidden text = no square at all
        dSwipe, dSpark = true, true           -- the square's color IS the timer
        -- The square's static / above-threshold color is the SOLID ICON
        -- color, never the cooldown font color -- the live block re-resolves
        -- it for exactly this reason, since the resolve above may have
        -- replaced fontColor.
        dFontColor = {
            r = squareEntry.r or 0, g = squareEntry.g or 0.7,
            b = squareEntry.b or 1, a = squareEntry.a or 1,
        }
        dCurve = self.GetSolidIconColorCurve and self.GetSolidIconColorCurve(sid, c) or nil
        -- SquareGlyphScale, live rule: fill the button minus the solid-edge
        -- border band, so the square sits INSIDE the border rather than
        -- underlapping it. Rounded styles never inset -- their ring hangs
        -- OUTSIDE the button and the rounded glyph fills it edge to edge.
        -- PixelRound'd because the client rasterizes the em box in physical
        -- pixels and a FontString cannot snap to the grid (the v93 fix).
        local inset = 0
        if not roundedBorder and bThick and bThick > 0 then
            inset = BF:PixelsToUI(bThick)
        end
        local sq = BF:PixelRound(size - 2 * inset)
        if sq < 1 then sq = 1 end
        squareScale = sq / (BF.SQUARE_GLYPH_FONT_BASE or 12)
        bfScale = squareScale
    end

    ApplyDummyIcon(icon, tex, bR, bG, bB, size, showDuration,
        dSwipe, dSpark, dRev, dFont, bfSize, dBorder, bfScale,
        bA, dFontColor, nil, dCurve, bThick, bStyle, nil)

    -- The Square fill color. ApplyDummyIcon has no solid-icon parameter, so
    -- it is tinted onto the flat texture chosen above -- which is what the
    -- live solidIcon path paints too. `enabled == false` means the fill is
    -- off, and GetSolidIconColor has already returned nil for that.
    if durationSquare then
        -- The glyph IS the icon, so the icon region shows nothing -- the live
        -- path expresses this as an alpha-0 solidIcon.
        if icon.Icon then
            icon.Icon:SetVertexColor(1, 1, 1)
            icon.Icon:SetAlpha(0)
        end
        -- Center the glyph on the (now invisible) icon region, with the live
        -- path's 0.4 px correction. SetPoint offsets resolve in the
        -- FontString's OWN scaled space, so the correction is divided by the
        -- scale and the points must be re-stamped whenever the scale moves --
        -- which is every repaint here.
        local cd = icon.cooldown
        local glyph = icon._bf_sbSquareGlyph
        if cd and not glyph and squareScale and squareScale > 0 then
            -- Created once per pooled icon and kept. Hosted on the cooldown at
            -- the same draw layer the countdown text uses, so it sits above
            -- the (disabled) swipe like the live square does.
            glyph = cd:CreateFontString(nil, "OVERLAY")
            glyph:SetDrawLayer("OVERLAY", 7)
            icon._bf_sbSquareGlyph = glyph
        end
        if glyph and squareScale and squareScale > 0 then
            -- The engine's own countdown must not draw underneath: it would
            -- render the remaining time as a SECOND run of squares, which is
            -- the bug this FontString exists to remove.
            if cd.SetHideCountdownNumbers then cd:SetHideCountdownNumbers(true) end
            glyph:SetFont(dFont, bfSize, "")
            glyph:SetScale(squareScale)
            glyph:SetJustifyH("CENTER")
            glyph:SetJustifyV("MIDDLE")
            -- Constant, one character, at every duration.
            glyph:SetText("#")
            glyph:SetTextColor(dFontColor.r, dFontColor.g, dFontColor.b, dFontColor.a or 1)
            -- Center on the (now invisible) icon region with the live path's
            -- 0.4 px correction. SetPoint offsets resolve in the FontString's
            -- OWN scaled space, so the correction is divided by the scale and
            -- the points are re-stamped whenever the scale moves -- every
            -- repaint here.
            local anchorTo = icon.Icon or icon
            pcall(function()
                glyph:ClearAllPoints()
                glyph:SetPoint("CENTER", anchorTo, "CENTER", 0.4 / squareScale, 0)
            end)
            glyph:Show()
            -- Re-point the threshold curve at the glyph. ApplyDummyIcon bound
            -- it to the countdown text a moment ago; the poll reads
            -- icon.colorCurveText every tick, so moving the pointer is the
            -- whole of it -- and the immediate re-run stops the square showing
            -- its base color for one poll interval.
            if dCurve and icon.colorCurveObject then
                icon.colorCurveText = glyph
                local durObj = icon._bf_dummyDurObj
                if durObj and BF.UpdateIconColorCurve then
                    BF.UpdateIconColorCurve(icon, durObj)
                end
            end
            icon._bf_sbSquareText = true
        end
    else
        -- ApplyDummyIcon has already reset the region to opaque white, so only
        -- the static Square's own fill needs painting here.
        if isSquare and icon.Icon then
            -- v94: ALPHA included. It was dropped by a three-argument
            -- SetVertexColor, so an Icon Color set fully or partly transparent
            -- still painted opaque. The live solid-icon path carries `a` (the
            -- spec stores the whole entry, and RenderContainerIcons paints
            -- SetColorTexture(r, g, b, a or 1)), so the preview must too.
            icon.Icon:SetVertexColor(squareEntry.r or 0, squareEntry.g or 0.7,
                squareEntry.b or 1, squareEntry.a or 1)
        end
        -- No un-sticking needed here: ApplyDummyIcon has already restored the
        -- glyph anchoring for every caller (see the note there).
    end

    -- ICON EFFECTS. The painting half already exists and is already shared
    -- with the container preview (BF.PaintPreviewIconEffectFx); only the
    -- CONFIG lookup differs, and GetSpellIconEffect already takes sbC.
    local ie = self.GetSpellIconEffect and self.GetSpellIconEffect(sid, c)
    if ie and ie.enabled ~= false then
        if self.PaintPreviewIconEffectFxTracked then
            self.PaintPreviewIconEffectFxTracked(icon, ie)
        end
    elseif self.ClearPreviewIconEffectFx then
        self.ClearPreviewIconEffectFx(icon)
    end

    SetDummyTooltip(icon, tooltip or ("Setup Mode: " .. (c.name or tostring(sid))))
    return true
end

-- Hide -- and forget -- every inline container slot the LAST row pass
-- painted. Used by the row-hidden early-out: with the Debuffs display off
-- there is no row to flow into, so a Debuffs-anchored container shows
-- nothing, exactly like the runtime (its groups live inside that row).
-- Debuffs-row sort order: rank asc, then base dummies (sub 0) ahead of inline
-- container icons (sub 1) at an equal rank, then record / canonical-preset
-- order. The same rank -> position semantics as ShapeEntryLess
-- (Indicators/DebuffIcons.lua), without invoking the live resolver.
-- File-local so the row pass does not allocate a fresh closure per repaint --
-- and it is a pure comparator over the item fields, so it needs no upvalues.
local function _RowItemLess(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    if a.sub  ~= b.sub  then return a.sub  < b.sub  end
    return a.seq < b.seq
end

local function _HideRowOwnedInlineSlots(frame)
    local owned = frame._bf_rowOwnedCI
    if not owned then return end
    for ci in pairs(owned) do
        _hidePreviewContainerSlots(frame, "debuff", ci, 1)
    end
    frame._bf_rowOwnedCI = nil
end

-- ============================================================
-- _ShowDummyDebuffs(self, frame, s)
-- Paint the dummy debuff icons on a preview/test frame, plus the inline
-- icons of every Debuffs-anchored custom debuff container (v92 §B7.2).
-- Also updates the stack-count text on the first debuff icon (stack text
-- renders only on debuff pool index 1 in the preview -- which after
-- §B7.1 is whichever dummy SORTED first, not a fixed record).
-- ============================================================
-- 2026-08-25: grow the DUMMY debuff pool to what this pass needs. The pool is
-- built once at BF.MAX_DEBUFFS (8) with the buff / big-def pools; per-group
-- counting can want more than that, and the painter's `if icon then` guard
-- would otherwise DROP the surplus silently -- a preview quietly missing its
-- lowest-ranked group. Preview/setup frames only (this file paints nothing
-- else), lazy (only ever the shortfall), and permanent for the frame's life,
-- which is what makes it free on every later pass.
--
-- Returns the pool's high-water mark so the caller's trailing hide-sweep
-- covers icons a PREVIOUS, larger pass left shown.
local function _EnsureDummyDebuffPool(frame, want)
    local pool = frame.debuffFrames
    if not pool then return 0 end
    if want > MAX_PREVIEW_DEBUFFS then want = MAX_PREVIEW_DEBUFFS end
    local have = frame._bf_dummyDebuffPoolN or MAX_DEBUFFS
    if want > have then
        local level = frame:GetFrameLevel() + 223
        for i = have + 1, want do
            if not pool[i] then pool[i] = BuildAuraIconFrame(frame, level) end
        end
        frame._bf_dummyDebuffPoolN = want
        return want
    end
    return have
end

local function _ShowDummyDebuffs(self, frame, s)
    if not frame.debuffFrames then return end
    local db, debuffsP = s.db, s.debuffsP
    local showDebuffs = debuffsP.showDebuffs ~= false
    if s.dispelDebuffBorderOnly or s.customAurasOnly then showDebuffs = false end
    -- v70: preview frames gate on the active Preview dropdown (Debuffs side);
    -- setup-mode test frames keep the old showDummyDebuffs toggle.
    if s.pvIsPreview then
        if not s.pvShowDebuffs then showDebuffs = false end
    elseif showDebuffs and BF.db.global.showDummyDebuffs == false then
        showDebuffs = false
    end
    if not showDebuffs then
        -- 2026-08-25: to the pool's HIGH-WATER MARK, not the fixed 8 -- a
        -- previous pass may have grown it, and those icons must hide too.
        for i = 1, (frame._bf_dummyDebuffPoolN or MAX_DEBUFFS) do
            local icon = frame.debuffFrames[i]; if icon and icon:IsShown() then icon:Hide() end
        end
        -- v92 §B7.2: no row -> no inline icons either.
        _HideRowOwnedInlineSlots(frame)
        return
    end
    local ac            = BF:GetAuraCacheForFrame(frame)
    local dSize         = s.dSize
    local showDuration  = ac.showDebuffDuration
    local swipeDisabled = ac.disableDebuffSwipe or false
    local sparkDisabled = ac.disableDebuffSpark or false
    local reverseSwipe  = ac.reverseDebuffSwipe == true
    local autoScale     = ac.debuffAutoScale
    local bfFont        = ac.debuffDurationFont
    local bfSize        = autoScale and 11 or (ac.debuffFontSize or 11)
    local bfBorder      = ac.debuffDurationBorder or "OUTLINE"
    -- v92 §B7.1: the old row-global bfScale (dSize-derived) is gone -- the row
    -- is mixed-size now, so the duration-text scale is computed PER ICON below.
    -- v93: NOT clamped by ac.maxDebuffs. That key's slider was removed with the
    -- row-wide cap, and clamping the preview to a number the user can no longer
    -- see or edit is exactly the trap removing it was meant to avoid.
    --
    -- 2026-08-25 (owner ruling): previewDebuffCount is a PER-GROUP count, not a
    -- row total, and each group is additionally clamped by its OWN Max Debuffs
    -- -- "preview count for each group, or that group's Max, whichever is
    -- lower". So the row is no longer capped at MAX_DEBUFFS either: with three
    -- live groups at 3 apiece it is 9 icons, and the dummy pool grows to suit
    -- (see the ensure call after the item list is built).
    local perGroup = #DUMMY_DEBUFFS
    if frame._isPreviewFrame then
        -- Account-wide (db.global) -- see the previewBuffCount read in
        -- _ShowDummyBuffs above; declared default is 3.
        perGroup = BF.db.global.previewDebuffCount or 3
    end

    -- ── v92 §B7.1: RANK INPUTS ────────────────────────────────────────────
    -- The preview row is rank-ordered now, from the SAME inputs the live row
    -- reads: the Debuff Category Priority ranks (Combine flags already folded
    -- in by ComputeDebuffPresetRanks) and the container CLAIM map. A claimed
    -- type YIELDS -- its dummy falls back to a plain one at the `other` rank
    -- and base size, mirroring how ResolveDebuffShape parks a claimed group.
    -- Nothing here invokes the live resolver or touches a real frame.
    local groupTypeKey = frame._bf_containerGroupTypeKey or self:ResolveGroupTypeKey(frame)
    -- v92 (combined pairs, owner ruling 2026-08-20): resolve the Layout's pair
    -- OWNERSHIP once per paint and thread it through every claim / flow / preset
    -- read below, exactly as ResolveDebuffShape does for a live frame. A combined
    -- pair is one unit owned by the FIRST member's container, so this is what
    -- makes the preview's claims EFFECTIVE: the owner claims the partner too (the
    -- boss dummy must yield to a container that only stores `boss` when Boss/Role
    -- is combined), and an unowned pair is claimed by nobody, so both members
    -- render in the main row.
    --
    -- ComputeDebuffContainerClaims does NOT recompute this when the argument is
    -- nil -- it feeds `pairOwn` straight to EffectiveDebuffPresetSet, which reads
    -- STORED presets on nil. Passing it is mandatory, not an optimization.
    --
    -- `ac` (not the raw debuffs profile) is the flags table, matching the runtime
    -- call sites: UpdateDB writes real booleans for both combine keys into the
    -- cache (AuraConfig.lua), so PairCombineOn's nil-defaults never fire here and
    -- the preview cannot disagree with ComputeDebuffPresetRanks' own `== true`
    -- combine tests over the same cache.
    local pairOwn = BF._ResolveDebuffPairOwnership
        and BF._ResolveDebuffPairOwnership(ac, groupTypeKey) or nil
    -- 2026-08-25: claimSuffix is captured now (it used to be discarded) --
    -- BF._ResolveDebuffShape takes it, and the normal-mode branch below drives
    -- the whole row off that resolver.
    local claims, flowClaims, claimSuffix
    if BF._ComputeDebuffContainerClaims then
        local suffix, _, _, cl, fc = BF._ComputeDebuffContainerClaims(frame, groupTypeKey, pairOwn)
        claims, flowClaims, claimSuffix = cl, fc, suffix
    end
    local ranks = (BF._ComputeDebuffPresetRanks and BF._ComputeDebuffPresetRanks(ac)) or {}
    -- 2026-08-25: through the mode-aware resolver -- Simple Mode has its own
    -- rank keys (BF:DebuffRankOf, Indicators/DebuffIcons.lua).
    local otherRank = (BF.DebuffRankOf and BF:DebuffRankOf(ac, "other")) or 7

    -- One merged item list: base dummies (sub 0) + inline container icons
    -- (sub 1). `mult` is the size multiplier against dSize; `seq` is the
    -- record / canonical-preset order used as the rank tiebreak.
    local items, nItems = {}, 0

    -- v70/v92: dispellability is per RECORD now (it used to be one row-global
    -- boolean). Setup-mode test frames always simulate dispellable; preview
    -- frames read the Preview dropdown's simDispel bit.
    local simDispel = s.pvIsPreview and s.pvSimDispel or (not s.pvIsPreview)
    -- ── 2026-08-25: GROUP-DRIVEN, not record-driven ──────────────────────
    -- The row used to be built by walking previewDebuffCount records and asking
    -- each one "which type could you stand for?", which meant the preview could
    -- only ever show the types the four records happen to describe, showed no
    -- per-group Max at all, and in Simple Mode drew the normal-mode model
    -- outright.
    --
    -- Now it walks GROUPS and asks each one for icons. A group contributes
    -- min(perGroup, its own Max Debuffs) icons at its rank and Relative Size;
    -- a group that is off, or claimed by a custom debuff container, contributes
    -- NONE (the container renders its content, and in the preview that is the
    -- inline-icon pass below). The consequence worth stating plainly: the
    -- on-screen count no longer matches the slider -- the slider is per group
    -- now, so three live groups at 3 is nine icons.
    --
    -- SIMPLE MODE reads BF:ResolveSimpleDebuffRows (Indicators/DebuffIcons.lua)
    -- -- the ONE statement of that mode's group rule, shared with
    -- ResolveDebuffShape and the options page's row list, so the preview cannot
    -- drift from what actually renders.
    --
    -- NORMAL MODE drives off BF._ResolveDebuffShape -- the live resolver
    -- itself, not a restatement of it. This function used to hand-roll
    -- liveness and rank for three of the seven types, which is why Role, CC
    -- and Priority could never appear and why a combined pair, a
    -- force-included Priority+Other or a claimed group could each be drawn
    -- differently here than on a real frame. Its `entries` already carry
    -- exactly what an item needs (id, live, rank, sub, mult) in the order
    -- ShapeEntryLess resolved.
    local groups, nGroups = {}, 0
    local simpleShape = ac.debuffSimpleMode == true
    -- `sub` is the shape's own rank tiebreak (0/1) -- it is what keeps a
    -- force-included Priority group flowing immediately AHEAD of the residual
    -- they share a rank with. Defaults to 0 for callers that have no opinion.
    local function addGroup(id, live, rank, mult, sub)
        if not live then return end
        local n = perGroup
        local cap = BF.ResolveDebuffTypeMax and BF:ResolveDebuffTypeMax(ac, id)
        if cap and cap < n then n = cap end
        if n < 1 then return end
        nGroups = nGroups + 1
        groups[nGroups] = {
            id = id, n = n, rank = rank, mult = mult, sub = sub or 0,
            label = (simpleShape and DUMMY_GROUP_LABEL_SIMPLE[id])
                or DUMMY_GROUP_LABEL[id] or "Debuffs",
        }
    end
    if simpleShape and BF.ResolveSimpleDebuffRows then
        -- rows are the LIVE ones already, in rank order, carrying the resolved
        -- rank / mult / max -- so `live` is true by construction here and the
        -- cap re-resolves to the same number the row already holds.
        local rows = BF:ResolveSimpleDebuffRows(ac, claims)
        for i = 1, #rows do
            local r = rows[i]
            addGroup(r.id, true, r.rank, r.mult)
        end
    elseif BF._ResolveDebuffShape then
        local flowSetN, flowSigN
        if flowClaims and BF._ComputeDebuffFlowSet then
            flowSetN, flowSigN = BF._ComputeDebuffFlowSet(ac, groupTypeKey, flowClaims, pairOwn)
        end
        local shape = BF._ResolveDebuffShape(frame, ac, claimSuffix, claims,
                                             flowSetN, flowSigN)
        local order = shape and shape.order
        for i = 1, (order and #order or 0) do
            local e = order[i]
            -- FLOWED entries are the inline container pass's business below --
            -- they draw in the container's own preview slots, not from this
            -- row's pool -- and a parked entry (claimed, or its type switched
            -- off) renders nothing anywhere.
            if e.live and not e.flowed then
                addGroup(e.id, true, e.rank, e.mult or 1, e.sub or 0)
            end
        end
    else
        -- Resolver unavailable (load-order belt and braces): the residual row
        -- alone, so the preview is sparse rather than empty.
        addGroup("other", ac.debuffShowOther ~= false, otherRank, 1)
    end
    -- Which dummy record stands for each group. Boss has exactly one piece of
    -- art; the dispel arms and the residual row cycle the three dispellable
    -- records, the two arms offset so they do not read as the same group.
    -- `seq` is the rank TIEBREAK, so it counts within the whole row, not within
    -- the group -- two groups at the same rank then interleave by the order
    -- their groups were added, which is the canonical order above.
    local seq = 0
    for gi = 1, nGroups do
        local g = groups[gi]
        local cycle = DUMMY_GROUP_RECORDS[g.id] or DUMMY_GROUP_RECORDS.other
        -- 2026-08-25 (owner request): ONLY the dispel arms show dispel typing.
        -- The residual Other row cycles the same dispellable records for its
        -- art, but a dispel-type badge and a per-type border color there said
        -- "this is a dispellable debuff" about a group that is not the dispel
        -- group -- and with both arms live it made three groups look alike.
        -- Forced false here rather than by giving Other its own records: the
        -- painter already draws a non-dispellable dummy correctly (configured
        -- Debuff Border Color, no corner badge, duration text on Font Color),
        -- so this is the one bit that had to change. Boss was never
        -- dispellable, so it is unaffected.
        local typed = (g.id == "dispMe" or g.id == "dispOthers")
        for i = 1, g.n do
            local rec = DUMMY_DEBUFFS[cycle[((i - 1) % #cycle) + 1]]
            seq = seq + 1
            nItems = nItems + 1
            items[nItems] = {
                rec = rec, rank = g.rank, sub = g.sub, seq = seq, mult = g.mult,
                label = g.label,
                dispellable = (typed and rec.dispellable and simDispel) and true or false,
            }
        end
    end

    -- ── v92 §B7.2: INLINE CONTAINER ICONS ─────────────────────────────────
    -- One icon per preset claimed by a DEBUFFS-anchored container.
    -- ComputeDebuffFlowSet is the authority for (rank, mult) -- the exact data
    -- the runtime flow builder consumes, so preview and live row cannot
    -- disagree about position or relative size. _debuffPresetPreviewList
    -- supplies the texture and the dispellable bit, so those resolve in ONE
    -- place for the floating and the inline case alike.
    --
    -- Size = dSize x mult, where mult is (resolved / ac._roundedDebuffSize) x
    -- PresetRatio (§B4). Multiplying the PREVIEW row's own cell size keeps the
    -- inline icon proportional to the row actually drawn even if the frame's
    -- aura cache and the previewed flat's Debuff Size ever disagree.
    local owned  -- ci -> inline slots painted this pass
    if flowClaims and BF._ComputeDebuffFlowSet then
        -- v92 (combined pairs): `pairOwn` is the flow set's fourth argument -- a
        -- virtual partner's flowClaim already names the OWNER's ci, so the size
        -- override is right without it, but the Relative Size must be read under
        -- the FIRST member's key (owner decision 3).
        local flowSet = BF._ComputeDebuffFlowSet(ac, groupTypeKey, flowClaims, pairOwn)
        local containers = flowSet and self:GetActiveCustomDebuffContainers()
        if flowSet and containers then
            local byCI = {}
            for i = 1, #flowSet do
                local f = flowSet[i]
                local m = byCI[f.ci]
                if not m then m = {}; byCI[f.ci] = m end
                m[f.pkey] = f
            end
            for ci, c in ipairs(containers) do
                local m = byCI[ci]
                -- Rank-sorted preset list (the §B7.2 inline mode: no 0/1
                -- early-out -- a one-preset anchored container still
                -- contributes its icon to the row).
                -- v92 (combined pairs): `ci`/`pairOwn` make it the EFFECTIVE
                -- list, so an anchored OWNER contributes both members (the
                -- partner virtually) and an anchored container that merely
                -- stores the suppressed partner contributes nothing from that
                -- pair. It stays in lockstep with `m` (the flow set), which is
                -- built from the same effective claims.
                local list = m and _debuffPresetPreviewList(self, c, ranks, ci, pairOwn, ac)
                if list then
                    for pi = 1, #list do
                        local p = list[pi]
                        local f = m[p.pkey]
                        -- Only presets that actually FLOW: a preset with no
                        -- claim has no rank slot in the row (same guard the
                        -- flowClaims builder applies).
                        if f and p.tex then
                            nItems = nItems + 1
                            items[nItems] = {
                                ci = ci, c = c, pkey = p.pkey, tex = p.tex,
                                dispellable = p.dispellable,
                                rank = f.rank, mult = f.mult,
                                sub = 1, seq = p.order,
                            }
                        end
                    end
                end
            end
        end
    end

    -- Merged order (see _RowItemLess above).
    if nItems > 1 then table.sort(items, _RowItemLess) end

    -- ── v92 §B7.1: CURSOR LAYOUT (replaces the uniform CalcAuraOffsets grid) ─
    -- The offsets table advanced EVERY slot by exactly size + spacing, so it
    -- cannot express an enlarged boss dummy or a differently-sized inline
    -- container icon. Accumulate each icon's OWN size along the grow axis
    -- instead (the pattern the container multi-preset arm already uses), wrap
    -- by Icons Per Row, and step the cross axis by the completed row's TALLEST
    -- icon -- the preview twin of the live row's lineSizeSlack semantics. The
    -- 1px AnchorNudge the offsets table used to bake in is added here.
    local ApplyDummyIcon = s.ApplyDummyIcon
    local debuffAnchor, debuffOffX, debuffOffY = s.debuffAnchor, s.debuffOffX, s.debuffOffY
    local perRow = s.debuffsPerRow or 3
    if perRow < 1 then perRow = 1 end
    local spacing = BF:PixelRound(s.debuffSpacing or 1)
    local rowSp   = BF:PixelRound(s.debuffRowSpacing or 1)
    local dir = (BF.NormalizeGrowDirection
        and BF.NormalizeGrowDirection(s.debuffGrowDir or "RIGHT_DOWN", debuffAnchor))
        or "RIGHT_DOWN"
    local prim, sec = dir:match("^(%u+)_(%u+)$")
    if not prim then prim, sec = "RIGHT", "DOWN" end
    local pvx = (prim == "RIGHT" and 1) or (prim == "LEFT" and -1) or 0
    local pvy = (prim == "UP"    and 1) or (prim == "DOWN" and -1) or 0
    local wvx = (sec  == "RIGHT" and 1) or (sec  == "LEFT" and -1) or 0
    local wvy = (sec  == "UP"    and 1) or (sec  == "DOWN" and -1) or 0
    local nx, ny = AnchorNudge(debuffAnchor)
    -- BOTTOM-anchor gate: lifting above the power bar only makes sense when
    -- icons grow from the bottom edge of the health bar. Hoisted -- it is
    -- constant for the whole row (inline icons ride the same host).
    local anchorParent = frame
    if db.aurasAbovePowerBar and frame.powerBar and frame.powerBar:IsShown() and frame.healthBar
       and (debuffAnchor == "BOTTOM" or debuffAnchor == "BOTTOMLEFT" or debuffAnchor == "BOTTOMRIGHT") then
        anchorParent = frame.healthBar
    end

    local presetDefs = BF.DEBUFF_CONTAINER_PRESETS
    -- 2026-08-25: only the `rec` items draw from the pool -- inline container
    -- icons ride their container's own SF_PreviewContainerIcons slots -- but
    -- nItems is a safe upper bound and costs nothing to over-ask by.
    local poolN = _EnsureDummyDebuffPool(frame, nItems)
    local primC, secC, rowMax, col = 0, 0, 0, 0
    local dummySlot = 0
    for i = 1, nItems do
        local it = items[i]
        if col >= perRow then
            secC = secC + rowMax + rowSp
            primC, rowMax, col = 0, 0, 0
        end
        local isz = BF:PixelRound(dSize * (it.mult or 1))
        if isz < 2 then isz = 2 end
        local px = primC * pvx + secC * wvx + nx + debuffOffX
        local py = primC * pvy + secC * wvy + ny + debuffOffY
        if it.rec then
            dummySlot = dummySlot + 1
            local icon = frame.debuffFrames[dummySlot]
            if icon then
                local rec = it.rec
                local isDispellable = it.dispellable
                -- v70: a NON-dispellable debuff has no dispel type, so on a
                -- real frame it draws the CONFIGURED Debuff Border Color (black
                -- default), not a hardcoded red -- and its duration text falls
                -- back to Font Color (dispelColor nil below). Dispellable ones
                -- keep the per-dispel-type color from the record.
                local dbColor = ac.debuffBorderColor
                local cr, cg, cb = rec.r, rec.g, rec.b
                if not isDispellable then
                    cr = dbColor and dbColor.r or 0
                    cg = dbColor and dbColor.g or 0
                    cb = dbColor and dbColor.b or 0
                end
                -- v66: border alpha follows the debuff Border Color's alpha.
                local dbA = dbColor and (dbColor.a or 0.8) or 0.8
                -- v92 §B7.1: per-ICON duration-text scale (was one row-global
                -- bfScale off dSize) -- the enlarged boss dummy must scale its
                -- timer text with itself.
                local iScale = autoScale and (isz / 12 * (ac.debuffTimerScale or 1.0)) or 1.0
                -- The record doubles as the dispelColor table (r/g/b are the
                -- only fields read) -- no per-paint allocation.
                local dispelColorForText = isDispellable and rec or nil
                -- Non-dispellable: Blizzard-style border uses the typeless
                -- default atlas; dispellable uses the record's per-type atlas.
                ApplyDummyIcon(icon, DummyRecordTexture(rec), cr, cg, cb, isz, showDuration,
                    swipeDisabled, sparkDisabled, reverseSwipe,
                    bfFont, bfSize, bfBorder, iScale,
                    dbA, ac.debuffFontColor, dispelColorForText,
                    ac.expiringCurveDebuff, ac.debuffBorderThickness,
                    DummyBorderStyle(ac.debuffBorderStyle, ac.debuffBlizzardBorders),
                    (isDispellable and rec.atlas) or "ui-debuff-border-default-noicon")
                -- v71: preview of the dispel-type CORNER ICON on the main
                -- Debuffs row. Shown only on a dispellable dummy when the
                -- section toggle is on; v92: sized off THIS icon, not dSize.
                local dtiIcon = icon._bf_prevDispelTypeIcon
                if isDispellable and ac.showDebuffDispelTypeIcon and rec.typeAtlas then
                    -- 2026-08-25 FIX (owner report): the badge was a texture on
                    -- `icon` itself, and a parent's texture draws BELOW its
                    -- child frames -- so the dummy cooldown's swipe painted
                    -- over it. Host it on a frame one level ABOVE the cooldown
                    -- instead, exactly as the container inline painter already
                    -- does (_paintContainerKind's dispel-type block, same two
                    -- fields). The duration text lives ON the cooldown, so it
                    -- still draws above the badge, matching the live path.
                    local host = icon._bf_prevDTIFrame
                    if not host then
                        host = CreateFrame("Frame", nil, icon)
                        host:SetAllPoints(icon)
                        icon._bf_prevDTIFrame = host
                    end
                    -- Re-stamped every paint, not just at creation: the pool is
                    -- reused across passes and an icon's cooldown level can
                    -- move with a resize or a re-anchor.
                    if icon.cooldown then
                        host:SetFrameLevel(icon.cooldown:GetFrameLevel() + 1)
                    end
                    if not dtiIcon then
                        dtiIcon = BF.Texture(host, nil, "OVERLAY", nil, 3)
                        icon._bf_prevDispelTypeIcon = dtiIcon
                    end
                    dtiIcon:SetAtlas(rec.typeAtlas)
                    local dsz = isz * ((ac.debuffDispelTypeIconScale or 40) / 100)
                    dtiIcon:SetSize(dsz, dsz)
                    -- Match the live badge: overlap the corner by ~35% of its size.
                    local dn = dsz * 0.35
                    dtiIcon:ClearAllPoints()
                    dtiIcon:SetPoint("CENTER", icon, "TOPRIGHT", -dn, -dn)
                    dtiIcon:Show()
                elseif dtiIcon then
                    dtiIcon:Hide()
                end
                icon:ClearAllPoints()
                icon:SetPoint(debuffAnchor, anchorParent, debuffAnchor, px, py)
                -- The group's own name, not a blanket "Debuffs". The
                -- Setup-Mode -> Preview prefix swap in SetDummyTooltip keys on
                -- the "Setup Mode: " prefix, which this keeps.
                SetDummyTooltip(icon, "Setup Mode: " .. (it.label or "Debuffs"))
                icon.SF_LastIndex = dummySlot
                -- Host size for the stack-text auto-scale (_ShowDummyStackText
                -- runs on pool index 1, which may now be the enlarged boss).
                icon._bf_dummySize = isz
            end
        else
            -- Inline container icon. _paintPreviewContainerIcon is
            -- geometry-agnostic by design, so every per-container override
            -- (border, color-by-dispel, duration text, dispel badge) rides
            -- along for free -- the caller owns size and position, which is
            -- exactly what this cursor already computed.
            owned = owned or {}
            local n = (owned[it.ci] or 0) + 1
            owned[it.ci] = n
            local icon = _ensurePreviewContainerIcon(frame, "debuff", it.ci, n)
            icon:SetSize(isz, isz)
            icon:ClearAllPoints()
            icon:SetPoint(debuffAnchor, anchorParent, debuffAnchor, px, py)
            local pdef = presetDefs and presetDefs[it.pkey]
            _paintPreviewContainerIcon(self, frame, icon, it.c, it.ci, "debuff", ac,
                groupTypeKey, ApplyDummyIcon, it.tex, isz, it.dispellable,
                "Setup Mode: " .. ((pdef and pdef.name) or it.pkey))
            icon:Show()
        end
        primC = primC + isz + spacing
        if isz > rowMax then rowMax = isz end
        col = col + 1
    end
    for idx = dummySlot + 1, poolN do
        local icon = frame.debuffFrames[idx]; if icon and icon:IsShown() then icon:Hide() end
    end

    -- ── v92 §B7.2: INLINE-SLOT OWNERSHIP ──────────────────────────────────
    -- THE SPLIT: the row pass owns the SF_PreviewContainerIcons slots of every
    -- Debuffs-anchored container; _paintContainerKind skips those containers
    -- WHOLE (paint and sweeps alike -- see the guard there), so it can never
    -- hide what this pass just painted. The row therefore runs both sweeps
    -- itself:
    --   * a container it owned last pass but not this one (an anchor flip, or
    --     the container going away) loses EVERY slot -- and _paintContainerKind
    --     owns it again from the next container pass;
    --   * a container it still owns loses the slots past what it painted.
    local prevOwned = frame._bf_rowOwnedCI
    if prevOwned then
        for ci in pairs(prevOwned) do
            if not (owned and owned[ci]) then
                _hidePreviewContainerSlots(frame, "debuff", ci, 1)
            end
        end
    end
    if owned then
        for ci, n in pairs(owned) do
            _hidePreviewContainerSlots(frame, "debuff", ci, n + 1)
        end
    end
    frame._bf_rowOwnedCI = owned

    -- Stack text renders on debuff pool index 1 only. Call after the loop so
    -- the first-sorted dummy has been ApplyDummyIcon'd and is Show()n.
    _ShowDummyStackText(self, frame, s)
end

-- ============================================================
-- Live-parity preview glow (owner). The real 12.1 container glow is a
-- STATIC IconAlert ring, optionally pulsing (ApplyGlowCore,
-- Auras/ContainerFactory.lua) -- LCG's animated ButtonGlow, which this
-- preview used to run, looked nothing like it. Same asset, texcoords,
-- pad (BF.AURA_GLOW_PAD_BIGDEF, see ApplyDummyGlow) and pulse floor
-- (alpha x0.35) as the live path, and the same Glow Color / Glow Style
-- options drive it.
-- Preview icons are ordinary frames (no forbidden partition), so the
-- animation group plays freely.
-- ============================================================
local function EnsureDummyGlow(icon)
    local g = icon._bf_dummyGlow
    if g then return g end
    local host = CreateFrame("Frame", nil, icon)
    host:SetAllPoints(icon)
    host:SetFrameLevel(icon:GetFrameLevel() + 4)
    local ring = BF.Texture(host, nil, "OVERLAY")
    ring:SetTexture("Interface\\SpellActivationOverlay\\IconAlert")
    ring:SetTexCoord(0.00781250, 0.50781250, 0.27734375, 0.52734375)
    ring:Hide()
    local ag = ring:CreateAnimationGroup()
    ag:SetLooping("REPEAT")
    local gIn = ag:CreateAnimation("Alpha")
    gIn:SetOrder(1); gIn:SetDuration(0.6)
    local gOut = ag:CreateAnimation("Alpha")
    gOut:SetOrder(2); gOut:SetDuration(0.6)
    g = { ring = ring, ag = ag, gIn = gIn, gOut = gOut }
    icon._bf_dummyGlow = g
    return g
end

local function ApplyDummyGlow(icon, size, color, pulse)
    local g = EnsureDummyGlow(icon)
    -- Matches the live Big Defensive ring, not the shared default: this
    -- dummy stands in for the Big Defensive icons. Both now read the same
    -- constant (top of Auras/ContainerFactory.lua), so the preview can no
    -- longer drift from what the live ring actually draws -- it used to be
    -- pinned at 0.26 while the live pad had moved to 0.42.
    local pad = (size or 24) * BF.AURA_GLOW_PAD_BIGDEF
    g.ring:ClearAllPoints()
    g.ring:SetPoint("TOPLEFT", icon, "TOPLEFT", -pad, pad)
    g.ring:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", pad, -pad)
    local ca = color and (color.a or 1) or 1
    -- Tint on the vertex color, STRENGTH on object alpha -- live parity with
    -- ApplyGlowCore (Auras/ContainerFactory.lua). Vertex-color alpha does not
    -- read on this ring asset, so the picker's alpha was inert here too.
    g.ring:SetVertexColor(
        color and (color.r or 1) or 1,
        color and (color.g or 1) or 1,
        color and (color.b or 1) or 1)
    g.ring:SetAlpha(ca)
    g.ring:Show()
    if pulse then
        g.gIn:SetFromAlpha(ca * 0.35); g.gIn:SetToAlpha(ca)
        g.gOut:SetFromAlpha(ca); g.gOut:SetToAlpha(ca * 0.35)
        if not g.ag:IsPlaying() then g.ag:Play() end
    else
        -- Stop() restores the baked alpha (1); re-stamp the configured alpha,
        -- exactly as ApplyGlowCore does.
        if g.ag:IsPlaying() then g.ag:Stop() end
        g.ring:SetAlpha(ca)
    end
end

local function HideDummyGlow(icon)
    local g = icon._bf_dummyGlow
    if not g then return end
    if g.ag:IsPlaying() then g.ag:Stop() end
    g.ring:Hide()
end

-- ============================================================
-- _ShowDummyBigDef(self, frame, s)
-- Paint the dummy Big Defensive icons.
-- ============================================================
local function _ShowDummyBigDef(self, frame, s)
    if not frame.bigDefIcons then return end
    local db, bdP = s.db, s.bdP
    local bdSize  = s.bdSize
    local enabled = bdP.showBigDef or false
    if s.dispelDebuffBorderOnly or s.customAurasOnly then enabled = false end
    -- v70: Big Defensive is a Buffs-tab subcat, so on preview frames it rides
    -- the active Preview dropdown's Buffs side; setup-mode keeps showDummyBigDef.
    -- 2026-09-15: a buff container's tab previews that container alone, so
    -- the Big Defensive dummy stays hidden there (BuildSharedState's
    -- containerTabOnly). Its own subtab and the Buffs subtab are unchanged.
    if s.pvIsPreview then
        if not s.pvShowBuffs then enabled = false end
        if s.containerTabOnly then enabled = false end
    elseif enabled and BF.db.global.showDummyBigDef == false then
        enabled = false
    end
    if not enabled then
        for i = 1, #frame.bigDefIcons do
            HideDummyGlow(frame.bigDefIcons[i])
            if frame.bigDefIcons[i]:IsShown() then frame.bigDefIcons[i]:Hide() end
        end
        return
    end
    local ac         = BF:GetAuraCacheForFrame(frame)
    local anchorPos  = bdP.bigDefAnchor or "CENTER"
    local maxCount   = bdP.bigDefMaxCount or 1
    local showDur    = ac.showBigDefDuration
    local bdAutoScale = ac.bigDefAutoScale
    local bfFont     = ac.bigDefDurationFont
    local bfSize     = bdAutoScale and 11 or (ac.bigDefFontSize or 11)
    local bfBorder   = ac.bigDefDurationBorder or "OUTLINE"
    local bfScale    = bdAutoScale and (bdSize / 12 * (ac.bigDefTimerScale or 1.0)) or 1.0
    local bdSwipe    = ac.disableBigDefSwipe or false
    local bdSpark    = ac.disableBigDefSpark or false
    local bdReverse  = ac.reverseBigDefSwipe == true
    local nx, ny = AnchorNudge(anchorPos)
    local ap   = (anchorPos ~= "") and anchorPos or "CENTER"
    local offX = bdP.bigDefOffsetX or 0
    local offY = bdP.bigDefOffsetY or 0
    -- v34: two-axis grid offsets — use the cache's CalcAuraOffsets
    -- precompute (includes the anchor nudge). One source of truth with
    -- the real path and the buff/debuff dummies; replaces the old inline
    -- single-axis step math (which hardcoded rows-down wrapping).
    local bdOffsets = ac._bigDefOffsets
    -- v33: border color resolves via GetDefaultBorderColorFor so the
    -- "Also Color Aura Border" toggle (bigDefColorAuraBorder) paints the
    -- border in Font Color instead of black. Matches the real-path branch.
    local bR, bG, bB, bA = BF.GetDefaultBorderColorFor("bigDef", ac)
    local ApplyDummyIcon = s.ApplyDummyIcon
    -- v94: BIGDEF-anchored single buffs (matrix row 14) preview here.
    --
    -- While the Buff List has an entry set, the Max Defensives DUMMIES are
    -- suppressed and only the entries draw -- the same owner ruling the buffs
    -- row follows, for the same reason: the subtab is for looking at these
    -- entries, and a stand-in icon of an unrelated spell among them defeats it.
    -- (This reverses an earlier "preview alongside it" ruling.) NOTE this
    -- deliberately DIVERGES from the live render, where row 14's anchored
    -- entries do draw in addition to Max Defensives -- the preview is showing
    -- the user their configuration, not simulating a fight.
    --
    -- Gated on the SET, not on this bucket: a spec whose entries all anchor
    -- elsewhere leaves Big Defensive EMPTY, rather than letting the dummy back
    -- in depending on where the entries happen to be anchored. The set is nil
    -- only when nothing is being previewed at all (Filter by Spec = All with no
    -- selection), and then the dummies below run unchanged.
    local bdGroupTypeKey = frame._bf_containerGroupTypeKey or self:ResolveGroupTypeKey(frame)
    local bdSet   = _SingleBuffPreviewItems(self, frame, ac, bdGroupTypeKey)
    local bdItems = bdSet and bdSet.bigDef
    if bdItems and #bdItems == 0 then bdItems = nil end
    local bdBaseCount = bdSet and 0 or math.min(maxCount, #frame.bigDefIcons)
    for i = 1, bdBaseCount do
        local icon = frame.bigDefIcons[i]
        ApplyDummyIcon(icon, DUMMY_BIGDEF_ICON, bR, bG, bB, bdSize, showDur, bdSwipe, bdSpark, bdReverse, bfFont, bfSize, bfBorder, bfScale, bA, ac.bigDefFontColor, nil, ac.expiringCurveBigDef, ac.bigDefBorderThickness, DummyBorderStyle(ac.bigDefBorderStyle, ac.bigDefBlizzardBorders), nil)
        -- v94: same reason as the buffs row -- raising Max Defensives hands a
        -- slot an anchored entry held last pass back to a base dummy, and the
        -- entry's glow would ride along.
        if BF.ClearPreviewIconEffectFx then BF.ClearPreviewIconEffectFx(icon) end
        icon:SetSize(bdSize, bdSize)
        icon:ClearAllPoints()
        local off = bdOffsets and bdOffsets[i]
        local slotOffX = offX + (off and off.x or nx)
        local slotOffY = offY + (off and off.y or ny)
        local anchorParent = frame
        -- BOTTOM-anchor gate: matches the real BigDefIcons render path.
        if db.aurasAbovePowerBar and frame.powerBar and frame.powerBar:IsShown() and frame.healthBar
           and (ap == "BOTTOM" or ap == "BOTTOMLEFT" or ap == "BOTTOMRIGHT") then
            anchorParent = frame.healthBar
        end
        icon:SetPoint(ap, anchorParent, ap, slotOffX, slotOffY)
        SetDummyTooltip(icon, "Setup Mode: Big Defensive")
        icon:Show()
        -- Glow
        -- Read from s.bdP (previewed flat) rather than BF.AuraCache
        -- (which reflects the LIVE flat). Matches the rest of this
        -- block, which already reads bigDef settings from s.bdP.
        --
        -- Owner: LIVE-PARITY ring (see ApplyDummyGlow above) instead of
        -- LCG's animated ButtonGlow, which looked nothing like what the
        -- 12.1 container path actually renders. Color and style come
        -- from the new Glow Color / Glow Style options, exactly as
        -- BigDefContainerSpecs feeds them to ApplyGlow on live frames.
        if s.bdP.bigDefShowGlow == true then
            ApplyDummyGlow(icon, bdSize, s.bdP.bigDefGlowColor,
                s.bdP.bigDefGlowStyle == "pulse")
        else
            HideDummyGlow(icon)
        end
    end
    -- v94: the anchored entries, continuing the same offsets grid so they land
    -- in the row rather than on top of it. Each at its OWN size and visuals --
    -- an anchored entry always has its own group live (row 14: "No share path
    -- exists"), so it is never drawn at the bigDef base size.
    -- Anchored entries continue from wherever the dummies stopped -- which is
    -- slot 0 while the entry set is suppressing them, so they start at 1.
    local used = bdBaseCount
    if bdItems then
        for i = 1, #bdItems do
            local slot = used + 1
            local icon = frame.bigDefIcons[slot]
            if not icon then break end
            local it  = bdItems[i]
            local isz = BF:PixelRound(self:ResolveContainerGeometry(it.c, bdGroupTypeKey, ac, nil) or bdSize)
            if _PaintSingleBuffDummy(self, frame, icon, it, isz, ac, bdGroupTypeKey,
                    ApplyDummyIcon, bR, bG, bB, bA,
                    "Setup Mode: " .. (it.c.name or tostring(it.sid))) then
                icon:SetSize(isz, isz)
                icon:ClearAllPoints()
                local off = bdOffsets and bdOffsets[slot]
                local anchorParent = frame
                if db.aurasAbovePowerBar and frame.powerBar and frame.powerBar:IsShown() and frame.healthBar
                   and (ap == "BOTTOM" or ap == "BOTTOMLEFT" or ap == "BOTTOMRIGHT") then
                    anchorParent = frame.healthBar
                end
                icon:SetPoint(ap, anchorParent, ap,
                    offX + (off and off.x or nx), offY + (off and off.y or ny))
                -- The bigDef glow is a container-level feature of the Big
                -- Defensive display, not a property of an anchored entry, so
                -- an entry's icon never carries it.
                HideDummyGlow(icon)
                icon:Show()
                used = slot
            end
        end
    end
    for i = used + 1, #frame.bigDefIcons do
        HideDummyGlow(frame.bigDefIcons[i])
        if frame.bigDefIcons[i]:IsShown() then
            if BF.ClearPreviewIconEffectFx then BF.ClearPreviewIconEffectFx(frame.bigDefIcons[i]) end
            frame.bigDefIcons[i]:Hide()
        end
    end
end

-- v64: _ShowDummyImportant removed with the Important feature.

-- v69: _ShowDummyCrowdControl removed with the dedicated Crowd Control
-- feature (now a seeded custom debuff container — previewed through
-- _ShowDummyContainerAuras like every other container).

-- ============================================================
-- _ShowDummyDispelBorders(self, frame, s)
-- Paints dispel border, debuff overlay, and dispel indicator on
-- the preview/test frame. Uses a single magic-purple dispel color
-- as representative. Reads per-flat `borders` via
-- GetSectionProfileForFrame for preview frames and via the
-- modifying flat for setup-mode test frames.
-- ============================================================
local function _ShowDummyDispelBorders(self, frame, s)
    if s.customAurasOnly then
        if frame.dispelDebuffIndicator then
            frame.dispelDebuffIndicator:Hide()
            SetDummyTooltip(frame.dispelDebuffIndicator, nil)
        end
        -- dispelDebuffBorder and dispelDebuffOverlay are managed by ShowSingleSpellPreview
        -- (which has else-branches that clear them), but when no spell is being
        -- previewed we must also clear them here.
        -- Clear dispel borders/overlays when no spell is being previewed.
        -- buffOverlay/buffColorOverlay are handled by _ShowDummyContainerAuras.
        if not BF:IsPreviewingSpell() then
            if frame.dispelDebuffBorder then
                self:SetHighlightBorder(frame.dispelDebuffBorder, frame, 0, 0, 0, 0)
            end
            if frame.dispelDebuffOverlay then
                frame.dispelDebuffOverlay:Hide()
            end
            if frame.dispelHealthColorTex then
                frame.dispelHealthColorTex:Hide()
            end
        end
        return
    end
    if not (frame.dispelDebuffBorder or frame.dispelDebuffIndicator or frame.dispelDebuffOverlay) then return end

    -- v70: the dispel border/overlay/indicator is a Debuffs-tab surface. On a
    -- preview frame whose active mode does not show debuffs, clear all three
    -- and bail so a mode switch away from debuffs leaves nothing stale.
    if s.pvIsPreview and not s.pvShowDebuffs then
        if frame.dispelDebuffBorder then
            self:SetHighlightBorder(frame.dispelDebuffBorder, frame, 0, 0, 0, 0)
        end
        if frame.dispelDebuffOverlay then frame.dispelDebuffOverlay:Hide() end
        if frame.dispelHealthColorTex then frame.dispelHealthColorTex:Hide() end
        if frame.dispelDebuffIndicator then
            frame.dispelDebuffIndicator:Hide()
            SetDummyTooltip(frame.dispelDebuffIndicator, nil)
        end
        return
    end

    local db, diP = s.db, s.diP

    local blizzardActive = diP.dispelIndicatorOverlayMode == "blizzard"
    local showDispel = (not blizzardActive) and (diP.showDispelIndicator ~= false)
    local borderEnabled = (not blizzardActive) and diP.enableDebuffBorder
    local overlayEnabled = (not blizzardActive) and (diP.enableDebuffOverlay == true)
    -- Magic purple as the representative dispel color
    local dr, dg, db_ = 0.20, 0.60, 1.00

    -- When dispellable simulation is off, only show border/overlay/indicator
    -- if their mode is "all" (meaning they show for all debuffs, not just dispellable).
    -- The dispel indicator is always dispellable-only, so it always hides.
    -- v70: preview frames read the active Preview dropdown's dispellable bit;
    -- setup-mode test frames (not preview) always simulate dispellable (old
    -- default was on; that toggle is retired).
    local simDispel = s.pvIsPreview and s.pvSimDispel or (not s.pvIsPreview)

    if frame.dispelDebuffBorder then
        local borderMode = diP.debuffBorderMode or "dispellable"
        -- v36: blizzard-native mode simulation. When the master dropdown is
        -- "blizzard" and simulateDispellableDebuff is on, paint a fixed 3px
        -- magic-purple border to match the native Blizzard dispel border look.
        -- This fires regardless of the user's enableDebuffBorder toggle (the
        -- Debuff Border section is hidden in blizzard mode and its cache value
        -- is forced false upstream — borderEnabled is nil here, which is the
        -- intended branch). Must match the blizzard-mode branch in
        -- Preview/Options_PreviewData.lua ApplyPreviewHighlights, which runs
        -- before this function on the full-refresh path; on the per-type aura
        -- refresh path (30s timer / RefreshPreviewDummyAuras) ONLY this
        -- function runs, so this site also owns edge thickness in blizzard
        -- mode, not just color.
        if blizzardActive and simDispel then
            local thickness = BF:PixelsToUI(3)
            local dh = frame.dispelDebuffBorder
            if dh.top    then dh.top:SetHeight(thickness)    end
            if dh.bottom then dh.bottom:SetHeight(thickness) end
            if dh.left   then dh.left:SetWidth(thickness)    end
            if dh.right  then dh.right:SetWidth(thickness)   end
            self:SetHighlightBorder(dh, frame, dr, dg, db_, 1, 3)
        elseif borderEnabled and (simDispel or borderMode == "all") then
            self:SetHighlightBorder(frame.dispelDebuffBorder, frame, dr, dg, db_, 1,
                diP.debuffBorderWidth or 2)
        else
            self:SetHighlightBorder(frame.dispelDebuffBorder, frame, 0, 0, 0, 0)
        end
    end

    -- Debuff overlay
    -- Two independent paths, chosen by blizzardActive:
    --   * blizzardActive == true — render Blizzard preview visuals
    --     (alpha=1, height=0.5, no fillOnly), gated solely by blizzardActive.
    --     The addon's own overlay widget is reused to simulate what the
    --     Blizzard private-aura container will draw at runtime, because
    --     preview frames don't have a real Blizzard container attached.
    --   * blizzardActive == false — render the addon's own overlay, gated
    --     solely by overlayEnabled (the user's enableDebuffOverlay toggle).
    if frame.dispelDebuffOverlay then
        local overlayMode = diP.debuffOverlayMode or "dispellable"
        local shouldShow, alpha, heightFrac, fillOnly
        if blizzardActive then
            shouldShow = (simDispel or overlayMode == "all")
            alpha      = 1
            heightFrac = 0.5
            fillOnly   = false
        else
            shouldShow = overlayEnabled and (simDispel or overlayMode == "all")
            alpha      = diP.debuffOverlayAlpha  or 0.5
            heightFrac = diP.debuffOverlayHeight or 0.7
            fillOnly   = diP.debuffOverlayFillOnly
        end
        if shouldShow then
            frame.dispelDebuffOverlay:SetVertexColor(dr, dg, db_, 1)
            frame.dispelDebuffOverlay:SetAlpha(alpha)
            if frame.healthBar then
                local hFill = frame.healthBar:GetStatusBarTexture()
                frame.dispelDebuffOverlay:ClearAllPoints()
                if fillOnly and hFill then
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

    -- Debuff Health Color Change: the health bar tinted in the dispel
    -- type's color. Mirrors the engine-bound dispelHealthColor kind
    -- (Indicators/DispelDebuffOverlay.lua): the tint sits over the health
    -- FILL wearing the bar's own texture so its shading survives, magic
    -- purple as the representative type, opacity from the profile
    -- (debuffHealthColorAlpha). Hidden in blizzard mode, which has no
    -- health-color kind. The only-if-ready gate is ignored here like the
    -- other kinds' gates: the preview simulates a ready dispel.
    if frame.dispelHealthColorTex then
        local hcEnabled = (not blizzardActive)
            and (diP.enableDebuffHealthColor == true)
        local hcMode = diP.debuffHealthColorMode or "dispellable"
        local hcTex  = frame.dispelHealthColorTex
        if hcEnabled and (simDispel or hcMode == "all") and frame.healthBar then
            local hFill = frame.healthBar:GetStatusBarTexture()
            local file  = hFill and hFill.GetTexture and hFill:GetTexture()
            if file then
                hcTex:SetTexture(file)
            else
                hcTex:SetColorTexture(1, 1, 1)
            end
            hcTex:ClearAllPoints()
            if hFill then
                hcTex:SetAllPoints(hFill)
            else
                hcTex:SetAllPoints(frame.healthBar)
            end
            hcTex:SetVertexColor(dr, dg, db_, diP.debuffHealthColorAlpha or 0.7)
            hcTex:Show()
        else
            hcTex:Hide()
        end
    end

    if frame.dispelDebuffIndicator then
        -- Two independent paths, chosen by blizzardActive:
        --   * blizzardActive == true  — render Blizzard multi-icon preview,
        --     gated solely by blizzardActive. The addon's own dispelIndicator
        --     widget is reused to simulate what the Blizzard private-aura
        --     container will draw at runtime, because preview frames don't
        --     have a real Blizzard container attached.
        --   * blizzardActive == false — render addon's own dispel indicator
        --     (square or per-type icon per dispelIndicatorStyle), gated
        --     solely by showDispel (the user's showDispelIndicator toggle).
        local shouldShow = blizzardActive or showDispel
        if shouldShow and simDispel then
            local size = diP.dispelIndicatorSize or 10
            local pos  = diP.dispelIndicatorPosition or "TOPRIGHT"
            local style = diP.dispelIndicatorStyle or "square"
            -- Blizzard indicator preview (multi-icon growing left, respecting
            -- dispelIndicatorMaxIcons) is driven solely by the new
            -- dispelIndicatorOverlayMode dropdown ("blizzard" value).
            local isBlizzardIndicator = blizzardActive
            frame.dispelDebuffIndicator:SetSize(size, size)
            frame.dispelDebuffIndicator:ClearAllPoints()
            -- v93: all nine anchor points; shared inset helper keeps Setup
            -- Mode identical to the live DotGeom placement.
            local xOff, yOff = BF:GetDispelIndicatorInset(pos)
            xOff = xOff + (diP.dispelIndicatorOffsetX or 0)
            yOff = yOff + (diP.dispelIndicatorOffsetY or 0)
            frame.dispelDebuffIndicator:SetPoint(pos, frame.healthBar or frame, pos, xOff, yOff)
            if style == "icon" or isBlizzardIndicator then
                -- Show dispel type icons. For Blizzard mode, show up to
                -- dispelIndicatorMaxIcons icons growing left from anchor.
                frame.dispelDebuffIndicator.texture:Hide()
                local names = frame.dispelDebuffIndicator.iconNames
                if names then
                    -- Determine how many icons to show: plain icon style always 1,
                    -- Blizzard mode uses the maxIcons setting.
                    local maxIcons = isBlizzardIndicator and (diP.dispelIndicatorMaxIcons or 1) or 1
                    -- Representative dispel types in priority order
                    local previewTypes = { "magic", "poison", "curse" }
                    for i = 1, #names do
                        local iconTex = frame.dispelDebuffIndicator.icons[names[i]]
                        -- Find this name's slot in the preview order
                        local slot = nil
                        for si = 1, #previewTypes do
                            if previewTypes[si] == names[i] then slot = si; break end
                        end
                        if slot and slot <= maxIcons then
                            iconTex:SetVertexColor(1, 1, 1, 1)
                            -- Position each icon: first at full frame, extras offset left
                            iconTex:ClearAllPoints()
                            local iconOffset = (slot - 1) * size
                            iconTex:SetSize(size, size)
                            iconTex:SetPoint("TOPRIGHT", frame.dispelDebuffIndicator, "TOPRIGHT", -iconOffset, 0)
                            iconTex:Show()
                        else
                            iconTex:Hide()
                        end
                    end
                    -- Widen the frame so all icons fit
                    frame.dispelDebuffIndicator:SetSize(size * maxIcons, size)
                end
            else
                -- Square mode: show colored dot
                local names = frame.dispelDebuffIndicator.iconNames
                if names then
                    for i = 1, #names do
                        frame.dispelDebuffIndicator.icons[names[i]]:Hide()
                    end
                end
                if frame.dispelDebuffIndicator.texture then
                    frame.dispelDebuffIndicator.texture:SetVertexColor(dr, dg, db_, 1)
                    frame.dispelDebuffIndicator.texture:Show()
                end
            end
            frame.dispelDebuffIndicator:Show()
            SetDummyTooltip(frame.dispelDebuffIndicator, "Setup Mode: Dispel Indicator")
        else
            frame.dispelDebuffIndicator:Hide()
            SetDummyTooltip(frame.dispelDebuffIndicator, nil)
        end
    end
end

-- v67: the _ShowDummyPrivateAuras painter was removed with the Private
-- Auras feature (12.0.7-only icons; the addon is 12.1-only now). The
-- native dispel overlay lives in PrivateAuraDispelOverlay.lua and is
-- unrelated.

-- ============================================================
-- _ShowDummyContainerAuras(self, frame, s)
-- Dispatch custom container aura rendering on the dummy frame.
-- Mirrors the original inline block exactly.
-- ============================================================
-- ============================================================
-- v94: the selected Buff List entry's frame effects.
--
-- Thin: it resolves WHICH entry and hands the three families to the shared
-- painter (BF:ApplyPreviewSpellFrameEffects). The gate for a single buff is
-- its Display Type, which lives inside GetSingleBuffVisualEntry -- an entry in
-- "Show (Default Buff)" or Blacklist mode returns nil for every family and so
-- paints nothing, which is correct: neither mode has frame effects.
-- ============================================================
local function _ShowBuffListFrameEffects(self, frame, s)
    if not frame._isPreviewFrame then return end
    if not _BuffListPreviewActive(self) then return end
    if not self.ApplyPreviewSpellFrameEffects then return end

    -- Does the dispel simulation own frame.dispelDebuffBorder this pass? The
    -- two features share that one widget (see the plan's §1.4 table), and
    -- _ShowDummyDispelBorders has already run by the time we get here -- it is
    -- step 4 of ShowDummyAuras, this branch is step 5. These are exactly its
    -- own early-outs, so the answer cannot disagree with what it did.
    local keepDispelBorder = (not s.dispelDebuffBorderOnly) and (not s.customAurasOnly)
        and ((not s.pvIsPreview) or s.pvShowDebuffs)

    local key = self:GetBuffListPreviewKey()
    local c   = key and self.FindSingleBuffByKey and (self:FindSingleBuffByKey(key)) or nil
    local sid = c and self.GetSingleBuffSpellID and self:GetSingleBuffSpellID(c) or nil
    -- A blacklisted entry renders nothing in game, effects included.
    if c and c.singleBuffHidden then c, sid = nil, nil end

    if not (c and sid) then
        -- No usable selection: nil for every family clears all three widgets.
        self:ApplyPreviewSpellFrameEffects(frame, function() return nil end,
            { keepDispelBorder = keepDispelBorder })
        return
    end
    self:ApplyPreviewSpellFrameEffects(frame, function(family)
        local t = BF.GetSingleBuffVisualEntry and BF.GetSingleBuffVisualEntry(c, family, sid)
        if t and t.enabled == false then return nil end
        return t
    end, { keepDispelBorder = keepDispelBorder })
end

local function _ShowDummyContainerAuras(self, frame, s)
    local isRaid = s.isRaid
    local raidProfile = s.raidProfile
    local overridePartyProfile = s.overridePartyProfile

    if BF._debugContainerPreview then
        print("|cff00ffff[BF Dispatcher]|r _ShowDummyContainerAuras: customAurasOnly=", s.customAurasOnly, "dispelOnly=", s.dispelDebuffBorderOnly, "previewingCM=", BF:IsPreviewingContainerMgmt(), "previewingSpell=", BF:IsPreviewingSpell(), "section=", BF._currentSection)
    end

    -- Dispel tab: no containers
    if s.dispelDebuffBorderOnly then
        if BF._debugContainerPreview then print("|cffff0000[BF Dispatcher]|r dispel-only, hiding") end
        if BF.HideDummyContainerAuras then BF:HideDummyContainerAuras(frame) end
        return
    end

    -- Clear stale per-spell preview effects when not in spell preview mode
    if not (s.customAurasOnly and BF:IsPreviewingSpell()) then
        if frame.buffOverlay and frame.buffOverlay:IsShown() then frame.buffOverlay:Hide() end
        if frame.buffColorOverlay and frame.buffColorOverlay:IsShown() then frame.buffColorOverlay:Hide() end
    end

    if s.customAurasOnly and BF:IsPreviewingSpell() then
        -- Per-spell settings tab: show single spell preview
        if BF._debugContainerPreview then print("|cff00ffff[BF Dispatcher]|r → ShowSingleSpellPreview") end
        if BF.ShowSingleSpellPreview then
            BF:ShowSingleSpellPreview(frame, isRaid, raidProfile, overridePartyProfile)
        end
    elseif s.customAurasOnly and BF:IsPreviewingContainerMgmt() then
        -- Container Management tab: show container auras with spec fallback
        -- enabled (the tab is explicitly a "show me this container" preview
        -- and should display SOMETHING even when the current spec has no
        -- assignments — it picks the first healer spec that does).
        if BF._debugContainerPreview then print("|cff00ffff[BF Dispatcher]|r → ShowDummyContainerAuras (fallback ON)") end
        if BF.ShowDummyContainerAuras then
            BF:ShowDummyContainerAuras(frame, isRaid, raidProfile, overridePartyProfile, true)
        end
    elseif s.customAurasOnly then
        -- Custom Auras top-level (not container mgmt, not spell): hide containers
        if BF._debugContainerPreview then print("|cffff0000[BF Dispatcher]|r customAurasOnly but no preview mode → hiding") end
        if BF.HideDummyContainerAuras then BF:HideDummyContainerAuras(frame) end
    else
        -- v70: Regular aura sections (Buffs / Debuffs tabs). Each custom
        -- container — buff AND debuff — shows ONE representative preview icon at
        -- its configured position/geometry. Single whitelist buffs show NO
        -- preview icon. Buff containers follow the active mode's Buffs side,
        -- debuff containers its Debuffs side. This is a preview-only painter
        -- (like every other _ShowDummy* helper); it does not touch the live
        -- container render pipeline or its combat caches.
        if BF._debugContainerPreview then print("|cff00ffff[BF Dispatcher]|r → ShowGeneralContainerPreviews") end
        if BF.ShowGeneralContainerPreviews then
            BF:ShowGeneralContainerPreviews(frame, s.pvShowBuffs, s.pvShowDebuffs, s.fakeNow, s.fakeDur)
        end
        -- ── v94: BUFF LIST FRAME EFFECTS ──────────────────────────────────
        -- Frame effects are properties of the FRAME, not of an icon: the unit
        -- has one health bar, so they can only ever show for ONE entry. That
        -- entry is the SELECTED one (owner ruling) -- every other matching
        -- entry previews its icon and its icon effects only.
        --
        -- Runs on every pass of this branch, not just when something is
        -- selected: with no selection the getter returns nil for all three
        -- families, which is what drives the else-branches that hide the
        -- widgets. Skipping the call instead would strand the last selection's
        -- effects on the frame.
        _ShowBuffListFrameEffects(self, frame, s)
    end
end

-- ============================================================
-- v70: GENERAL CONTAINER PREVIEW (Buffs / Debuffs tabs)
--
-- One representative icon per custom container, at the container's own
-- geometry. This is the same kind of preview-only painter as _ShowDummy*:
-- it pools its own icon frames on the preview frame, reads geometry through
-- BF:ResolveContainerGeometry (the shared resolver every path uses), and
-- never touches the live container render pipeline or its combat caches.
--
-- Rules (owner, v70):
--   * Single whitelist buffs (c.singleBuff) show NO preview icon.
--   * Every other buff container shows one icon when showBuffs; every debuff
--     container shows one icon when showDebuffs.
--   * A globally-disabled container (c.enabled == false) shows nothing.
--   * Icon is derived: a preset's representative icon, else the first assigned
--     spell's icon; a container with neither shows nothing.
-- ============================================================

-- Resolve one representative texture for a container's preview icon, or nil.
-- Presets win (first in canonical order); otherwise the first assigned spell.
function BF:GetContainerPreviewIcon(c, ci, kind)
    if type(c) ~= "table" then return nil end
    local isDebuff = (kind == "debuff")
    local defs  = isDebuff and BF.DEBUFF_CONTAINER_PRESETS or BF.CONTAINER_PRESETS
    local order = isDebuff and BF.DEBUFF_CONTAINER_PRESET_ORDER or BF.CONTAINER_PRESET_ORDER
    if c.presets and defs and order then
        for i = 1, #order do
            local k = order[i]
            if c.presets[k] and defs[k] and defs[k].previewIcon then
                return defs[k].previewIcon
            end
        end
    end
    -- Debuff containers are preset-only, so nothing more to try.
    if isDebuff then return nil end
    -- A single buff carries its spell on the container (but single buffs are
    -- excluded from this preview entirely — the caller never reaches here for
    -- one). A regular buff container's spells live in acp.spellAssign as
    -- "c:<ci>"; pick the lowest sid for a deterministic representative icon.
    local acp = self.acDB and self.acDB.profile
    local sa  = acp and acp.spellAssign
    if sa then
        local bestSid
        for _, bySpec in pairs(sa) do
            if type(bySpec) == "table" then
                for sid, val in pairs(bySpec) do
                    if type(val) == "string" and val == ("c:" .. ci) then
                        if not bestSid or sid < bestSid then bestSid = sid end
                    end
                end
            end
        end
        if bestSid and C_Spell and C_Spell.GetSpellTexture then
            return C_Spell.GetSpellTexture(bestSid)
        end
    end
    return nil
end

-- Per-(frame, kind, ci, slot) preview icon pool. Separate from the live
-- SF_CustomContainerIcons pool so preview painting can never disturb the
-- combat render path's frames. v71: a debuff container with several presets
-- previews ONE icon per preset (at its Relative Size), so each ci holds an
-- ARRAY of icon frames keyed by slot (1..N).
-- v92 §B7.2: ASSIGNED to the local forward-declared above _ShowDummyDebuffs
-- (which paints Debuffs-anchored containers inline and needs this pool), not
-- re-declared -- a second `local` here would shadow it and leave the row
-- pass's upvalue nil.
_ensurePreviewContainerIcon = function(frame, kind, ci, slot)
    slot = slot or 1
    frame.SF_PreviewContainerIcons = frame.SF_PreviewContainerIcons or {}
    local byKind = frame.SF_PreviewContainerIcons[kind]
    if not byKind then byKind = {}; frame.SF_PreviewContainerIcons[kind] = byKind end
    local slots = byKind[ci]
    if type(slots) ~= "table" then slots = {}; byKind[ci] = slots end
    local icon = slots[slot]
    if not icon then
        local level = frame:GetFrameLevel() + 223
        icon = BuildAuraIconFrame(frame, level)
        slots[slot] = icon
    end
    return icon
end

-- Hide every pooled slot of container ci from `fromSlot` onward (default: all).
-- v92 §B7.2: assigned to the forward-declared local (see above).
_hidePreviewContainerSlots = function(frame, kind, ci, fromSlot)
    local root = frame.SF_PreviewContainerIcons
    local byKind = root and root[kind]
    local slots = byKind and byKind[ci]
    if type(slots) ~= "table" then return end
    for slot, icon in pairs(slots) do
        if slot >= (fromSlot or 1) then
            if icon and icon:IsShown() then icon:Hide() end
            -- Stop any container Icon Effect animation on the hidden slot
            -- (animation groups keep stepping on hidden frames).
            if icon and BF.ClearPreviewIconEffectFx then BF.ClearPreviewIconEffectFx(icon) end
            SetDummyTooltip(icon, nil)
        end
    end
end

local function _hideAllPreviewContainerIcons(frame, kind)
    local root = frame.SF_PreviewContainerIcons
    local byKind = root and root[kind]
    if not byKind then return end
    for _, slots in pairs(byKind) do
        if type(slots) == "table" then
            for _, icon in pairs(slots) do
                if icon and icon:IsShown() then icon:Hide() end
                if icon and BF.ClearPreviewIconEffectFx then BF.ClearPreviewIconEffectFx(icon) end
                SetDummyTooltip(icon, nil)
            end
        end
    end
end

-- Paint ONE preview icon (border, duration/swipe/font, dispel border + corner
-- icon). Geometry-agnostic: the caller sizes/positions the icon frame; this only
-- styles it. `dispellable` = this icon represents a dispellable preset (draws the
-- blue dispel border + Magic corner icon). Returns nothing.
-- v92 §B7.2: assigned to the forward-declared local (see above) -- the Debuffs
-- row pass styles its inline container icons through this same function, which
-- is why every per-container override previews inline for free.
_paintPreviewContainerIcon = function(self, frame, icon, c, ci, kind, ac,
                                          groupTypeKey, ApplyDummyIcon, texPath,
                                          size, dispellable, tooltip)
    local isDebuff = (kind == "debuff")
    -- Border via the per-container resolver (honors Use Buffs/Debuffs Border).
    local rStyle, rColor, rThick, rBlizz =
        self:ResolveContainerBorder(c, groupTypeKey, ac, isDebuff and "debuff" or nil)
    local borderStyle     = DummyBorderStyle(rStyle, rBlizz)
    local borderThickness = rThick
    local borderColor     = rColor
    local blizzAtlas      = isDebuff and "ui-debuff-border-default-noicon" or nil
    local bR = borderColor and borderColor.r or 0
    local bG = borderColor and borderColor.g or 0
    local bB = borderColor and borderColor.b or 0
    local bA = borderColor and (borderColor.a or 0.8) or 0.8
    -- Dispellable presets draw the magic-blue dispel border at full opacity, at
    -- the Dispel Border Width, across every style incl. Blizzard — but ONLY when
    -- "Color Border by Dispel Type" is on (default). When off, a dispellable
    -- preview keeps the configured Border Color (resolved above).
    local colorByDispel = true
    if isDebuff and self.ResolveContainerColorBorderByDispel then
        local on = self:ResolveContainerColorBorderByDispel(c, groupTypeKey, ac)
        if on == nil then on = ac.debuffColorBorderByDispel ~= false end
        colorByDispel = on and true or false
    end
    if dispellable and colorByDispel then
        bR, bG, bB, bA = 0.20, 0.60, 1.00, 1
        blizzAtlas = "ui-debuff-border-magic-noicon"
        borderThickness = ac.debuffDispelBorderThickness or borderThickness or 2
    end
    -- Duration / swipe / spark / font, via the per-container resolver.
    local baseAuto, baseShowDur, baseFont, baseSize, baseBorder
    local baseTimer, baseColor, baseSwipe, baseSpark, baseRev, baseCurve
    if isDebuff then
        baseAuto, baseShowDur = ac.debuffAutoScale, ac.showDebuffDuration
        baseFont, baseSize    = ac.debuffDurationFont, ac.debuffFontSize or 11
        baseBorder, baseTimer = ac.debuffDurationBorder or "OUTLINE", ac.debuffTimerScale or 1.0
        baseColor             = ac.debuffFontColor
        baseSwipe, baseSpark  = ac.disableDebuffSwipe or false, ac.disableDebuffSpark or false
        baseRev, baseCurve    = ac.reverseDebuffSwipe == true, ac.expiringCurveDebuff
    else
        baseAuto, baseShowDur = ac.buffAutoScale, ac.showBuffDuration
        baseFont, baseSize    = ac.buffDurationFont, ac.buffFontSize or 11
        baseBorder, baseTimer = ac.buffDurationBorder or "OUTLINE", ac.buffTimerScale or 1.0
        baseColor             = ac.buffFontColor
        baseSwipe, baseSpark  = ac.disableBuffSwipe or false, ac.disableBuffSpark or false
        baseRev, baseCurve    = ac.reverseBuffSwipe == true, ac.expiringCurveBuff
    end
    local showDuration, autoScale = baseShowDur, baseAuto
    local dFont, dFontSize, dBorder, dTimerScale = baseFont, baseSize, baseBorder, baseTimer
    local dFontColor, dSwipe, dSpark, dRev, dCurve = baseColor, baseSwipe, baseSpark, baseRev, baseCurve
    if self.ResolveContainerDuration then
        local r = self:ResolveContainerDuration(c, groupTypeKey, ac, isDebuff and "debuff" or nil)
        if r then
            showDuration, autoScale = r.showDur, r.autoScale
            dFont, dFontSize = r.durationFont, r.fontSize or 11
            dBorder, dTimerScale = r.durationBorder or "OUTLINE", r.timerScale or 1.0
            dFontColor, dSwipe, dSpark, dRev, dCurve = r.fontColor, r.swipeDis, r.sparkDis, r.revSwipe, r.expCurve
        end
    end
    local bfSize  = autoScale and 11 or dFontSize
    local bfScale = autoScale and (size / 12 * (dTimerScale or 1.0)) or 1.0

    ApplyDummyIcon(icon, texPath, bR, bG, bB, size, showDuration,
        dSwipe, dSpark, dRev,
        dFont, bfSize, dBorder, bfScale,
        bA, dFontColor, nil, dCurve, borderThickness, borderStyle, blizzAtlas)

    -- v94: this pool is now shared with the Buff List pass, which paints
    -- per-ENTRY icon effects onto buff-kind slots (_PaintSingleBuffDummy). The
    -- fx block below is debuff-only, so without this a buff container's
    -- representative icon could inherit the glow of a single buff that used to
    -- hold this slot -- reachable by deleting an entry, which shifts the array
    -- and hands its index to a different container. Cleared unconditionally on
    -- the buff kind; the debuff arm's own resolve/clear is untouched.
    if not isDebuff and BF.ClearPreviewIconEffectFx then
        BF.ClearPreviewIconEffectFx(icon)
    end

    -- Dispel-type CORNER ICON (dispellable presets only, when the setting is on).
    local dtiIcon = icon._bf_prevDispelTypeIcon
    local wantDTI, dtiScale = false, 40
    if dispellable then
        local on, sc = nil, nil
        if self.ResolveContainerDispelTypeIcon then
            on, sc = self:ResolveContainerDispelTypeIcon(c, groupTypeKey, ac)
        end
        if on == nil then
            on = ac.showDebuffDispelTypeIcon == true
            sc = ac.debuffDispelTypeIconScale or 40
        end
        wantDTI = on and true or false
        dtiScale = sc or 40
    end
    -- ── Container ICON EFFECT (debuff containers only — Glow / Marching
    -- Ants / Flash, v92 Effects group). Resolved through the SAME
    -- BF:ResolveContainerIconEffect the live spec builder uses, painted
    -- through the per-spell preview's exported fx painter
    -- (PreviewIconEffects.lua) — same art, geometry and pulse behavior
    -- as both the live path and the per-spell preview. Cleared when the
    -- effect is None so a turned-off effect leaves no stale art; the
    -- clear is a cheap no-op on icons never painted.
    -- NOTE: called AFTER the icon is sized (the caller owns geometry, and
    -- both call sites SetSize before painting) — the fx layout reads the
    -- icon's current width.
    if isDebuff and self.ResolveContainerIconEffect and BF.PaintPreviewIconEffectFx then
        local ie = self:ResolveContainerIconEffect(c, groupTypeKey)
        if ie then
            BF.PaintPreviewIconEffectFx(icon, ie)
        elseif BF.ClearPreviewIconEffectFx then
            BF.ClearPreviewIconEffectFx(icon)
        end
    end

    if wantDTI then
        if not dtiIcon then
            -- Host frame ABOVE the dummy cooldown so the swipe doesn't cover the
            -- badge (mirrors the live path's _bf_textFrame > cd). A plain texture
            -- on `icon` sits below the child Cooldown frame. The duration text
            -- (icon.cooldown.timerText, on the cooldown) still draws above this.
            local host = icon._bf_prevDTIFrame
            if not host then
                host = CreateFrame("Frame", nil, icon)
                host:SetAllPoints(icon)
                icon._bf_prevDTIFrame = host
            end
            if icon.cooldown then
                host:SetFrameLevel(icon.cooldown:GetFrameLevel() + 1)
            end
            dtiIcon = BF.Texture(host, nil, "OVERLAY", nil, 3)
            dtiIcon:SetAtlas("RaidFrame-Icon-DebuffMagic")
            icon._bf_prevDispelTypeIcon = dtiIcon
        elseif icon._bf_prevDTIFrame and icon.cooldown then
            -- Keep the host above the cooldown across re-paints / size changes.
            icon._bf_prevDTIFrame:SetFrameLevel(icon.cooldown:GetFrameLevel() + 1)
        end
        local dsz = size * (dtiScale / 100)
        dtiIcon:SetSize(dsz, dsz)
        local dn = dsz * 0.35
        dtiIcon:ClearAllPoints()
        dtiIcon:SetPoint("CENTER", icon, "TOPRIGHT", -dn, -dn)
        dtiIcon:Show()
    elseif dtiIcon then
        dtiIcon:Hide()
    end
    SetDummyTooltip(icon, tooltip)
end

-- Build the ordered preset list for a debuff container's multi-icon preview:
-- one entry { pkey, order, ratio, rank, tex, dispellable } per assigned preset.
-- Two callers, two orders (v92 §B7.2):
--   * FLOATING container (`ranks` nil) -- sorted LARGEST-FIRST (ratio desc, tie
--     by canonical preset order) to mirror the live layoutIndex ordering.
--     v92 (combined pairs): the old "nil for a 0/1-preset container" early-out
--     is gone -- it collapsed "no presets" and "one preset" into one answer, and
--     the caller then re-derived the icon from c.presets (GetContainerPreviewIcon),
--     which is the STORED set. A suppressed partner would have kept its floating
--     icon that way. Now nil means EMPTY and a one-entry list is returned, so the
--     caller reads the single icon out of this same effective list. It branches on
--     #list > 1 for the multi-icon arm, so a one-preset container previews exactly
--     as before.
--   * INLINE (DEBUFFS-anchored, `ranks` = ComputeDebuffPresetRanks) -- sorted by
--     RANK asc, because the row merges these entries with the base dummies at
--     Debuff Category Priority positions; ratio no longer decides anything
--     there (it is already folded into the flow set's size mult). No 0/1
--     early-out either: a ONE-preset anchored container still contributes its
--     icon to the row.
-- v92 §B7.2: assigned to the forward-declared local (see above).
-- 2026-09-14: `ac` is the frame's aura cache -- the per-Layout debuffs
-- profile the Relative Size now lives on. Without it the ratio resolver saw
-- only the container's (cleared) copy and a floating preview never moved.
_debuffPresetPreviewList = function(self, c, ranks, ci, pairOwn, ac)
    if not (c and c.presets) then return nil end
    local defs, order = BF.DEBUFF_CONTAINER_PRESETS, BF.DEBUFF_CONTAINER_PRESET_ORDER
    if not (defs and order) then return nil end
    -- v92 (combined pairs): walk the container's EFFECTIVE preset set. On a
    -- Layout where the pair's Combine box is ticked, the owner of the FIRST
    -- member carries the partner virtually and any other container stops
    -- carrying it -- the same single substitution the live claim / presence
    -- builders make (DebuffIcons.lua). `pairOwn` nil (no pair combined, or a
    -- caller with no Layout context) reads stored presets, byte-identical to
    -- pre-v92.
    --
    -- REENTRANCY: EffectiveDebuffPresetSet may hand back a module scratch that
    -- its NEXT call re-points, so the set is consumed to completion in the loop
    -- below and never escapes this function -- nothing inside re-enters it
    -- (_DebuffPresetRatioKey and _DebuffPresetRatio are pure reads), and the
    -- returned list is a fresh table. No copy needed.
    local presets = c.presets
    if pairOwn and ci and BF._EffectiveDebuffPresetSet then
        presets = BF._EffectiveDebuffPresetSet(c, ci, pairOwn) or presets
    end
    local list = {}
    for i = 1, #order do
        local pk = order[i]
        if presets[pk] then
            -- v92: ratio under the ALIAS key -- a virtual partner renders at the
            -- FIRST member's Relative Size (owner decision 3), so the two halves
            -- of one unit can never size differently. Same read as
            -- ComputeDebuffFlowSet / ComputeDebuffPresetPresence.
            local rk = (pairOwn and BF._DebuffPresetRatioKey
                and BF._DebuffPresetRatioKey(pk, pairOwn)) or pk
            local ratio = (BF._DebuffPresetRatio and BF._DebuffPresetRatio(c, rk, ac)) or 1.0
            list[#list + 1] = {
                pkey = pk, order = i, ratio = ratio,
                rank = ranks and (ranks[pk] or i) or nil,
                tex = defs[pk].previewIcon,
                -- v92: BOTH dispel presets. The test used to read
                -- `allDispellable or meDispellable`, but v91 retired
                -- allDispellable (migrated to othersDispellable), so the first
                -- term was dead and a By-Others container previewed with the
                -- plain border instead of the Magic one. §B7.2 makes that
                -- visible: an inline icon now sits directly beside base dummies
                -- carrying the correct per-type borders.
                dispellable = (pk == "meDispellable" or pk == "othersDispellable"),
            }
        end
    end
    if ranks then
        if #list == 0 then return nil end
        table.sort(list, function(a, b)
            if a.rank ~= b.rank then return a.rank < b.rank end
            return a.order < b.order
        end)
        return list
    end
    -- v92: EMPTY is the only nil now (see the header) -- a one-entry list is a
    -- real answer the caller paints as its single representative icon.
    if #list == 0 then return nil end
    if #list > 1 then
        table.sort(list, function(a, b)
            if a.ratio ~= b.ratio then return a.ratio > b.ratio end
            return a.order < b.order
        end)
    end
    return list
end

-- Paint the preview icon(s) for every container of one kind.
local function _paintContainerKind(self, frame, kind, containers, fakeNow, fakeDur)
    if not containers or #containers == 0 then
        _hideAllPreviewContainerIcons(frame, kind)
        return
    end
    local isDebuff = (kind == "debuff")
    local ac = self:GetAuraCacheForFrame(frame)
    local groupTypeKey = frame._bf_containerGroupTypeKey or self:ResolveGroupTypeKey(frame)
    local ApplyDummyIcon = MakeApplyDummyIcon(fakeNow, fakeDur)

    -- v92 (combined pairs): one ownership resolution for the whole pass, the
    -- twin of the row assembler's. Debuff containers only -- the pairs are
    -- debuff presets, and a buff container has no effective view to resolve.
    -- Holding it across the container loop is safe: nothing this painter calls
    -- (ResolveContainerGeometry / Border / Duration, _paintPreviewContainerIcon)
    -- re-enters ResolveDebuffPairOwnership, so the interned per-pair state it
    -- points at cannot be re-pointed mid-pass.
    local pairOwn = isDebuff and BF._ResolveDebuffPairOwnership
        and BF._ResolveDebuffPairOwnership(ac, groupTypeKey) or nil

    -- Per-layout gate active for THIS preview frame's layout? (Mirrors the live
    -- ComputeDebuffPresetPresence / ApplyDebuffCustomContainers gate.)
    --
    -- v65: hoist the GROUP RESOLUTION, never the ANSWER. The gate has two
    -- axes (BF:IsContainerPerLayoutActive): the CONTAINER's own perLayoutConfig
    -- flag, and -- on a CFG scope only -- that group's override flag for this
    -- sub-category. The first is per container, so a hoisted answer would
    -- ignore it. groupTypeKey is fixed for the whole loop, so resolving the
    -- GROUP once keeps the linear ResolveCFGGroupByFlatID scan at one per
    -- repaint and leaves each container one field read plus a boolean OR.
    -- Do not "restore" the old whole-answer hoist.
    -- 2026-08-25: the per-preset preview count, the same slider the main
    -- Debuffs row uses. Each preset is additionally clamped by its own type's
    -- Max Debuffs below -- "preview count for each group, or that group's Max,
    -- whichever is lower".
    local perGroupIcons = (BF.db and BF.db.global and BF.db.global.previewDebuffCount) or 3
    if perGroupIcons < 1 then perGroupIcons = 1 end
    local subcat = isDebuff and "debuffs" or "buffs"
    local grpKey = BF.AURAS_SUBCAT_GROUP[subcat] or "aurasBuffs"
    local cfgFlag = BF.AURAS_GROUP_CFG_FLAG and BF.AURAS_GROUP_CFG_FLAG[grpKey]
    local isCFG = type(groupTypeKey) == "string" and not groupTypeKey:find("^flat_")
    local grp   = isCFG and self.ResolveCFGGroupByFlatID
        and self:ResolveCFGGroupByFlatID(groupTypeKey) or nil
    local cfgOn = (grp and cfgFlag and grp[cfgFlag]) and true or false

    -- ── v94: BUFF LIST buckets for this pass ──────────────────────────────
    -- Two of the four buckets land here: entries anchored INSIDE a multi-icon
    -- buff container (matrix rows 12-13) append to that host's own preview
    -- run, and entries on a real frame point (rows 3, 6) get the single
    -- representative icon this painter already draws per container -- which is
    -- why the c.singleBuff skip below is lifted for exactly those.
    --
    -- Buff containers only: a single buff is a BUFF container by construction,
    -- so the debuff pass has nothing to merge.
    local sbSet   = (not isDebuff) and _SingleBuffPreviewItems(self, frame, ac, groupTypeKey) or nil
    -- The container tab's own set, when the Buff List is not previewing:
    -- the viewed container's anchored buffs, on its slots (the v94 host
    -- arm below paints them).
    if (not isDebuff) and sbSet == nil then
        sbSet = _ContainerTabPreviewItems(self, frame, ac, groupTypeKey)
    end
    -- 2026-09-15 (owner ruling): on a buff container's tab, the buff pass
    -- paints THAT container and no other -- the tab previews the buffs
    -- assigned to it, and the row painters hide the regular Buffs row and
    -- Big Defensive for the same reason (BuildSharedState's
    -- containerTabOnly). Same stamp, read the same way: the containerMgmt
    -- mode and the index SetContainerPreview stamped on arrival. Preview
    -- frames only; the debuff pass is not narrowed, it follows the dropdown.
    local onlyCI = nil
    if (not isDebuff) and frame._isPreviewFrame
       and self.IsPreviewingContainerMgmt and self:IsPreviewingContainerMgmt() then
        onlyCI = self.GetPreviewContainerIndex and self:GetPreviewContainerIndex() or nil
    end
    local sbFloat = nil
    if sbSet then
        for i = 1, #sbSet.floating do
            sbFloat = sbFloat or {}
            sbFloat[sbSet.floating[i].ci] = sbSet.floating[i]
        end
    end

    for ci, c in ipairs(containers) do
        -- ── v92 §B7.2: ROUTING (and THE crash guard) ──────────────────────
        -- A DEBUFFS-anchored debuff container does not render as a BLOCK at
        -- its own geometry: its claimed presets flow INSIDE the main Debuffs
        -- row, and the row pass (_ShowDummyDebuffs) paints them into this very
        -- pool and owns their slots. So skip such a container's geometry and
        -- paint whole -- and skip the per-ci sweep too WHEN THE ROW ACTUALLY
        -- PAINTED IT, because that sweep would hide exactly what the row just
        -- drew.
        --
        -- This is ALSO the crash guard: ResolveContainerGeometry returns the
        -- "DEBUFFS" sentinel RAW (it is not a frame point -- see
        -- BF.IsFlowAnchorValue), and the two icon:SetPoint(anchor, ...) sites
        -- below would throw on it. That is the exact "BUFFS" failure
        -- Single_Buffs_Buffs_Anchor_Plan.md §9.1 documents.
        local rowOwned = isDebuff and self.IsDebuffContainerDebuffsAnchored
            and self:IsDebuffContainerDebuffsAnchored(c, groupTypeKey) or false
        if rowOwned then
            -- v92 §B7.2: the ownership gap. The two passes do NOT share a
            -- visibility gate -- this painter runs on pvShowDebuffs alone,
            -- while the row also gates on the section's own showDebuffs /
            -- showDummyDebuffs / dispelDebuffBorderOnly / customAurasOnly. Flip
            -- a container to the Debuffs anchor while the ROW is hidden and the
            -- row early-returns with an empty _bf_rowOwnedCI, so nobody ever
            -- clears the FLOATING icon it left behind -- it would hang on the
            -- frame forever. Sweeping it here is safe precisely because
            -- _bf_rowOwnedCI names the containers the row DID paint: absent
            -- from that map means nothing of ours is on screen to protect.
            if not (frame._bf_rowOwnedCI and frame._bf_rowOwnedCI[ci]) then
                _hidePreviewContainerSlots(frame, kind, ci, 1)
            end
        else
            local perLayoutActive = c.perLayoutConfig == true or cfgOn
            -- Owner rules: single whitelist buffs never preview; a globally
            -- disabled container never previews.
            --
            -- v94: "never preview" still holds everywhere EXCEPT the Buff List
            -- pass, which is the one place whose whole job is previewing them.
            -- Only entries the collector actually put in the floating bucket
            -- are lifted -- an entry anchored into a flow host is appended to
            -- that host's run below instead, and must NOT be drawn here: its
            -- anchorPoint is a sentinel ("BUFFS" / "BIGDEF" / "C:<key>") that
            -- ResolveContainerGeometry returns RAW, and the icon:SetPoint below
            -- would throw on it. Same crash guard as the DEBUFFS-anchored
            -- routing above.
            local sbHere = sbFloat and sbFloat[ci] or nil
            local skip = (c.singleBuff == true and not sbHere) or (c.enabled == false)
            -- The container tab's narrowing (see onlyCI above): every other
            -- container of this kind is swept, not painted.
            if onlyCI ~= nil and ci ~= onlyCI then skip = true; sbHere = nil end
            -- v71: also respect the per-container "Enabled for this Layout"
            -- (showForGroupType) gate — a container disabled for this layout must
            -- not preview on that layout's frame, matching the live frames.
            if not skip and perLayoutActive and c.groupSettings then
                local gs = c.groupSettings[groupTypeKey]
                if gs and gs.showForGroupType == false then skip = true end
            end
            -- v71: a debuff container with 2+ presets previews ONE icon per preset,
            -- each at its Relative Size, in a row (largest first) so the sizes are
            -- visible. Otherwise: one representative icon (buff containers, single-
            -- preset debuff containers, spell-derived).
            -- v92 (combined pairs): EFFECTIVE list (`ci`/`pairOwn`) -- a container
            -- storing only the pair's first member previews BOTH icons here (the
            -- partner virtual, at the first member's Relative Size), and one
            -- storing only the suppressed partner previews neither. It also
            -- feeds the single-icon arm below, so both arms read one set.
            local presetList = (not skip) and isDebuff
                and _debuffPresetPreviewList(self, c, nil, ci, pairOwn, ac) or nil

            -- Geometry (size/anchor/grow) once per container.
            -- 2026-08-25: _perRow is READ now (the per-preset counts wrap by
            -- it); the remaining underscored locals are still unused.
            local size, _maxIcons, _spacing, _rowSpacing, _perRow, anchor, offX, offY, growDir =
                self:ResolveContainerGeometry(c, groupTypeKey, ac, isDebuff and "debuff" or nil)
            size = size or 12
            anchor = anchor or (isDebuff and "BOTTOMLEFT" or "BOTTOMRIGHT")
            local nx, ny = AnchorNudge(anchor)
            local baseX, baseY = (offX or 0) + nx, (offY or 0) + ny
            -- Row grow: which way and along which axis. Default matches the debuff
            -- anchor (BOTTOMLEFT grows RIGHT). Vertical grow stacks on Y.
            local norm = (BF.NormalizeGrowDirection and BF.NormalizeGrowDirection(growDir, anchor)) or growDir
            local vertical = BF.GrowDirectionIsVertical and BF.GrowDirectionIsVertical(norm) or false
            -- Sign of the row step along the primary axis: horizontal grows +X
            -- unless "LEFT"; vertical grows +Y ("UP") unless "DOWN".
            local ns = type(norm) == "string" and norm or ""
            local negative
            if vertical then negative = ns:find("DOWN") ~= nil
            else negative = ns:find("LEFT") ~= nil end
            -- 2026-08-25 FIX (owner report: "I updated the icon spacing in a
            -- container and the preview doesn't update"). This was a hardcoded
            -- SPACING = 1 while ResolveContainerGeometry's own `spacing` and
            -- `rowSpacing` -- the container's Icon Spacing and Row/Column
            -- Spacing -- were unpacked and thrown away.
            --
            -- Pixel-rounded like the main row's cursor, so a container block
            -- and the Debuffs row snap identically.
            --
            -- _maxIcons stays unused, deliberately: the engine gives a debuff
            -- container one GROUP PER PRESET, each capped by its own type's Max
            -- Debuffs (applied per preset just above), so a single
            -- container-wide ceiling here would cap the preview at a number no
            -- live group honors.
            local SPACING = BF:PixelRound(_spacing or 1)
            local ROWSPACING = BF:PixelRound(_rowSpacing or 0)

            -- ── 2026-08-25 (owner report): PER-PRESET COUNTS ─────────────
            -- A floating debuff container previewed ONE icon per preset --
            -- so a container holding only Crowd Control drew a single icon
            -- however high its Max Debuffs was, and fell into the single
            -- representative arm below on top of that. Each preset now
            -- contributes min(Preview Debuffs, that preset's Max) icons, the
            -- same rule the main Debuffs row uses, and a debuff container is
            -- routed into the multi-icon arm whenever the TOTAL exceeds one.
            --
            -- The cap is the debuff TYPE's Max (BF:ResolveDebuffPresetMax maps
            -- preset -> row), which is the number the live container honors;
            -- the preview slider is the other half of the min(), exactly as in
            -- the row.
            local presetCount, totalIcons = nil, 0
            if presetList and isDebuff then
                presetCount = {}
                for idx, p in ipairs(presetList) do
                    local n = perGroupIcons
                    local cap = BF.ResolveDebuffPresetMax
                        and BF:ResolveDebuffPresetMax(ac, p.pkey)
                    if cap and cap < n then n = cap end
                    if n < 1 then n = 1 end
                    presetCount[idx] = n
                    if p.tex then totalIcons = totalIcons + n end
                end
            end
            local slotCount = 0
            if presetList and (#presetList > 1 or totalIcons > 1) then
                -- One RUN per preset, largest-first, laid out along the grow
                -- axis accumulating each icon's own (different) size, and
                -- wrapping by the container's own Icons Per Row.
                --
                -- Wrapping is new with the counts and is why maxPerRow is read
                -- at all (it was resolved and discarded before): three presets
                -- at Max 3 would otherwise draw a nine-icon strip that ignores
                -- the layout the container is actually configured for. Cross-
                -- axis step is the completed line's TALLEST icon -- the same
                -- mixed-size rule the main row's cursor uses.
                local maxPerRow = _perRow or 0
                if maxPerRow < 1 then maxPerRow = #presetList end
                if maxPerRow < 1 then maxPerRow = 1 end
                local cursor, lineMax, col, cross = 0, 0, 0, 0
                for idx, p in ipairs(presetList) do
                    local isz = math.max(2, math.floor(size * (p.ratio or 1) + 0.5))
                    local tex = p.tex
                    if tex then
                        local label = "Setup Mode: " .. (BF.DEBUFF_CONTAINER_PRESETS[p.pkey]
                            and BF.DEBUFF_CONTAINER_PRESETS[p.pkey].name or p.pkey)
                        for _ = 1, (presetCount and presetCount[idx] or 1) do
                            if col >= maxPerRow then
                                cross = cross + lineMax + ROWSPACING
                                cursor, lineMax, col = 0, 0, 0
                            end
                            slotCount = slotCount + 1
                            local icon = _ensurePreviewContainerIcon(frame, kind, ci, slotCount)
                            icon:SetSize(isz, isz)
                            local dx, dy = baseX, baseY
                            local step  = (negative and -1 or 1) * cursor
                            -- The cross axis is whichever one the grow axis is
                            -- not; its sign follows the anchor the same way the
                            -- primary step does.
                            local xstep = (negative and -1 or 1) * cross
                            if vertical then
                                dy = baseY + step
                                dx = baseX + xstep
                            else
                                dx = baseX + step
                                dy = baseY + xstep
                            end
                            icon:ClearAllPoints()
                            icon:SetPoint(anchor, frame, anchor, dx, dy)
                            _paintPreviewContainerIcon(self, frame, icon, c, ci, kind, ac,
                                groupTypeKey, ApplyDummyIcon, tex, isz, p.dispellable,
                                label)
                            icon:Show()
                            cursor = cursor + isz + SPACING
                            if isz > lineMax then lineMax = isz end
                            col = col + 1
                        end
                    end
                end
            else
                -- Single representative icon.
                -- v92 (combined pairs): a DEBUFF container takes its icon and its
                -- dispel bit from the effective list above, not from
                -- GetContainerPreviewIcon -- that helper scans c.presets, the
                -- STORED set, so a container holding only a suppressed partner
                -- would still paint the partner's icon here. Debuff containers are
                -- preset-only (see GetContainerPreviewIcon's own note), so the
                -- list is the whole answer for them; with the pair flags off it
                -- resolves to the same single preset, first in canonical order.
                -- Buff containers keep the helper -- presets, then spell-derived.
                -- The dispel bit is now read off that one entry too, which is
                -- exactly what the old `meDispellable or othersDispellable` test
                -- said for a one-preset container (v91 retired allDispellable);
                -- _debuffPresetPreviewList is the single place that decides it.
                local single = presetList and presetList[1] or nil
                local texPath, dispellable = nil, false
                if sbHere then
                    -- v94: a free-floating single buff. It uses this arm's
                    -- geometry (its own anchor, offsets and size, all resolved
                    -- by ResolveContainerGeometry exactly as for any other
                    -- container) but its OWN visual resolvers, so the paint is
                    -- routed to _PaintSingleBuffDummy instead of the
                    -- container-field painter below.
                    slotCount = 1
                    local icon = _ensurePreviewContainerIcon(frame, kind, ci, 1)
                    local dR, dG, dB, dA = BF.GetDefaultBorderColorFor("buff", ac)
                    if _PaintSingleBuffDummy(self, frame, icon, sbHere, size, ac,
                            groupTypeKey, ApplyDummyIcon, dR, dG, dB, dA,
                            "Setup Mode: " .. (c.name or tostring(sbHere.sid))) then
                        icon:SetSize(size, size)
                        icon:ClearAllPoints()
                        icon:SetPoint(anchor, frame, anchor, baseX, baseY)
                        icon:Show()
                    else
                        slotCount = 0
                    end
                elseif skip then
                    texPath = nil
                elseif isDebuff then
                    texPath     = single and single.tex or nil
                    dispellable = (single and single.dispellable) and true or false
                else
                    texPath = self:GetContainerPreviewIcon(c, ci, kind)
                end
                if texPath then
                    slotCount = 1
                    local icon = _ensurePreviewContainerIcon(frame, kind, ci, 1)
                    icon:SetSize(size, size)
                    icon:ClearAllPoints()
                    icon:SetPoint(anchor, frame, anchor, baseX, baseY)
                    _paintPreviewContainerIcon(self, frame, icon, c, ci, kind, ac,
                        groupTypeKey, ApplyDummyIcon, texPath, size, dispellable,
                        "Setup Mode: Container " .. (c.name or tostring(ci)))
                    icon:Show()
                end
            end
            -- ── v94: entries anchored INSIDE this container ───────────
            -- Matrix rows 12-13: the entry flows in the HOST, so it is drawn
            -- on the host's own slots, continuing the host's cursor along its
            -- grow axis. Painted before the sweep below, so slotCount covers
            -- them and they are released with the rest of the host's slots
            -- when the host goes away or the entry re-anchors.
            local sbIn = sbSet and sbSet.byCI[ci] or nil
            if sbIn and #sbIn > 0 and not skip then
                local step = (vertical and (negative and -1 or 1))
                    or (negative and -1 or 1)
                local dR, dG, dB, dA = BF.GetDefaultBorderColorFor("buff", ac)
                -- Continue past whatever the host itself drew, at the host's
                -- own spacing. The host's icons are all `size`, so the cursor
                -- start is exact; each entry then advances by its OWN size,
                -- which is what makes the run mixed-size.
                local cursor = slotCount * (size + SPACING)
                for i = 1, #sbIn do
                    local it = sbIn[i]
                    local isz = BF:PixelRound(
                        self:ResolveContainerGeometry(it.c, groupTypeKey, ac, nil) or size)
                    local icon = _ensurePreviewContainerIcon(frame, kind, ci, slotCount + 1)
                    if _PaintSingleBuffDummy(self, frame, icon, it, isz, ac,
                            groupTypeKey, ApplyDummyIcon, dR, dG, dB, dA,
                            "Setup Mode: " .. (it.c.name or tostring(it.sid))) then
                        slotCount = slotCount + 1
                        icon:SetSize(isz, isz)
                        icon:ClearAllPoints()
                        if vertical then
                            icon:SetPoint(anchor, frame, anchor, baseX, baseY + cursor * step)
                        else
                            icon:SetPoint(anchor, frame, anchor, baseX + cursor * step, baseY)
                        end
                        icon:Show()
                        cursor = cursor + isz + SPACING
                    end
                end
            end
            -- Hide any leftover slots of this container beyond what we painted.
            _hidePreviewContainerSlots(frame, kind, ci, slotCount + 1)
        end
    end
    -- Hide pooled icons of containers that no longer exist (index past #containers).
    local root = frame.SF_PreviewContainerIcons
    local byKind = root and root[kind]
    if byKind then
        for idx, slots in pairs(byKind) do
            if idx > #containers and type(slots) == "table" then
                for _, icon in pairs(slots) do
                    if icon and icon:IsShown() then
                        -- v94: its sibling _hidePreviewContainerSlots already
                        -- clears fx; this sweep did not, so a deleted entry's
                        -- glow outlived the icon it was hidden on.
                        if BF.ClearPreviewIconEffectFx then BF.ClearPreviewIconEffectFx(icon) end
                        icon:Hide()
                    end
                    SetDummyTooltip(icon, nil)
                end
            end
        end
    end
end

function BF:ShowGeneralContainerPreviews(frame, showBuffs, showDebuffs, fakeNow, fakeDur)
    if not frame then return end
    fakeNow = fakeNow or GetTime()
    fakeDur = fakeDur or 30
    -- Clear the LEGACY spec-driven buff-container pool (SF_CustomContainerIcons)
    -- once: earlier builds / the Container-Management path may have left icons
    -- there, and this new painter uses its own SF_PreviewContainerIcons pool.
    if self.HideDummyContainerAuras then self:HideDummyContainerAuras(frame) end
    if showBuffs then
        _paintContainerKind(self, frame, "buff", self:GetActiveCustomBuffContainers(), fakeNow, fakeDur)
    else
        _hideAllPreviewContainerIcons(frame, "buff")
    end
    if showDebuffs then
        _paintContainerKind(self, frame, "debuff", self:GetActiveCustomDebuffContainers(), fakeNow, fakeDur)
    else
        -- v92 §B7.2: this arm only runs when the Debuffs side of the Preview
        -- dropdown is OFF, which also hides the row -- so _ShowDummyDebuffs has
        -- already dropped its inline icons and cleared _bf_rowOwnedCI. Wiping
        -- the whole pool here is the same answer, one pass later.
        _hideAllPreviewContainerIcons(frame, "debuff")
        frame._bf_rowOwnedCI = nil
    end
end

-- Hide every general-container preview icon (both kinds) on a frame.
function BF:HideGeneralContainerPreviews(frame)
    if not frame then return end
    _hideAllPreviewContainerIcons(frame, "buff")
    _hideAllPreviewContainerIcons(frame, "debuff")
    -- v92 §B7.2: the row's inline-slot bookkeeping goes with them, so the next
    -- row pass does not walk a map of already-hidden slots.
    frame._bf_rowOwnedCI = nil
end

-- ============================================================
-- _ShowDummyNameRoleHealth(self, frame, isRaid)
-- Show/hide name/role/health on the preview/test frame based on
-- text/icons profile settings.
--
-- 2026-08-30: the two sections resolve through GetSectionProfileForFrame
-- rather than rpDB.profile.text / .icons directly, so a preview frame sees
-- ITS OWN flat's values (and a CFG preview its override) exactly like every
-- other paint path. The old global-only reads pre-dated per-Layout routing.
-- ============================================================
local function _ShowDummyNameRoleHealth(self, frame, isRaid)
    local tp = self:GetSectionProfileForFrame("text",  frame) or {}
    local ip = self:GetSectionProfileForFrame("icons", frame) or {}
    if frame.nameText then
        if tp.showName then
            frame.nameText:Show()
        else
            frame.nameText:Hide()
        end
    end

    -- ---- ROLE ICON ----
    -- Visibility is NOT decided here. It belongs to the role-icon painters:
    -- ApplyPreviewRoleIcon (Preview/Options_PreviewData.lua) for options
    -- preview frames, RoleIcon:Update for live / setup-mode frames. Only they
    -- apply the per-role filters (showRoleIconTank / Healer / DPS), the Custom
    -- Frame Group module flag, and the current style's texture.
    --
    -- Owner-reported bug: a bare Show() here re-showed an icon the per-role
    -- filter had just hidden, and because the painter returns BEFORE touching
    -- the texture when it hides, the re-shown icon kept whatever art it last
    -- carried -- so the Raid preview (the only preview whose fake unit is a
    -- DAMAGER) displayed a stale-style DPS icon with DPS icons switched off,
    -- and dragged the previous profile's style back after a profile swap.
    -- This pass runs on the preview aura timer, so it always won the race.
    -- Delegate to the painter; only the feature-off case is answered locally.
    if frame.roleIcon then
        if not ip.showRoleIcons then
            frame.roleIcon:Hide()
        elseif frame._isPreviewFrame then
            local paint = BF._preview and BF._preview.ApplyPreviewRoleIcon
            if paint then
                paint(frame, isRaid, self.db and self.db.profile,
                      frame._flatID or frame._previewTier)
            end
        else
            self:UpdateRoleIcon(frame)
        end
    end

end

-- ============================================================
-- BF:ShowDummyAuras(frame, isRaid, raidProfile, overridePartyProfile)
-- Monolithic entry point: resolves shared state, installs the 30s
-- dummy-cooldown restart timer, and invokes each per-type helper
-- in order. Behavior is byte-identical to the pre-split version.
-- Called by:
--   * The 30s restart timer closure (self-recurring)
--   * Options_PreviewSystem.lua ApplyPreviewDummyAuras (full preview
--     refresh and the 30s preview timer)
--   * Setup-mode test frame renders
-- ============================================================
function BF:ShowDummyAuras(frame, isRaid, raidProfile, overridePartyProfile)
    if not frame then return end
    -- 12.1: suspend live aura containers while dummies render on this frame.
    -- v67: 12.0.7 branch removed (addon is 12.1-only).
    if self.SuspendFrameAuraContainers then
        self:SuspendFrameAuraContainers(frame)
    end

    local fakeDur = 30
    local fakeNow = GetTime()
    local s = BuildSharedState(self, frame, isRaid, raidProfile, overridePartyProfile, fakeNow, fakeDur)

    -- Lazy aura slot creation + slot size re-stamp.
    EnsureSlotsAndBackdrop(self, frame, s)

    -- Cancel any old restart timer before setting a new cooldown start time
    if frame.SF_DummyRestartTimer then
        frame.SF_DummyRestartTimer:Cancel()
        frame.SF_DummyRestartTimer = nil
    end

    -- Schedule a restart after fakeDur seconds so icons don't go stale.
    -- Preview frames use RefreshPreviewDummyAuras' _previewAuraTimer instead
    -- of a per-frame timer, avoiding duplicate refreshes. Non-preview frames
    -- (setup mode test frames) still need per-frame timers.
    if not frame._isPreviewFrame then
        local capturedIsRaid    = isRaid
        local capturedProfile   = raidProfile
        local capturedPartyProf = overridePartyProfile
        frame.SF_DummyRestartTimer = C_Timer.NewTimer(fakeDur, function()
            frame.SF_DummyRestartTimer = nil
            if BF.ShouldShowPreviewAuras and BF:ShouldShowPreviewAuras() then
                BF:ShowDummyAuras(frame, capturedIsRaid, capturedProfile, capturedPartyProf)
            end
        end)
    end

    _ShowDummyBuffs(self, frame, s)
    _ShowDummyDebuffs(self, frame, s)  -- includes _ShowDummyStackText on idx=1
    _ShowDummyBigDef(self, frame, s)
    _ShowDummyDispelBorders(self, frame, s)
    -- v67: _ShowDummyPrivateAuras call removed with the Private Auras feature.
    _ShowDummyContainerAuras(self, frame, s)
    _ShowDummyNameRoleHealth(self, frame, isRaid)
end

-- ============================================================
-- Per-type public wrappers.
--
-- Each resolves the same shared state as BF:ShowDummyAuras (via
-- BuildSharedState) and invokes a SINGLE _ShowDummy<Type> helper.
-- They do NOT install a restart timer — the monolithic entry point
-- owns that, and these wrappers are only used for targeted refreshes
-- triggered by Options aura-text setters (which happen while the
-- monolithic timer is already running, or while the options-tab
-- visit will schedule one via ApplyPreviewDummyAuras).
--
-- EnsureSlotsAndBackdrop is called first so per-type refreshes on a
-- freshly-created preview frame don't skip slot creation.
-- ============================================================

function BF:ShowDummyBuffs(frame, isRaid, raidProfile, overridePartyProfile)
    if not frame then return end
    local fakeDur = 30
    local fakeNow = GetTime()
    local s = BuildSharedState(self, frame, isRaid, raidProfile, overridePartyProfile, fakeNow, fakeDur)
    EnsureSlotsAndBackdrop(self, frame, s)
    _ShowDummyBuffs(self, frame, s)
end

function BF:ShowDummyDebuffs(frame, isRaid, raidProfile, overridePartyProfile)
    if not frame then return end
    local fakeDur = 30
    local fakeNow = GetTime()
    local s = BuildSharedState(self, frame, isRaid, raidProfile, overridePartyProfile, fakeNow, fakeDur)
    EnsureSlotsAndBackdrop(self, frame, s)
    _ShowDummyDebuffs(self, frame, s)
end

function BF:ShowDummyBigDef(frame, isRaid, raidProfile, overridePartyProfile)
    if not frame then return end
    local fakeDur = 30
    local fakeNow = GetTime()
    local s = BuildSharedState(self, frame, isRaid, raidProfile, overridePartyProfile, fakeNow, fakeDur)
    EnsureSlotsAndBackdrop(self, frame, s)
    _ShowDummyBigDef(self, frame, s)
end

-- v67: BF:ShowDummyPrivateAuras removed with the Private Auras feature.
-- v69: BF:ShowDummyCrowdControl removed with the dedicated Crowd Control
-- feature (now a seeded custom debuff container).

-- Stack text is rendered on the first preview debuff icon. Callers
-- should ensure debuffs have been painted first (idx=1 must be Show()n)
-- or the stack FontString has nothing to attach to. In the normal
-- Aura Text → Stack Text setter flow the debuffs are already on-screen
-- from the prior full preview refresh, so this is a pure re-stamp of
-- the stack count font/anchor/scale on the existing icon.
function BF:ShowDummyStackText(frame, isRaid, raidProfile, overridePartyProfile)
    if not frame then return end
    local fakeDur = 30
    local fakeNow = GetTime()
    local s = BuildSharedState(self, frame, isRaid, raidProfile, overridePartyProfile, fakeNow, fakeDur)
    EnsureSlotsAndBackdrop(self, frame, s)
    _ShowDummyStackText(self, frame, s)
end

-- ============================================================
-- Batch multi-type refresh: builds shared state ONCE and calls
-- the requested type helpers. Used by RefreshPreviewDummyGlobal
-- to avoid rebuilding BuildSharedState 6 times per frame.
--
-- typeFlags: table with optional boolean keys:
--   buffs, debuffs, bigDef,
--   stackText, containers, dispelBorders, nameRoleHealth
--   (v67: the privateAuras flag was removed with the Private Auras feature.)
-- ============================================================
function BF:ShowDummyBatch(frame, isRaid, raidProfile, overridePartyProfile, typeFlags)
    if not frame then return end
    local fakeDur = 30
    local fakeNow = GetTime()
    local s = BuildSharedState(self, frame, isRaid, raidProfile, overridePartyProfile, fakeNow, fakeDur)
    EnsureSlotsAndBackdrop(self, frame, s)
    if typeFlags.buffs          then _ShowDummyBuffs(self, frame, s)          end
    if typeFlags.debuffs        then _ShowDummyDebuffs(self, frame, s)        end
    if typeFlags.bigDef         then _ShowDummyBigDef(self, frame, s)         end
    -- v67: the privateAuras branch was removed with the Private Auras feature.
    if typeFlags.stackText      then _ShowDummyStackText(self, frame, s)      end
    if typeFlags.dispelBorders  then _ShowDummyDispelBorders(self, frame, s)  end
    if typeFlags.containers     then _ShowDummyContainerAuras(self, frame, s) end
    if typeFlags.nameRoleHealth then _ShowDummyNameRoleHealth(self, frame, isRaid) end
end
