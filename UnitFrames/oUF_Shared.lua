-- ============================================================
-- BuzzardFrames: oUF_Shared.lua
-- Shared style function and helpers for oUF-based bluzzard frames.
-- Loaded before oUF_Player.lua and oUF_Target.lua.
-- ============================================================
local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")
-- Embedded oUF (Libs\oUF) stores itself in the addon's private namespace
-- table (ns.oUF, set in Libs\oUF\init.lua). All files in this addon share
-- the same ns table, so we read it directly per the oUF embedding docs:
-- https://github.com/oUF-wow/oUF/wiki/Embedding
local _, ns = ...
local oUF = ns.oUF
assert(oUF, "BuzzardFrames: embedded oUF not found in addon namespace (ns.oUF)")
BF.oUF = oUF  -- cache on BF for oUF_Player / oUF_Target

-- 12.x "secrets": while execution is tainted by the addon, some engine
-- unit-info returns (UnitClass token, class-colored GetStatusBarColor, ...)
-- come back as forbidden/secret values. Indexing them or passing them into
-- a texture setter throws "Attempt to access forbidden object". Guard every
-- such value with canaccessvalue() before touching it (Grid2 pattern:
-- GridShims.UnitClassSafe, StatusColor.lua). Fallback preserves pre-12.x
-- clients where the global does not exist.
local canaccessvalue = canaccessvalue or function() return true end

-- v95: localized for the profiler's idle-gated inline segment timing in
-- Health.PostUpdate (BF._profActive -> BF:_ProfSeg). Present on all 12.x
-- clients; the segment calls are gated so this only matters while profiling.
local GetTimePreciseSec = GetTimePreciseSec

-- v92: power-type index → PowerTypeColors token, for Override-forced
-- displayTypes (Balance Druid mana). File-local — this used to be a table
-- literal allocated inside Power.PostUpdate.
local POWER_TOKEN_BY_TYPE = { [0] = "MANA", [1] = "RAGE", [2] = "FOCUS", [3] = "ENERGY" }


-- ============================================================
-- Unit-frame border mode (v59 rounded borders)
-- "square" | "rounded" | "rounded_thick" — one setting for ALL unit
-- frames (Unit Frames → Global → Borders). Rounded modes reuse the
-- raid-frame ring/mask machinery: the same Frame* nine-sliced art
-- (Indicators/Container.lua), the same v58 pixel host
-- (BF:StampRingPixelHost) and the same hidden-mask-off convention.
-- Style checks route through BF.IsRoundedBorderStyle (Container.lua)
-- so the two systems can never disagree on what counts as rounded.
-- ============================================================
function BF:GetOUFBorderMode()
    local p = self.ufDB and self.ufDB.profile
    return (p and p.oufBorderMode) or "square"
end

function BF:IsOUFRounded()
    return BF.IsRoundedBorderStyle and BF.IsRoundedBorderStyle(self:GetOUFBorderMode()) or false
end

-- v90: master enable for the FRAME border in rounded modes. Global
-- Styles' Enable Border writes all three <bar>BorderEnabled keys, so
-- "any of the three on" is the rounded outline's enable — a legacy
-- profile with a single bar's border off keeps its ring, while the
-- Global Styles toggle (all three off) kills it. Square mode never
-- reads this: each box checks its own key as before.
function BF:IsOUFBorderEnabled()
    local p = self.ufDB and self.ufDB.profile
    if not p then return false end
    return p.nameBorderEnabled == true
        or p.healthBorderEnabled == true
        or p.powerBorderEnabled == true
end

-- v90.4 (owner report: with the icon on the LEFT, the health bar's
-- right edge sat 1-2px past the power bar's right edge): the anchor
-- side for a bar must be the ICON-side decision, not the bar's own
-- chord inset. A bar whose own inset happened to be 0 (icon chord not
-- reaching it) anchored to the icon side with offset 0 and derived
-- its FAR edge as anchor + PixelRound(width) — a different rounding
-- path from its neighbors' direct offset-0 far-side anchors, one
-- pixel off at fractional frame positions. Every bar/box now anchors
-- to the NON-ICON side whenever a circular icon is active
-- (frame._iconChordSide, stamped by _ComputeOUFIconInsets), falling
-- back to the old per-bar rule when no icon chord is in play.
function BF:GetOUFBarAnchorSide(frame, inL)
    local side = frame and frame._iconChordSide
    if side == "left"  then return "TOPRIGHT" end
    if side == "right" then return "TOPLEFT" end
    return ((inL or 0) > 0) and "TOPRIGHT" or "TOPLEFT"
end

-- Rounded border art: the SAME dedicated Frame* asset family the raid
-- frames use (128px source, 32px slice margins — margins MUST match the
-- art; see Indicators/Container.lua for the v56 geometry: outer corner
-- radius 6.4 texels, masks inset to the mid-band so content underlaps
-- the ring with no gap and no sliver). Local path constants (in-repo
-- precedent: Container.lua keeps local pixel helpers "to avoid
-- cross-file dependency"). NOTE the v61 UF band remap below: the UF
-- modes deliberately map one weight HEAVIER than the raid modes.
local ROUND_SLICE            = 32

-- v61 UF band remap (owner request): with identical art the UF rings
-- read one weight THINNER in situ than the raid rings, so the UF modes
-- map one step heavier — UF Rounded uses the raid THICK pair (3-texel
-- band) and UF Rounded (Thick) uses a NEW extra-thick pair
-- (FrameBorderXThick / FrameMaskXThick: 4.5-texel band, generated to
-- the exact v56 spec — 128px/32-margin, outer corner radius 6.4, hard
-- edges with ≤1-texel AA, mask = the ring's outer silhouette inset by
-- half the band so content sits mid-band). The raid mapping
-- (BF:GetRoundedBorderRing) is untouched.
-- v87: the v61 remap above is RETIRED (owner report: "the border on
-- the unit frames looks genuinely different compared to the raid/party
-- frames", and the one-heavier outline sat next to the true-weight
-- 2px piece-built bar borders, reading as "the power bar border is way
-- thinner than the health bar border"). The UF composite now uses the
-- IDENTICAL art pair the raid frames use (Container.lua mapping):
-- Rounded = FrameBorder (2-texel band), Thick = FrameBorderThick
-- (3-texel) -- matching the piece-kit band weights (2/3 phys px) and
-- the raid look exactly. FrameBorderXThick/FrameMaskXThick are
-- retired from defaults.
-- v90: the composite outline is PIECE-BUILT (ApplyUFBarRoundBorder on
-- the composite rect -- see _ApplyOUFRoundedFrameBorder), so the
-- sliced ring texture below is no longer drawn at all. The RING paths
-- stay: the piece kit cuts its corner caps from the ring art.
-- v90.1: briefly swapped the composite content mask to the Bar* class
-- to escape the FrameMask 32-margin degeneration; reverted in v90.2 —
-- superseded by the v90.7 corner-mask sets below.
local ROUND_UF_RING_TEX = {
    rounded       = "Interface\\AddOns\\BuzzardFrames\\Media\\FrameBorder",
    rounded_thick = "Interface\\AddOns\\BuzzardFrames\\Media\\FrameBorderThick",
}

-- ════════════════════════════════════════════════════════════════
-- v90.8: EDGE-STRIP CONTENT MASKS (two per bar) — the sliced
-- rounded-rect masks AND the v90.7 four-corner masks are retired.
--
-- Two hard facts drove this design, both established live:
--   1. THE ENGINE'S SLICING RULE (fit-short): a nine-sliced texture
--      renders its texels scaled by regionShort/artSize — corners are
--      NOT drawn at a fixed art scale. Every observation across
--      v90.2-v90.6 fits it: FrameMask(128) on 40-80px bars rendered
--      tiny corners; FrameMaskSmall(32) was exact at 32-phys-px bar
--      height (scale 1) and grew past it; the raid frames stay
--      correct because ring and mask are both sliced and scale
--      together; v63's "renders square" on 13px bars is the curve at
--      scale 13/128. A sliced mask therefore can never pair the
--      kits' FIXED-size caps across bar heights.
--   2. THE ENGINE'S MASK LIMIT: a texture accepts at most THREE mask
--      textures ("Texture already has the maximum number of mask
--      textures (3)" — live error), so v90.7's four per-corner
--      masks were unattachable.
--
-- The strip design satisfies both. Each bar gets TWO masks:
--   TOP    — full-width strip anchored to the bar's top edge,
--   BOTTOM — full-width strip anchored to the bar's bottom edge,
-- each drawn from 64x64 art (FrameMaskEdgeTop/Bottom + Thick pair,
-- generated from the FrameMask texels: two corner curves on the
-- strip's outer edge, the 1-texel side insets running the full
-- height, everything else opaque) sliced at 16-texel margins
-- (artSize/4, the proven ratio). The strip's HEIGHT is set in code
-- to EDGE_MASK_ART * capScale physical px, so by the fit-short rule
-- the engine's texel scale is pinned to exactly capScale — corner
-- curves render pixel-paired with the ring caps at EVERY bar size,
-- because the mask's short dimension no longer depends on the bar.
-- On short bars the strips overlap and the masks multiply, each
-- contributing only its own curves. Two masks per region sits
-- comfortably under the 3-mask limit.
-- v90.9: a SLICED mask contributes nothing outside its own rect (see
-- StampCornerMaskSet), so a strip is now grown when the bar is taller
-- than the design height rather than leaving the middle uncovered.
-- NEW FILES (client RESTART required once): FrameMaskEdgeTop,
-- FrameMaskEdgeBottom, FrameMaskThickEdgeTop, FrameMaskThickEdgeBottom.
-- (The v90.6/v90.7 FrameMaskSmall*/FrameMaskCorner* files are
-- orphaned and can be deleted.)
-- ════════════════════════════════════════════════════════════════
local EDGE_MASK_ART   = 64  -- art size in texels; strip height at capScale 1
local EDGE_MASK_SLICE = 16  -- artSize/4 (corner blocks hold the 6.4 curve)
local EDGE_MASK_KEYS  = { "TOP", "BOTTOM" }
local ROUND_UF_EDGE_MASK_TEX = {
    rounded = {
        TOP    = "Interface\\AddOns\\BuzzardFrames\\Media\\FrameMaskEdgeTop",
        BOTTOM = "Interface\\AddOns\\BuzzardFrames\\Media\\FrameMaskEdgeBottom",
    },
    rounded_thick = {
        TOP    = "Interface\\AddOns\\BuzzardFrames\\Media\\FrameMaskThickEdgeTop",
        BOTTOM = "Interface\\AddOns\\BuzzardFrames\\Media\\FrameMaskThickEdgeBottom",
    },
}

local BAR_KIT_CORNERS = { "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT" }

-- Build one TOP/BOTTOM strip-mask set on `owner`. BLOCKING LOAD is
-- mandatory: the textures are swapped live on rounded<->thick and an
-- async-loading mask erases its region until it finishes.
local function EnsureCornerMaskSet(owner)
    local set = {}
    for i = 1, 2 do
        local m = BF.MaskTexture(owner)
        if m.SetBlockingLoadsRequested then
            m:SetBlockingLoadsRequested(true)
        end
        m:SetTextureSliceMargins(EDGE_MASK_SLICE, EDGE_MASK_SLICE,
            EDGE_MASK_SLICE, EDGE_MASK_SLICE)
        m:Hide()
        set[EDGE_MASK_KEYS[i]] = m
    end
    return set
end

-- Stamp art/anchor/height on a strip set. stripH is the strip height
-- in the anchor frame's UI units — EDGE_MASK_ART * capScale physical
-- px, which pins the engine's fit-short texel scale to capScale.
-- topOff (optional) lifts the TOP strip that many UI units above the
-- anchor's top edge — used by same-frame kits that draw a shared-edge
-- top band above the bar (see ApplyUFBarRoundBorder's topShared).
-- Snap AFTER SetTexture — these strips are created through the
-- unsnapping funnel (BF.Texture) and snap is the point here.
--
-- ── v90.9 COVERAGE (owner report: "when I increase the height of a
-- health bar above 35 the border keeps growing but the bar doesn't —
-- there's a gap between the bottom of the health bar and the bottom
-- border, in rounded / rounded thick only") ─────────────────────────
-- The reported threshold IS the strip height: EDGE_MASK_ART = 64
-- PHYSICAL px, ≈35 UI units at a typical effective scale. Up to that
-- height the two strips overlap and between them cover the whole bar;
-- one pixel past it they no longer do, and the uncovered middle is
-- erased — the mask does NOT extend past its own rect here.
--
-- That is specific to these masks being SLICED. A plain mask does
-- extend: _oufIconCutoutMask is stamped "CLAMP" and the whole design
-- of its art (opaque field around a transparent disc) depends on the
-- engine reading that opaque edge alpha far outside the mask's rect —
-- and it works. The strips are the only masks in the file carrying
-- SetTextureSliceMargins, and they are the only ones that cut content
-- off at their own edge, so nine-slicing is what drops the
-- outside-rect contribution.
--
-- The fix therefore does NOT rely on wrap semantics: each strip is
-- grown to at least cover the anchor rect it is masking, so there is
-- no outside-the-strip region left for the engine to erase.
--
-- THE TRADE, stated plainly: under the design's own fit-short rule a
-- grown strip renders ABOVE scale 1, so on a rect taller than 64
-- phys px the fill's corner curve (and the art's 1-texel side inset)
-- scale by rectH/64 instead of staying pinned — a 90px bar rounds its
-- fill ~9px against 8px ring caps and pulls the fill ~1.4px in from
-- the side bands, and it grows from there. That is worse than pinned
-- and better than the hole it replaces, and it applies ONLY where the
-- strips did not reach: the clamp cannot fire on a rect the design
-- height already covered, so nothing that renders correctly today
-- changes. If the fill-vs-cap corner on very tall bars becomes the
-- next complaint, the fix is strip ART that pins the curve at a
-- larger height, not a smaller clamp.
-- The wrap mode moves to "CLAMPTOWHITE" in the same pass: if slicing
-- turns out to honor wrap after all, clamping to OPAQUE is the
-- correct value for a mask whose outside must not erase anything
-- (the "CLAMP" transparent border would be exactly wrong), and it
-- costs nothing either way now that the strips cover the rect.
local function StampCornerMaskSet(set, anchorTo, mode, stripH, topOff)
    local paths = ROUND_UF_EDGE_MASK_TEX[mode]
        or ROUND_UF_EDGE_MASK_TEX.rounded
    topOff = topOff or 0
    -- Coverage clamp: the TOP strip starts topOff ABOVE the rect, so it
    -- needs that much extra to still reach the bottom edge. GetHeight()
    -- can read 0 on a rect that has only just been anchored; the clamp
    -- is simply skipped then and the next layout pass applies it.
    local coverH = (anchorTo:GetHeight() or 0) + topOff
    if coverH > stripH then stripH = coverH end
    for i = 1, 2 do
        local key = EDGE_MASK_KEYS[i]
        local m = set[key]
        local path = paths[key]
        if m._bf_lastTex ~= path then
            m:SetTexture(path, "CLAMPTOWHITE", "CLAMPTOWHITE")
            m._bf_lastTex = path
        end
        m:ClearAllPoints()
        if key == "TOP" then
            m:SetPoint("TOPLEFT",  anchorTo, "TOPLEFT",  0, topOff)
            m:SetPoint("TOPRIGHT", anchorTo, "TOPRIGHT", 0, topOff)
        else
            m:SetPoint("BOTTOMLEFT",  anchorTo, "BOTTOMLEFT",  0, 0)
            m:SetPoint("BOTTOMRIGHT", anchorTo, "BOTTOMRIGHT", 0, 0)
        end
        m:SetHeight(stripH)
        m:SetSnapToPixelGrid(true)
        m:SetTexelSnappingBias(0)
    end
end

local function ShowCornerMaskSet(set, shown)
    if not set then return end
    for i = 1, 2 do
        set[EDGE_MASK_KEYS[i]]:SetShown(shown and true or false)
    end
end

-- Swap the strip-mask SET attached to a region. Config/layout time
-- only (mode switches), so the Add/Remove churn the hidden-mask
-- convention avoids on hot paths is fine here; off-states still just
-- HIDE the attached set. Two masks per region — the engine allows
-- three.
local function SetRegionCornerMasks(tex, set)
    if not tex or tex._bfCMaskSet == set then return end
    local old = tex._bfCMaskSet
    if old then
        for i = 1, 2 do tex:RemoveMaskTexture(old[EDGE_MASK_KEYS[i]]) end
    end
    if set then
        for i = 1, 2 do tex:AddMaskTexture(set[EDGE_MASK_KEYS[i]]) end
    end
    tex._bfCMaskSet = set
end

local function RoundedUFRingPath(mode)
    return ROUND_UF_RING_TEX[mode] or ROUND_UF_RING_TEX.rounded
end

-- (v90.7: the sliced content-mask lineage is fully retired from the
-- UF border paths — BarMask/BarMaskThick (v63 small-bar class),
-- StampBarRoundMask/StampRoundMask, and the scaled mask pixel hosts
-- are gone; the corner-mask sets above are the single content-mask
-- mechanism. The Bar* mask files stay on disk: HET and history use
-- them. v88 note preserved: the v86 BarCornerCaps atlas is retired —
-- caps are cut from the Frame* ring art directly; see the
-- standalone-bar kit section.)

-- Ring tint: ONE color for the whole rounded outline (owner decision) —
-- frameBorderColor + its alpha, shared by every unit frame ring,
-- standalone-bar ring, and resource pip ring.
local function GetRingColor()
    local p = BF.ufDB and BF.ufDB.profile
    local c = p and p.frameBorderColor
    if c then return c.r or 0, c.g or 0, c.b or 0, c.a or 1 end
    return 0, 0, 0, 1
end

-- ============================================================
-- Unit-frame AURA border style (v60, per-kind split v68)
-- "blizzard" | "flat" | "rounded" | "rounded_thick".
-- v68: accepts an optional `kind` ("buffs" | "debuffs") to resolve
-- the per-kind keys (oufBuffBorderStyle / oufDebuffBorderStyle).
-- Falls back to the legacy shared key (oufAuraBorderStyle) when the
-- per-kind key is nil, so pre-v68 profiles work unchanged.
-- Called without `kind`, returns the shared style (backward compat for
-- callers that don't distinguish).
--
-- The dual-key rule still applies: BOTH *Style and *UseBlizzardBorders
-- must agree. The options setter always writes both together.
-- ============================================================
function BF:GetOUFAuraBorderStyle(kind)
    local p = self.ufDB and self.ufDB.profile
    if not p then return "blizzard" end

    -- Per-kind keys (v68)
    local styleKey, flagKey
    if kind == "buffs" then
        styleKey, flagKey = "oufBuffBorderStyle", "oufBuffUseBlizzardBorders"
    elseif kind == "debuffs" then
        styleKey, flagKey = "oufDebuffBorderStyle", "oufDebuffUseBlizzardBorders"
    end

    -- Try per-kind first, fall back to shared
    local v    = styleKey and p[styleKey] or p.oufAuraBorderStyle
    local flag = flagKey  and p[flagKey]  or p.oufAuraUseBlizzardBorders

    if v == "rounded" or v == "rounded_thick" then return v end
    -- `~= false`, not a plain truth test: the legacy render-path reads
    -- the flag DIRECTLY (`== false` checks that pick FlatCreateButton),
    -- so a nil flag means Blizzard to them. Matching that exactly here
    -- keeps all paths in agreement.
    if v == "blizzard" or flag ~= false then return "blizzard" end
    return v or "flat"
end

-- Rounded aura-icon art (v60): the STRETCHED (unsliced) aura treatment
-- from Auras/ContainerFactory.lua — IconMask clips the icon (and is the
-- swipe texture, so the swipe matches the rounded shape), IconBorder /
-- IconBorderThick is the ring drawn just outside the button (outer
-- offset 0.5 thin / 1 thick = the visible side thickness, v59 rethin).
local ROUND_AURA_RING_TEX       = "Interface\\AddOns\\BuzzardFrames\\Media\\IconBorder"
local ROUND_AURA_RING_THICK_TEX = "Interface\\AddOns\\BuzzardFrames\\Media\\IconBorderThick"
local ROUND_AURA_MASK_TEX       = "Interface\\AddOns\\BuzzardFrames\\Media\\IconMask"
-- v68: swipe uses the dedicated hardened/dilated asset, not the mask — the
-- mask's AA corner alpha left the ring's corner arc under-darkened under
-- mipmap filtering. See ROUND_SWIPE_TEX in Auras/ContainerFactory.lua.
local ROUND_AURA_SWIPE_TEX      = "Interface\\AddOns\\BuzzardFrames\\Media\\IconSwipe"

-- Dispel color map for the rounded ring binding: the owner's dispel
-- colors (engine recolors the ring per dispel type via PreserveAsset)
-- with the configured border color as the "None" base so
-- non-dispellable debuffs keep the plain border look. RGB-ONLY entries
-- — the engine recolor ignores map alpha (raid v63 finding); border
-- alpha lives on the ring HOST frame instead (raid v65 pattern).
local function RoundedAuraDispelMap(owner, bc)
    local m = {}
    for k, c in next, owner.colors.dispel do
        m[k] = { r = c.r, g = c.g, b = c.b }
    end
    if bc and not ((bc.r or 0) == 0 and (bc.g or 0) == 0 and (bc.b or 0) == 0) then
        m.None = { r = bc.r or 0, g = bc.g or 0, b = bc.b or 0 }
    end
    return m
end

-- Bluzzard style constants
BF.bluzzardIconSide = {
    player       = "LEFT",   -- portrait overhangs the left
    target       = "RIGHT",  -- portrait overhangs the right
    focus        = "RIGHT",  -- portrait overhangs the right (mirrors target)
    targettarget = "RIGHT",  -- portrait overhangs the right (mirrors target)
    focustarget  = "RIGHT",  -- portrait overhangs the right (mirrors target)
    pet          = "LEFT",   -- portrait overhangs the left (mirrors player)
    boss1        = "RIGHT",  -- boss frames mirror target
    boss2        = "RIGHT",
    boss3        = "RIGHT",
    boss4        = "RIGHT",
    boss5        = "RIGHT",
}

-- ============================================================
-- Font override resolver for unit frame text elements.
-- Returns the resolved font path for a given element key, or
-- the supplied default if no override is configured.
-- ============================================================
function BF:GetOUFFont(elementKey, default)
    local p = self.ufDB and self.ufDB.profile
    if not p then return default end
    if not p.oufAdjustFonts then return default end
    local separate = p.oufSeparateFonts == true
    local name
    if separate and elementKey then
        name = p[elementKey]
    end
    if not name or name == "" then
        name = p.oufGlobalFont
    end
    if not name or name == "" then
        -- v61: with Adjust Fonts ON, unset keys resolve to the addon
        -- default font ("PT Sans Narrow") — exactly what the Fonts page
        -- dropdowns display for unset keys, and the same fallback
        -- RefreshOUFFonts uses. Returning the per-call-site `default`
        -- here made layouts and the font refresher disagree, so fonts
        -- flip-flopped depending on which ran last.
        return self:ResolveFontPath("PT Sans Narrow")
    end
    return self:ResolveFontPath(name)
end

-- ============================================================
-- Shared style function
-- oUF calls this once per spawned frame. `self` is the oUF unit frame,
-- `unit` is the unit string ("player", "target", etc.).
-- ============================================================
-- ============================================================
-- Power type colors matched to Blizzard's muted palette.
-- ============================================================
-- Power type colors: uses the shared BF.PowerTypeColors table (Core.lua)
-- so raid/party frames and oUF frames always match.

-- ============================================================
-- Aura cooldown/duration styling (12.1 AuraContainer)
-- Applied per pooled button at init (PostCreateAuraButton) AND live
-- from the BF:RestyleOUFAuraButtons walk (v61: these are plain
-- Cooldown widget property setters on OUR cd frames — the same call
-- class the raid ApplyCooldownStyle re-runs live — so the Duration/
-- Cooldown settings no longer need a /reload).
-- ============================================================
local function ApplyUFAuraCooldownStyle(button)
    local p = BF.ufDB and BF.ufDB.profile
    local cd = button.Cooldown
    if not cd then return end
    local showDur   = p and (p.auraShowDuration == true) or false
    local showSwipe = not p or (p.auraShowSwipe ~= false)
    local showSpark = not p or (p.auraShowSpark ~= false)
    cd:SetHideCountdownNumbers(not showDur)
    cd:SetDrawSwipe(showSwipe)
    cd:SetDrawEdge(showSpark)
    -- CooldownFrameTemplate defaults SetReverse(true) in its XML.
    -- PTR-VERIFY: the container drives the cooldown via
    -- SetDurationCooldown; confirm it doesn't reset reverse per update
    -- (the old code had to re-apply this in PostUpdateButton).
    cd:SetReverse(not p or p.auraReverseSwipe ~= false)
    if showDur then
        local tt = cd:GetCountdownFontString()
        if tt then
            local sz = math.max(6, p and p.auraFontSize or 9)
            tt:SetFont("Interface\\AddOns\\BuzzardFrames\\Media\\Fonts\\RobotoCondensed-Bold.ttf", sz, "OUTLINE")
            -- Grid2 pattern: explicitly center the text
            tt:ClearAllPoints()
            tt:SetPoint("CENTER", cd, "CENTER", 0, 0)
        end
    end
end

-- ============================================================
-- Aura stack-count styling (12.1 AuraContainer)
-- Applied per pooled button at init (PostCreateAuraButton) AND live from
-- the BF:RestyleOUFAuraButtons walk. Before this the count FontString was
-- baked once with RobotoCondensed-Bold 9 OUTLINE at BOTTOMRIGHT 2/-2 and
-- never touched again, so unit-frame auras ignored every stack setting
-- while raid/party auras honored Aura Text > Stack Text.
--
-- Deliberate parity with Auras/ContainerFactory.lua's ApplyStackCountStyle:
-- same field meanings, same defaults, and auto-scale measured off the
-- button's own icon size against the same 12px baseline -- so "Auto Scale"
-- at a given Scale reads the same on a unit frame as on a raid frame.
-- `el` may be nil (init path); the size then falls back to the button.
-- ============================================================
local function ApplyUFAuraStackTextStyle(el, button)
    local count = button and button.Count
    if not count then return end
    local p = (BF.ufDB and BF.ufDB.profile) or {}

    count:SetFont(
        BF:ResolveFontPathOr(p.oufStackFont,
            "Interface\\AddOns\\BuzzardFrames\\Media\\Fonts\\RobotoCondensed-Bold.ttf"),
        p.oufStackFontSize or 9,
        p.oufStackFontBorder or "OUTLINE")
    count:SetTextColor(1, 1, 1)

    -- Auto scale: the icon size relative to the 12px baseline, times the
    -- user's multiplier. el._bf_size is the live effective size maintained
    -- by BF:_ApplyOUFAuraLiveGeometry; the rendered width is the fallback
    -- before the first geometry pass has run.
    local scale = 1
    if p.oufStackAutoScale == true then
        local sz = el and el._bf_size
        if not sz or sz <= 0 then
            sz = (button.GetWidth and button:GetWidth()) or 0
        end
        if not sz or sz <= 0 then sz = 18 end
        scale = sz / 12 * (p.oufStackScale or 1.0)
    end
    count:SetScale(scale)

    local anchor = p.oufStackAnchor or "BOTTOMRIGHT"
    count:ClearAllPoints()
    count:SetPoint(anchor, button, anchor, p.oufStackX or 4, p.oufStackY or -3)

    -- Show Stack Text. The FontString is BOUND to the engine's
    -- application count, and the engine owns its shown state (a bare
    -- binding shows it only above 1 application), so never force-show it
    -- -- only un-hide a string THIS function hid. Alpha is the real kill
    -- and the engine never touches alpha; the Hide() is belt-and-braces.
    local show = p.oufStackShow ~= false
    count:SetAlpha(show and 1 or 0)
    if show then
        if count._bf_stackHidden then
            count._bf_stackHidden = nil
            count:Show()
        end
    else
        count._bf_stackHidden = true
        count:Hide()
    end
end

-- ============================================================
-- PostCreateAuraButton (12.1 AuraContainer)
-- Fires ONCE per pooled AuraButton at init from FlatInitButton (the
-- unified init for every border style). Static widget styling only —
-- everything settings-driven lives in ApplyUFAuraCooldownStyle /
-- ApplyUFAuraButtonStyle so it can be re-stamped live.
-- ============================================================
local function PostCreateAuraButton(element, button, options)
    -- Stack count: fully settings-driven (Unit Frames > Global > Auras >
    -- Stack Text). Re-stamped live by BF:RestyleOUFAuraButtons.
    ApplyUFAuraStackTextStyle(element, button)
    ApplyUFAuraCooldownStyle(button)
end

-- ============================================================
-- UNIFIED UF AURA BUTTON INIT + LIVE RESTYLE (12.1 AuraContainer, v61)
-- Used in place of oUF's default CreateButton for EVERY border style
-- (including Blizzard-Style, whose look — full-bleed icon + engine
-- Border-art dispel texture — is replicated here from the lib default).
-- The new aura element hands us a Blizzard-pooled AuraButton to
-- INITIALIZE (nothing is returned); this fully replaces the lib
-- default, so it also wires the native sub-widget bindings (SetIcon /
-- SetDurationCooldown / SetApplicationCount / SetTooltipAnchorPoint).
-- Registered as element.CreateButton BEFORE AddGroup — the group
-- captures the init closure at AddGroup time.
--
-- LIVE SWITCHING (v61, raid ContainerFactory pattern): pooled buttons
-- cannot be re-initialized, but textures can't be destroyed either —
-- so ALL widget sets are created here at init (inactive ones hidden)
-- and ApplyUFAuraButtonStyle stamps the current style onto a button.
-- Buttons register on the element (_bf_buttons) so
-- BF:RestyleOUFAuraButtons can re-stamp every live button when the
-- style/color/thickness/stealable settings change — no /reload, same
-- call classes the raid restyle walk ships: SetPoint/SetTexCoord/
-- texture+color setters on OUR sub-regions, SetSwipeTexture, and
-- ClearDispelTypeTextures + re-Add (PTR-VERIFY: dispel re-binding
-- post-PEW — same flag the raid ApplyDispelBorderBinding carries).
--
-- Looks: Blizzard = full uncropped icon, full-bleed swipe, engine
-- Border-art dispel texture over the icon (lib default parity).
-- Flat = color/thickness-configurable WHITE8x8 underlay with inset
-- cropped icon (raid flat parity). Rounded = the raid aura-icon
-- treatment — stretched IconMask clip, mask-as-swipe (v57 1px swipe
-- expansion), IconBorder ring outside the button, PreserveAsset dispel
-- recolor of the ring with alpha on the ring host (raid v63/v65).
-- ============================================================
local function IsRoundedAuraStyle(s)
    return s == "rounded" or s == "rounded_thick"
end

-- Stamp the CURRENT profile style onto one button. Init + restyle path
-- (config-time only — never per-update).
local function ApplyUFAuraButtonStyle(element, button)
    local p = BF.ufDB and BF.ufDB.profile
    local kind = element._bf_kind  -- "buffs" or "debuffs"
    local style = BF:GetOUFAuraBorderStyle(kind)
    local rounded = IsRoundedAuraStyle(style)
    -- Per-kind border color (v68), falling back to the shared key
    local colorKey = (kind == "buffs" and "oufBuffBorderColor")
                  or (kind == "debuffs" and "oufDebuffBorderColor")
                  or "oufAuraBorderColor"
    local bc = (p and p[colorKey]) or (p and p.oufAuraBorderColor) or { r = 0, g = 0, b = 0, a = 0.8 }
    local ba = bc.a or 0.8

    local icon, cd = button.Icon, button.Cooldown
    local flat = button.FlatBorder
    local ring, ringHost = button._bf_roundRing, button._bf_ringHost
    local rmask = button._bf_roundMask

    -- ── Geometry + per-style widgets ─────────────────────────────────
    if style == "blizzard" then
        -- Lib-default parity: uncropped full-bleed icon + swipe.
        icon:ClearAllPoints()
        icon:SetAllPoints(button)
        icon:SetTexCoord(0, 1, 0, 1)
        cd:ClearAllPoints()
        cd:SetAllPoints(button)
        flat:Hide()
        if ring then ring:Hide() end
        if rmask then rmask:Hide() end
    elseif rounded then
        -- Full-bleed cropped icon clipped by the mask; swipe rect == RING
        -- rect (button expanded by `o`), so the swipe covers the border
        -- band exactly and stops on its outer edge.
        -- The ring art's outer contour is pixel-identical to the mask
        -- asset's (verified 256/256 rows), and the mask IS the swipe
        -- texture, so the two outer edges coincide — corners included.
        -- v59: uses raw `o`, matching the units the ring is anchored with.
        -- The old code expanded by BF:PixelsToUI(1) — PIXELS against a
        -- raw-unit `o` — so once v59 rethinned the ring (o: 1 → 0.5 for
        -- plain Rounded) the swipe overhung the ring's outer edge.
        local o = style == "rounded_thick" and 1 or 0.5
        icon:ClearAllPoints()
        icon:SetAllPoints(button)
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        flat:Hide()
        -- Ring FIRST, then the swipe anchored TO THE RING — see
        -- ApplyBorderInsets in Auras/ContainerFactory.lua. Matching
        -- numbers is not enough: a FRAME (cd) and a TEXTURE (ring) round
        -- their rects independently, and `o` is a HALF unit for plain
        -- Rounded, which is what produced the intermittent 1px corner
        -- overshoot. SetAllPoints makes them one rect by construction.
        if ring then
            ring:SetTexture(style == "rounded_thick"
                and ROUND_AURA_RING_THICK_TEX or ROUND_AURA_RING_TEX)
            -- Outer offset IS the visible side thickness (HET pattern,
            -- v59 rethin: 0.5 thin / 1 thick). Raw `o`, not PixelsToUI.
            ring:ClearAllPoints()
            ring:SetPoint('TOPLEFT', button, 'TOPLEFT', -o, o)
            ring:SetPoint('BOTTOMRIGHT', button, 'BOTTOMRIGHT', o, -o)
            ring:Show()
        end
        cd:ClearAllPoints()
        if ring then
            cd:SetAllPoints(ring)
        else
            cd:SetPoint('TOPLEFT', button, 'TOPLEFT', -o, o)
            cd:SetPoint('BOTTOMRIGHT', button, 'BOTTOMRIGHT', o, -o)
        end
        if rmask then rmask:Show() end
    else
        -- Flat: color/thickness-configurable underlay + inset icon.
        local thickKey = (kind == "buffs" and "oufBuffBorderThickness")
                      or (kind == "debuffs" and "oufDebuffBorderThickness")
                      or "oufAuraBorderThickness"
        local thickN = (p and (p[thickKey] or p.oufAuraBorderThickness)) or 1
        local borderSize = BF:PixelsToUI(thickN)
        icon:ClearAllPoints()
        icon:SetPoint('TOPLEFT', button, 'TOPLEFT', borderSize, -borderSize)
        icon:SetPoint('BOTTOMRIGHT', button, 'BOTTOMRIGHT', -borderSize, borderSize)
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        -- FULL-BLEED swipe: FlatBorder is SetAllPoints(button), so the
        -- border's outer edge IS the button rect and both shapes are
        -- square — a button-sized swipe covers the band exactly with
        -- nothing beyond. Parity with ApplyBorderInsets' flat branch.
        cd:ClearAllPoints()
        cd:SetAllPoints(button)
        flat:SetColorTexture(bc.r or 0, bc.g or 0, bc.b or 0, ba)
        flat:Show()
        if ring then ring:Hide() end
        if rmask then rmask:Hide() end
    end

    -- ── Swipe texture (rounded = the mask asset; the Blizzard
    -- Cooldown Manager trick). Restoring WHITE8X8 reads like the stock
    -- swipe; only ever touched on buttons that have been rounded, so
    -- never-rounded buttons keep the untouched template swipe (raid
    -- ApplyCooldownStyle pattern; PTR-VERIFY: runtime SetSwipeTexture).
    if rounded then
        cd:SetSwipeTexture(ROUND_AURA_SWIPE_TEX)
        button._bf_swipeRounded = true
    elseif button._bf_swipeRounded then
        cd:SetSwipeTexture([[Interface\Buttons\WHITE8x8]])
        button._bf_swipeRounded = nil
    end

    -- ── Dispel binding (per-style texture; re-bound on every stamp).
    -- ClearDispelTypeTextures also drops the stealable binding, so that
    -- is re-added below on every stamp too.
    -- 12.0.7 compat (v64): ClearDispelTypeTextures is unverified on the
    -- live client (the pre-restyle UF code bound once at init and never
    -- cleared). With it: clear + re-bind on every stamp (live style
    -- switches). Without it: bind ONCE for the current style and keep
    -- that binding — a later live style switch keeps the original
    -- binding's texture until reload (graceful degrade, never zero
    -- dispel coloring and never duplicate bindings).
    local wantsDispel = element.showDebuffBorder or element.showBuffBorder
    local canRebind = button.ClearDispelTypeTextures ~= nil
    if wantsDispel and (canRebind or not button._bf_dispelBound) then
        button._bf_dispelBound = true
        if canRebind then
            button:ClearDispelTypeTextures()
        end
        local harmful = element.showDebuffBorder and true or false
        local helpful = element.showBuffBorder and true or false
        if style == "blizzard" then
            -- Engine Border art over the icon (lib default parity).
            if button.DispelBorder then button.DispelBorder:Hide() end
            -- Show-before-bind (raid v65 edge-binding pattern); the
            -- engine drives visibility once bound.
            button.BlizzDispelBorder:Show()
            button:AddDispelTypeTexture(button.BlizzDispelBorder, {
                style = Enum.CustomAuraButtonDispelTypeTextureStyle
                    and Enum.CustomAuraButtonDispelTypeTextureStyle.Border or 0,
                showWhenHarmful = harmful,
                showWhenHelpful = helpful,
                customDispelColorMap = element.__owner.colors.dispel,
            })
        elseif rounded then
            -- Engine recolors the RING (PreserveAsset) with the border
            -- color as the "None" base — the ring doubles as the base
            -- border, so showWithoutDispelType is true. Alpha lives on
            -- the ring host (raid v63/v65 findings).
            if button.DispelBorder then button.DispelBorder:Hide() end
            if button.BlizzDispelBorder then button.BlizzDispelBorder:Hide() end
            button:AddDispelTypeTexture(ring, {
                style = Enum.CustomAuraButtonDispelTypeTextureStyle
                    and Enum.CustomAuraButtonDispelTypeTextureStyle.PreserveAsset or 3,
                showWhenHarmful = harmful,
                showWhenHelpful = helpful,
                showWithoutDispelType = true,
                customDispelColorMap = RoundedAuraDispelMap(element.__owner, bc),
            })
        else
            -- Flat: WHITE8x8 above the base underlay (below the icon),
            -- shown/colored per dispel type, hidden when there is none.
            if button.BlizzDispelBorder then button.BlizzDispelBorder:Hide() end
            -- Show-before-bind (raid v65 edge-binding pattern).
            button.DispelBorder:Show()
            button:AddDispelTypeTexture(button.DispelBorder, {
                style = Enum.CustomAuraButtonDispelTypeTextureStyle
                    and Enum.CustomAuraButtonDispelTypeTextureStyle.Border or 0,
                showWhenHarmful = harmful,
                showWhenHelpful = helpful,
                showWithoutDispelType = false,
                customDispelColorMap = element.__owner.colors.dispel,
            })
        end
        -- Re-add the stealable binding dropped by the Clear (on the
        -- bind-once path nothing was cleared — the init-time binding
        -- is still in place, so no re-add).
        if canRebind and button.Stealable then
            button:AddDispelTypeTexture(button.Stealable, {
                style = Enum.CustomAuraButtonDispelTypeTextureStyle
                    and Enum.CustomAuraButtonDispelTypeTextureStyle.PreserveAsset or 3,
                showWhenHelpful = true, -- required for stealableFilter (lib finding)
                showWithoutDispelType = true, -- probably required too (lib finding)
                stealableFilter = element.stealableBorderFilter
                    or Enum.CustomAuraButtonDispelTypeStealableFilter.Stealable,
            })
        end
    elseif wantsDispel then
        -- Bound-once client (no ClearDispelTypeTextures), later stamp:
        -- leave the original engine binding alone. Base-tint the ring
        -- so a live switch TO rounded never shows an untinted ring
        -- (the engine recolor, if the binding is on the ring, paints
        -- over this).
        if rounded and ring then
            ring:SetVertexColor(bc.r or 0, bc.g or 0, bc.b or 0, 1)
        end
    else
        -- No dispel binding on this container (buffs): the dispel
        -- textures are never engine-bound here, so keep them hidden in
        -- every style (v62 — a shown-by-default WHITE8x8 drew square
        -- corners past the rounded mask).
        if button.DispelBorder then button.DispelBorder:Hide() end
        if button.BlizzDispelBorder then button.BlizzDispelBorder:Hide() end
        if rounded and ring then
            -- Static ring tint (no engine recolor on this container).
            ring:SetVertexColor(bc.r or 0, bc.g or 0, bc.b or 0, 1)
        end
    end

    -- Ring host alpha applies in rounded mode regardless of binding.
    if ringHost then ringHost:SetAlpha(ba) end

    -- Stealable toggle is LIVE via its host's alpha (its binding stays
    -- in place — engine drives shown state; alpha survives recolors,
    -- raid v65 host-alpha pattern).
    if button._bf_stealableHost then
        button._bf_stealableHost:SetAlpha(
            (not p or p.oufAuraShowStealable ~= false) and 1 or 0)
    end
end

-- Style signature of one aura element: every profile input the three button
-- stamps read (ApplyUFAuraButtonStyle, ApplyUFAuraCooldownStyle,
-- ApplyUFAuraStackTextStyle), i.e. exactly what BF:RestyleOUFAuraButtons
-- re-applies. Icon size is NOT in it: size goes through
-- _ApplyOUFAuraLiveGeometry and its own recreate request.
--
-- WHY (plan §3.1 / §3.2 C, field report 2026-09-10): inside a keystone every
-- post-creation write on these buttons is denied, so the in-key answer to a
-- style edit is to re-declare the element's groups (new buttons are styled
-- inside initializeFrame). This sig is what tells a real edit from a no-op
-- pass: stamped at spawn, after a clean restyle walk and after a re-declare
-- (el._bf_bakedStyleSig), and compared in the restricted restyle branch.
-- Config-time only (allocates one string).
local function OUFAuraStyleSig(el)
    local p = (BF.ufDB and BF.ufDB.profile) or {}
    local kind = el._bf_kind
    local style = BF:GetOUFAuraBorderStyle(kind)
    local colorKey = (kind == "buffs" and "oufBuffBorderColor")
                  or (kind == "debuffs" and "oufDebuffBorderColor")
                  or "oufAuraBorderColor"
    local bc = p[colorKey] or p.oufAuraBorderColor or { r = 0, g = 0, b = 0, a = 0.8 }
    -- Thickness only drives the flat branch; outside it an edit is a no-op
    -- and must not cost a rebuild.
    local thick = ""
    if style ~= "blizzard" and not IsRoundedAuraStyle(style) then
        local thickKey = (kind == "buffs" and "oufBuffBorderThickness")
                      or (kind == "debuffs" and "oufDebuffBorderThickness")
                      or "oufAuraBorderThickness"
        thick = tostring(p[thickKey] or p.oufAuraBorderThickness or 1)
    end
    local showDur = (p.auraShowDuration == true)
    return table.concat({
        tostring(style), tostring(bc.r or 0), tostring(bc.g or 0),
        tostring(bc.b or 0), tostring(bc.a or 0.8), thick,
        tostring(el.showDebuffBorder and true or false),
        tostring(el.showBuffBorder and true or false),
        tostring(el._bf_stealableCandidate and (p.oufAuraShowStealable ~= false) or false),
        -- ApplyUFAuraCooldownStyle
        tostring(showDur), tostring(p.auraShowSwipe ~= false),
        tostring(p.auraShowSpark ~= false), tostring(p.auraReverseSwipe ~= false),
        showDur and tostring(p.auraFontSize or 9) or "",
        -- ApplyUFAuraStackTextStyle
        tostring(p.oufStackFont), tostring(p.oufStackFontSize or 9),
        tostring(p.oufStackFontBorder or "OUTLINE"),
        tostring(p.oufStackAutoScale == true),
        tostring(p.oufStackAutoScale == true and (p.oufStackScale or 1.0) or ""),
        tostring(p.oufStackAnchor or "BOTTOMRIGHT"), tostring(p.oufStackX or 4),
        tostring(p.oufStackY or -3), tostring(p.oufStackShow ~= false),
    }, "|")
end

local function FlatInitButton(element, options, button)
    local size = options.size or element.size or 16
    local width = options.width or element.width or size
    local height = options.height or element.height or size
    button:SetSize(width, height)
    button:EnableMouse(not (options.disableMouse or element.disableMouse))
    button:SetTooltipAnchorPoint(options.tooltipAnchor or element.tooltipAnchor or 'ANCHOR_BOTTOMRIGHT', 0, 0)

    -- ── Create EVERY widget set (inactive ones hidden; geometry and
    -- visibility are stamped by ApplyUFAuraButtonStyle below). ─────────

    -- Flat underlay (BACKGROUND 0) + flat dispel texture (BACKGROUND 1,
    -- above the underlay, below the icon).
    local flat = BF.Texture(button, nil, 'BACKGROUND', nil, 0)
    flat:SetAllPoints(button)
    flat:SetTexture([[Interface\Buttons\WHITE8x8]])
    flat:Hide()
    button.FlatBorder = flat

    -- Created HIDDEN (v62 fix): textures default to shown, and on BUFF
    -- containers these are never engine-bound — the shown-by-default
    -- WHITE8x8 drew a white square under every buff icon whose corners
    -- poked past the rounded mask ("corners look bad"). The raid only
    -- ever creates dispel textures where the engine manages them; here
    -- the flat dispel branch Shows it right before binding (raid v65
    -- edge-binding pattern: edges[i]:Show() then AddDispelTypeTexture)
    -- and the engine drives visibility from there.
    local dispel = BF.Texture(button, nil, 'BACKGROUND', nil, 1)
    dispel:SetAllPoints(button)
    dispel:SetTexture([[Interface\Buttons\WHITE8x8]])
    dispel:Hide()
    button.DispelBorder = dispel

    -- Blizzard-mode dispel texture: OVERLAY on the button (above the
    -- icon, below the child cooldown frame) — the engine draws its
    -- border atlas on it (lib default parity; no file set — the Border
    -- style assigns the engine's own art).
    local blizzDispel = BF.Texture(button, nil, 'OVERLAY')
    blizzDispel:SetAllPoints(button)
    blizzDispel:Hide()
    button.BlizzDispelBorder = blizzDispel

    local cd = CreateFrame('Cooldown', '$parentCooldown', button, 'CooldownFrameTemplate')
    cd:SetAllPoints(button)
    button.Cooldown = cd
    button:SetDurationCooldown(cd)

    local icon = BF.Texture(button, nil, 'BORDER')
    icon:SetAllPoints(button)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    -- v49 pixel parity with the cooldown swipe (raid InitAuraButton):
    -- textures snap to the pixel grid by default, the swipe's radial
    -- shader does not — on buttons whose position lands off-grid (unit
    -- frames are user-positioned, so this is common) the snapped icon
    -- rasterized 1px past the swipe on the misaligned axis, reading as
    -- broken corners. Unsnapped, both rasterize the same rect. The
    -- SetTexCoord hook usually covers this; explicit per the raid.
    if icon.SetSnapToPixelGrid then
        icon:SetSnapToPixelGrid(false)
        icon:SetTexelSnappingBias(0)
    end
    button.Icon = icon
    button:SetIcon(icon)

    -- Rounded mask: attached ONCE here in the init window (HET proves
    -- masks on engine-bound icons render on 12.1); hidden mask =
    -- masking off (oUF cutout-mask precedent). BLOCKING LOAD: an async
    -- CLAMPTOBLACKADDITIVE mask reads BLACK (erases the icon) until it
    -- finishes loading — and it is Shown live on a style switch.
    local rmask = BF.MaskTexture(button)
    if rmask.SetBlockingLoadsRequested then
        rmask:SetBlockingLoadsRequested(true)
    end
    rmask:SetTexture(ROUND_AURA_MASK_TEX,
        'CLAMPTOBLACKADDITIVE', 'CLAMPTOBLACKADDITIVE')
    rmask:SetAllPoints(button)
    rmask:Hide()
    icon:AddMaskTexture(rmask)
    button._bf_roundMask = rmask

    -- Rounded ring host: created BEFORE countFrame so the count text (a
    -- later sibling at the same level) draws above the ring. The host
    -- carries the border ALPHA — the engine's PreserveAsset recolor
    -- ignores map/region alpha (raid v63/v65 findings) and frame alpha
    -- survives every recolor.
    -- v59: at the BUTTON's own level, i.e. BELOW the cooldown (cd is at
    -- button + 1 in flat-family modes), so the swipe draws OVER the
    -- border band. It sat at cd + 1 back when the swipe overhung the
    -- button and the ring was there to hide the overhang; the swipe now
    -- matches the ring rect exactly, so the ring belongs underneath.
    -- Frame alpha still reaches the ring, so the v63/v65 border-alpha
    -- contract is unaffected.
    local ringHost = CreateFrame('Frame', nil, button)
    ringHost:SetAllPoints(button)
    ringHost:SetFrameLevel(button:GetFrameLevel())
    local ring = BF.Texture(ringHost, nil, 'OVERLAY', nil, 0)
    ring:Hide()
    button._bf_roundRing = ring
    button._bf_ringHost = ringHost

    local countFrame = CreateFrame('Frame', nil, button)
    countFrame:SetAllPoints(button)
    countFrame:SetFrameLevel(cd:GetFrameLevel() + 1)

    local count = countFrame:CreateFontString(nil, 'OVERLAY', 'NumberFontNormal')
    -- Through the funnel explicitly: this container is skipped by
    -- BF.UnsnapTree (_bf_unsnapStop), so nothing sweeps it later.
    BF:DisablePixelSnapRegion(count)
    count:SetPoint('BOTTOMRIGHT', countFrame, 'BOTTOMRIGHT', -1, 0)
    button.Count = count
    button:SetApplicationCount(count, {
        formatter = options.countFormatter or element.countFormatter,
    })

    -- Stealable/purgeable buff border (v60): engine-driven via the
    -- aurapocalypse stealableFilter payload. Widget on its OWN alpha
    -- host above the swipe (BF layering convention — the lib puts it
    -- under the cooldown frame) so the toggle can flip it live via
    -- host alpha. Created whenever this container is a stealable
    -- candidate (element flag, set in BuildContainer) and the 12.1 enum
    -- exists; the profile toggle only drives the host alpha.
    -- PTR-VERIFY: filter behavior on friendly targets' buffs (expected:
    -- the engine only flags buffs stealable/purgeable BY THE PLAYER).
    if element._bf_stealableCandidate
        and Enum.CustomAuraButtonDispelTypeStealableFilter then
        local stealHost = CreateFrame('Frame', nil, button)
        stealHost:SetAllPoints(button)
        stealHost:SetFrameLevel(cd:GetFrameLevel() + 1)
        local stealable = BF.Texture(stealHost, nil, 'OVERLAY', nil, 1)
        stealable:SetPoint('TOPLEFT', button, 'TOPLEFT', -3, 3)
        stealable:SetPoint('BOTTOMRIGHT', button, 'BOTTOMRIGHT', 3, -3)
        stealable:SetTexture([[Interface\TargetingFrame\UI-TargetingFrame-Stealable]])
        stealable:SetBlendMode('ADD')
        button.Stealable = stealable
        button._bf_stealableHost = stealHost
        -- Initial binding; ApplyUFAuraButtonStyle re-adds it whenever a
        -- dispel re-bind clears it.
        button:AddDispelTypeTexture(stealable, {
            style = Enum.CustomAuraButtonDispelTypeTextureStyle
                and Enum.CustomAuraButtonDispelTypeTextureStyle.PreserveAsset or 3,
            showWhenHelpful = true, -- required for stealableFilter (lib finding)
            showWithoutDispelType = true, -- probably required too (lib finding)
            stealableFilter = element.stealableBorderFilter
                or Enum.CustomAuraButtonDispelTypeStealableFilter.Stealable,
        })
    end

    -- Register for the live restyle walk, then stamp the current style.
    local reg = element._bf_buttons
    if reg then reg[#reg + 1] = button end
    ApplyUFAuraButtonStyle(element, button)

    button._flatBorder = true

    if element.PostCreateButton then element:PostCreateButton(button, options) end
end

-- ============================================================
-- BF:RestyleOUFAuraButtons
-- Live re-stamp of every pooled UF aura button after a border
-- style/color/thickness/stealable settings change (no /reload —
-- raid ContainerFactory restyle-walk parity). Config-time only.
-- pcall per button (raid pattern): a pcall-aborted stamp on one
-- button never strands the rest of the walk.
-- ============================================================
-- ============================================================
-- BF:_ApplyOUFAuraLiveGeometry(el, pf, pk, kind) -> size, spacing, maxN
--
-- v67: applies Icon Size / Spacing / Max Icons to a spawned unit-frame aura
-- container LIVE, replacing the /reload prompt that sat on 24 option widgets.
--
-- The old comment claimed group options were "FROZEN at AddGroup time". That
-- was never an engine limit -- SetAuraGroupMaxFrameCount and SetAuraGroupLayout
-- are live setters, and BuzzardFrames' own raid path has used them since the
-- container migration. The unit-frame path simply never adopted them. This is
-- a direct port of Auras/ContainerFactory.lua, including its PTR findings:
--
--   * SetAuraGroupMaxFrameCount alone does NOT re-evaluate which auras
--     display (raid "Max Buffs" edits did nothing until this was found). It
--     needs an UpdateAllAuras poke, which schedules the engine's documented
--     full rebuild on the next OnUpdate. Change-guarded -- that rebuild is not
--     free and must not run on routine layout passes.
--   * elementWidth/elementHeight size the layout CELLS only. Pooled buttons
--     keep their baked size, so cells-only looks like grown spacing; the
--     buttons must each be SetSize-d.
--   * Every native call is pcall-guarded. If a resize is denied we abandon the
--     size change wholesale and leave the baked sizes intact, rather than ship
--     half of it (cells resized, buttons not).
--
-- Combat: bails to the baked values. These are protected-ish container calls
-- and the options widgets are combat-locked anyway; the next out-of-combat
-- layout applies the change.
--
-- Returns the EFFECTIVE values so the caller's wrap-width maths uses fresh
-- numbers on the same pass rather than the previous frame's.
-- ============================================================
function BF:_ApplyOUFAuraLiveGeometry(el, pf, pk, kind)
    local size    = pf[pk..kind.."Size"]     or 18
    local spacing = pf[pk..kind.."Spacing"]  or 2
    local maxN    = pf[pk.."Max"..kind.."s"] or (pk == "boss" and 8 or 16)

    -- v96: every DECLARED group, not just the base one. The hostility
    -- variants are real groups now (see the AddGroup site) and an inactive
    -- one still has to carry this pass's geometry, or it lands wrong the
    -- moment it becomes the active group.
    local keys = el._bf_groupKeys
    -- Inside the keystone recreate window (plan §3.1) auras are secret out of
    -- combat and the button SetSize walk below is denied on every pass: Max
    -- and the group layout are container-level and still apply live, and a
    -- size change asks for a group re-declare instead of walking the buttons.
    -- Outside the window this function is unchanged (combat bail only).
    local inWindow = BF.IsAuraRecreateWindow and BF:IsAuraRecreateWindow()
    if not keys or InCombatLockdown() then
        return el._bf_size or size, el._bf_spacing or spacing, el._bf_maxN or maxN
    end

    -- ---- Max icons ----
    if el._bf_maxN ~= maxN then
        local maxOK = true
        for i = 1, #keys do
            if not pcall(el.SetAuraGroupMaxFrameCount, el, keys[i], maxN) then
                maxOK = false
            end
        end
        if maxOK then
            el._bf_maxN      = maxN
            el.maxFrameCount = maxN   -- future AddGroup/pool growth
            pcall(el.UpdateAllAuras, el)
        end
    end

    -- ---- Button size ----
    local sizeChanged, sizeOK = (el._bf_size ~= size), true
    if sizeChanged and inWindow then
        -- Pooled buttons are post-init: SetSize on them is denied. The new
        -- groups bake the new size in initializeFrame (RecreateOUFAuraGroups
        -- reads it from the profile). sizeOK=false keeps the baked size and
        -- keeps the layout cells below off the new value until then.
        sizeOK = false
        local owner = el.__owner
        if owner and el._bf_elKey then
            BF:RequestAuraRecreate(owner, "ouf", el._bf_elKey, "size")
        end
    elseif sizeChanged then
        local reg = el._bf_buttons
        if reg then
            for i = 1, #reg do
                local b = reg[i]
                if b and not pcall(b.SetSize, b, size, size) then sizeOK = false break end
                -- Border insets and the cooldown swipe inset are pixel offsets
                -- derived from the button size, so they must be re-stamped.
                if b then
                    pcall(ApplyUFAuraButtonStyle, el, b)
                    pcall(ApplyUFAuraCooldownStyle, b)
                end
            end
        end
        if sizeOK then
            el._bf_size = size
            el.size     = size   -- FlatInitButton reads this for future buttons
            -- Auto-scaled stack text is a function of the icon size, so it
            -- follows a live Icon Size change. Deliberately a SECOND pass:
            -- ApplyUFAuraStackTextStyle reads el._bf_size, which is only
            -- committed here, after the whole resize succeeded.
            local reg2 = el._bf_buttons
            if reg2 then
                for i = 1, #reg2 do
                    local b = reg2[i]
                    if b then pcall(ApplyUFAuraStackTextStyle, el, b) end
                end
            end
        end
    end

    -- ---- Layout cells + spacing ----
    if el._bf_spacing ~= spacing or (sizeChanged and sizeOK) then
        local layout = { elementSpacing = spacing, lineSpacing = spacing }
        if sizeOK then
            layout.elementWidth  = size
            layout.elementHeight = size
        end
        local layoutOK = true
        for i = 1, #keys do
            if not pcall(el.SetAuraGroupLayout, el, keys[i], layout) then
                layoutOK = false
            end
        end
        if layoutOK then
            el._bf_spacing    = spacing
            el.elementSpacing = spacing
            el.lineSpacing    = spacing
        end
    end

    return el._bf_size or size, el._bf_spacing or spacing, el._bf_maxN or maxN
end

function BF:RestyleOUFAuraButtons()
    -- Same guard the ContainerFactory restyle walks use: aura-button child
    -- textures are FORBIDDEN objects while auras are engine-secret (combat OR
    -- C_Secrets.ShouldAurasBeSecret), so SetVertexColor in ApplyUFAuraButtonStyle
    -- would taint. Skip cleanly and re-apply on the next out-of-combat pass —
    -- bare InCombatLockdown() missed the not-locked-but-secret window.
    if BF:IsAuraCreationRestricted() then
        -- Inside the recreate window (plan §3.1): per frame and element, a
        -- style that moved since the buttons were styled re-declares that
        -- element's groups (RecreateOUFAuraGroups) instead of the denied
        -- walk. Outside it: today's skip, re-applied on the next pass.
        if not (BF.IsAuraRecreateWindow and BF:IsAuraRecreateWindow()) then return end
        local function requestFrame(f)
            if not f then return end
            for i = 1, 2 do
                local elKey = (i == 1) and "Buffs" or "Debuffs"
                local el = f[elKey]
                if el and el._bf_buttons and el._bf_bakedStyleSig ~= OUFAuraStyleSig(el) then
                    BF:RequestAuraRecreate(f, "ouf", elKey, "style")
                end
            end
        end
        requestFrame(self.oufPlayer)
        requestFrame(self.oufTarget)
        requestFrame(self.oufFocus)
        if self.oufBoss then
            for i = 1, 5 do requestFrame(self.oufBoss[i]) end
        end
        return
    end
    local function walkFrame(f)
        if not f then return end
        local els = { f.Buffs, f.Debuffs }
        for i = 1, 2 do
            local el = els[i]
            local reg = el and el._bf_buttons
            if reg then
                -- The buttons now carry this style: re-baseline the sig so the
                -- next in-key compare does not rebuild for an edit that already
                -- landed here. Only on a walk with no refused stamp.
                local clean = true
                for j = 1, #reg do
                    local ok, err = pcall(ApplyUFAuraButtonStyle, el, reg[j])
                    if not ok then
                        clean = false
                        print("|cffff0000BuzzardFrames UF aura restyle error:|r", tostring(err))
                    end
                    -- Duration/cooldown settings restyle live too (v61).
                    local ok2, err2 = pcall(ApplyUFAuraCooldownStyle, reg[j])
                    if not ok2 then
                        clean = false
                        print("|cffff0000BuzzardFrames UF aura restyle error:|r", tostring(err2))
                    end
                    -- Stack text settings likewise.
                    local ok3, err3 = pcall(ApplyUFAuraStackTextStyle, el, reg[j])
                    if not ok3 then
                        clean = false
                        print("|cffff0000BuzzardFrames UF aura restyle error:|r", tostring(err3))
                    end
                end
                if clean then el._bf_bakedStyleSig = OUFAuraStyleSig(el) end
                -- Poke the container so the engine re-evaluates the
                -- re-bound dispel textures' shown state now rather than
                -- on the next aura update.
                if el.ForceUpdate then el:ForceUpdate() end
            end
        end
        -- Castbar spell icon is an aura-icon-class element (v62): it
        -- follows the aura border settings, so it restyles with them.
        if f.Castbar and BF._ApplyOUFCastbarIconBorder then
            BF:_ApplyOUFCastbarIconBorder(f)
        end
    end
    walkFrame(self.oufPlayer)
    walkFrame(self.oufTarget)
    walkFrame(self.oufFocus)
    if self.oufBoss then
        for i = 1, 5 do walkFrame(self.oufBoss[i]) end
    end
end

-- ============================================================
-- Aura group activation (12.1 AuraContainer)
--
-- v96: the unit-frame aura containers no longer RE-STAMP a group's filter
-- string to follow unit hostility. Every filter a frame can need is
-- DECLARED as its own group at spawn (see the AddGroup site), inside the
-- pre-PLAYER_ENTERING_WORLD configuration window, and the hostility switch
-- only chooses which of them is live.
--
-- Two reasons, in order:
--   1. oUF has no filter setter at all. The element mixin is AddGroup /
--      AddSlot / ForceUpdate and nothing else (Libs/oUF/elements/auras.lua);
--      a group's filter is declared once and never touched. The live
--      SetAuraGroupFilterString we were calling is a raw engine call
--      reached past the library.
--   2. Owner report: friendly-PLAYER debuffs rendered on the FIRST friendly
--      target after a reload and never again -- i.e. while the group still
--      held its creation filter, and never after the first hostility flip
--      re-stamped it. Harmful auras on an assistable unit are the secret
--      class; enemy debuffs (HARMFUL|PLAYER -- the player's own auras) and
--      friendly buffs are not, which is exactly the set that kept working.
--
-- Parking is the raid path's proven mechanism, verbatim: candidateFilters
-- { maxDuration = 0 }, a documented empty set (every timed aura exceeds the
-- bound, and any non-nil bound hides permanents), NOT a filter-string write
-- and NOT the "HELPFUL|HARMFUL" trap. See BF:SetAuraGridGroupDormant in
-- Auras/ContainerFactory.lua.
-- ============================================================
local OUF_DORMANT_CANDIDATES = { maxDuration = 0 }
local OUF_LIVE_CANDIDATES    = {}   -- shared constants: never mutated

-- Make groupKey the container's only live group. Change-guarded, so the hot
-- path (repeat target swaps within one hostility class) costs one compare.
-- On a refused stamp the recorded active group is rolled back, so the next
-- pass retries rather than believing a transition that did not happen
-- (the v94 SetAuraGridGroupDormant lesson).
local function SetActiveOUFAuraGroup(el, groupKey, force)
    local keys = el._bf_groupKeys
    if not (keys and groupKey) then return false end
    if not force and el._bf_activeGK == groupKey then return false end
    local prev = el._bf_activeGK
    el._bf_activeGK = groupKey
    local ok = true
    for i = 1, #keys do
        local k = keys[i]
        if not pcall(el.SetAuraGroupCandidateFilters, el, k,
                     (k == groupKey) and OUF_LIVE_CANDIDATES
                     or OUF_DORMANT_CANDIDATES) then
            ok = false
        end
    end
    if not ok then el._bf_activeGK = prev end
    -- The container is delta-driven: a live reconfigure does not re-evaluate
    -- the auras the engine already holds for the unit (v85 finding, and the
    -- same pairing SetAuraGridGroupDormant uses).
    pcall(el.UpdateAllAuras, el)
    return ok
end

-- Declare an aura element's full group set: EVERY filter the frame can need
-- (v96), each its own group. `kind` = "Buff" | "Debuff". Reads the per-unit
-- constants BluzzardStyle bakes on the frame before calling it
-- (_bf_auraDynBuffs = boss, _bf_auraDynDebuffs = target/focus/boss).
--
-- ONE function for both callers -- the spawn (BluzzardStyle) and the in-key
-- re-declare (RecreateOUFAuraGroups) -- so a recreated element can never carry
-- a different group set from a freshly spawned one (plan §3.2 C).
--
-- The keys list is published on `el` BEFORE the first AddGroup and filled one
-- key at a time, so a caller that catches an AddGroup error still sees every
-- group that DID get created (and can park it).
--
-- Filters: see the notes at the spawn site. The |PLAYER buff variant only on
-- the frames whose buff filter is dynamic (boss), the two attackable-unit
-- debuff variants only where the debuff filter is; each group costs its own
-- 10-button engine pool.
local function DeclareOUFAuraGroups(self, el, kind)
    local keys = {}
    el._bf_groupKeys = keys
    el._bf_gkMine, el._bf_gkMineNP = nil, nil
    if kind == "Buff" then
        el._bf_gkAll = el:AddGroup("HELPFUL")
        keys[#keys + 1] = el._bf_gkAll
        if self._bf_auraDynBuffs then
            el._bf_gkMine = el:AddGroup("HELPFUL|PLAYER")
            keys[#keys + 1] = el._bf_gkMine
        end
    else
        -- v87: never a bare HARMFUL query -- see the spawn site.
        el._bf_gkAll = el:AddGroup("HARMFUL|INCLUDE_NAME_PLATE_ONLY")
        keys[#keys + 1] = el._bf_gkAll
        if self._bf_auraDynDebuffs then
            el._bf_gkMine = el:AddGroup("HARMFUL|PLAYER")
            keys[#keys + 1] = el._bf_gkMine
            el._bf_gkMineNP = el:AddGroup("HARMFUL|PLAYER|INCLUDE_NAME_PLATE_ONLY")
            keys[#keys + 1] = el._bf_gkMineNP
        end
    end
    el._bf_groupKey = el._bf_gkAll  -- base group (geometry/debug)
    return keys
end

-- ============================================================
-- In-key group re-declare: the "ouf" recreate kind (plan §3.2 C)
--
-- WHY: inside an active keystone auras stay secret out of combat too, so
-- every post-creation write on a pooled aura button (style, size) is denied
-- until the key ends (field report 2026-09-10). New groups style their
-- buttons inside initializeFrame, where those writes are accepted -- verified
-- in game 2026-09-11: AddAuraGroup on a live, unit-bound container that already
-- has groups works while secret, with initializeFrame eager.
--
-- WHY NOT a second element: the oUF library keeps every element in its
-- per-frame state forever and re-binds / re-enables all of them on each unit
-- swap, so a retired element would come back. The SAME element gets a new
-- group set instead; AddGroup keys are monotonic per frame in the library
-- ('Group'..n), so they cannot collide with the retired ones.
--
-- Key encoding for BF:RequestAuraRecreate(frame, "ouf", key): `frame` is the
-- oUF unit frame, `key` is the element's field name on it, "Buffs" or
-- "Debuffs" (el._bf_elKey, baked at spawn).
--
-- Returns ok, leakedButtons (#newGroups * 10: one engine pool per group).
-- Retired groups are parked by candidate set (container-level, allowed while
-- secret) and their buttons leave el._bf_buttons, so no walk touches them.
-- ============================================================
local function RecreateOUFAuraGroups(frame, el)
    local kind = (el._bf_elKey == "Buffs") and "Buff" or "Debuff"
    local p = BF.ufDB and BF.ufDB.profile
    local pk = frame._bf_auraUFKey
    if not (p and pk and el.AddGroup) then return false, 0 end
    local pf = p[pk] or p.player or {}
    -- The same reads (and fallbacks) as BuildContainer.
    local sz      = pf[pk..kind.."Size"]     or 18
    local spacing = pf[pk..kind.."Spacing"]  or 2
    local maxN    = pf[pk.."Max"..kind.."s"] or (pk == "boss" and 8 or 16)
    local perRow  = pf[pk..kind.."sPerRow"]  or 8

    -- Which hostility role was live, so the same role comes back live on the
    -- new keys (UpdateOUFAuraFilters below re-derives it anyway).
    local act = el._bf_activeGK
    local role = (act and act == el._bf_gkMineNP and "MineNP")
              or (act and act == el._bf_gkMine and "Mine") or "All"

    -- Everything a failed declare has to put back.
    local old = {
        keys = el._bf_groupKeys, all = el._bf_gkAll, mine = el._bf_gkMine,
        mineNP = el._bf_gkMineNP, base = el._bf_groupKey, buttons = el._bf_buttons,
        size = el.size, es = el.elementSpacing, ls = el.lineSpacing,
        mfc = el.maxFrameCount, bsize = el._bf_size,
    }

    -- The fields FlatInitButton and AddGroup read (auras.lua AddGroup inherits
    -- maxFrameCount / elementSpacing / lineSpacing from the element).
    -- _bf_size goes up BEFORE the declare, not after (plan step 5): the eager
    -- init runs ApplyUFAuraStackTextStyle, whose auto-scale reads it.
    el._bf_buttons    = {}
    el.size           = sz
    el.elementSpacing = spacing
    el.lineSpacing    = spacing
    el.maxFrameCount  = maxN
    el._bf_size       = sz

    local ok, err = pcall(DeclareOUFAuraGroups, frame, el, kind)
    local newKeys = el._bf_groupKeys
    if not ok then
        -- A partly built set: park what did get created (it is live by
        -- default and would draw next to the old groups), then restore.
        local made = (newKeys ~= old.keys) and newKeys or nil
        if made then
            for i = 1, #made do
                pcall(el.SetAuraGroupCandidateFilters, el, made[i], OUF_DORMANT_CANDIDATES)
            end
            local rk = el._bf_retiredGroupKeys
            if not rk then rk = {}; el._bf_retiredGroupKeys = rk end
            for i = 1, #made do rk[#rk + 1] = made[i] end
        end
        el._bf_groupKeys, el._bf_gkAll, el._bf_gkMine = old.keys, old.all, old.mine
        el._bf_gkMineNP, el._bf_groupKey, el._bf_buttons = old.mineNP, old.base, old.buttons
        el.size, el.elementSpacing, el.lineSpacing = old.size, old.es, old.ls
        el.maxFrameCount, el._bf_size = old.mfc, old.bsize
        pcall(el.UpdateAllAuras, el)
        geterrorhandler()(err)
        return false, (made and #made or 0) * 10
    end

    -- Retire the old set, then park every retired key.
    local rk = el._bf_retiredGroupKeys
    if not rk then rk = {}; el._bf_retiredGroupKeys = rk end
    if old.keys then
        for i = 1, #old.keys do rk[#rk + 1] = old.keys[i] end
    end
    for i = 1, #rk do
        pcall(el.SetAuraGroupCandidateFilters, el, rk[i], OUF_DORMANT_CANDIDATES)
    end
    local want = (role == "MineNP" and el._bf_gkMineNP)
              or (role == "Mine" and el._bf_gkMine) or el._bf_gkAll
    el._bf_activeGK = nil
    -- Parks the non-active new groups and pokes UpdateAllAuras, which clears
    -- the retired groups' displayed buttons.
    SetActiveOUFAuraGroup(el, want, true)

    el._bf_spacing = spacing
    el._bf_maxN    = maxN
    el._bf_bakedStyleSig = OUFAuraStyleSig(el)
    -- Wrap width is container-level and follows the new size now, rather than
    -- on the next unit-frame layout pass.
    pcall(el.SetFlowLayoutMaximumLineSize, el, perRow * (sz + spacing))
    if BF.UpdateOUFAuraFilters then pcall(BF.UpdateOUFAuraFilters, frame) end
    return true, #newKeys * 10
end

-- Registered once at load (ContainerFactory is earlier in the TOC).
if BF.RegisterAuraRecreateHandler then
    BF:RegisterAuraRecreateHandler("ouf", function(frame, key)
        if key ~= "Buffs" and key ~= "Debuffs" then return false, 0 end
        local el = frame and frame[key]
        if not (el and el._bf_groupKeys and el._bf_elKey == key) then return false, 0 end
        return RecreateOUFAuraGroups(frame, el)
    end)
end

-- ============================================================
-- BF.UpdateOUFAuraFilters (12.1 AuraContainer)
-- Single source of truth for the dynamic per-unit aura state:
--   * hostile/friendly group switching (replaces the old element.filter
--     functions, and, as of v96, the live filter-string re-stamp)
--   * player-only filtering (replaces the old FilterAura callbacks;
--     expressed as |PLAYER filter tokens so filtering happens C-side)
--   * visibility/connection gating (replaces the old PreUpdate check;
--     Grid2 pattern: gate aura display behind UnitIsVisible)
-- Triggers: hooksecurefunc on frame.UpdateAllElements (fires on
-- target/focus/boss unit swaps), UNIT_FACTION / UNIT_CONNECTION /
-- UNIT_PHASE unit events, and the layout functions (after changing
-- container._bf_userShown).
-- Change-guarded: the activation and SetShown only run when the computed
-- state actually changed, so repeat calls in combat cost a few unit API
-- calls and value compares.
-- HOT PATH (fires on every target/focus swap, incl. tab-targeting in
-- combat): deliberately zero allocations -- the group keys and the two
-- candidate tables are constants and the per-unit facts (isBoss/dynamic
-- flags/profile key) are baked onto the frame at spawn instead of derived
-- here (Grid2 pattern: precompute per-unit constants at setup, keep the
-- event path allocation-free).
-- Plain function (not a method) so it can be passed to hooksecurefunc
-- and oUF's RegisterEvent directly (extra event args are ignored).
-- ============================================================
function BF.UpdateOUFAuraFilters(frame)
    local buffs, debuffs = frame.Buffs, frame.Debuffs
    if not buffs and not debuffs then return end
    local unit = frame.__unit
    if not unit then return end

    local visible = (UnitIsVisible(unit) and UnitIsConnected(unit)) and true or false
    local canAttack = UnitCanAttack("player", unit) and true or false
    local shownChanged = false

    if buffs then
        -- Friendly boss frames (_bf_auraDynBuffs): only buffs the player
        -- applied -- matches the raid/party frame buff filter baseline
        -- (HELPFUL|PLAYER). Enemy bosses and all other units: unfiltered.
        -- _bf_gkMine exists only on the frames that can need it.
        local gk = buffs._bf_gkAll
        if frame._bf_auraDynBuffs and not canAttack and buffs._bf_gkMine then
            gk = buffs._bf_gkMine
        end
        SetActiveOUFAuraGroup(buffs, gk)
        local shown = (buffs._bf_userShown ~= false) and visible
        if buffs._bf_curShown ~= shown then
            buffs._bf_curShown = shown
            buffs:SetShown(shown)
            shownChanged = true
        end
    end

    if debuffs then
        -- Attackable target/focus/boss (_bf_auraDynDebuffs): player debuffs
        -- only, optionally the nameplate-inclusive variant. Friendly units
        -- and the player frame: the base set, which is the group's own
        -- creation filter and is never re-stamped.
        local gk = debuffs._bf_gkAll
        if canAttack and frame._bf_auraDynDebuffs and debuffs._bf_gkMine then
            local prof = BF.ufDB and BF.ufDB.profile
            local uf = prof and prof[frame._bf_auraUFKey]
            if uf and uf.targetNameplateDebuffsOnly and debuffs._bf_gkMineNP then
                gk = debuffs._bf_gkMineNP
            else
                gk = debuffs._bf_gkMine
            end
        end
        SetActiveOUFAuraGroup(debuffs, gk)
        local shown = (debuffs._bf_userShown ~= false) and visible
        if debuffs._bf_curShown ~= shown then
            debuffs._bf_curShown = shown
            debuffs:SetShown(shown)
            shownChanged = true
        end
    end

    -- Container shown-state flipped: the attached cast bar's Avoid Auras
    -- offset keys off container:IsShown(), which PostCastStart can read
    -- BEFORE this hook runs (PostCastStart fires INSIDE UpdateAllElements;
    -- hooksecurefunc hooks run after it returns), so the first cast after
    -- a zone-in / fresh target anchors against the stale hidden state and
    -- overlaps the auras until the next cast. Re-anchor on the flip.
    -- Change-guarded above -- this block only runs on an actual flip; the
    -- hot path (every target swap) adds one boolean init and a nil test.
    if shownChanged then
        local cb = frame.Castbar
        if cb and cb._avoidAurasEnabled and cb:IsShown()
            and cb:GetParent() ~= UIParent then
            BF:_AnchorAttachedCastbar(frame)
        end
    end
end

-- ClassPower widget: creates 10 invisible dummy StatusBars for oUF's
-- ClassPower element to manage. PostUpdate/PostVisibility feed data
-- into the resource bar's own rendering.
local function BuildClassPowerWidget(frame)
    local cp = {}
    for i = 1, 10 do
        local bar = BF.StatusBar(nil, frame)
        bar:SetSize(1, 1)
        bar:SetAlpha(0)
        bar:EnableMouse(false)
        bar:Hide()
        cp[i] = bar
    end

    -- oUF 14.0.0 inserted `hasCurChanged` at position 3:
    --   PostUpdate(cur, max, hasCurChanged, hasMaxChanged, powerType, ...)
    -- The old 4-parameter signature therefore received hasMaxChanged (a
    -- BOOLEAN) as powerType, CLASSPOWER_TYPE_MAP[boolean] resolved nil, and
    -- the resource bar hid itself for every ClassPower class — silently, with
    -- no error.
    --
    -- The same release moved __isEnabled / __cur / __max / __powerType off the
    -- element into a private STATE table, so callers can no longer read the
    -- last values back. We cache them here, on the frame, for the options
    -- refresh and layout re-apply paths that used to do exactly that.
    cp.PostUpdate = function(self, cur, max, hasCurChanged, hasMaxChanged, powerType)
        local host = self.__owner or frame
        host._bf_cpCur, host._bf_cpMax, host._bf_cpPowerType = cur, max, powerType
        BF:UpdateOUFResourceBar(cur, max, powerType)
    end

    cp.PostVisibility = function(self, isVisible)
        BF:UpdateOUFResourceBarVisibility(isVisible)
    end

    frame.ClassPower = cp
end

-- Replacement for the removed `ClassPower.__isEnabled` / `__cur` / `__max` /
-- `__powerType` reads. IsElementEnabled is oUF's public, activeElements-backed
-- API and is unchanged in 14.0.0; the values come from the cache stamped in
-- PostUpdate above. Returns nil when the element is disabled or has not
-- reported yet, so callers keep their existing "no data → hide" behavior.
function BF:GetOUFClassPowerState(host)
    if not host or not host.ClassPower then return nil end
    if not (host.IsElementEnabled and host:IsElementEnabled("ClassPower")) then
        return nil
    end
    return true, host._bf_cpCur, host._bf_cpMax, host._bf_cpPowerType
end


local function BluzzardStyle(self, unit)
    local p    = BF.ufDB.profile
    local side = BF.bluzzardIconSide[unit] or "LEFT"

    -- Boss frames (boss1-boss5) share a single profile table under p.boss.
    local profileKey = unit
    if unit and unit:match("^boss%d") then profileKey = "boss" end
    local pf      = p[profileKey] or p.player or {}  -- per-unit sub-table
    local iconSz    = p.iconSize or pf.iconSize or 51
    local ringThick = pf.iconBorderThickness or 4
    local nameH     = pf.nameBarHeight       or 13
    local healthH   = pf.healthBarHeight     or 22
    local powerH    = pf.powerBarHeight      or 10
    local barW      = pf.frameWidth          or 156

    -- v91: the player's health band carries the alt power bar's reserved
    -- strip. Harmless for every other unit (the helper returns the plain
    -- configured height when nothing is reserved), and it keeps the spawn
    -- size in agreement with the first layout pass rather than one frame off.
    if profileKey == "player" and BF.GetOUFPlayerHealthBandHeight then
        healthH = BF:GetOUFPlayerHealthBandHeight()
    end
    self:SetSize(barW, nameH + healthH + powerH)

    -- Name strip background
    local nameBarBg = BF.Texture(self, nil, "BACKGROUND", nil, -1)
    nameBarBg:SetColorTexture(0.08, 0.08, 0.08, 0.6)
    nameBarBg:SetPoint("TOPLEFT",  self, "TOPLEFT",  0, 0)
    nameBarBg:SetPoint("TOPRIGHT", self, "TOPRIGHT", 0, 0)
    nameBarBg:SetHeight(nameH)
    self._oufNameBarBg = nameBarBg

    -- Health bar (oUF element: self.Health)
    -- For player/target/focus, the Health bar is placed inside a clipFrame
    -- which follows an anchor-only _oufHealthContainer. This mirrors the
    -- raid/party HealthBar indicator pattern so the reduced-max-health
    -- feature (Indicators/AbsorbBars.lua:_UpdateReducedMaxHealth) can
    -- clip the health bar at the (1-pct) boundary by re-anchoring the
    -- clipFrame's right edge. Other unit kinds (pet/ToT/FT/boss) keep
    -- the simple direct-anchor path — they do not render reduced-max.
    local wantsHealthContainer = (unit == "player" or unit == "target" or unit == "focus")

    local Health, healthContainer, healthClipFrame
    if wantsHealthContainer then
        -- Container: invisible Frame used only as an anchor target for
        -- the clipFrame. Layout functions anchor this to the unit frame
        -- with the same insets/offsets Health used to receive directly.
        healthContainer = CreateFrame("Frame", nil, self)
        healthContainer:SetPoint("TOPLEFT",  self, "TOPLEFT",  0, -nameH)
        healthContainer:SetPoint("TOPRIGHT", self, "TOPRIGHT", 0, -nameH)
        healthContainer:SetHeight(healthH)

        -- ClipFrame: parented to self (matches HealthBar.lua:Create —
        -- raid's clipFrame is parented to `parent`, not to `container`).
        -- Anchored to follow healthContainer via SetAllPoints; reduced-max
        -- will override this anchoring by pinning RIGHT to the reduced-max
        -- bar's LEFT edge.
        healthClipFrame = CreateFrame("Frame", nil, self)
        healthClipFrame:SetAllPoints(healthContainer)
        healthClipFrame:SetClipsChildren(true)

        -- Health: parented to clipFrame, oversized by 1px on all sides so
        -- the clipFrame's bounds define the visible region. Matches the
        -- raid HealthBar:Create pattern exactly.
        Health = BF.StatusBar(nil, healthClipFrame)
        BF:DisablePixelSnapRegion(Health)
        Health:SetAllPoints(healthClipFrame)
    else
        -- Pet/ToT/FT/boss: direct anchoring, no container/clipFrame.
        Health = BF.StatusBar(nil, self)
        BF:DisablePixelSnapRegion(Health)
        Health:SetPoint("TOPLEFT",  self, "TOPLEFT",  0, -nameH)
        Health:SetPoint("TOPRIGHT", self, "TOPRIGHT", 0, -nameH)
        Health:SetHeight(healthH)
    end
    Health:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    -- Set an initial color so the bar is never white before oUF's first color pass
    Health:SetStatusBarColor(0.24, 0.78, 0.24)
    -- We manage health bar color ourselves (see _GetOUFHealthColor) so that
    -- class colors match BF.classColors (same source as the raid frames).
    -- Disable oUF's built-in coloring flags to prevent conflicts.
    Health.colorClass    = false
    Health.colorReaction = false
    Health.colorHealth   = false

    local healthBg = BF.Texture(Health, nil, "BACKGROUND")
    healthBg:SetColorTexture(0.08, 0.08, 0.08, 0.6)
    -- Anchor bg to the UNFILLED region only (Grid2 pattern: Bar_Layout).
    -- The fill texture's right edge is the bg's left edge so the background
    -- never sits behind the fill, allowing independent opacity control.
    local fillTex = Health:GetStatusBarTexture()
    if fillTex then
        local layer, sublayer = fillTex:GetDrawLayer()
        healthBg:SetDrawLayer(layer, sublayer - 1)
        healthBg:SetPoint("TOPLEFT", fillTex, "TOPRIGHT", 0, 0)
        healthBg:SetPoint("BOTTOMLEFT", fillTex, "BOTTOMRIGHT", 0, 0)
        healthBg:SetPoint("TOPRIGHT", Health, "TOPRIGHT", 0, 0)
        healthBg:SetPoint("BOTTOMRIGHT", Health, "BOTTOMRIGHT", 0, 0)
    else
        healthBg:SetAllPoints(Health)
    end

    self._oufHealthBg       = healthBg
    self.Health             = Health
    self._oufHealthContainer = healthContainer  -- nil for pet/ToT/FT/boss
    self._oufHealthClipFrame = healthClipFrame  -- nil for pet/ToT/FT/boss

    -- Health's visual parent is the clipFrame (so SetClipsChildren on the
    -- clipFrame clips it), but its logical owner is the oUF unit frame
    -- (self). PostUpdate callbacks read frame state off the owner, so we
    -- stash a back-reference here. Pet/ToT/FT/boss don't use the clipFrame
    -- wrapper and have Health parented directly to self, so this is also
    -- set there for uniform PostUpdate access.
    Health._bf_ownerFrame = self

    -- Power bar (oUF element: self.Power)
    local Power = BF.StatusBar(nil, self)
    BF:DisablePixelSnapRegion(Power)
    Power:SetPoint("TOPLEFT",  Health, "BOTTOMLEFT",  0, 0)
    Power:SetPoint("TOPRIGHT", Health, "BOTTOMRIGHT", 0, 0)
    Power:SetHeight(powerH)
    Power:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    -- Set an initial color so the bar is never white before oUF's first color pass
    Power:SetStatusBarColor(0.00, 0.44, 1.00)
    Power.colorPower = false  -- we manage color entirely in PostUpdate via _GetOUFPowerColor

    local powerBg = BF.Texture(Power, nil, "BACKGROUND")
    powerBg:SetAllPoints(Power)
    -- Seeded from the profile, not a literal: the first layout pass would
    -- otherwise be the only thing that applies the user's color, and that
    -- pass is deferred by RunSecure when the frames are built in combat
    -- (a /reload mid-fight), leaving the bar default gray until combat ends.
    powerBg:SetColorTexture(BF:_GetOUFPowerBgColor())

    self.Power = Power
    self._powerBg = powerBg

    -- Apply the user's saved Power Bar Opacity (Unit Frames -> Global ->
    -- Colors -> Power Bars) to the Power StatusBar. One-shot SetAlpha;
    -- persists for the lifetime of the frame. The matching SetAlpha on
    -- the power border (fb.power) happens after the border boxes are
    -- created below. Live updates from the slider go through the setter
    -- in Options_oUF_Player_Target.lua which walks every oUF frame.
    do
        local op = BF.ufDB and BF.ufDB.profile and BF.ufDB.profile.oufPowerBarOpacity
        if op ~= nil then Power:SetAlpha(op) end
    end

    -- Icon cutout mask: an inverted-disc mask (transparent inside a
    -- centered circle, opaque outside) carves an icon-shaped hole out
    -- of the bar textures so they don't bleed past the icon's curved
    -- edge. Chord-inset alone leaves a small sliver of bar fill where
    -- the bar's straight edge sits inside the icon's curve at the
    -- bar's near corner; the mask removes that sliver cleanly.
    -- Sized/positioned at the icon's visible circle in _ApplyOUFFrameBorder.
    -- Hidden when icon is hidden, square-shaped, or in model style.
    -- Note: AddMaskTexture keeps target pixels where the mask is opaque
    -- and erases them where the mask is transparent. With CLAMP wrap
    -- modes, beyond the texture extent it reads the edge alpha (opaque)
    -- so the bar stays visible far from the icon.
    local iconCutoutMask = BF.MaskTexture(self)
    iconCutoutMask:SetTexture("Interface\\AddOns\\BuzzardFrames\\Media\\IconCutoutMask",
        "CLAMP", "CLAMP")
    iconCutoutMask:SetSize(1, 1)
    iconCutoutMask:SetPoint("CENTER", self, "CENTER", 0, 0)
    iconCutoutMask:Hide()
    self._oufIconCutoutMask = iconCutoutMask

    -- Attach the mask to every chord-inset texture that can bleed past
    -- the icon's curve: the name strip background, the health fill +
    -- bg, and the power fill + bg. The bg textures anchor LEFT to the
    -- fill's RIGHT edge -- as fill shrinks toward the icon side (health
    -- depleting on player/pet), bg slides into the icon's chord region
    -- and bleeds without the mask.
    if self._oufNameBarBg then self._oufNameBarBg:AddMaskTexture(iconCutoutMask) end
    local healthFill = Health:GetStatusBarTexture()
    if healthFill then healthFill:AddMaskTexture(iconCutoutMask) end
    if healthBg then healthBg:AddMaskTexture(iconCutoutMask) end
    local powerFill = Power:GetStatusBarTexture()
    if powerFill then powerFill:AddMaskTexture(iconCutoutMask) end
    if powerBg then powerBg:AddMaskTexture(iconCutoutMask) end

    -- Override oUF's Power:Update to force Mana display for Balance Druid
    -- when the resource bar is already showing Astral Power.
    -- Without this, the power bar shows Astral Power (the primary power type
    -- for Balance Druid in caster/boomkin form), duplicating the resource bar.
    Power.Override = function(powerSelf, event, unit)
        if powerSelf.__unit ~= unit then return end
        local element = powerSelf.Power
        if element.PreUpdate then element:PreUpdate(unit) end

        local displayType, displayMin
        if element.displayAltPower then
            displayType, displayMin = element:GetDisplayPower(unit)
        end

        local cur, max = UnitPower(unit, displayType), UnitPowerMax(unit, displayType)
        displayMin = displayMin or 0
        element:SetMinMaxValues(displayMin, max)

        if UnitIsConnected(unit) then
            element:SetValue(cur, element.smoothing)
        else
            element:SetValue(max, element.smoothing)
        end

        element.cur = cur
        element.min = displayMin
        element.max = max
        element.displayType = displayType

        if element.PostUpdate then
            element:PostUpdate(unit, cur, displayMin, max)
        end
    end

    -- Text overlay frame (sits above bars so text is never clipped)
    -- v90.9 LEVEL (owner report: "the frame level of text seems to be
    -- lower than the borders — all text should be a higher frame level
    -- than borders"): this frame used to sit at +7, the SAME level as
    -- every border widget on the unit frame (the square boxes
    -- fb.name/health/power, the composite rounded rect/host, the
    -- separator-line host). A frame-level TIE is broken by creation
    -- order, and all of those are created after this one, so they won
    -- every overlap. The per-bar rounded kits climb higher still
    -- (slotKitLevel resolves to frame+8, because the health chain is
    -- frame+2 and the kit clears it by 6), so the text lost to those
    -- outright.
    -- +10 clears every BAR border layer (max +8, the per-bar kits) and
    -- stays under the phase / raid-target / ping overlays (+15/+16).
    -- It also lands above iconFrame (+8) and the square portrait model
    -- (+9), so text that reaches into the portrait column now draws
    -- over it instead of under — deliberate, since that column is
    -- where the border used to eat the text. The icon block's own ring
    -- (+13) still draws over text, which only matters if text is moved
    -- onto the portrait itself.
    local textFrame = CreateFrame("Frame", nil, self)
    textFrame:SetAllPoints(self)
    textFrame:SetFrameLevel(self:GetFrameLevel() + 10)
    textFrame:EnableMouse(false)

    -- Name and level mirror each other between player and target:
    --   Player: [level] right-aligned on the right, [name] left-aligned filling the rest
    --   Target: [level] left-aligned on the left, [name] right-aligned filling the rest
    --           (mirrors player since the portrait overhangs the opposite side)
    local nameText = textFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameText:SetTextColor(1, 1, 1, 1)
    nameText:SetWordWrap(false)
    nameText:SetNonSpaceWrap(false)
    -- Do NOT call SetFont with addon path here — this runs on the restricted thread
    -- where addon font files may not be accessible, causing silent failure.
    -- _ApplyOUFRightFrameLayout applies the correct font on a normal Lua thread.
    self:Tag(nameText, "[name]")
    self.Name = nameText
    -- Store a reference so _ApplyOUFNameColor can reach it from PostUpdate.
    self._nameText = nameText

    local levelText = textFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    levelText:SetTextColor(1, 0.82, 0, 1)
    self:Tag(levelText, "[level]")
    self.Level = levelText

    -- Skull icon for boss-level units (level == -1). Positioned over the level
    -- text; toggled in Health.PostUpdate. Player frame never shows a skull.
    if unit ~= "player" and unit ~= "pet" then
        local skullIcon = BF.Texture(textFrame, nil, "OVERLAY")
        skullIcon:SetAtlas("UI-HUD-UnitFrame-Target-HighLevelTarget_Icon")
        skullIcon:SetSize(11, 14)
        skullIcon:Hide()
        self._skullIcon = skullIcon
    end

    -- Raid Group text (player frame only)
    -- Shows "[Group X]" or "[X]" when in a raid group.
    if unit == "player" then
        local raidGroupText = textFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        raidGroupText:SetTextColor(1, 1, 1, 1)
        raidGroupText:SetJustifyH("RIGHT")
        raidGroupText:Hide()
        self.RaidGroupText = raidGroupText
    end

    if unit == "player" or unit == "pet" then
        -- Player/Pet: portrait on the LEFT.
        -- name:  LEFT-anchored, left-justified
        -- level: RIGHT-anchored, right-justified
        nameText:SetJustifyH("LEFT")
        nameText:SetPoint("TOPLEFT",  self, "TOPLEFT",  21, -2)
        nameText:SetPoint("TOPRIGHT", self, "TOPRIGHT", -38, -2)
        levelText:SetJustifyH("RIGHT")
        levelText:SetPoint("TOPRIGHT", self, "TOPRIGHT", -4, -2)
    else
        -- Target/Focus: portrait on the RIGHT.
        -- level: LEFT-anchored at top, center-justified
        -- name:  spans the name bar right-aligned at top
        levelText:SetJustifyH("CENTER")
        levelText:SetPoint("TOPLEFT", self, "TOPLEFT", 4, -2)
        nameText:SetJustifyH("RIGHT")
        nameText:SetPoint("TOPLEFT",  self, "TOPLEFT",   4, -2)
        nameText:SetPoint("TOPRIGHT", self, "TOPRIGHT", -21, -2)
    end

    local hPct = textFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hPct:SetTextColor(1, 1, 1, 1)
    self.HealthPctText = hPct

    local hVal = textFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hVal:SetTextColor(1, 1, 1, 1)
    self.HealthValText = hVal

    -- "Dead" text — left-aligned in the health bar, shown when the unit is dead.
    local deadText = textFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    deadText:SetTextColor(1, 0.1, 0.1, 1)
    deadText:SetText("Dead")
    deadText:SetAlpha(0)
    self.DeadText = deadText

    local pPct = textFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pPct:SetTextColor(1, 1, 1, 1)
    self.PowerPctText = pPct

    local pVal = textFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pVal:SetTextColor(1, 1, 1, 1)
    self.PowerValText = pVal

    -- ── Frame borders: one non-secure box per bar (name / health / power) ──────
    -- Parented to self so they automatically show/hide with the unit frame.
    -- This means settings changed while no target (frame hidden) are applied
    -- immediately when the frame next shows, without any OnShow/OnHide wiring.
    local function MakeBorderBox()
        local bf = CreateFrame("Frame", nil, self)
        bf:SetAllPoints(false)  -- no automatic sizing; ApplyBox sets size/points
        bf:EnableMouse(false)
        bf:Hide()
        local function MakeEdge()
            local t = BF.Texture(bf, nil, "OVERLAY", nil, 2)
            t:SetColorTexture(0, 0, 0, 1)
            return t
        end
        bf.top    = MakeEdge()
        bf.bottom = MakeEdge()
        bf.left   = MakeEdge()
        bf.right  = MakeEdge()
        return bf
    end

    local fb = {
        name   = MakeBorderBox(),
        health = MakeBorderBox(),
        power  = MakeBorderBox(),
    }
    self._frameBorder = fb

    -- Apply the user's saved Power Bar Opacity to the power border box.
    -- Pairs with the SetAlpha applied to self.Power above. SetAlpha on
    -- the border Frame propagates to its top/bottom/left/right edge
    -- textures, so subsequent ApplyBox calls that re-color those
    -- textures don't fight with the opacity.
    do
        local op = BF.ufDB and BF.ufDB.profile and BF.ufDB.profile.oufPowerBarOpacity
        if op ~= nil then fb.power:SetAlpha(op) end
    end

    -- Attach the icon cutout mask to each border edge texture so the
    -- chord-side vertical edge doesn't poke through the icon's curve
    -- (the chord inset is tangent at the bar's FAR corner; at the
    -- NEAR corner the icon's curve extends past the chord line, so
    -- the border's straight edge would otherwise cross under the icon).
    for _, box in pairs(fb) do
        box.top:AddMaskTexture(iconCutoutMask)
        box.bottom:AddMaskTexture(iconCutoutMask)
        box.left:AddMaskTexture(iconCutoutMask)
        box.right:AddMaskTexture(iconCutoutMask)
    end

    -- ── Rounded composite ring + content mask (v59) ───────────────────────
    -- One nine-sliced ring around the whole block (name+health+alt+power)
    -- plus one rounded-rect mask clipping the bar content to the corner
    -- radius — the raid-frame Container.lua pattern applied per block.
    -- Hidden until a rounded oufBorderMode selects them in layout
    -- (_ApplyOUFRoundedFrameBorder); hidden mask = masking off (oUF
    -- cutout-mask precedent — attachments stay in place permanently).
    --
    -- Structure (v58 pixel host, adapted for shrinkable geometry):
    --   rect : UNSCALED child of self — geometry owner. Layout anchors it
    --          to the visible block (top drops below a hidden name bar,
    --          bottom lifts above a hidden/detached power bar), with all
    --          offsets expressed in self's coordinate space.
    --   host : child of rect whose SetScale is stamped in layout so its
    --          effective scale == pixelSize → 1 art texel renders as
    --          EXACTLY 1 physical pixel (band exactly 2/3 px, constant
    --          ~6 px corner radius at any UI/frame scale).
    --   ring/mask : SetAllPoints(rect) — zero-offset anchors convert
    --          cleanly across the host's scale (same guarantee the raid
    --          ring gets from SetAllPoints(parent)).
    -- Level +7 matches the square border boxes so the ring layers exactly
    -- where the 4-edge boxes do (above bars/absorbs, below iconFrame +8).
    local roundRect = CreateFrame("Frame", nil, self)
    roundRect:SetAllPoints(self)
    roundRect:SetFrameLevel(self:GetFrameLevel() + 7)
    roundRect:EnableMouse(false)
    self._oufRoundRect = roundRect

    local roundHost = CreateFrame("Frame", nil, roundRect)
    roundHost:SetAllPoints(roundRect)
    roundHost:SetFrameLevel(roundRect:GetFrameLevel())
    self._oufRoundHost = roundHost

    local roundRing = BF.Texture(roundHost, nil, "OVERLAY", nil, 2)
    roundRing:SetTextureSliceMargins(ROUND_SLICE, ROUND_SLICE, ROUND_SLICE, ROUND_SLICE)
    roundRing:SetAllPoints(roundRect)
    roundRing:Hide()
    self._oufRoundBorder = roundRing

    -- LEGACY sliced composite mask (v90.7: retired from rendering —
    -- the composite content mask is now the fixed-size corner-mask
    -- set built lazily in _ApplyOUFRoundedFrameBorder. This widget is
    -- kept, permanently hidden, because historical profiles/regions
    -- reference it via the attach/remove sites; a hidden mask is
    -- inert).
    local roundMask = BF.MaskTexture(roundHost)
    if roundMask.SetBlockingLoadsRequested then
        roundMask:SetBlockingLoadsRequested(true)
    end
    roundMask:SetTextureSliceMargins(ROUND_SLICE, ROUND_SLICE, ROUND_SLICE, ROUND_SLICE)
    roundMask:SetAllPoints(roundRect)
    roundMask:Hide()
    self._oufRoundMask = roundMask

    -- The ring takes the icon cutout mask exactly as the square border
    -- edges do above, so it never crosses under the portrait's curve.
    roundRing:AddMaskTexture(iconCutoutMask)

    -- Bar Separators (oufRoundedSeparators): v63 drew separator LINES
    -- at the bar boundaries here; v65 replaced them with PER-BAR full
    -- rounded borders (owner request) — each visible bar gets its own
    -- standalone ring+mask kit instead. See _ApplyOUFPerBarRoundBorders;
    -- no widgets to pre-create (kits are lazy per bar frame).

    -- Circular portrait icon
    -- Use SecureActionButtonTemplate so the icon can forward clicks (target,
    -- togglemenu) and participate in Clique/click-cast bindings just like
    -- the unit frame itself.
    local iconFrameSz = iconSz + ringThick * 2
    -- Grid2 pattern: use SecureUnitButtonTemplate (not SecureActionButtonTemplate)
    -- so the icon frame has the same unit-aware click dispatch as the main bar.
    -- SecureUnitButtonTemplate processes *type1/*type2 with the "unit" attribute
    -- to fire target/togglemenu correctly.
    -- PingableUnitFrameTemplate: the icon is its own mouse-enabled secure
    -- button ABOVE the unit frame, so without the template pings over it
    -- fall through to the world instead of resolving the unit. Like the
    -- oUF frames (__unit rename), no `.unit` Lua field is set here, so
    -- the secret-identity ping bug can't reach it.
    local iconFrame = CreateFrame("Button", nil, self,
        "SecureUnitButtonTemplate,PingableUnitFrameTemplate")
    iconFrame:SetFrameLevel(self:GetFrameLevel() + 8)
    iconFrame:SetSize(iconFrameSz, iconFrameSz)
    iconFrame:SetAttribute("unit",   unit)
    iconFrame:SetAttribute("*type1", "target")
    iconFrame:SetAttribute("*type2", "togglemenu")
    iconFrame:EnableMouse(true)
    iconFrame:RegisterForClicks("AnyUp")
    -- Register with ClickCastFrames so Clique picks it up alongside self.
    -- _ApplyIconClickOverrides may remove it later if the user wants the
    -- icon to ignore custom click-cast bindings.
    _G.ClickCastFrames = _G.ClickCastFrames or {}
    _G.ClickCastFrames[iconFrame] = true
    -- Tooltip: mirror the unit frame's OnEnter/OnLeave logic.
    iconFrame:HookScript("OnEnter", function(btn)
        local dbp = BF.ufDB and BF.ufDB.profile
        if not dbp or not dbp.showUnitTooltip then return end
        if InCombatLockdown() and not dbp.showUnitTooltipInCombat then return end
        local u = btn:GetAttribute("unit")
        if u and UnitExists(u) then
            GameTooltip_SetDefaultAnchor(GameTooltip, UIParent)
            GameTooltip:SetUnit(u)
            GameTooltip:Show()
        end
    end)
    iconFrame:HookScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    if side == "LEFT" then
        iconFrame:SetPoint("RIGHT", self, "LEFT", 20, 0)
    else
        iconFrame:SetPoint("LEFT",  self, "RIGHT", -20, 0)
    end

    local goldRing = BF.Texture(iconFrame, nil, "BACKGROUND")
    goldRing:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask",
        "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    goldRing:SetVertexColor(0.85, 0.65, 0.1, 1)
    goldRing:SetAllPoints(iconFrame)

    -- circIconMaskedCirc: for classicon+circular — circular mask clips the square icon
    local circIconMaskedCirc = BF.Texture(iconFrame, nil, "ARTWORK")
    local circMask = BF.MaskTexture(iconFrame)
    circMask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask",
        "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    circIconMaskedCirc:AddMaskTexture(circMask)
    circIconMaskedCirc:Hide()

    -- circIconBare: no mask — portrait+circular (already round), or any square style
    local circIconBare = BF.Texture(iconFrame, nil, "ARTWORK")
    circIconBare:Hide()

    -- squarePortraitModel: PlayerModel for model style
    local squarePortraitModel = CreateFrame("PlayerModel", nil, iconFrame)
    squarePortraitModel:SetFrameLevel(iconFrame:GetFrameLevel() + 1)
    squarePortraitModel:EnableMouse(false)
    squarePortraitModel:Hide()

    -- squareBorder: 4-edge solid border shown for square shape.
    -- Parented to iconFrame at a high frame level so it draws over the icon texture.
    -- EnableMouse(false) so it never intercepts clicks meant for the icon button.
    local squareBorder = CreateFrame("Frame", nil, iconFrame)
    squareBorder:SetFrameLevel(iconFrame:GetFrameLevel() + 5)
    squareBorder:EnableMouse(false)
    squareBorder:SetHitRectInsets(10000, 10000, 10000, 10000)
    squareBorder:Hide()
    local function MakeBorderEdge()
        local t = BF.Texture(squareBorder, nil, "OVERLAY")
        t:SetColorTexture(0.85, 0.65, 0.1, 1)  -- default gold, overridden by _ApplyOUFIconBorder
        return t
    end
    squareBorder.top    = MakeBorderEdge()
    squareBorder.bottom = MakeBorderEdge()
    squareBorder.left   = MakeBorderEdge()
    squareBorder.right  = MakeBorderEdge()

    -- oUF requires self.Portrait to be set to activate the Portrait element.
    -- We use a dedicated invisible dummy texture so oUF can call Show/Hide/SetPortraitTexture
    -- on it freely without interfering with our own display textures (circIconMaskedCirc,
    -- circIconBare, squarePortraitModel). The Override hook routes all portrait update
    -- events into _UpdateOUFIcon which manages the real visuals.
    local portraitDummy = BF.Texture(iconFrame, nil, "BACKGROUND")
    portraitDummy:SetAlpha(0)
    portraitDummy:Hide()
    self.Portrait             = portraitDummy
    self._iconFrame           = iconFrame
    self._iconRing            = goldRing
    self._circIconMaskedCirc  = circIconMaskedCirc
    self._circMask            = circMask
    self._circIconBare        = circIconBare
    self._squarePortraitModel = squarePortraitModel
    self._squareBorder        = squareBorder

    -- Override oUF's Portrait update: called as Override(unitframe, event, unit)
    -- Routes through the coalescing queue (see _QueueOUFIconUpdate): portrait
    -- events arrive in bursts, and the queue collapses each burst to ONE
    -- _UpdateOUFIcon render per frame on the next tick. Cosmetic events
    -- (UNIT_FACTION, UNIT_CONNECTION) are dropped there before queueing.
    portraitDummy.Override = function(unitframe, event, unit)
        BF:_QueueOUFIconUpdate(unitframe, unit or unitframe.__unit, event)
    end

    -- Phase Indicator (oUF element: self.PhaseIndicator)
    -- Shows the phasing icon when the unit is in a different phase.
    -- Parented to a dedicated Frame at level +15 so it draws above all other frame elements.
    local phaseFrame = CreateFrame("Frame", nil, self)
    phaseFrame:SetFrameLevel(self:GetFrameLevel() + 15)
    phaseFrame:SetSize(16, 16)
    phaseFrame:EnableMouse(true)
    phaseFrame:Hide()
    local phaseIcon = BF.Texture(phaseFrame, nil, "OVERLAY", nil, 1)
    phaseIcon:SetAllPoints(phaseFrame)
    -- oUF will automatically set the atlas 'RaidFrame-Icon-Phasing' since no texture is set.
    phaseFrame.Icon = phaseIcon
    -- Position: above the top-right corner of the bar frame (repositioned in ApplyLayout).
    phaseFrame:SetPoint("CENTER", self, "TOPLEFT", 0, 0)
    self.PhaseIndicator = phaseFrame

    -- Raid Target Indicator (oUF element: self.RaidTargetIndicator)
    -- oUF listens for RAID_TARGET_UPDATE and calls SetTexture on this automatically.
    -- Hosted on a dedicated Frame at level +15 so it draws above the icon frame (+8)
    -- and squareBorder (+8+5=13), ensuring it is never obscured by the portrait or border.
    local raidTargetFrame = CreateFrame("Frame", nil, self)
    raidTargetFrame:SetFrameLevel(self:GetFrameLevel() + 15)
    raidTargetFrame:SetAllPoints(self)
    raidTargetFrame:EnableMouse(false)
    local raidTarget = BF.Texture(raidTargetFrame, nil, "OVERLAY", nil, 1)
    raidTarget:SetSize(20, 20)
    raidTarget:SetPoint("CENTER", self, "CENTER", 0, 0)  -- repositioned in ApplyLayout
    self.RaidTargetIndicator = raidTarget
    self._raidTargetFrame    = raidTargetFrame

    -- Combat Indicator (oUF element: self.CombatIndicator)
    -- Only for the player frame. oUF listens for UNIT_FLAGS and shows/hides
    -- based on UnitAffectingCombat.
    if unit == "player" then
        local combatFrame = CreateFrame("Frame", nil, self)
        combatFrame:SetFrameLevel(self:GetFrameLevel() + 15)
        combatFrame:SetAllPoints(self)
        combatFrame:EnableMouse(false)
        local combatTex = BF.Texture(combatFrame, nil, "OVERLAY", nil, 2)
        combatTex:SetSize(24, 24)
        combatTex:SetPoint("CENTER", self.Health or self, "CENTER", 0, 0)
        self.CombatIndicator = combatTex
        self._combatFrame    = combatFrame
    end

    -- Ping Indicator. Engine ping pins don't render on addon frames on
    -- 12.1, and both UNIT_PING_PIN_ADDED/REMOVED (SecureOnly) and
    -- UnitPingIconFrameTemplate (forbidden frame) are closed to addons.
    -- BF.CreateOUFPingWidget builds our pin/background textures; real
    -- pings reach them by mirroring Blizzard's own TargetFrame/FocusFrame
    -- receivers (see PingMirror.lua), and /bf pingtest drives them
    -- directly. Stored as self._bfPingIndicator, NOT self.PingIndicator:
    -- the latter would make oUF auto-enable the salvaged PingIndicator
    -- element, which registers the events directly (forbidden).
    if BF.HasPingPinEvents() then
        BF.CreateOUFPingWidget(self)
    end -- BF.HasPingPinEvents()

    -- Cast bar (oUF Castbar element)
    -- MUST be set here, inside the style function, so f.Castbar exists when
    -- oUF calls Enable() on all registered elements immediately after Spawn().
    -- If set after Spawn() returns, the element is never enabled and no events fire.
    if unit == "target" or unit == "focus" then
        BF:_BuildOUFCastbar(self, unit)
    elseif unit and unit:match("^boss%d") then
        -- Boss cast bars have their own independent settings under the "boss" prefix.
        BF:_BuildOUFCastbar(self, "boss")
        -- Boss cast bars are always attached (never detachable).
        self.Castbar._isBossCastbar = true
    end

    -- Aura elements (12.1 AuraContainer rewrite, oUF PR #870):
    -- Blizzard-owned AuraContainers created via the oUF meta function
    -- self:CreateAuras(). The container handles UNIT_AURA, layout, sorting,
    -- filtering, cooldowns, tooltips and cancelling natively (C-side).
    -- IMPORTANT: group/button options are FROZEN at AddGroup time —
    -- everything read from the profile here requires a /reload to change
    -- (the options UI prompts for it). Live at layout time: anchoring,
    -- show/hide, and wrap width (SetFlowLayoutMaximumLineSize).
    -- targettarget/focustarget/pet auras remain intentionally omitted.
    if unit ~= "targettarget" and unit ~= "focustarget" and unit ~= "pet" then do
        -- Aura profile keys are the per-unit subtable pf with keys prefixed
        -- by the profile key ("player"/"target"/"focus"/"boss"), matching
        -- the layout functions. Player show defaults differ (opt-in).
        local pk = profileKey
        local defaultShown = (unit ~= "player")
        local isBoss = unit:match("^boss%d") ~= nil

        -- Per-unit constants for BF.UpdateOUFAuraFilters, baked here so its
        -- combat path (target swaps) never string.matches or concatenates.
        self._bf_auraUFKey      = pk                -- profile subtable key
        self._bf_auraDynBuffs   = isBoss            -- friendly-boss buff filter
        self._bf_auraDynDebuffs = (unit == "target" or unit == "focus" or isBoss)

        -- Aura border style (v61): EVERY style (Blizzard-Style included)
        -- initializes through FlatInitButton, which creates all widget
        -- sets and stamps the current style — style/color/thickness/
        -- stealable changes apply LIVE via BF:RestyleOUFAuraButtons
        -- (no /reload; raid ContainerFactory restyle parity).

        -- initialAnchor is the corner the content hugs inside the
        -- auto-sizing container, and must be the same corner the container
        -- is pinned by in the layout functions. Buffs sit below the frame,
        -- pinned by TOPLEFT and growing DOWN → content hugs TOPLEFT (rows
        -- extend the container downward without moving existing rows).
        -- Debuffs sit above, pinned by BOTTOMLEFT growing UP → BOTTOMLEFT.
        -- Using the wrong corner makes every existing row shift when a new
        -- row appears (content follows the far edge as the container grows).
        local function BuildContainer(kind, growthY, contentAnchor)  -- kind = "Buff"/"Debuff"
            local sz      = pf[pk..kind.."Size"]     or 18
            local spacing = pf[pk..kind.."Spacing"]  or 2
            -- v67: fallback 32 -> per-unit defaults (16, boss 8). This only
            -- fires for a profile with no stored value; it must agree with
            -- Defaults.lua / Defaults_UnitFrames.lua or boss silently spawns a
            -- 32-frame container while its options page reports 8.
            local maxN    = pf[pk.."Max"..kind.."s"] or (pk == "boss" and 8 or 16)
            local perRow  = pf[pk..kind.."sPerRow"]  or 8
            -- v96: ProcessAura processing policy on the DEBUFF container.
            -- The one debuff container in this addon that provably renders
            -- debuffs on friendly PLAYERS is the raid `debuffs` container,
            -- and the ONLY structural difference between it and this one was
            -- that it carries this policy (EnsureDebuffProcessPolicy,
            -- Indicators/DebuffIcons.lua) while the unit-frame containers
            -- carried none. Passed through oUF's own CreateAuras option
            -- (Libs/oUF/elements/auras.lua -> SetAuraProcessingPolicy), not a
            -- direct engine call, so the library stays the only caller.
            -- ignoreBuffs: this container is HARMFUL-only, so buff
            -- classification is dead work. The engine call carries an
            -- UpdateAllAuras with it. Enum-gated so a 12.0 client never
            -- reaches the setter.
            local policy = nil
            if kind == "Debuff" and CustomAuraContainerAuraProcessingPolicy
                and CustomAuraContainerAuraProcessingPolicy.ProcessAura then
                policy = { ignoreBuffs = true }
            end
            local c = self:CreateAuras({
                initialAnchor = contentAnchor,
                growthX       = "RIGHT",
                growthY       = growthY,
                -- The default layoutLimit reads the unit frame's CURRENT
                -- width, which is wrong pre-layout — always pass it.
                layoutLimit   = perRow * (sz + spacing),
                policy        = policy,
            })
            c._bf_policyOn   = (policy ~= nil)
            -- Engine-owned container: BF.UnsnapTree must not walk into it.
            -- Its buttons are forbidden objects while an addon restriction
            -- is active (active keystone run), and GetRegions() on one
            -- throws out of the style function. FlatInitButton unsnaps
            -- each button's own widgets through the funnel instead.
            c._bf_unsnapStop = true
            c.size           = sz
            c.elementSpacing = spacing
            c.lineSpacing    = spacing
            c.maxFrameCount  = maxN
            c.showCount      = true
            -- Preserve the old oUF tooltip anchor (new default is BOTTOMLEFT).
            c.tooltipAnchor  = "ANCHOR_BOTTOMRIGHT"
            -- Baked values the layout functions need for live wrap-width math
            -- and the castbar's Avoid Auras reservation.
            c._bf_size       = sz
            c._bf_spacing    = spacing
            c._bf_maxN       = maxN
            c._bf_userShown  = defaultShown
            -- Live-restyle registry (BF:RestyleOUFAuraButtons walks it).
            c._bf_buttons    = {}
            c.PostCreateButton = PostCreateAuraButton
            c.CreateButton = FlatInitButton  -- must be set BEFORE AddGroup
            return c
        end

        -- Stealable/purgeable buff border (v60, restored; v61 live):
        -- the aurapocalypse oUF update exposes the engine's
        -- stealableFilter on AddDispelTypeTexture, so the pre-12.1
        -- stealable glow is back as an engine-driven border. The
        -- CANDIDATE flag marks containers whose buttons get the widget
        -- + binding at init (creation can't happen later on pooled
        -- buttons); the oufAuraShowStealable toggle then flips it LIVE
        -- via the widget's alpha host. Player's own buffs are excluded
        -- (the glow marks buffs the PLAYER can steal/purge on other
        -- units — matching the old oUF showStealableBuffs usage).
        -- Enum-gated in FlatInitButton so 12.0 clients never bind it.
        local Buffs = BuildContainer("Buff", "DOWN", "TOPLEFT")
        Buffs._bf_stealableCandidate = (unit ~= "player")
        Buffs._bf_kind = "buffs"
        -- Field name on the frame: the "ouf" recreate key (see
        -- RecreateOUFAuraGroups).
        Buffs._bf_elKey = "Buffs"
        -- v96: EVERY filter this frame can need is declared here, at spawn,
        -- inside the pre-PEW configuration window. Nothing re-stamps a
        -- filter string afterwards -- SetActiveOUFAuraGroup parks and
        -- unparks these by candidate set instead. The |PLAYER variant is
        -- built only on the frames whose buff filter is dynamic (boss,
        -- _bf_auraDynBuffs), because each group costs its own 10-button
        -- engine pool. Shared with the in-key re-declare (plan §3.2 C).
        DeclareOUFAuraGroups(self, Buffs, "Buff")
        -- Style the buttons were just initialized with (after _bf_kind and
        -- the stealable flag: both are sig inputs).
        Buffs._bf_bakedStyleSig = OUFAuraStyleSig(Buffs)
        self.Buffs = Buffs

        local Debuffs = BuildContainer("Debuff", "UP", "BOTTOMLEFT")
        -- Colored dispel-type border on debuffs (replaces showDebuffType):
        -- driven natively via AddDispelTypeTexture with the string-keyed
        -- colors.dispel map (see lib default CreateButton / FlatInitButton).
        Debuffs.showDebuffBorder = true
        Debuffs._bf_kind = "debuffs"
        -- v87: NEVER a bare HARMFUL query (owner report: debuffs missing on
        -- friendly PLAYERS -- self-target included -- while friendly NPCs
        -- and enemies worked). On player-controlled friendlies the aura
        -- data is SECRET, and the one configuration in this addon that
        -- failed on exactly those units was also the one issuing the only
        -- unqualified "all harmful" query; every raid-frame debuff group
        -- that provably renders friendly players carries a qualifying
        -- token. INCLUDE_NAME_PLATE_ONLY is ADDITIVE (base set plus
        -- nameplate-personal auras), so NPC/enemy behavior is a superset
        -- of before -- this is raid-parity, not a restriction.
        -- The two attackable-unit variants (player debuffs only, and the
        -- nameplate-inclusive form the "Include Nameplate Only Debuffs"
        -- toggle selects) are declared here rather than stamped later, only
        -- on the frames whose debuff filter is dynamic (_bf_auraDynDebuffs).
        Debuffs._bf_elKey = "Debuffs"
        DeclareOUFAuraGroups(self, Debuffs, "Debuff")
        Debuffs._bf_bakedStyleSig = OUFAuraStyleSig(Debuffs)
        self.Debuffs = Debuffs

        -- Dynamic filters + visibility gating (replaces the old .filter
        -- functions / FilterAura / PreUpdate callbacks, which no longer
        -- exist in the rewritten element). oUF fires UpdateAllElements on
        -- target/focus/boss unit swaps; hostility, connection and phase
        -- changes are covered by the unit events. BF.UpdateOUFAuraFilters
        -- is change-guarded, so repeat calls are cheap.
        hooksecurefunc(self, "UpdateAllElements", BF.UpdateOUFAuraFilters)
        -- Registered directly (no per-frame closure): oUF passes
        -- (frame, event, ...) and the extra args are ignored.
        self:RegisterEvent("UNIT_FACTION", BF.UpdateOUFAuraFilters)
        self:RegisterEvent("UNIT_CONNECTION", BF.UpdateOUFAuraFilters)
        self:RegisterEvent("UNIT_PHASE", BF.UpdateOUFAuraFilters)
        BF.UpdateOUFAuraFilters(self)
    end end  -- do / if unit ~= "targettarget" and unit ~= "focustarget" and unit ~= "pet"

    -- PostUpdate callbacks
    -- We ignore the secret cur/max args passed by oUF and call the safe
    -- percent/abbreviation APIs directly, same as UpdatePlayerFrame does.
    local S = CurveConstants and CurveConstants.ScaleTo100

    -- Called from Health.PostUpdate so name color is refreshed on every unit
    -- change without needing SetScript on a FontString (which is unsupported).
    local function ApplyNameColor(unit)
        local nameText = self._nameText
        if not nameText then return end
        local ufKey = self._bf_ufKey or self.__unit
        local r, g, b = BF:_GetOUFNameColor(unit, ufKey)
        nameText:SetTextColor(r, g, b, 1)
    end

    -- Cache ufKey: resolve boss pattern match once, reuse on every PostUpdate.
    -- Set during BluzzardStyle and updated if the frame's unit changes.
    self._bf_ufKey = unit and unit:match("^boss%d") and "boss" or unit

    -- Hook PreUpdate: oUF calls frame:PreUpdate(event) at the top of
    -- UpdateAllElements, which fires on PLAYER_TARGET_CHANGED,
    -- PLAYER_FOCUS_CHANGED, INSTANCE_ENCOUNTER_ENGAGE_UNIT, ForceUpdate,
    -- etc. — any event that means the unit identity may have changed.
    -- Regular UNIT_HEALTH does NOT go through UpdateAllElements, so the
    -- flag stays nil on health ticks.
    self.PreUpdate = function(frame, event)
        frame._bf_unitChanged = true
        -- v94 PERF: per-frame update generation, bumped on every
        -- UpdateAllElements (unit swap AND settings change). Lets per-element
        -- config stamps (Power.PostUpdate) detect a refresh without the
        -- _bf_unitChanged bool that Health.PostUpdate consumes and clears.
        frame._bf_ufGen = (frame._bf_ufGen or 0) + 1
    end

    Health.PostUpdate = function(element, unit, cur, max)
        -- Owner frame: the oUF unit frame. Health's visual parent is the
        -- clipFrame on player/target/focus, so element:GetParent() returns
        -- the clipFrame there. _bf_ownerFrame is set in BluzzardStyle to
        -- the true unit frame regardless of parenting.
        local frame    = element._bf_ownerFrame or element:GetParent()
        local prof     = BF.ufDB.profile
        local ufKey    = frame._bf_ufKey or frame.__unit
        local uf       = prof[ufKey] or prof.player or {}  -- per-unit sub-table

        -- Detect unit change: _bf_unitChanged is set by PreUpdate which
        -- fires on UpdateAllElements (PLAYER_TARGET_CHANGED, ForceUpdate,
        -- etc.). Regular UNIT_HEALTH ticks do NOT trigger UpdateAllElements,
        -- so the flag is nil on health ticks. No GUID comparison needed.
        local unitChanged = frame._bf_unitChanged
        if unitChanged then
            frame._bf_unitChanged = nil
        end

        -- ── Health bar color ───────────────────────────────────────────
        -- Only recompute on unit change; reuse cached color on health ticks.
        -- Exception: when health gradient is active the color depends on
        -- current health %, so it must be recalculated every tick.
        -- Alpha precedence (see _GetOUFHealthBarFillAlpha): gradient curve
        -- alpha > playerFrameHealthBarOpacity (when separate config) >
        -- oufHealthBarOpacity (global slider).
        -- v95: idle-gated segment timing. _pm is nil unless profiling; each
        -- BF:_ProfSeg closes the prior slice and returns a fresh mark. Setup
        -- above (frame/prof/uf + unitChanged detect) is the report remainder.
        local _pm = BF._profActive and GetTimePreciseSec()
        if unitChanged or frame._bf_healthGradient then
            local r, g, b, isGradient, gradAlpha = BF:_GetOUFHealthColor(unit, uf.useClassColor, ufKey)
            local fillAlpha = BF:_GetOUFHealthBarFillAlpha(ufKey, isGradient, gradAlpha)
            frame._bf_healthR, frame._bf_healthG, frame._bf_healthB = r, g, b
            frame._bf_healthA = fillAlpha
            frame._bf_healthGradient = isGradient
            element:SetStatusBarColor(r, g, b, fillAlpha)
            -- Class-color background depends on the unit's class, so it must
            -- be recomputed when the unit changes (target/focus swaps). Cheap:
            -- only runs on unit change, not per health tick. Static/gradient
            -- modes are also re-applied harmlessly (gradient is then driven
            -- per-tick by the _bf_bgGradient branch below).
            if unitChanged and (prof.oufBackgroundColorMode or "static") == "class"
               and prof.oufUseCustomBackgroundColor then
                BF:_ApplyOUFHealthBgColor(frame)
            end
            -- Refresh icon border if it tracks the health bar color.
            if unitChanged and prof.classIconBorderUseHealthColor and frame._iconRing then
                BF:_ApplyOUFIconBorder(frame)
            end
        else
            -- Health tick: reapply cached color (StatusBar may need it after
            -- smoothing interpolation completes).
            local r, g, b = frame._bf_healthR, frame._bf_healthG, frame._bf_healthB
            if r then
                element:SetStatusBarColor(r, g, b, frame._bf_healthA or BF:_GetOUFHealthBarFillAlpha(ufKey))
            end
        end

        -- ── Background gradient (per-tick when active) ────────────────
        -- Alpha for the bg comes from the gradient curve (interpolated
        -- per-stop alpha). _ApplyOUFHealthBgColor already set the bg
        -- frame's SetAlpha to 1 when in gradient mode, so the alpha
        -- baked into the color texture is the final rendered alpha.
        if _pm then _pm = BF:_ProfSeg("oUF:H.PU [color]", _pm) end
        if frame._bf_bgGradient and frame._oufHealthBg and BF.bgGradientCurve then
            local cr, cg, cb, ca = UnitHealthPercent(unit, true, BF.bgGradientCurve):GetRGBA()
            frame._oufHealthBg:SetColorTexture(cr, cg, cb, ca)
        end

        -- ── Health text (always updates — value changes every tick) ────
        -- v94 PERF: show flags + percent format are config, not per-tick
        -- data -- stamp on unit/settings change (both set _bf_unitChanged)
        -- instead of three profile reads + a string rebuild every tick.
        if _pm then _pm = BF:_ProfSeg("oUF:H.PU [bggrad]", _pm) end
        if unitChanged or frame._bf_htShowPct == nil then
            frame._bf_htShowPct = uf.showHealthPct ~= false
            frame._bf_htShowVal = uf.showHealthVal ~= false
            frame._bf_htPctFmt  = (uf.showHealthPctSymbol ~= false) and "%d%%" or "%d"
            -- v95 PERF: Show/Hide is config-driven (showHealthPct / showHealthVal
            -- are plain bools, never secret), so apply visibility HERE on
            -- unit/settings change instead of re-calling Show() on every health
            -- tick. The per-tick path below is SetText only. NOTE: a
            -- cache-and-skip guard on the text VALUE is impossible in 12.1 --
            -- UnitHealth / UnitHealthPercent are secret (player frame included)
            -- and cannot be compared -- so the value is re-set every tick; only
            -- the redundant per-tick Show() is removed here.
            if frame.HealthPctText then frame.HealthPctText:SetShown(frame._bf_htShowPct) end
            if frame.HealthValText then frame.HealthValText:SetShown(frame._bf_htShowVal) end
        end
        local showPct = frame._bf_htShowPct
        local showVal = frame._bf_htShowVal
        local pctFmt  = frame._bf_htPctFmt
        if frame.HealthPctText and showPct then
            frame.HealthPctText:SetText(format(pctFmt, UnitHealthPercent(unit, true, S)))
        end
        if frame.HealthValText and showVal then
            frame.HealthValText:SetText(AbbreviateNumbers(UnitHealth(unit)))
        end

        -- ── Dead state: secret-safe handling ─────────────────────────────
        -- UnitIsDeadOrGhost may return a secret boolean for non-player units.
        -- We cannot compare secret values, so on unit change we always update
        -- all alpha states. On health ticks (no unit change), we use
        -- SetAlphaFromBoolean unconditionally — it's a widget API that
        -- handles secrets natively, and the cost is minimal (5 calls).
        if _pm then _pm = BF:_ProfSeg("oUF:H.PU [text]", _pm) end
        local isDead = UnitIsDeadOrGhost(unit)
        if unitChanged then
            frame._bf_deadAlphaApplied = true
            -- Reset the change-guard BASELINE for the new unit. Without
            -- this, _bf_wasDead kept the previous unit's state: target a
            -- living unit (false), then a dead one (branch applies DEAD
            -- but baseline stays false), then they resurrect -> the tick
            -- compares false == false and skips -> DEAD stuck on screen
            -- (field report). A secret isDead cannot be stored (a later
            -- compare against it would assert); nil makes the first
            -- non-secret tick unconditionally re-apply.
            if issecretvalue and issecretvalue(isDead) then
                frame._bf_wasDead = nil
            else
                frame._bf_wasDead = isDead
            end
            if frame.DeadText then
                frame.DeadText:SetAlphaFromBoolean(isDead, 1, 0)
            end
            if frame.HealthPctText and showPct then
                frame.HealthPctText:SetAlphaFromBoolean(isDead, 0, 1)
            end
            if frame.HealthValText and showVal then
                frame.HealthValText:SetAlphaFromBoolean(isDead, 0, 1)
            end
            if frame.PowerPctText then
                frame.PowerPctText:SetAlphaFromBoolean(isDead, 0, 1)
            end
            if frame.PowerValText then
                frame.PowerValText:SetAlphaFromBoolean(isDead, 0, 1)
            end
        elseif not (issecretvalue and issecretvalue(isDead)) then
            -- Non-secret: use change guard (Grid2 Death pattern)
            if isDead ~= frame._bf_wasDead then
                frame._bf_wasDead = isDead
                if frame.DeadText then
                    frame.DeadText:SetAlphaFromBoolean(isDead, 1, 0)
                end
                if frame.HealthPctText and showPct then
                    frame.HealthPctText:SetAlphaFromBoolean(isDead, 0, 1)
                end
                if frame.HealthValText and showVal then
                    frame.HealthValText:SetAlphaFromBoolean(isDead, 0, 1)
                end
                if frame.PowerPctText then
                    frame.PowerPctText:SetAlphaFromBoolean(isDead, 0, 1)
                end
                if frame.PowerValText then
                    frame.PowerValText:SetAlphaFromBoolean(isDead, 0, 1)
                end
            end
        else
            -- Secret value: always apply (can't compare to detect change)
            if frame.DeadText then
                frame.DeadText:SetAlphaFromBoolean(isDead, 1, 0)
            end
            if frame.HealthPctText and showPct then
                frame.HealthPctText:SetAlphaFromBoolean(isDead, 0, 1)
            end
            if frame.HealthValText and showVal then
                frame.HealthValText:SetAlphaFromBoolean(isDead, 0, 1)
            end
            if frame.PowerPctText then
                frame.PowerPctText:SetAlphaFromBoolean(isDead, 0, 1)
            end
            if frame.PowerValText then
                frame.PowerValText:SetAlphaFromBoolean(isDead, 0, 1)
            end
        end

        -- ── Unit-change-only work ──────────────────────────────────────
        if _pm then _pm = BF:_ProfSeg("oUF:H.PU [dead]", _pm) end
        if unitChanged then
            ApplyNameColor(unit)

            -- Skull icon: show for boss-level (level == -1) units, hide level text.
            if frame._skullIcon and frame.Level then
                local level = UnitLevel(unit)
                if level == -1 then
                    frame._skullIcon:Show()
                    frame.Level:Hide()
                else
                    frame._skullIcon:Hide()
                    local uf2 = prof[ufKey] or prof.player or {}
                    -- Master Name-Bar-Text switch gates Level visibility.
                    local showLevel = (uf2.showNameBarText ~= false) and (uf2.showLevel ~= false)
                    if showLevel and uf2.hideLevelAtMax and ufKey == "player" then
                        local maxLevel = GetMaxLevelForPlayerExpansion and GetMaxLevelForPlayerExpansion() or MAX_PLAYER_LEVEL or 80
                        if level and level >= maxLevel then showLevel = false end
                    end
                    frame.Level:SetShown(showLevel)
                end
            end
        end
        if _pm then _pm = BF:_ProfSeg("oUF:H.PU [unitchg]", _pm) end
    end

    Power.PostUpdate = function(element, unit, cur, min, max)
        local frame = element:GetParent()
        local prof  = BF.ufDB.profile
        local ufKey = frame._bf_ufKey or frame.__unit
        local uf    = prof[ufKey] or prof.player or {}
        -- Use element.displayType (set by the Override) so that Balance Druid
        -- shows Mana color/text instead of Astral Power on the power bar.
        local pt    = element.displayType or UnitPowerType(unit)

        -- Color: when the Override forced a displayType (e.g. Mana=0 for
        -- Balance Druid), use that type's color from BF.PowerTypeColors.
        --
        -- v92 PERF: keyed on the power TYPE, which only changes on
        -- UNIT_DISPLAYPOWER / unit swap — not per UNIT_POWER_FREQUENT tick
        -- (10-20x/sec for the player). `pt` is a plain readable number
        -- (compared raw all over the power path). Invalidated by
        -- _RefreshAllOUFPowerColors when custom power colors change, and
        -- self-invalidating on any type/unit change through the key itself
        -- (same type ⇒ same color by construction).
        if frame._bf_powerCType ~= pt then
            frame._bf_powerCType = pt
            local r, g, b
            if element.displayType ~= nil then
                local token = POWER_TOKEN_BY_TYPE[element.displayType]
                local c = token and BF.PowerTypeColors and BF.PowerTypeColors[token]
                if c then
                    r, g, b = c.r, c.g, c.b
                end
            end
            if not r then
                r, g, b = BF:_GetOUFPowerColor(unit, frame.__unit)
            end
            element:SetStatusBarColor(r, g, b)
        end

        -- When the power bar is detached AND the bar is shown, the
        -- detached pb renders its own text so suppress the attached
        -- text widgets to avoid duplicates. When showPowerBar is off,
        -- the detached pb's text is alpha-faded too, so the attached
        -- text widgets show as the only visible text.
        -- v94 PERF: power text config + the detach probe are settings/state,
        -- not per-tick data, but this runs at UNIT_POWER_FREQUENT rate
        -- (10-20x/sec for the player). Stamp on _bf_ufGen (bumped by every
        -- UpdateAllElements; Power cannot use the _bf_unitChanged bool that
        -- Health.PostUpdate clears) instead of four profile reads + a
        -- GetUFDetachState call + a string rebuild every tick.
        if frame._bf_pwrCfgGen ~= frame._bf_ufGen or frame._bf_pwrTextOn == nil then
            frame._bf_pwrCfgGen  = frame._bf_ufGen
            frame._bf_pwrTextOn  = uf.showPowerText ~= false
            frame._bf_pwrShowPct = uf.showPowerPct ~= false
            frame._bf_pwrShowVal = uf.showPowerVal ~= false
            frame._bf_pwrPctFmt  = (uf.showPowerPctSymbol ~= false) and "%d%%" or "%d"
            frame._bf_pwrDetached = (frame.__unit == "player"
                and BF.GetUFDetachState and BF:GetUFDetachState("playerPowerBar")
                and uf.showPowerBar ~= false) or false
        end
        local powerDetached = frame._bf_pwrDetached
        local textOn  = frame._bf_pwrTextOn
        local pPctFmt = frame._bf_pwrPctFmt
        if frame.PowerPctText then
            if textOn and frame._bf_pwrShowPct and not powerDetached then
                frame.PowerPctText:SetText(format(pPctFmt, UnitPowerPercent(unit, pt, false, S)))
                frame.PowerPctText:Show()
            else
                frame.PowerPctText:Hide()
            end
        end
        if frame.PowerValText then
            if textOn and frame._bf_pwrShowVal and not powerDetached then
                frame.PowerValText:SetText(AbbreviateNumbers(UnitPower(unit, pt)))
                frame.PowerValText:Show()
            else
                frame.PowerValText:Hide()
            end
        end

        -- PERF (double-fire fix): the cross-calls to BF:UpdateOUFPowerBar()
        -- and BF:UpdateOUFAltPowerBar() that lived here ran BOTH bars a
        -- second time on every player power event — each file already owns
        -- a player-filtered UNIT_POWER_FREQUENT / UNIT_DISPLAYPOWER /
        -- UNIT_MAXPOWER registration (oUF_PowerBar.lua BuildOUFPowerBar;
        -- oUF_AltPowerBar.lua BuildOUFAltPowerBar), so this PostUpdate added
        -- nothing but a duplicate full pass 10-20x/sec. Removed.
    end

    -- Tooltip on mouseover — same logic as the raid/party frames.
    -- HookScript so aura tooltip hooks added later don't conflict.
    self:HookScript("OnEnter", function(btn)
        if btn.SF_AuraTooltipActive then return end
        local dbp = BF.ufDB and BF.ufDB.profile
        if not dbp or not dbp.showUnitTooltip then return end
        if InCombatLockdown() and not dbp.showUnitTooltipInCombat then return end
        local u = btn.__unit
        if u and UnitExists(u) then
            GameTooltip_SetDefaultAnchor(GameTooltip, UIParent)
            GameTooltip:SetUnit(u)
            GameTooltip:Show()
        end
    end)
    self:HookScript("OnLeave", function(btn)
        if not btn.SF_AuraTooltipActive then
            GameTooltip:Hide()
        end
    end)

    -- ClassPower: let oUF manage class resource detection and events
    -- for the player frame. The resource bar renders the data.
    if unit == "player" then
        BuildClassPowerWidget(self)
    end

    -- Set up absorb/overshield/heal prediction overlays for
    -- player, target, focus, and boss frames.
    if unit ~= "targettarget" and unit ~= "focustarget" and unit ~= "pet" then
        if BF.SetupOUFAbsorbs then
            BF:SetupOUFAbsorbs(self)
        end
    end

    -- Pixel-snap sweep. Everything Buzzard Frames creates itself comes
    -- out of the funnel already unsnapped (BF.Texture / BF.MaskTexture /
    -- BF.StatusBar, PixelPerfect.lua section 7), but the vendored oUF
    -- library builds a few element regions internally and cannot be
    -- edited -- Libs/oUF stays a pristine upstream copy. One sweep of
    -- the finished frame catches those. The aura containers under this
    -- frame are engine-owned and skipped (_bf_unsnapStop, BuildContainer
    -- above): their buttons are forbidden objects during an active
    -- keystone run, and touching one here threw out of the style function
    -- and aborted the whole PLAYER_ENTERING_WORLD build.
    BF.UnsnapTree(self)
end

-- Register with oUF
oUF:RegisterStyle("BuzzardBluzzard", BluzzardStyle)

-- Minimal style for hosting ClassPower when the player frame is disabled.
oUF:RegisterStyle("BuzzardClassPowerHost", function(self, unit)
    self:SetSize(1, 1)
    self:EnableMouse(false)
    BuildClassPowerWidget(self)
    BF.UnsnapTree(self)
end)

-- ============================================================
-- _GetOUFPowerColor
-- Returns r, g, b for the power bar of `unit`.
-- When usePowerTypeColor is true, looks up the Blizzard-matched
-- muted color for the unit's current power type.
-- Falls back to the profile's custom powerColor otherwise.
-- ============================================================
function BF:_GetOUFPowerColor(unit, unitKey)
    -- Always use the shared BF.PowerTypeColors table.
    -- This table reflects default power-type colors, overlaid with
    -- custom overrides when p.useCustomPowerColors is enabled.
    -- The same table is shared with the Raid/Party Frames.
    local r, g, b = self:GetPowerColor(unit)
    return r, g, b
end

-- ============================================================
-- _RefreshAllOUFPowerColors
-- Refreshes power bar colors on ALL oUF unit frames.
-- Called when custom power colors change so every frame updates.
-- ============================================================
function BF:_RefreshAllOUFPowerColors()
    local frames = {
        self.oufPlayer,
        self.oufTarget,
        self.oufFocus,
        self.oufPet,
        self.oufTargetOfTarget,
        self.oufFocusTarget,
    }
    if self.oufBoss then
        for i = 1, 5 do
            if self.oufBoss[i] then frames[#frames + 1] = self.oufBoss[i] end
        end
    end
    for _, f in ipairs(frames) do
        if f and f.Power and f.__unit then
            -- v92: drop the PostUpdate color cache so the ForceUpdate below
            -- recomputes from the edited PowerTypeColors table.
            f._bf_powerCType = nil
            -- ForceUpdate triggers the full Power element cycle (Override → PostUpdate)
            -- which re-reads from the updated PowerTypeColors table.
            if f.Power.ForceUpdate then
                f.Power:ForceUpdate()
            else
                local r, g, b = self:_GetOUFPowerColor(f.__unit, f.__unit)
                f.Power:SetStatusBarColor(r, g, b)
            end
        end
    end
    if self.UpdateOUFPowerBar then self:UpdateOUFPowerBar() end
end

-- ============================================================
-- _RefreshAllOUFClassColors
-- Refreshes health bar + name text colors on ALL oUF unit frames.
-- Called when custom class colors change so every frame updates.
-- Mirrors _RefreshAllOUFPowerColors: iterate every known oUF frame
-- and ForceUpdate the Health element, which triggers the full
-- Health PostUpdate cycle -> _GetOUFHealthColor read -> new
-- BF.classColors value picked up. The Health PostUpdate also calls
-- ApplyNameColor internally when the unit changes, but custom-color
-- changes don't set _bf_unitChanged, so we explicitly refresh name
-- colors too via _ApplyOUFNameBarTextPositions (which re-reads the
-- class color).
-- ============================================================
function BF:_RefreshAllOUFClassColors()
    local frames = {
        self.oufPlayer,
        self.oufTarget,
        self.oufFocus,
        self.oufPet,
        self.oufTargetOfTarget,
        self.oufFocusTarget,
    }
    if self.oufBoss then
        for i = 1, 5 do
            if self.oufBoss[i] then frames[#frames + 1] = self.oufBoss[i] end
        end
    end
    for _, f in ipairs(frames) do
        if f and f.__unit then
            -- Force the Health element to re-read colors. We set
            -- _bf_unitChanged so Health.PostUpdate re-runs the color
            -- path (it's gated on this flag for perf -- without this
            -- flag the PostUpdate would only refresh text, not color).
            if f.Health and f.Health.ForceUpdate then
                f._bf_unitChanged = true
                f.Health:ForceUpdate()
            end
            -- Name color path: runs outside Health.PostUpdate (from
            -- layout) so we refresh it explicitly via the name-bar
            -- text positioner, which re-reads _GetOUFNameColor.
            local unitKey = f._bf_ufKey or f.__unit
            if self._ApplyOUFNameBarTextPositions and unitKey then
                self:_ApplyOUFNameBarTextPositions(f, unitKey)
            end
        end
    end
end

-- GetClassHealthColor lives in BFStatus.lua (single definition).
-- It takes (r, g, b, hasCustomTexture) and skips the darkening
-- when a custom bar texture is active.

-- ============================================================
-- _ClassifyNPC
-- Returns a classification key for an NPC unit, used to pick
-- per-type health bar colors. Priority order follows the common
-- nameplate convention: boss > lieutenant > caster > trivial > regular.
-- Returns nil for players.
-- ============================================================
function BF:_ClassifyNPC(unit)
    if UnitIsPlayer(unit) or (UnitInPartyIsAI and UnitInPartyIsAI(unit)) then
        return nil
    end

    -- 12.1: several Unit APIs return SECRET values for combat-relevant
    -- units (comparing one throws). Every read below is secret-guarded;
    -- a secret value simply skips that heuristic and falls through to
    -- the next (worst case: "regular").
    local secret = issecretvalue or function() return false end

    -- Friendly and Neutral take highest priority — classification colors
    -- only apply to enemies. However, if a neutral NPC is in combat with
    -- the player, treat it as an enemy so it gets a classification color.
    local reaction = UnitReaction(unit, "player")
    if secret(reaction) then reaction = nil end
    if reaction and reaction >= 5 then return "friendly" end
    if reaction and reaction == 4 and not UnitAffectingCombat(unit) then return "neutral" end

    local classification = UnitClassification(unit) or "normal"
    if secret(classification) then classification = "normal" end

    -- Boss: worldboss, level -1, or level == playerLevel + 2
    if classification == "worldboss" then return "boss" end
    local level = UnitEffectiveLevel and UnitEffectiveLevel(unit) or UnitLevel(unit)
    if secret(level) then level = nil end
    local playerLevel = UnitLevel("player")
    if secret(playerLevel) then playerLevel = nil end
    if level == -1 then return "boss" end
    if level and playerLevel and level == playerLevel + 2 then return "boss" end

    -- Lieutenant: level == playerLevel + 1 or UnitIsLieutenant
    if level and playerLevel and level == playerLevel + 1 then return "lieutenant" end
    if UnitIsLieutenant and UnitIsLieutenant(unit) then return "lieutenant" end

    -- Caster / trivial / regular: the SAME decision Buzzard Plates makes
    -- (owner report 2026-09-11: an elite caster was blue on the nameplate
    -- and red here, a normal mob gray there and red here; lieutenants
    -- matched). Two differences were behind it:
    --   * "has mana" was read as UnitClassBase == PALADIN/MAGE or
    --     UnitPowerMax(unit, Mana) > 0. On 12.1 both reads come back SECRET
    --     for hostile units, the guards dropped them, and every caster fell
    --     through to "regular". UnitHasPowerType(unit, Mana) is a plain
    --     boolean and is what the nameplates use.
    --   * only the engine's "trivial"/"minus" labels counted as trivial; a
    --     plain "normal" (non-elite) mob was "regular". The nameplates put
    --     normal/minus/trivial together as trivial (caster if it has mana),
    --     and elite/rareelite non-boss non-lieutenant as caster-or-regular.
    local hasMana
    if UnitHasPowerType then
        hasMana = UnitHasPowerType(unit, Enum.PowerType.Mana)
    else
        hasMana = (UnitPowerType(unit) == Enum.PowerType.Mana)
    end
    if secret(hasMana) then hasMana = false end
    if classification == "elite" or classification == "rareelite" or classification == "rare" then
        if hasMana then return "caster" end
        return "regular"
    end
    -- normal / minus / trivial (and anything unrecognized)
    if hasMana then return "caster" end
    return "trivial"
end

-- ============================================================
-- _GetOUFHealthColor
-- Returns r, g, b[, isGradient[, gradientAlpha]] for the health bar of `unit`.
-- Color mode is determined by globalPlayerHealthColorMode (for player
-- units) and globalNpcHealthColorMode (for NPC units).
-- The optional 4th return value (true) signals that the color depends on
-- the unit's current health % and must be recalculated every health tick.
-- The optional 5th return value, when isGradient is true, is the
-- interpolated alpha read from the gradient curve at the unit's health %.
-- Callers use it as the bar's render alpha in gradient mode (replacing
-- the oufHealthBarOpacity slider for that mode only).
-- ============================================================
function BF:_GetOUFHealthColor(unit, useClassColor, unitKey)
    -- Pet: if "Match Player Color" is on, resolve as if we were coloring the player bar.
    if unitKey == "pet" then
        local pf = self.ufDB.profile.pet or {}
        if pf.petMatchPlayerColor ~= false then
            return BF:_GetOUFHealthColor("player", nil, "player")
        end
        -- Pet with match off: use per-frame healthColor
        local c = pf.healthColor
        if c then return c.r, c.g, c.b end
        return 0.24, 0.78, 0.24
    end

    local p = self.ufDB.profile
    local unitIsPlayer = UnitIsPlayer(unit) or (UnitInPartyIsAI and UnitInPartyIsAI(unit))

    if unitIsPlayer then
        -- ── Player unit color (class / gradient / static) ──────────
        -- If the player frame has separate config and this IS the player frame,
        -- use the per-frame mode/color instead of the global player mode.
        local mode, staticColor
        if unitKey == "player" and p.separatePlayerFrameColor then
            mode = p.playerFrameHealthColorMode or "class"
            staticColor = p.playerFrameHealthColor
        else
            mode = p.globalPlayerHealthColorMode or "class"
            staticColor = p.globalHealthColor
        end
        if mode == "class" then
            local _, className = UnitClass(unit)
            -- 12.1: identity-secret unit (e.g. hostile player in combat) —
            -- a secret class name is truthy but cannot index a table
            -- ("attempted to index a table that cannot be indexed with
            -- secret keys"). Fall through to the static color instead.
            -- Same guard SetClassIcon already uses.
            if not canaccessvalue(className) then className = nil end
            if className then
                local c = (self.classColors and self.classColors[className])
                       or (RAID_CLASS_COLORS and RAID_CLASS_COLORS[className])
                if c then
                    return self:GetClassHealthColor(c.r, c.g, c.b, p.oufUseCustomHealthBarTexture)
                end
            end
        elseif mode == "gradient" then
            if self.healthGradientCurve then
                local cr, cg, cb, ca = UnitHealthPercent(unit, true, self.healthGradientCurve):GetRGBA()
                return cr, cg, cb, true, ca
            end
        end
        -- "static" mode or fallback from class/gradient with no data
        local c = staticColor
        if c then return c.r, c.g, c.b end
        return 0.24, 0.78, 0.24
    else
        -- ── NPC unit color (classification / hostility / gradient / static) ──
        local mode = p.globalNpcHealthColorMode or "classification"
        if mode == "classification" then
            local npcType = self:_ClassifyNPC(unit)
            local colorKey = npcType and ("globalNpc" .. npcType:sub(1,1):upper() .. npcType:sub(2) .. "Color")
            local c = colorKey and p[colorKey]
            if c then return c.r, c.g, c.b end
        elseif mode == "hostility" then
            local reaction = UnitReaction(unit, "player")
            -- 12.1: secret-guard before any comparison (see _ClassifyNPC).
            if issecretvalue and issecretvalue(reaction) then reaction = nil end
            if reaction then
                if reaction >= 5 then
                    local c = p.globalNpcFriendlyColor
                    if c then return c.r, c.g, c.b end
                    return 0.0, 0.65, 0.0
                elseif reaction >= 4 then
                    local c = p.globalNpcNeutralColor
                    if c then return c.r, c.g, c.b end
                    return 0.9, 0.7, 0.0
                else
                    local c = p.globalNpcRegularColor
                    if c then return c.r, c.g, c.b end
                    return 0.8, 0.1, 0.1
                end
            end
        elseif mode == "gradient" then
            if self.healthGradientCurve then
                local cr, cg, cb, ca = UnitHealthPercent(unit, true, self.healthGradientCurve):GetRGBA()
                return cr, cg, cb, true, ca
            end
        end
        -- "static" mode or fallback from classification/hostility/gradient with no data
        local c = p.globalNpcHealthColor
        if c then return c.r, c.g, c.b end
        return 0.24, 0.78, 0.24
    end
end

-- ============================================================
-- _GetOUFHealthBarFillAlpha
-- Single source of truth for the health-bar fill alpha. Encapsulates
-- the precedence rules:
--   1. Gradient mode: use the per-stop alpha read from the gradient
--      curve (passed as gradAlpha when isGradient is true).
--   2. Player frame with separatePlayerFrameColor enabled: use
--      playerFrameHealthBarOpacity. The pet frame, when
--      petMatchPlayerColor is on, follows the player here too.
--   3. Default: the global oufHealthBarOpacity slider.
-- ============================================================
function BF:_GetOUFHealthBarFillAlpha(unitKey, isGradient, gradAlpha)
    if isGradient and gradAlpha then return gradAlpha end
    local p = self.ufDB.profile
    -- Resolve pet-match-player so the pet shares the player's opacity
    -- when matching the player's color.
    local effectiveUnit = unitKey
    if unitKey == "pet" then
        local pf = p.pet or {}
        if pf.petMatchPlayerColor ~= false then
            effectiveUnit = "player"
        end
    end
    if effectiveUnit == "player" and p.separatePlayerFrameColor then
        return p.playerFrameHealthBarOpacity or 1
    end
    return p.oufHealthBarOpacity or 1
end

-- ============================================================
-- _GetOUFNameColor
-- Returns r, g, b for the name text of `unit`.
-- Pet frame uses per-unit profile keys (or delegates to player).
-- Player frame uses global mode unless separatePlayerFrameNameColor
-- is on.  All other frames use globalPlayerNameColorMode (for
-- player units) and globalNpcNameColorMode (for NPC units).
-- ============================================================
function BF:_GetOUFNameColor(unit, unitKey)
    local p = self.ufDB.profile
    -- Pet: if "Match Player Color" is on for the name, resolve as player.
    if unitKey == "pet" then
        local pf = p.pet or {}
        if pf.petMatchPlayerNameColor ~= false then
            return BF:_GetOUFNameColor("player", "player")
        end
        -- Pet with match off: per-frame keys
        if pf.useClassColorName and (UnitIsPlayer(unit) or (UnitInPartyIsAI and UnitInPartyIsAI(unit))) then
            local _, className = UnitClass(unit)
            -- 12.1: secret class name cannot index a table (see _GetOUFHealthColor).
            if not canaccessvalue(className) then className = nil end
            local c = className and ((self.classColors and self.classColors[className])
                      or (RAID_CLASS_COLORS and RAID_CLASS_COLORS[className]))
            if c then return c.r, c.g, c.b end
        end
        if not UnitIsPlayer(unit) and not UnitPlayerControlled(unit) then
            if pf.useHostilityColorName then
                local reaction = UnitReaction(unit, "player")
                if reaction then
                    if reaction >= 5 then return 0.0, 0.65, 0.0
                    elseif reaction >= 4 then return 0.9, 0.7, 0.0
                    else return 0.8, 0.1, 0.1 end
                end
            end
            local nc = pf.npcNameColor
            if nc then return nc.r, nc.g, nc.b end
        end
        local nc = pf.nameColor or { r=1, g=1, b=1 }
        return nc.r, nc.g, nc.b
    end

    local unitIsPlayer = UnitIsPlayer(unit) or (UnitInPartyIsAI and UnitInPartyIsAI(unit))

    if unitIsPlayer then
        -- Player frame with separate config uses its own mode/color
        local mode, staticColor
        if unitKey == "player" and p.separatePlayerFrameNameColor then
            mode = p.playerFrameNameColorMode or "class"
            staticColor = p.playerFrameNameColor
        else
            mode = p.globalPlayerNameColorMode or "class"
            staticColor = p.globalNameColor
        end
        if mode == "class" then
            local _, className = UnitClass(unit)
            -- 12.1: secret class name cannot index a table (see _GetOUFHealthColor).
            if not canaccessvalue(className) then className = nil end
            local c = className and ((self.classColors and self.classColors[className])
                      or (RAID_CLASS_COLORS and RAID_CLASS_COLORS[className]))
            if c then return c.r, c.g, c.b end
        end
        -- "static" mode or class fallback
        local nc = staticColor or { r=1, g=1, b=1 }
        return nc.r, nc.g, nc.b
    else
        -- NPC unit
        local mode = p.globalNpcNameColorMode or "classification"
        if mode == "classification" then
            local npcType = self:_ClassifyNPC(unit)
            local colorKey = npcType and ("globalNpc" .. npcType:sub(1,1):upper() .. npcType:sub(2) .. "Color")
            local c = colorKey and p[colorKey]
            if c then return c.r, c.g, c.b end
        elseif mode == "hostility" then
            local reaction = UnitReaction(unit, "player")
            -- 12.1: secret-guard before any comparison (see _ClassifyNPC).
            if issecretvalue and issecretvalue(reaction) then reaction = nil end
            if reaction then
                if reaction >= 5 then
                    local c = p.globalNpcFriendlyColor
                    if c then return c.r, c.g, c.b end
                    return 0.0, 0.65, 0.0
                elseif reaction >= 4 then
                    local c = p.globalNpcNeutralColor
                    if c then return c.r, c.g, c.b end
                    return 0.9, 0.7, 0.0
                else
                    local c = p.globalNpcRegularColor
                    if c then return c.r, c.g, c.b end
                    return 0.8, 0.1, 0.1
                end
            end
        end
        -- "static" mode or fallback
        local nc = p.globalNpcNameColor or { r=1, g=1, b=1 }
        return nc.r, nc.g, nc.b
    end
end

-- ============================================================
-- _ApplyOUFBarTextPositions
-- Re-anchors the four bar text FontStrings from profile position keys.
-- Called from both ApplyOUFPlayerLayout and ApplyOUFTargetLayout.
-- prefix is "blizzPlayer" or "blizzTarget".
-- The anchor parent for each text is the corresponding bar StatusBar.
-- ============================================================
local _anchorJustify = {
    LEFT        = "LEFT",
    CENTER      = "CENTER",
    RIGHT       = "RIGHT",
    TOPLEFT     = "LEFT",
    TOP         = "CENTER",
    TOPRIGHT    = "RIGHT",
    BOTTOMLEFT  = "LEFT",
    BOTTOM      = "CENTER",
    BOTTOMRIGHT = "RIGHT",
}
-- unitKey is "player" or "target" (the profile sub-table key)
function BF:_ApplyOUFBarTextPositions(frame, unitKey)
    if not frame then return end
    local uf     = BF.ufDB.profile[unitKey] or BF.ufDB.profile.player or {}
    -- Anchor health text to the health CONTAINER (frame-relative, never
    -- shrinks) rather than frame.Health itself. When reduced-max-health
    -- is active, oUF_Absorbs reanchors the clipFrame to stop at the
    -- reduced-max bar's left edge, which shrinks frame.Health visually.
    -- Text anchored directly to frame.Health would follow that shrink
    -- and move toward the center of the frame on every health tick. The
    -- container is anchored to the unit frame's edges with fixed insets
    -- (see oUF_Shared.lua:237-240) and does NOT move when reduced-max
    -- activates, so text stays in its profile-defined position.
    -- Pet/ToT/FT/boss have no container — fall back to frame.Health.
    local health = frame._oufHealthContainer or frame.Health
    local power  = frame.Power

    -- Icon-side text inset: ensures health and power text align vertically
    -- even when bars have different circular-icon insets.
    local textInL = frame._iconTextInsetLeft  or 0
    local textInR = frame._iconTextInsetRight or 0

    -- Anchor a bar text FontString. Compensation for slider=0 is chosen
    -- by the CHOSEN anchor `pt`, not by the role (Pct vs Val) of the
    -- FontString -- so swapping the user's Pct and Val position points
    -- keeps each text at the correct default offset.
    --
    -- leftComp  : x-offset to add when the chosen pt is LEFT-ish
    --             (LEFT / TOPLEFT / BOTTOMLEFT).
    -- rightComp : x-offset to add when the chosen pt is RIGHT-ish
    --             (RIGHT / TOPRIGHT / BOTTOMRIGHT).
    -- centerComp: x-offset to add when the chosen pt is center-ish
    --             (CENTER / TOP / BOTTOM). Typically 0.
    local function anchor(fs, bar, pos, defaultPoint, leftComp, rightComp, centerComp)
        if not fs or not bar then return end
        local pt = (pos and pos.point) or defaultPoint
        local ox = (pos and pos.x)     or 0
        local oy = (pos and pos.y)     or 0
        local comp
        if pt:find("LEFT") then
            comp = leftComp
        elseif pt:find("RIGHT") then
            comp = rightComp
        else
            comp = centerComp
        end
        ox = ox + (comp or 0)
        fs:ClearAllPoints()
        fs:SetPoint(pt, bar, pt, ox, oy)
        fs:SetJustifyH(_anchorJustify[pt] or "LEFT")
    end

    if unitKey == "player" or unitKey == "pet" then
        -- Portrait on the LEFT: icon chord pushes bars right on the LEFT
        -- edge. LEFT-anchored text needs to clear the icon chord; the
        -- (maxIn - thisBarInset) term keeps all bars' LEFT-anchored text
        -- visually aligned at slider=0 regardless of which bar has the
        -- deepest chord. RIGHT-anchored text just gets a 3px inset off
        -- the bar's right edge.
        local hPct = (unitKey == "pet") and nil or uf.healthPctPos
        local hVal = (unitKey == "pet") and nil or uf.healthValPos
        local pPct = (unitKey == "pet") and nil or uf.powerPctPos
        local pVal = (unitKey == "pet") and nil or uf.powerValPos
        local hInset = frame._iconBarInsetLeft_health or 0
        local pInset = frame._iconBarInsetLeft_power  or 0
        local maxIn  = math.max(hInset, pInset)
        local hLeftComp  = (maxIn - hInset) + 3
        local pLeftComp  = (maxIn - pInset) + 3
        local rightComp  = -3
        local centerComp = 0
        anchor(frame.HealthPctText, health, hPct, "RIGHT", hLeftComp, rightComp, centerComp)
        anchor(frame.HealthValText, health, hVal, "LEFT",  hLeftComp, rightComp, centerComp)
        anchor(frame.PowerPctText,  power,  pPct, "RIGHT", pLeftComp, rightComp, centerComp)
        anchor(frame.PowerValText,  power,  pVal, "LEFT",  pLeftComp, rightComp, centerComp)
        -- Keep legacy cached fields so any caller that reads them for
        -- slider display continues to see the LEFT-side compensation.
        frame._valTextCompLeft_health = hLeftComp
        frame._valTextCompLeft_power  = pLeftComp
    else
        -- Portrait on the RIGHT: icon chord pushes bars left on the RIGHT
        -- edge. RIGHT-anchored text pulls in by (maxIn - thisBarInset) + 3
        -- to clear the chord; LEFT-anchored text gets a 3px inset off the
        -- bar's left edge.
        local hInset = frame._iconBarInsetRight_health or 0
        local pInset = frame._iconBarInsetRight_power  or 0
        local maxIn  = math.max(hInset, pInset)
        local hRightComp = -((maxIn - hInset) + 3)
        local pRightComp = -((maxIn - pInset) + 3)
        local leftComp   = 3
        local centerComp = 0
        anchor(frame.HealthPctText, health, uf.healthPctPos, "LEFT",  leftComp, hRightComp, centerComp)
        anchor(frame.HealthValText, health, uf.healthValPos, "RIGHT", leftComp, hRightComp, centerComp)
        anchor(frame.PowerPctText,  power,  uf.powerPctPos,  "LEFT",  leftComp, pRightComp, centerComp)
        anchor(frame.PowerValText,  power,  uf.powerValPos,  "RIGHT", leftComp, pRightComp, centerComp)
        frame._valTextCompRight_health = hRightComp
        frame._valTextCompRight_power  = pRightComp
    end

    -- Dead text — RIGHT-anchored for player, LEFT-anchored for others
    if frame.DeadText and health then
        frame.DeadText:ClearAllPoints()
        if unitKey == "player" or unitKey == "pet" then
            frame.DeadText:SetPoint("RIGHT", health, "RIGHT", -3, 0)
            frame.DeadText:SetJustifyH("RIGHT")
        else
            frame.DeadText:SetPoint("LEFT", health, "LEFT", 3, 0)
            frame.DeadText:SetJustifyH("LEFT")
        end
        frame.DeadText:SetFont(BF:GetOUFFont("oufHealthPctFont", GameFontNormalSmall:GetFont()), uf.healthFontSize or 10, "")
    end
end

-- ============================================================
-- _ApplyOUFNameBarTextPositions
-- Re-anchors Name and Level FontStrings from profile offset keys.
-- Called from ApplyOUFPlayerLayout and ApplyOUFTargetLayout.
-- ============================================================
function BF:_ApplyOUFNameBarTextPositions(frame, unitKey)
    if not frame then return end
    local uf      = BF.ufDB.profile[unitKey] or BF.ufDB.profile.player or {}
    local isPlayer = (unitKey == "player" or unitKey == "pet")

    local health = frame.Health
    if not health then return end

    -- Master Name-Bar-Text switch gates both Name and Level visibility.
    local nameTextMaster = uf.showNameBarText ~= false

    -- Name text — anchored to the TOP of the health bar, offset upward so it
    -- sits in the name strip above. Moving the name bar height slider moves
    -- the health bar, which carries this text with it automatically.
    if frame.Name then
        local show = nameTextMaster and (uf.showName ~= false)
        frame.Name:SetShown(show)
        if show then
            local hInsetL = frame._iconBarInsetLeft_health or 0
            local hInsetR = frame._iconBarInsetRight_health or 0
            local maxInL  = frame._iconTextInsetLeft or 0
            local maxInR  = frame._iconTextInsetRight or 0
            local nameDefaultX
            if isPlayer then
                nameDefaultX = (maxInL - hInsetL) + 3
            else
                nameDefaultX = -((maxInR - hInsetR) + 3)
            end
            local ox = (unitKey == "pet") and 3 or (uf.nameOffsetX or nameDefaultX)
            local oy = uf.nameOffsetY or 4   -- positive = above the health bar top edge
            local sz = uf.nameFontSize or 11
            frame.Name:SetFont(BF:GetOUFFont("oufNameFont", BF.font), sz, "")
            -- Name color: use shared _GetOUFNameColor helper
            local unit = frame.__unit
            if unit then
                local r, g, b = BF:_GetOUFNameColor(unit, unitKey)
                frame.Name:SetTextColor(r, g, b, 1)
            end
            frame.Name:ClearAllPoints()
            if isPlayer then
                frame.Name:SetJustifyH("LEFT")
                frame.Name:SetPoint("BOTTOMLEFT",  health, "TOPLEFT",  ox, oy)
                local levelInset = (unitKey == "pet") and 38 or (uf.levelOffsetX and math.abs(uf.levelOffsetX) + 14 or 38)
                frame.Name:SetPoint("BOTTOMRIGHT", health, "TOPRIGHT", -levelInset, oy)
            else
                frame.Name:SetJustifyH("RIGHT")
                frame.Name:SetPoint("BOTTOMLEFT",  health, "TOPLEFT",  (uf.levelOffsetX and math.abs(uf.levelOffsetX) + 14 or 21), oy)
                frame.Name:SetPoint("BOTTOMRIGHT", health, "TOPRIGHT", ox, oy)
            end
        end
    end

    -- Level text — same anchor strategy as Name.
    if frame.Level then
        local show = nameTextMaster and (uf.showLevel ~= false)
        -- Hide at max level (player frame only)
        if show and uf.hideLevelAtMax and unitKey == "player" then
            local maxLevel = GetMaxLevelForPlayerExpansion and GetMaxLevelForPlayerExpansion() or MAX_PLAYER_LEVEL or 80
            local playerLevel = UnitLevel("player")
            if playerLevel and playerLevel >= maxLevel then
                show = false
            end
        end
        frame.Level:SetShown(show)
        if show then
            local ox = (unitKey == "pet") and -4 or (uf.levelOffsetX or (isPlayer and -4 or 4))
            local oy = uf.levelOffsetY or 4
            local sz = uf.levelFontSize or 10
            frame.Level:SetFont(BF:GetOUFFont("oufLevelFont", BF.font), sz, "")
            -- Level color
            local lc = uf.levelColor or { r=1, g=0.82, b=0 }
            frame.Level:SetTextColor(lc.r, lc.g, lc.b, 1)
            frame.Level:ClearAllPoints()
            if isPlayer then
                frame.Level:SetJustifyH("RIGHT")
                frame.Level:SetPoint("BOTTOMRIGHT", health, "TOPRIGHT", ox, oy)
            else
                frame.Level:SetJustifyH("CENTER")
                frame.Level:SetPoint("BOTTOMLEFT", health, "TOPLEFT", ox, oy)
            end
        end
    end

    -- Skull icon — anchored at the same position as the level text
    if frame._skullIcon and frame.Level then
        frame._skullIcon:ClearAllPoints()
        frame._skullIcon:SetPoint("CENTER", frame.Level, "CENTER", 0, 0)
    end

    -- Raid Group text (player frame only)
    if frame.RaidGroupText and unitKey == "player" then
        BF:_UpdateRaidGroupText(frame)
    end
end

-- ============================================================
-- _UpdateRaidGroupText
-- Shows "[Group X]" (or "[X]" if numberOnly) to the left of the
-- level text on the player frame, only when in a raid group.
-- ============================================================
function BF:_UpdateRaidGroupText(frame)
    local rgt = frame.RaidGroupText
    if not rgt then return end

    local p  = self.ufDB.profile
    local pf = p.player or {}

    -- Master Name-Bar-Text switch gates raid group text too.
    if pf.showNameBarText == false or not pf.showRaidGroup or not IsInRaid() then
        rgt:Hide()
        return
    end

    -- Find the player's raid subgroup
    local groupNum
    for i = 1, GetNumGroupMembers() do
        local name, _, subgroup = GetRaidRosterInfo(i)
        if name and UnitIsUnit("raid" .. i, "player") then
            groupNum = subgroup
            break
        end
    end
    if not groupNum then
        rgt:Hide()
        return
    end

    -- Text
    if pf.raidGroupNumberOnly then
        rgt:SetText("[" .. groupNum .. "]")
    else
        rgt:SetText("[Group " .. groupNum .. "]")
    end

    -- Font
    local sz = pf.raidGroupFontSize or 11
    rgt:SetFont(BF:GetOUFFont("oufNameFont", BF.font), sz, "")

    -- Color
    local c = pf.raidGroupColor or { r = 1, g = 1, b = 1 }
    rgt:SetTextColor(c.r, c.g, c.b, 1)

    local ox = pf.raidGroupOffsetX or 0
    local oy = pf.raidGroupOffsetY or 0

    rgt:ClearAllPoints()
    rgt:SetJustifyH("RIGHT")
    -- Anchor to the left of the level text so position is stable
    -- regardless of level text width or render timing.
    if frame.Level and frame.Level:IsShown() then
        rgt:SetPoint("RIGHT", frame.Level, "LEFT", -4 + ox, oy)
    elseif frame.Health then
        rgt:SetPoint("BOTTOMRIGHT", frame.Health, "TOPRIGHT", ox, oy)
    else
        rgt:Hide()
        return
    end
    rgt:Show()
end


-- ============================================================
-- _AnchorOUFIconFrame
-- Positions the icon frame relative to the bar frame based on
-- p.iconLocation: "outer" (default), "center", or "inner".
-- side is "LEFT" (player) or "RIGHT" (target).
-- iconFrameSz is the full icon+ring size in pixels.
-- ============================================================
function BF:_AnchorOUFIconFrame(iconFrame, barFrame, side, iconFrameSz)
    local p   = BF.ufDB.profile
    local loc = p.iconLocation or "outer"
    local ox  =  (p.iconOffsetX or 0)
    local oy  =  (p.iconOffsetY or 0)
    local isCircular = (p.iconShape or "circular") == "circular"
    iconFrame:ClearAllPoints()
    -- Track how many pixels the icon overlaps the bar area on each side.
    -- Used by bar positioning to inset bars so the icon doesn't cover them.
    -- For "center" no overlap tracking is needed (icon sits over the bars).
    -- For "inner" the overlap is on the opposite side from "outer".
    barFrame._iconOverlapLeft  = 0
    barFrame._iconOverlapRight = 0

    if not isCircular then
        -- Square icon: anchor the icon edge flush with the bar edge so it
        -- lines up perfectly at any size with no overlap or gap.
        if side == "LEFT" then
            if loc == "inner" then
                -- Icon sits inside, extending right; LEFT edge at bar's RIGHT edge
                iconFrame:SetPoint("LEFT", barFrame, "RIGHT", ox, oy)
            elseif loc == "center" then
                iconFrame:SetPoint("CENTER", barFrame, "CENTER", ox, oy)
            else -- "outer"
                -- Icon sits outside, extending left; RIGHT edge at bar's LEFT edge
                iconFrame:SetPoint("RIGHT", barFrame, "LEFT", ox, oy)
            end
        else -- "RIGHT"
            local oxT = -ox
            if loc == "inner" then
                -- Icon sits inside, extending left; RIGHT edge at bar's LEFT edge
                iconFrame:SetPoint("RIGHT", barFrame, "LEFT", oxT, oy)
            elseif loc == "center" then
                iconFrame:SetPoint("CENTER", barFrame, "CENTER", oxT, oy)
            else -- "outer"
                -- Icon sits outside, extending right; LEFT edge at bar's RIGHT edge
                iconFrame:SetPoint("LEFT", barFrame, "RIGHT", oxT, oy)
            end
        end
        return
    end

    -- Circular icon: in "outer" mode the icon overlaps the bar edge so the
    -- curved edge hugs the bar.
    if side == "LEFT" then
        if loc == "inner" then
            iconFrame:SetPoint("RIGHT", barFrame, "RIGHT", 42 + ox, oy)
            -- Inner on the LEFT side: icon overhangs the RIGHT edge of bars
            barFrame._iconOverlapRight = math.max(0, iconFrameSz - 42 - ox)
        elseif loc == "center" then
            iconFrame:SetPoint("CENTER", barFrame, "CENTER", ox, oy)
            -- Center: icon is over the bars, no overlap to compensate
        else -- "outer"
            iconFrame:SetPoint("RIGHT", barFrame, "LEFT", 20 + ox, oy)
            barFrame._iconOverlapLeft = math.max(0, 20 + ox)
        end
    else -- "RIGHT"
        local oxT = -ox
        if loc == "inner" then
            iconFrame:SetPoint("LEFT", barFrame, "LEFT",  -42 + oxT, oy)
            -- Inner on the RIGHT side: icon overhangs the LEFT edge of bars
            barFrame._iconOverlapLeft = math.max(0, iconFrameSz - 42 + ox)
        elseif loc == "center" then
            iconFrame:SetPoint("CENTER", barFrame, "CENTER", oxT, oy)
            -- Center: icon is over the bars, no overlap to compensate
        else -- "outer"
            iconFrame:SetPoint("LEFT", barFrame, "RIGHT", -20 + oxT, oy)
            barFrame._iconOverlapRight = math.max(0, 20 - oxT)
        end
    end
end

-- ============================================================
-- _ApplyOUFIconBorder
-- Applies classIconBorderEnabled / classIconBorderColor to _iconRing.
-- Stores frame._borderEnabled so _UpdateOUFIcon can AND it with
-- the circular/model check when deciding whether to show the ring.
-- ============================================================
function BF:_ApplyOUFIconBorder(frame)
    local p = BF.ufDB.profile
    local enabled = p.classIconBorderEnabled ~= false
    frame._borderEnabled = enabled

    local r, g, b
    if p.classIconBorderUseHealthColor and frame.Health then
        -- Use the current health bar color for the icon border.
        r, g, b = frame.Health:GetStatusBarColor()
    end
    -- 12.x secrets: a class-colored health bar returns forbidden/secret
    -- values while tainted; passing them to SetVertexColor/SetColorTexture
    -- below throws. If we can't read them (or the health-color path was off),
    -- fall back to the configured icon border color -- same safe triple the
    -- else branch used, and analogous to Grid2 guarding every engine value
    -- with canaccessvalue() before use.
    if r == nil or not canaccessvalue(r) then
        local bc = p.classIconBorderColor
        r = bc and bc.r or 0.85
        g = bc and bc.g or 0.65
        b = bc and bc.b or 0.1
    end

    if frame._iconRing then
        if enabled then
            frame._iconRing:SetVertexColor(r, g, b, 1)
        end
    end
    if frame._squareBorder then
        local sb = frame._squareBorder
        if sb.top    then sb.top:SetColorTexture(r, g, b, 1)    end
        if sb.bottom then sb.bottom:SetColorTexture(r, g, b, 1) end
        if sb.left   then sb.left:SetColorTexture(r, g, b, 1)   end
        if sb.right  then sb.right:SetColorTexture(r, g, b, 1)  end
    end
end

-- ============================================================
-- Rounded composite border (v59)
-- ============================================================

-- Every content region the composite rounded mask must cover — the UF
-- mirror of the raid EachMaskableRegion walk (core bar layers +
-- absorb/heal-absorb overlays; the 3px overshield glow strip stays
-- square per the raid decision — visually negligible at the corner
-- radius). All regions exist by the first layout: bars + bgs are made
-- in BluzzardStyle and the absorb family in SetupOUFAbsorbs, both at
-- style time. SetStatusBarTexture(file) re-files the SAME region
-- object, so per-region attach flags survive texture swaps. The
-- attached alt power bar attaches its own regions in
-- ApplyOUFAltPowerBarLayout (it can be re-parented, mirroring its
-- iconCutout attach), and the castbar is a standalone bar with its own
-- ring+mask kit — neither is walked here.
local function EachOUFMaskableRegion(f, fn)
    fn(f._oufNameBarBg)
    local hb = f.Health
    if hb then fn(hb:GetStatusBarTexture()) end
    fn(f._oufHealthBg)
    local pb = f.Power
    if pb then fn(pb:GetStatusBarTexture()) end
    fn(f._powerBg)
    local hpr = f._oufHealPred
    if hpr then fn(hpr:GetStatusBarTexture()) end
    local ab = f._oufAbsorbBar
    if ab then fn(ab:GetStatusBarTexture()); fn(ab._bg); fn(ab._overlay) end
    local ov = f._oufOvershieldBar
    if ov then fn(ov:GetStatusBarTexture()); fn(ov._overlay) end
    local ha = f._oufHealAbsorb
    if ha then fn(ha:GetStatusBarTexture()); fn(ha._overlay); fn(ha._shadow) end
    local has = f._oufHealAbsorbStrip
    if has then fn(has:GetStatusBarTexture()); fn(has._overlay) end
    local rm = f._oufReducedMaxBar
    if rm then fn(rm:GetStatusBarTexture()) end
end

-- The health-slot subset of EachOUFMaskableRegion, as an array for
-- ApplyUFBarRoundBorder (per-bar borders): everything that renders
-- inside the health bar's rect. Name strip and power bar get their own
-- kits. Built per apply (config/layout time only); the kit flags each
-- region once, so repeat builds are attach-free.
local function OUFHealthKitRegions(f)
    local t = {}
    local function add(x) if x then t[#t + 1] = x end end
    if f.Health then add(f.Health:GetStatusBarTexture()) end
    add(f._oufHealthBg)
    local hpr = f._oufHealPred
    if hpr then add(hpr:GetStatusBarTexture()) end
    local ab = f._oufAbsorbBar
    if ab then add(ab:GetStatusBarTexture()); add(ab._bg); add(ab._overlay) end
    local ov = f._oufOvershieldBar
    if ov then add(ov:GetStatusBarTexture()); add(ov._overlay) end
    local ha = f._oufHealAbsorb
    if ha then add(ha:GetStatusBarTexture()); add(ha._overlay); add(ha._shadow) end
    local has = f._oufHealAbsorbStrip
    if has then add(has:GetStatusBarTexture()); add(has._overlay) end
    local rm = f._oufReducedMaxBar
    if rm then add(rm:GetStatusBarTexture()) end
    return t
end

-- ── Per-bar rounded borders (v65: the oufRoundedSeparators toggle) ──
-- Each visible bar slot gets its OWN full rounded ring+mask via the
-- standalone-bar kit (ApplyUFBarRoundBorder — the exact pipeline the
-- detached bars/castbars/pips use), replacing the v63 separator lines.
-- The composite ring+mask are hidden by the caller; the block outline
-- IS the per-bar rings. Kit rings additionally take the icon cutout
-- mask (once per ring) so the chord-side edge never crosses under the
-- circular portrait — same rule as the square border edges.
-- The attached druid alt bar's kit is managed by
-- _ApplyOUFAltPowerBarBorder (its attach/detach lifecycle lives there).
-- Config/layout time only — never per-update.
function BF:_ApplyOUFPerBarRoundBorders(frame, pf, powerDetached)
    local level = frame:GetFrameLevel() + 7
    local cutout = frame._oufIconCutoutMask

    -- Kit anchor PAIR per bar slot (lazy): `clip` mirrors the bar's
    -- exact rect; `ext` is the rect the kit actually fills, extended
    -- past the icon-side edge when the bar carries a chord inset. The
    -- kit MASK then keeps the fill SQUARE at the icon side (no rounded
    -- corner notches against the portrait curve — owner report), and
    -- clip's SetClipsChildren cuts the RING's icon-side corners + band
    -- flat at the chord line — the same flat-end the composite ring
    -- shows where the icon cutout erases it. Extension = bar height:
    -- always past the corner radius (radius ≤ height/2 by the kit's
    -- short-dimension cap), and everything beyond the clip never
    -- renders. v90.11: clipping is UNCONDITIONAL — it is a whole-frame
    -- property, so gating it on "some side has an inset" made the class
    -- icon toggle change the render path of the far side too (see the
    -- note at the SetClipsChildren call). With no extension the clip
    -- rect is the kit rect and nothing is cut. (The name slot
    -- has no bar FRAME — the strip is a bg texture — so its clip
    -- anchors to the region; SetAllPoints(region) is fine.)
    local rects = frame._oufBarKitRects
    if not rects then
        rects = {}
        frame._oufBarKitRects = rects
    end

    -- v85 SHARED-EDGE OVERLAP: adjacent per-bar rings used to STACK
    -- their bands at every bar boundary (ring-bottom + ring-top =
    -- double thickness between health and power etc.). Each bar with a
    -- visible neighbor ABOVE now has its kit rect extended UP by one
    -- band width, so the two bands render on the SAME pixels and the
    -- boundary reads as a single border. Side bands are collinear, so
    -- the vertical extension is invisible there. (v90.10: the known gap
    -- is CLOSED at the source — the attached druid alt bar is no longer
    -- a kit built on its own bar frame in oUF_AltPowerBar.lua, it is the
    -- "alt" slot below, so it gets this same ext rect and the health→alt
    -- edge is overlapped exactly like every other boundary.)
    BF:RefreshPixelSize()
    local ovMode = BF:GetOUFBorderMode()
    local tOverlap = BF:PixelsToUI(ovMode == "rounded_thick" and 3 or 2)
    local ovScale = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
    if ovScale > 0 and ovScale < 1 then tOverlap = tOverlap / ovScale end

    -- v90.3 (owner report: with the class icon ENABLED, every fill
    -- rendered over its border; with it disabled things looked right):
    -- SetClipsChildren makes the clip frame a RENDER GROUP — the whole
    -- clipped subtree draws at the CLIP frame's own level relative to
    -- frames outside it, so the pieces' +7/+8 host levels stopped
    -- mattering the moment chord clipping switched on (icon on ⇒
    -- chord insets ⇒ clipping on; icon off ⇒ no clipping ⇒ correct).
    -- The clip frame was never leveled — it sat at the default
    -- child level, UNDER the bar fills. kitRect now takes the slot's
    -- resolved kit level and stamps clip + ext with it.
    -- v90.11: clipping is now ALWAYS on, so the render group is always
    -- in play — which is exactly why the clip has to stay leveled. It
    -- takes the same `lv` the kit's edge host takes, so the layer the
    -- pieces draw at is unchanged either way.
    --
    -- v90.4: the v90.3 square-top boundary is REVERTED (owner report:
    -- "the top right corner of the power bar is more square compared
    -- to the bottom right corner which looks correct" — every corner
    -- of every bar should round). Back to the v85 band-overlap rects:
    -- a slot with a visible neighbor above extends UP by one band
    -- width so the two bands share pixels, and it keeps ALL FOUR
    -- rounded caps at its (extended) rect corners. The kit mask rides
    -- the same rect, so cap curve and fill curve stay paired at every
    -- corner — the v90.2 art pairing plus the v90.3 level fixes are
    -- what the earlier "poking corners" actually needed.
    local function kitRect(slot, anchorTo, inL, inR, barH, topNeighbor, lv)
        local pair = rects[slot]
        if not pair then
            local clip = CreateFrame("Frame", nil, frame)
            clip:EnableMouse(false)
            local ext = CreateFrame("Frame", nil, clip)
            ext:EnableMouse(false)
            pair = { clip = clip, ext = ext }
            rects[slot] = pair
        end
        pair.clip:SetFrameLevel(lv)
        pair.ext:SetFrameLevel(lv)
        -- The clip rect carries the top extension too: with chord
        -- clipping active (SetClipsChildren) an ext-only extension
        -- would be clipped straight back off.
        local topExt = topNeighbor and tOverlap or 0
        pair.clip:ClearAllPoints()
        pair.clip:SetPoint("TOPLEFT", anchorTo, "TOPLEFT", 0, topExt)
        pair.clip:SetPoint("BOTTOMRIGHT", anchorTo, "BOTTOMRIGHT", 0, 0)
        local extL = (inL or 0) > 0 and barH or 0
        local extR = (inR or 0) > 0 and barH or 0
        -- v90.11 (owner report: "with the class icon on, the vertical
        -- edges and rounded corners at the side WITHOUT the icon look
        -- sharp and clear; with the icon OFF they become less sharp and
        -- a bit blurry — the icon should not affect them in any way,
        -- it's at the other side").
        -- It did, and this line is why. SetClipsChildren is a property
        -- of the WHOLE clip frame, not of one side, but it was switched
        -- on only when the icon produced a chord inset on SOME side. So
        -- toggling the icon did not just change the icon-side end — it
        -- moved every piece of that bar's ring onto a different render
        -- path. Clipped, the pieces are scissored at the clip rect's
        -- integer pixel bounds, which shaves the partial-coverage
        -- fringe an off-grid band or cap leaves and reads crisp;
        -- unclipped they keep it and read soft, "randomly" so because
        -- it depends on where the frame's edges land on the physical
        -- grid.
        -- Clipping is now unconditional, which is what the owner asked
        -- for — the two configurations differ only by mirroring. It
        -- cannot cut anything that should be drawn: with no extension
        -- the clip rect IS the kit rect, and every band and cap is
        -- anchored inside it. The one thing that ever renders outside
        -- the rect is the shared-edge lift, and that lives in the CLIP
        -- rect (topExt above), not in the ext rect, precisely so
        -- clipping keeps it. This is also the exact configuration that
        -- ships today whenever the icon is on, which is the one the
        -- owner reports as correct.
        -- (Superseded: "clipping is only enabled WITH an extension, so
        -- iconless frames keep their untouched 4-corner rounded kits" —
        -- the caps are anchored at the rect's corners and drawn inward,
        -- so the scissor never reaches them.)
        pair.clip:SetClipsChildren(true)
        pair.ext:ClearAllPoints()
        pair.ext:SetPoint("TOPLEFT", pair.clip, "TOPLEFT", -extL, 0)
        pair.ext:SetPoint("BOTTOMRIGHT", pair.clip, "BOTTOMRIGHT", extR, 0)
        return pair.ext, topExt
    end

    -- v90.2 LEVEL HARDENING (owner report: bar fills covering the
    -- per-bar rings — the fill renders OVER the border): every OTHER
    -- kit caller (castbar, detached power, alt, resource) stamps the
    -- border host relative to ITS OWN BAR's frame level; this walk
    -- alone stamped relative to the unit frame (+7), which loses
    -- whenever the slot's fill chain sits higher — the absorb
    -- sub-bars alone reach Health+5 (== frame+7 through the clipFrame
    -- chain), and any level change that doesn't cascade to children
    -- makes the gap arbitrary. Each kit is stamped above every fill
    -- chain it overlaps (a slot's shared-edge top band renders inside
    -- the bar ABOVE it, so the power kit must clear the health chain
    -- too). Pieces near the portrait stay handled by the icon cutout
    -- mask, which is attached to the ring below.
    local function slotKitLevel(sf1, sf2)
        local lv = level
        if sf1 and sf1.GetFrameLevel then
            local bl = sf1:GetFrameLevel()
            if bl and (bl + 6) > lv then lv = bl + 6 end
        end
        if sf2 and sf2.GetFrameLevel then
            local bl = sf2:GetFrameLevel()
            if bl and (bl + 6) > lv then lv = bl + 6 end
        end
        return lv
    end

    -- One slot: resolve the level, lay the clip/ext pair, apply the
    -- kit. `anchorFrame` is the slot's real bar frame (its rect owner);
    -- `topNeighbor` true = a visible slot sits directly above, so this
    -- kit's rect extends up one band width (v85 shared-edge overlap —
    -- the two boundary bands render on the same pixels). All four
    -- corners stay rounded (v90.4 owner ruling).
    local function applySlot(slot, anchorFrame, inL, inR, barH, topNeighbor,
                             regions, shown, sf1, sf2)
        local lv = slotKitLevel(sf1, sf2)
        local bar, topExt = kitRect(slot, anchorFrame, inL, inR, barH,
            topNeighbor, lv)
        if not bar then return end
        if shown then
            -- visibleH: the ext rect is topExt taller than the bar;
            -- the cap tier must reflect the visible bar height.
            local opts = { visibleH = barH }
            if BF:ApplyUFBarRoundBorder(bar, regions, lv, nil, nil, opts) then
                local kit = bar._bfRoundKit
                if kit and cutout and not kit.ring._bfCutoutAttached then
                    kit.ring:AddMaskTexture(cutout)
                    kit.ring._bfCutoutAttached = true
                end
            end
        else
            local kit = bar._bfRoundKit
            if kit then kit.ring:Hide(); kit.mask:Hide() end
        end
    end

    -- Same visibility rules the v63 separators used: hidden slots are
    -- alpha-only (rects stay reserved), so their kits hide outright.
    if frame._oufNameBarBg then
        applySlot("name", frame._oufNameBarBg,
            frame._iconBarInsetLeft_name, frame._iconBarInsetRight_name,
            pf.nameBarHeight or 13, false,
            { frame._oufNameBarBg }, pf.showNameBar ~= false)
    end
    local health = frame._oufHealthContainer or frame.Health
    if health then
        -- v91: the DRAWN height for the player -- the kit's extension and
        -- visible-height tiers describe the rect on screen, and with the alt
        -- power bar active the health bar is shorter than its setting.
        local kitHealthH = pf.healthBarHeight or 22
        if frame.__unit == "player" and BF.GetOUFPlayerHealthDrawnHeight then
            kitHealthH = BF:GetOUFPlayerHealthDrawnHeight()
        end
        applySlot("health", health,
            frame._iconBarInsetLeft_health, frame._iconBarInsetRight_health,
            kitHealthH, pf.showNameBar ~= false,
            OUFHealthKitRegions(frame), true, frame.Health)
    end
    -- v90.10 THE ATTACHED ALT POWER BAR IS A REAL SLOT (owner report:
    -- "when I set the power bar to a very low height the borders still
    -- look good, but when I set the alt power bar to the same height it
    -- looks different — can't they just be the same?").
    -- It was the ONE bar building its own kit directly on the bar frame
    -- (oUF_AltPowerBar.lua, the sameFrame path), so it alone missed
    -- everything applySlot provides: the chord EXTENSION past the icon
    -- side, the clip's flat cut at the chord line (every other bar runs
    -- under the portrait and ends flat there; this one kept rounded caps
    -- at the chord), the ext rect's shared-edge overlap with the bar
    -- above, and the ext rect's leveled edge host. Routing it through
    -- the same call makes it identical to the power bar by construction
    -- at every height, which is what was asked for.
    -- Handled for the player frame whether or not the bar is currently
    -- attached/active: a detached or collapsed bar simply resolves
    -- `shown` false and its kit hides, instead of a stale ring being
    -- left behind on the frame.
    local altBar = (frame.__unit == "player") and BF.oufAltPowerBar or nil
    if altBar then
        local altOn = (altBar:GetParent() == frame)
            and BF.IsAltPowerBarActive and BF:IsAltPowerBarActive() or false
        local aRegions = {}
        local aFill = altBar:GetStatusBarTexture()
        if aFill then aRegions[#aRegions + 1] = aFill end
        if altBar._bg then aRegions[#aRegions + 1] = altBar._bg end
        applySlot("alt", altBar,
            frame._iconBarInsetLeft_alt, frame._iconBarInsetRight_alt,
            BF.ufDB.profile.altPowerBarHeight or 3, true,
            aRegions, altOn,
            altBar, frame.Health)
    end
    if frame.Power then
        local pRegions = {}
        local pFill = frame.Power:GetStatusBarTexture()
        if pFill then pRegions[#pRegions + 1] = pFill end
        if frame._powerBg then pRegions[#pRegions + 1] = frame._powerBg end
        applySlot("power", frame.Power,
            frame._iconBarInsetLeft_power, frame._iconBarInsetRight_power,
            pf.powerBarHeight or 10, true,
            pRegions,
            not (pf.showPowerBar == false or powerDetached),
            frame.Power, frame.Health)
    end
end

-- Hides every per-bar kit (toggle off / square mode). Attachments stay
-- (hidden mask = inert), matching the composite mask convention.
function BF:_HideOUFPerBarRoundBorders(frame)
    local rects = frame._oufBarKitRects
    if not rects then return end
    for _, pair in pairs(rects) do
        local kit = pair.ext._bfRoundKit
        if kit then kit.ring:Hide(); kit.mask:Hide() end
    end
end

-- ── Separator LINES (v85: oufSeparatorStyle "lines") ────────────────
-- The second Bar Separator Style: the composite ring stays SHOWN as
-- the block outline and each visible attached bar below the topmost
-- slot gets ONE straight line along its TOP edge (ring color,
-- band-matched thickness) — the v63 look, reintroduced as a
-- selectable style. Single thickness between bars by construction:
-- exactly one line per boundary, nothing stacked. Lines anchor to the
-- BAR frames, so chord insets and the attached alt bar's position are
-- inherited for free.
function BF:_EnsureOUFSepLines(frame)
    local lines = frame._oufSepLines
    if not lines then
        local host = CreateFrame("Frame", nil, frame)
        host:EnableMouse(false)
        host:SetAllPoints(frame)
        lines = { host = host }
        for _, slot in ipairs({ "health", "alt", "power" }) do
            local tex = BF.Texture(host, nil, "OVERLAY", nil, 3)
            tex:Hide()
            lines[slot] = tex
        end
        frame._oufSepLines = lines
    end
    return lines
end

function BF:_HideOUFSeparatorLines(frame)
    local lines = frame._oufSepLines
    if not lines then return end
    lines.health:Hide(); lines.alt:Hide(); lines.power:Hide()
end

-- Self-contained (derives profile/mode/style itself and self-hides
-- when not applicable), so transition sites — alt bar attach/detach,
-- druid form swaps — can call it directly without re-running the full
-- border pass.
function BF:_ApplyOUFSeparatorLines(frame)
    if not frame then return end
    local p = BF.ufDB and BF.ufDB.profile
    if not p then return end
    local mode = BF:GetOUFBorderMode()
    local on = BF.IsRoundedBorderStyle and BF.IsRoundedBorderStyle(mode)
        and p.oufRoundedSeparators == true
        and (p.oufSeparatorStyle or "rings") == "lines"
        and BF:IsOUFBorderEnabled()  -- v90: master Enable Border gate
    if not on then
        self:_HideOUFSeparatorLines(frame)
        return
    end
    local unitKey = frame.__unit
    if unitKey and unitKey:match("^boss%d") then unitKey = "boss" end
    local pf = p[unitKey] or {}

    local lines = self:_EnsureOUFSepLines(frame)
    -- Level +7 — same layer the square edges and per-bar rings use.
    lines.host:SetFrameLevel(frame:GetFrameLevel() + 7)
    BF:RefreshPixelSize()
    -- Band-matched thickness: the composite outline is the v61
    -- raid-weight Frame* pair (2 / 3 texel bands since the v87 remap
    -- retirement), so the lines
    -- match THAT — not the Bar* per-bar ring weights.
    local t = BF:PixelsToUI(mode == "rounded_thick" and 3 or 2)
    local fScale = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
    if fScale > 0 and fScale < 1 then t = t / fScale end
    local r, g, b, a = GetRingColor()

    local function lay(tex, bar, shown)
        if not (bar and shown) then tex:Hide(); return end
        tex:SetColorTexture(r, g, b, a)
        tex:ClearAllPoints()
        -- v85.2 (owner report): raised by half the line thickness so
        -- the line straddles the natural seam between the two bars
        -- instead of hanging entirely inside the lower bar.
        tex:SetPoint("TOPLEFT",  bar, "TOPLEFT",  0, t / 2)
        tex:SetPoint("TOPRIGHT", bar, "TOPRIGHT", 0, t / 2)
        tex:SetHeight(t)
        tex:Show()
    end

    local powerDetached = frame.__unit == "player" and BF.GetUFDetachState
        and BF:GetUFDetachState("playerPowerBar")
    local health = frame._oufHealthContainer or frame.Health
    -- Line above health only when the name strip occupies the slot
    -- above it (showNameBar is alpha-only; hidden slot = no boundary).
    lay(lines.health, health, pf.showNameBar ~= false)
    local altBar = frame.__unit == "player" and BF.oufAltPowerBar
    -- v90.10: IsAltPowerBarActive, NOT IsShown. The attached bar is
    -- never hidden — an inactive one collapses to height 0.001 at alpha
    -- 0 and stays shown as a layout spacer — so IsShown drew an alt
    -- separator line for every character with the bar attached and
    -- inactive: stacked on the power line 0.001 units away (double
    -- opacity at any border alpha below 1) and, because a collapsed bar
    -- carries no chord inset and the lines carry no icon cutout mask,
    -- running straight across the class icon column. This is the same
    -- visibility test the rings path resolves its "alt" slot with.
    local altBetween = altBar and altBar:GetParent() == frame
        and BF.IsAltPowerBarActive and BF:IsAltPowerBarActive() or false
    lay(lines.alt, altBar, altBetween)
    lay(lines.power, frame.Power,
        not (pf.showPowerBar == false or powerDetached))
end

-- Applies the composite ring + content mask for a rounded border mode.
-- Called ONLY from _ApplyOUFFrameBorder's rounded branch (config/layout
-- time — never per-update). `pf` is the frame's per-unit profile table.
function BF:_ApplyOUFRoundedFrameBorder(frame, pf, mode)
    local rect = frame._oufRoundRect
    local host = frame._oufRoundHost
    local ring = frame._oufRoundBorder
    local mask = frame._oufRoundMask
    if not (rect and host and ring and mask) then return end

    -- Geometry: the ring encloses the VISIBLE block. showNameBar /
    -- showPowerBar are alpha-only (layout slots stay reserved so chord
    -- math and bar positions never shift), and power detach is
    -- alpha-only too — so the rect shrinks past the invisible slots
    -- instead of ringing empty space. Offsets are in the UNSCALED
    -- rect's (== frame's) coordinate space.
    local nameH  = pf.nameBarHeight  or 13
    local powerH = pf.powerBarHeight or 10
    local topOff = (pf.showNameBar == false) and nameH or 0
    local powerDetached = frame.__unit == "player" and BF.GetUFDetachState
        and BF:GetUFDetachState("playerPowerBar")
    local botOff = (pf.showPowerBar == false or powerDetached) and powerH or 0
    rect:ClearAllPoints()
    rect:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -topOff)
    rect:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, botOff)

    -- v90 (owner report: "the rounded / rounded thick borders are
    -- thinner than the same borders on the raid/party frames", plus a
    -- suspected fill-over-border layering issue worst on power bars):
    -- the composite outline is now PIECE-BUILT via the standalone-bar
    -- kit (ApplyUFBarRoundBorder) instead of the sliced Frame* ring.
    -- Two failure classes of the sliced child-host ring go away at
    -- once, both already proven out by v86/v89 on the standalone bars:
    --   * BAND WEIGHT: the piece edges are snapped color textures at
    --     EXACTLY 2/3 physical px (the raid band weights), immune to
    --     the nine-slice compression that thinned the sliced band on
    --     blocks/screens where the block's short dimension dropped
    --     toward the art's 64-physical-px margin floor — the "reads
    --     one weight thinner in situ" mystery v61 papered over with
    --     the (since retired) heavier-art remap.
    --   * LAYERING: kit levels are re-stamped on EVERY apply (v89
    --     rule: explicit levels, never build-time snapshots), so the
    --     outline can't end up under the bar fills the way the old
    --     child-host ring could.
    -- Corner caps are cut from FrameBorder/FrameBorderThick — the
    -- exact corner texels the raid rings render — so the corners stay
    -- pixel-identical to the raid frames. The legacy sliced ring
    -- texture stays permanently hidden.
    ring:Hide()
    -- Square boxes / kits use level +7 (above bars/text/absorbs, below
    -- iconFrame +8); re-stamped every apply like fb.name/health/power.
    local level = frame:GetFrameLevel() + 7
    rect:SetFrameLevel(level)
    host:SetFrameLevel(level)

    -- v90.8: the composite CONTENT MASK is an edge-strip mask
    -- SET (see the corner-mask section at the top of this file — the
    -- v90.1-v90.6 sliced attempts all failed because a sliced mask's
    -- corner scales with the region while the piece caps are fixed).
    -- The legacy sliced mask stays permanently hidden; its historical
    -- attachments are inert.
    mask:Hide()
    local eff = frame:GetEffectiveScale()
    local pixelSize = 768 / select(2, GetPhysicalScreenSize())
    local pxUI = (eff and eff > 0) and (pixelSize / eff) or 1
    local cmasks = frame._oufRoundCMasks
    if not cmasks then
        cmasks = EnsureCornerMaskSet(rect)
        frame._oufRoundCMasks = cmasks
    end
    -- Composite caps are always full-size (the block is never tiny),
    -- so the strips are asked for EDGE_MASK_ART phys px — fit-short
    -- scale 1, i.e. 1 texel = 1 phys px, pixel-identical to the
    -- FrameBorder texels the caps are cut from.
    -- v90.9: StampCornerMaskSet raises that when the rect is TALLER
    -- than the strip, because a sliced mask erases whatever its rect
    -- does not reach. The block clears 64 phys px on any setup whose
    -- effective scale puts more than ~35 UI units of bar in it, and
    -- there the composite fill was being cut through the middle. The
    -- strips then render above scale 1 and the fill's corner curve
    -- runs correspondingly rounder than the ring caps — the trade is
    -- deliberate: a slightly soft corner against a hole in the bar.
    StampCornerMaskSet(cmasks, rect, mode, EDGE_MASK_ART * pxUI)

    -- ── Bar Separators toggle (v65): per-bar FULL borders. Each
    -- visible bar gets its own rounded ring+mask kit and the composite
    -- ring+mask hide — the block outline is the per-bar rings. (v63
    -- drew separator lines here instead; replaced per owner request.)
    if BF.ufDB.profile.oufRoundedSeparators == true
        and (BF.ufDB.profile.oufSeparatorStyle or "rings") ~= "lines" then
        -- "rings" style: per-bar full borders (shared edges overlapped
        -- to single thickness — see _ApplyOUFPerBarRoundBorders).
        -- Region mask-set assignment happens inside the per-bar walk
        -- (each slot's regions take that slot's corner set).
        local kit = rect._bfRoundKit
        if kit then kit.ring:Hide(); kit.mask:Hide() end
        ShowCornerMaskSet(cmasks, false)
        self:_HideOUFSeparatorLines(frame)
        self:_ApplyOUFPerBarRoundBorders(frame, pf, powerDetached)
    else
        -- Composite outline — separators off, or the "lines" style
        -- (whose applier self-hides when separators are off).
        self:_HideOUFPerBarRoundBorders(frame)
        -- v90 piece-built outline on the composite rect (see header
        -- comment above). regions=nil: region masking is handled by
        -- the composite corner set below, not the kit.
        if BF:ApplyUFBarRoundBorder(rect, nil, level) then
            local kit = rect._bfRoundKit
            if kit then
                kit.mask:Hide()
                -- The outline takes the icon cutout mask exactly as
                -- the sliced ring / square edges do, so it never
                -- crosses under the portrait's curve.
                local cutout = frame._oufIconCutoutMask
                if cutout and not kit.ring._bfCutoutAttached then
                    kit.ring:AddMaskTexture(cutout)
                    kit.ring._bfCutoutAttached = true
                end
            end
        end
        -- Every maskable region follows the COMPOSITE corner set in
        -- this mode (config-time set swap; per-bar mode reassigns
        -- them to the slot sets).
        EachOUFMaskableRegion(frame, function(tex)
            if tex then SetRegionCornerMasks(tex, cmasks) end
        end)
        ShowCornerMaskSet(cmasks, true)
        self:_ApplyOUFSeparatorLines(frame)
    end
end

-- v90: hide EVERY rounded frame-border widget on a unit frame — the
-- legacy sliced ring, the composite content mask, the composite rect's
-- piece kit, the per-bar kits, and the separator lines. Used by the
-- square branch of _ApplyOUFFrameBorder (mode switch away from
-- rounded) and by the rounded branch when the master Enable Border is
-- off. Hidden masks = masking off; every attachment stays in place
-- for the next toggle-on (oUF cutout-mask precedent).
function BF:_HideOUFRoundedFrameBorder(frame)
    if frame._oufRoundBorder then frame._oufRoundBorder:Hide() end
    if frame._oufRoundMask then frame._oufRoundMask:Hide() end
    ShowCornerMaskSet(frame._oufRoundCMasks, false)  -- v90.7
    local rect = frame._oufRoundRect
    local kit = rect and rect._bfRoundKit
    if kit then kit.ring:Hide(); kit.mask:Hide() end
    self:_HideOUFPerBarRoundBorders(frame)
    self:_HideOUFSeparatorLines(frame)
end

-- ============================================================
-- Standalone-bar rounded border kit (v86 -- PIECE CONSTRUCTION)
-- One kit per bar: 4 SOLID edge textures + 4 fixed-size corner caps
-- + 1 sliced content mask.
--
-- WHY pieces (owner requirement after the v85 sliced-ring iterations:
-- "the border thickness must be identical on every bar at every
-- size"): sliced ring + sliced mask on a scaled pixel host was the
-- one configuration with no working precedent anywhere (Coolinator:
-- border+mask same-space and unscaled; Grid2: never slices masks;
-- raid frames: sizes where any error is sub-pixel), and its failures
-- all presented as ring and mask disagreeing about geometry. The
-- piece build removes nine-slice semantics from the load-bearing
-- path entirely:
--   * Edges are plain color textures with exact physical-pixel
--     thickness -- the square-border mechanism, proven at all sizes.
--   * Corner caps render at fixed size, 1 art texel = 1 physical px,
--     from the Frame* ring art via SetTexCoord (reversed coords
--     for the right/bottom corners).
--   * The content mask keeps the accepted 32px baseline behavior on
--     the scaled mask host -- cosmetic fill rounding only.
-- Corner radius: 8 phys px, shrinking to ceil(short/2) on tiny
-- bars (v90.9 -- was floor, which stranded a sub-band sliver of
-- straight edge between the two caps), and dropping to SQUARE
-- corners below 6 phys px. The BAND NEVER CHANGES with bar size --
-- the single v90.9 exception is the sliver of SIDE band opened by a
-- shared-edge lift on a bar whose caps meet, which matches the caps
-- it connects rather than stepping past them.
--
-- kit.ring is a compatibility PROXY table (Hide / Show / IsShown /
-- SetVertexColor / AddMaskTexture / RemoveMaskTexture fan out over
-- the 8 pieces) so external callers -- alt power bar, resource bar,
-- pips, castbars, Incoming Casts -- are unchanged, including the
-- _bfCutoutAttached flag they stash on it. Config/layout time only
-- -- never per-update.
-- ============================================================

-- (BAR_KIT_CORNERS is defined with the corner-mask section near the
-- top of this file — v90.7.)

-- Corner-cap texcoords. Two sources (v88):
--   "frame" -- the top-left 8x8-texel corner of the Frame* art itself
--              (FrameBorder / FrameBorderThick, the raid ring files):
--              radius ~6.4, band 2/3 -- PIXEL-IDENTICAL to the raid
--              and composite corners, and the files are loaded by the
--              composite/raid paths since forever (no new-file
--              restart dependency).
--   "atlas" -- the BarCornerCaps synthetic cells (radius 2-4) for
--              bars too short for 8px corners.
-- Reversing u/v mirrors the TOP-LEFT master into the other corners.
local function BarCapTexCoords(corner)
    local u1, u2, v1, v2 = 0, 8 / 128, 0, 8 / 128
    if corner == "TOPRIGHT" or corner == "BOTTOMRIGHT" then u1, u2 = u2, u1 end
    if corner == "BOTTOMLEFT" or corner == "BOTTOMRIGHT" then v1, v2 = v2, v1 end
    return u1, u2, v1, v2
end

local function SnapBarKitPiece(t)
    t:SetSnapToPixelGrid(true)
    t:SetTexelSnappingBias(0)
end

local function SetBarKitColor(kit, r, g, b, a)
    a = (a ~= nil) and a or 1
    local e = kit.edges
    e.top:SetColorTexture(r, g, b, a)
    e.bottom:SetColorTexture(r, g, b, a)
    e.left:SetColorTexture(r, g, b, a)
    e.right:SetColorTexture(r, g, b, a)
    -- These pieces are created through the unsnapping funnel
    -- (BF.Texture, PixelPerfect.lua section 7) -- and SNAP IS THE
    -- POINT of them, so re-snap here. A solid
    -- 2-3 phys px band at a fractional screen position smears over an
    -- extra pixel row with AA and reads thinner; which bars smear
    -- depends on where the frame sits (owner report: power bar
    -- consistently thinner than health, varying with frame position).
    -- Re-snapping pins every band to exactly its pixel rows at any
    -- frame position.
    SnapBarKitPiece(e.top)
    SnapBarKitPiece(e.bottom)
    SnapBarKitPiece(e.left)
    SnapBarKitPiece(e.right)
    -- SetVertexColor is NOT hooked, so the caps keep their snap here;
    -- their SetTexCoord site re-snaps them (it IS hooked).
    for i = 1, 4 do
        kit.corners[BAR_KIT_CORNERS[i]]:SetVertexColor(r, g, b, a)
    end
end

function BF:_EnsureUFBarRoundKit(bar)
    local kit = bar._bfRoundKit
    if kit then return kit end

    -- v90.7: the kit's content mask is a fixed-size CORNER-MASK SET
    -- (see the corner-mask section at the top of this file); the v58
    -- sliced-mask pixel host is retired.

    -- v89 LAYERING FIX (owner-identified: "you keep putting the power
    -- bar fill OVER the border" -- THE root cause of every "thin /
    -- invisible bar border" report in this saga): when the kit's bar
    -- IS a StatusBar (detached power bar, alt power bar, castbars),
    -- the border pieces are created ON THE BAR ITSELF at OVERLAY
    -- sublayer 7. Within one frame the draw-layer order is absolute:
    -- the fill (ARTWORK) can NEVER cover OVERLAY textures, whatever
    -- happens to child-frame levels across SetParent/detach -- which
    -- is what kept inverting the old child-host ring under the fill.
    -- Plain-Frame bars (the per-bar ext rects, the resource bar) keep
    -- a leveled edge host: their fills live on OTHER frames, so
    -- same-frame layering cannot apply, and explicit levels do work
    -- there (the pips prove it: fill frame +0, border frame +2).
    local sameFrame = bar.GetStatusBarTexture ~= nil
    local edgeHost, pieceOwner
    if sameFrame then
        pieceOwner = bar
    else
        edgeHost = CreateFrame("Frame", nil, bar)
        edgeHost:SetAllPoints(bar)
        edgeHost:EnableMouse(false)
        pieceOwner = edgeHost
    end

    local edges = {}
    for _, ek in ipairs({ "top", "bottom", "left", "right" }) do
        local t = BF.Texture(pieceOwner, nil, "OVERLAY", nil, 7)
        t:SetColorTexture(0, 0, 0, 1)
        t:Hide()
        edges[ek] = t
    end
    local corners = {}
    for i = 1, 4 do
        local c = BF.Texture(pieceOwner, nil, "OVERLAY", nil, 7)
        c:Hide()
        corners[BAR_KIT_CORNERS[i]] = c
    end

    kit = { edgeHost = edgeHost, edges = edges, corners = corners }

    -- Corner-mask set + kit.mask PROXY: external callers only ever
    -- Hide/Show kit.mask, so the proxy fans those over the four
    -- corner masks (mirroring the kit.ring proxy below).
    kit.cmasks = EnsureCornerMaskSet(pieceOwner)
    kit.mask = {
        Hide = function()
            kit._bf_maskShown = false
            ShowCornerMaskSet(kit.cmasks, false)
        end,
        Show = function()
            kit._bf_maskShown = true
            ShowCornerMaskSet(kit.cmasks, true)
        end,
        IsShown = function() return kit._bf_maskShown or false end,
    }

    local pieces = { edges.top, edges.bottom, edges.left, edges.right,
        corners.TOPLEFT, corners.TOPRIGHT, corners.BOTTOMLEFT,
        corners.BOTTOMRIGHT }
    kit.pieces = pieces
    local function setShown(shown)
        kit._bf_ringShown = shown
        local e = kit.edges
        -- v90.9: _bf_edgeOn (stamped by ApplyUFBarRoundBorder) drops a
        -- straight band whose run between the two caps has collapsed —
        -- see the run guard there. Absent, i.e. a kit shown before its
        -- first apply, means all four on: the pre-v90.9 behavior.
        local eo = kit._bf_edgeOn
        e.top:SetShown(shown and (eo == nil or eo.top) and true or false)
        e.bottom:SetShown(shown and (eo == nil or eo.bottom) and true or false)
        e.left:SetShown(shown and (eo == nil or eo.left) and true or false)
        e.right:SetShown(shown and (eo == nil or eo.right) and true or false)
        local capsOn = shown and kit._bf_capsOn or false
        for i = 1, 4 do
            local ck = BAR_KIT_CORNERS[i]
            local on = capsOn
            -- v90.3: a squareTop kit never shows its TOP caps (the
            -- neighbor above owns the shared boundary's corners).
            if on and kit._bf_squareTop
                and (ck == "TOPLEFT" or ck == "TOPRIGHT") then
                on = false
            end
            kit.corners[ck]:SetShown(on)
        end
    end
    kit._bf_setShown = setShown
    kit.ring = {
        Hide = function() setShown(false) end,
        Show = function() setShown(true) end,
        IsShown = function() return kit._bf_ringShown or false end,
        SetVertexColor = function(_, cr, cg, cb, ca)
            SetBarKitColor(kit, cr, cg, cb, ca)
        end,
        AddMaskTexture = function(_, m)
            for i = 1, #pieces do pieces[i]:AddMaskTexture(m) end
        end,
        RemoveMaskTexture = function(_, m)
            for i = 1, #pieces do pieces[i]:RemoveMaskTexture(m) end
        end,
    }

    bar._bfRoundKit = kit
    return kit
end

-- Applies (or hides) the rounded piece-border + mask on a standalone
-- bar.
--   regions : array of textures the content mask must clip. v90.7:
--             each region's attached corner-mask SET is swapped via
--             SetRegionCornerMasks (its own tracking; the historical
--             `_bfBarRoundMasked` flags are dormant).
--   level   : frame level for the border host -- pass the level the
--             bar's square border frame uses so the pieces layer
--             identically. Re-stamped every call (castbars change level
--             on detach).
--   ringTex : RETIRED (v86) -- accepted and ignored; the ring is built
--             from pieces, not art.
--   maskTex : RETIRED (v90.7) -- accepted and ignored; the content
--             mask is the fixed-size corner set, not sliced art.
-- Returns true when a rounded mode is active -- the caller hides its
-- square border box and returns.
--   opts    : OPTIONAL override table.
--             { mode = "rounded"|"rounded_thick"|"square",
--               color = { r=, g=, b=, a= } }
--             Without it the helper follows the UNIT FRAME border mode
--             (ufDB.oufBorderMode) and the unit frame border color.
--             v90.3 additions (per-bar slot kits — oufRoundedSeparators
--             "rings" walk; squareTop/topInset were reverted in v90.4,
--             the plumbing remains for future callers):
--               squareTop/topInset : draw a square full-width top
--                 band at topInset below the kit rect's top, no top
--                 caps.
--               visibleH : the slot's real bar height in UI units —
--                 the cap-tier SHORT measurement, since the kit rect
--                 is one band width taller than the visible bar
--                 (shared-edge overlap).
--             v90.9 addition:
--               topShared : (v90.10: no current caller — the attached
--                 alt power bar, the only sameFrame kit that needed it,
--                 became an ext-rect slot. Kept for the next one.)
--                 true = this bar shares its TOP edge with a
--                 visible bar directly above. The top band, the two top
--                 caps, the tops of the side bands and the TOP
--                 content-mask strip all lift by ONE BAND WIDTH, so
--                 this bar's top band lands on the neighbor's bottom
--                 band instead of stacking under it. This is the
--                 shared-edge overlap for kits built ON the bar frame
--                 (the sameFrame path), which have no ext rect to grow;
--                 the ext-rect slots in _ApplyOUFPerBarRoundBorders get
--                 the same effect from their rect instead.
function BF:ApplyUFBarRoundBorder(bar, regions, level, ringTex, maskTex, opts)
    local mode = (opts and opts.mode) or self:GetOUFBorderMode()
    if not (BF.IsRoundedBorderStyle and BF.IsRoundedBorderStyle(mode)) then
        local kit = bar._bfRoundKit
        if kit then
            -- Hidden mask = masking off; attachments stay for the next
            -- rounded switch.
            kit.ring:Hide()
            kit.mask:Hide()
        end
        return false
    end
    local kit = self:_EnsureUFBarRoundKit(bar)
    if level and kit.edgeHost then
        kit.edgeHost:SetFrameLevel(level)
    end

    -- Geometry, in exact physical pixels expressed as BAR-LOCAL units.
    local eff = bar:GetEffectiveScale()
    local pxUI, shortPx = 1, 0
    -- The bar's own VISIBLE height in UI units (opts.visibleH when the
    -- kit rect is taller than the bar it belongs to). Kept out of the
    -- scale block: the connector-band rule below needs it.
    local visHUI = 0
    if eff and eff > 0 then
        local pixelSize = 768 / select(2, GetPhysicalScreenSize())
        pxUI = pixelSize / eff
        local w = (bar:GetWidth() or 0)
        local h = (bar:GetHeight() or 0)
        -- v90.3: a squareTop kit rect is a full bar height TALLER than
        -- the visible bar; measure the tier off the real bar height.
        if opts and opts.visibleH and opts.visibleH > 0
            and opts.visibleH < h then
            h = opts.visibleH
        end
        visHUI = h
        local short = (w > 0 and w < h) and w or h
        if pxUI > 0 then shortPx = short / pxUI end
    end
    local bandPx = (mode == "rounded_thick") and 3 or 2
    -- Cap tiering: bars with >= 16 phys px of short dimension get 8px
    -- corners cut from the Frame* ring art itself -- the SAME corner
    -- texels the raid frames and the composite outline render, so the
    -- bars match them exactly.
    -- v90.4 (owner report: "a bar at height 8 or below is incorrectly
    -- becoming square instead of rounded" -- the v88 hard 16px->square
    -- drop is retired): below 16 phys px the caps SCALE DOWN instead,
    -- r = floor(short/2), drawn from the same 8x8 art texels at the
    -- smaller size. The kit mask's existing tiny-bar host shrink
    -- (short/16) scales the mask's corner curve by exactly the same
    -- factor (r/8), so cap curve and fill curve stay paired all the
    -- way down. Only genuinely tiny bars (< 6 phys px -- the 3px
    -- detached alt bar) drop to square corners.
    -- v90.9 CEIL, NOT FLOOR (owner report: "if I set the height of the
    -- alt power bar lower than 8, the rounded right-hand side gets a
    -- weird dot added — a random extra border pixel at the side of the
    -- border that doesn't follow the curve"). floor(short/2) left
    -- short - 2*floor(short/2) physical px of STRAIGHT side band
    -- stranded between the two caps (short 13 → r 6 → a 1px sliver;
    -- short 15 → r 7 → 1px). That sliver drew at the FULL bandPx
    -- thickness while a scaled cap draws its band at bandPx * (rPx/8),
    -- so it poked past the curve it was supposed to continue — one
    -- stray pixel, at the side, not following the curve. Above 16 phys
    -- px rPx is a flat 8 (scale 1, cap band == bandPx) and the side
    -- band is a real run, which is why it only ever showed on short
    -- bars — exactly the reported "below 8" threshold.
    -- ceil guarantees 2*r >= short, so the two caps MEET or overlap by
    -- up to a pixel: nothing is stranded, and independent pixel
    -- snapping of the two caps cannot open a hole between them either.
    -- The now-degenerate band is hidden by the run guard below.
    local rPx = 8
    if shortPx > 0 and shortPx < 16 then
        rPx = (shortPx >= 6) and math.ceil(shortPx / 2) or 0
    end
    local t = bandPx * pxUI
    local r = rPx * pxUI
    -- v90.3 squareTop geometry: the top band is FULL-WIDTH at topInset
    -- below the kit rect's top (landing on the neighbor's bottom-band
    -- pixels), the side bands run up to that same line, and the two
    -- TOP caps stay hidden — the neighbor's bottom caps own those
    -- corners. Bottom half is unchanged.
    local squareTop = opts and opts.squareTop or false
    local ti = (squareTop and opts and opts.topInset) or 0
    kit._bf_squareTop = squareTop

    -- v90.9 SHARED-EDGE LIFT FOR SAME-FRAME KITS (owner report: "the
    -- border between the health bar and the alt power bar is way
    -- thicker than the border between the alt power bar and the power
    -- bar"). _ApplyOUFPerBarRoundBorders gives every slot an ext RECT
    -- one band width taller than its bar, so the slot's top band lands
    -- on the neighbor above's bottom band and the boundary renders at
    -- single thickness. The attached druid alt bar is the one slot
    -- whose kit lives on the BAR FRAME itself (the sameFrame path), so
    -- it had no ext rect to grow — its top band stacked on top of the
    -- health bar's bottom band, i.e. double thickness, while its own
    -- bottom edge was correctly single because the POWER slot's ext
    -- rect overlaps it from below. topShared reproduces the ext-rect lift
    -- directly in the piece geometry: the top band, the two top caps
    -- and the tops of the side bands all move up by that much (the
    -- TOP content-mask strip follows, so the fill's corner curve stays
    -- paired with the caps exactly as it does on an ext rect).
    -- The lift is the kit's OWN band width, resolved in the kit's own
    -- pixel space — the caller does not compute it. The neighbor above
    -- draws its bottom band in exactly the band width just above this
    -- bar's top edge, so lifting by t lands the two on the same pixels
    -- whatever the frame's scale is.
    local topExt = (opts and opts.topShared) and t or 0

    local rTop    = squareTop and 0 or r
    local topOff  = (squareTop and ti or 0) - topExt
    local sideTop = (squareTop and ti or r) - topExt

    local wUI = bar:GetWidth() or 0
    local hUI = bar:GetHeight() or 0

    -- v90.9 CONNECTOR BAND WIDTH. The bands keep the full band weight —
    -- "the border thickness must be identical on every bar at every
    -- size" (v86) — with exactly one exception. On the scaled-cap tier
    -- a cap drawn at SetSize(r, r) from the 8x8 art scales its arms on
    -- BOTH axes, to bandPx * (rPx/8). With the ceil radius those caps
    -- MEET over the bar's own height, so the side band has no run left
    -- across the bar at all and is dropped (see the run guard) — the
    -- two caps are the whole end of the bar, the look every short bar
    -- has had since v90.4.
    -- What re-opens a run is the shared-edge overlap: the kit RECT is a
    -- band width taller than the bar (an ext rect for the per-bar
    -- slots, opts.topShared for the attached alt bar), so a sliver of
    -- side band survives in the middle of the side, CONNECTING two
    -- scaled caps. At the full band weight that sliver steps past the
    -- curves it joins — the reported "random extra border pixel at the
    -- side that doesn't follow the curve" — so a connector matches the
    -- caps it connects. Floored at one physical px.
    -- Gated on the bar's own visible height, so only a bar whose caps
    -- already meet can take this branch: every bar at or above 16 phys
    -- px keeps the full band on all four sides, unchanged.
    local tSide = t
    if rPx >= 2 and visHUI > 0 and (visHUI - 2 * r) <= 0 then
        tSide = t * (rPx / 8)
        if tSide < pxUI then tSide = pxUI end
    end

    -- Piece layout (change-guarded on the resolved geometry).
    local geom = t .. ":" .. r .. ":" .. bandPx .. ":" .. rPx .. ":" .. mode
        .. ":" .. ti .. ":" .. tostring(squareTop) .. ":" .. topExt
        .. ":" .. tSide
    if kit._bf_geom ~= geom then
        kit._bf_geom = geom
        local e = kit.edges
        e.top:ClearAllPoints()
        e.top:SetPoint("TOPLEFT",  bar, "TOPLEFT",  rTop, -topOff)
        e.top:SetPoint("TOPRIGHT", bar, "TOPRIGHT", -rTop, -topOff)
        e.top:SetHeight(t)
        e.bottom:ClearAllPoints()
        e.bottom:SetPoint("BOTTOMLEFT",  bar, "BOTTOMLEFT",  r, 0)
        e.bottom:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -r, 0)
        e.bottom:SetHeight(t)
        e.left:ClearAllPoints()
        e.left:SetPoint("TOPLEFT",    bar, "TOPLEFT",    0, -sideTop)
        e.left:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 0, r)
        e.left:SetWidth(tSide)
        e.right:ClearAllPoints()
        e.right:SetPoint("TOPRIGHT",    bar, "TOPRIGHT",    0, -sideTop)
        e.right:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, r)
        e.right:SetWidth(tSide)
        local capTex = RoundedUFRingPath(mode)  -- FrameBorder / Thick
        kit._bf_capsOn = (rPx >= 2)
        for i = 1, 4 do
            local ck = BAR_KIT_CORNERS[i]
            local c = kit.corners[ck]
            local isTop = (ck == "TOPLEFT" or ck == "TOPRIGHT")
            local capOn = rPx >= 2 and not (squareTop and isTop)
            if capOn then
                if c._bf_capTex ~= capTex then
                    c:SetTexture(capTex)
                    c._bf_capTex = capTex
                end
                c:ClearAllPoints()
                -- Top caps ride the shared-edge lift with the top band.
                c:SetPoint(ck, bar, ck, 0, isTop and topExt or 0)
                c:SetSize(r, r)
                c:SetTexCoord(BarCapTexCoords(ck))
                -- Re-snap: the creation funnel unsnaps every region
                -- it makes, and these caps want the grid.
                SnapBarKitPiece(c)
            end
            c:SetShown(kit._bf_ringShown and capOn or false)
        end
    end

    -- v90.9 RUN GUARD. With the ceil radius above, a bar whose short
    -- dimension is under 16 phys px has 2*r >= short, so the straight
    -- band on that axis is anchored between two points that have met or
    -- crossed. The engine is then free to draw a remnant row — which is
    -- precisely the stray pixel this pass removes — so a band with no
    -- run left is hidden outright and the two caps own that end of the
    -- bar entirely. Recomputed on EVERY apply, deliberately NOT inside
    -- the geometry guard: the runs depend on the bar's current width
    -- and height, which change without changing the resolved
    -- band/radius geometry (a width slider, a detach, a druid form
    -- swap).
    if wUI > 0 and hUI > 0 then
        -- Strictly "> 0": a run that survives is a REAL gap between the
        -- two caps (the shared-edge lift opens one) and must be drawn,
        -- however short — it is now the same weight as the caps it
        -- joins, so a sub-pixel run snapping up to a full row is flush
        -- rather than a protrusion. Only a run that has closed is
        -- dropped. A bar with no size yet leaves the table alone, so an
        -- un-laid-out rect can never latch "everything hidden".
        local sideRun = hUI - sideTop - r
        kit._bf_edgeOn = {
            top    = (wUI - 2 * rTop) > 0,
            bottom = (wUI - 2 * r)    > 0,
            left   = sideRun > 0,
            right  = sideRun > 0,
        }
    end

    -- Color: edges via SetColorTexture, caps via vertex tint.
    local oc = opts and opts.color
    local cr, cg, cb, ca
    if oc then
        cr, cg, cb, ca = oc.r, oc.g, oc.b, (oc.a ~= nil) and oc.a or 1
    else
        cr, cg, cb, ca = GetRingColor()
    end
    SetBarKitColor(kit, cr, cg, cb, ca)

    -- v90.8 MASK/CAP PAIRING — TOP/BOTTOM edge-strip masks (see the
    -- edge-strip section at the top of this file; sliced masks scaled
    -- their corner with the region, and the v90.7 four-corner masks
    -- exceeded the engine's 3-masks-per-texture limit). The strip
    -- height is EDGE_MASK_ART phys px scaled by the SAME graded
    -- factor as the caps (rPx/8), which pins the engine's fit-short
    -- texel scale to that factor — cap curve and fill curve are
    -- paired by construction at every tier and every bar size. The
    -- square-cap tier uses scale 1/4 — a ~1.6px fill rounding +
    -- inset, matching the accepted small-bar look against square
    -- corners.
    local capScale = (rPx >= 2) and (rPx / 8) or 0.25
    -- The TOP strip follows the lifted top band/caps so the
    -- fill's corner curve stays paired with them (v90.9).
    StampCornerMaskSet(kit.cmasks, bar, mode,
        EDGE_MASK_ART * capScale * pxUI, topExt)
    -- /bf ufrects diagnostic. capScale is the REQUESTED strip scale;
    -- StampCornerMaskSet may have raised the strip to cover a tall
    -- rect (v90.9), in which case the rendered scale is higher.
    kit._bf_cmaskGeom = capScale .. ":" .. mode

    if regions then
        for i = 1, #regions do
            SetRegionCornerMasks(regions[i], kit.cmasks)
        end
    end
    kit.ring:Show()
    kit.mask:Show()
    return true
end

-- ============================================================
-- _ApplyOUFFrameBorder
-- Independent border boxes around name bar, health bar, power bar.
-- Profile keys: nameBorderEnabled/Thickness/Color
--               healthBorderEnabled/Thickness/Color
--               powerBorderEnabled/Thickness/Color
-- Rounded border modes (oufBorderMode) replace the three boxes with
-- ONE composite ring + content mask — see _ApplyOUFRoundedFrameBorder.
-- ============================================================
function BF:_ApplyOUFFrameBorder(frame)
    local fb = frame._frameBorder
    if not fb or not fb.name then return end

    local p  = BF.ufDB.profile
    local unitKey = frame.__unit
    if unitKey and unitKey:match("^boss%d") then unitKey = "boss" end
    local pf = p[unitKey] or {}

    local nameH   = pf.nameBarHeight   or 13
    local healthH = pf.healthBarHeight or 22
    local powerH  = pf.powerBarHeight  or 10
    local barW    = pf.frameWidth      or 156

    -- v91: for the PLAYER these are two different numbers. The alt power bar
    -- reserves a strip INSIDE the health band, so the band (which fixes where
    -- the power bar starts) and the rect the health border must hug (which
    -- shrinks when the player shifts) diverge. Identical for every other unit.
    local healthBand, healthDrawn = healthH, healthH
    if unitKey == "player" and BF.GetOUFPlayerHealthBandHeight then
        healthBand  = BF:GetOUFPlayerHealthBandHeight()
        healthDrawn = BF:GetOUFPlayerHealthDrawnHeight()
    end

    -- Level +7 = 57: above bars/text, below iconFrame at +8 = 58.
    local level = frame:GetFrameLevel() + 7
    fb.name:SetFrameLevel(level)
    fb.health:SetFrameLevel(level)
    fb.power:SetFrameLevel(level)

    local function ApplyBox(box, enableKey, thickKey, colorKey, topY, boxH, insetL, insetR)
        local show = p[enableKey] == true
        box._wantShown = show
        if not show then box:Hide(); return end

        insetL = insetL or 0
        insetR = insetR or 0

        BF:RefreshPixelSize()
        local thick = BF:PixelsToUI(p[thickKey] or 1)
        -- Compensate for the frame's own scale so borders don't shrink
        -- below 1 physical pixel on scaled-down frames.
        local fScale = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
        if fScale > 0 and fScale < 1 then
            thick = thick / fScale
        end
        -- Enforce a minimum of 1 physical pixel.
        local minThick = BF:PixelsToUI(1)
        if fScale > 0 and fScale < 1 then minThick = minThick / fScale end
        if thick < minThick then thick = minThick end
        local bc    = p[colorKey] or { r=0, g=0, b=0, a=1 }
        local r, g, b, a = bc.r or 0, bc.g or 0, bc.b or 0, bc.a or 1

        -- Anchor only to the non-icon side with offset 0 + SetSize.
        -- See Health/Power anchoring rationale in the layout functions:
        -- preserves offset-0 inheritance to avoid a 1px divergent-snap
        -- mismatch between this border's edge and the bar's edge.
        box:ClearAllPoints()
        -- v90.4: anchor side by ICON side (see GetOUFBarAnchorSide).
        local boxAnchor = BF:GetOUFBarAnchorSide(frame, insetL)
        box:SetPoint(boxAnchor, frame, boxAnchor, 0, topY)
        box:SetSize(BF:PixelRound(barW - insetL - insetR), boxH)
        box:Show()

        box.top:SetColorTexture(r, g, b, a)
        box.top:ClearAllPoints()
        box.top:SetPoint("TOPLEFT",  box, "TOPLEFT",  0, 0)
        box.top:SetPoint("TOPRIGHT", box, "TOPRIGHT", 0, 0)
        box.top:SetHeight(thick)

        box.bottom:SetColorTexture(r, g, b, a)
        box.bottom:ClearAllPoints()
        box.bottom:SetPoint("BOTTOMLEFT",  box, "BOTTOMLEFT",  0, 0)
        box.bottom:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", 0, 0)
        box.bottom:SetHeight(thick)

        box.left:SetColorTexture(r, g, b, a)
        box.left:ClearAllPoints()
        box.left:SetPoint("TOPLEFT",    box, "TOPLEFT",    0, 0)
        box.left:SetPoint("BOTTOMLEFT", box, "BOTTOMLEFT", 0, 0)
        box.left:SetWidth(thick)

        box.right:SetColorTexture(r, g, b, a)
        box.right:ClearAllPoints()
        box.right:SetPoint("TOPRIGHT",    box, "TOPRIGHT",    0, 0)
        box.right:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", 0, 0)
        box.right:SetWidth(thick)
    end

    -- Use the same per-bar icon insets that the actual bars use so the
    -- borders line up with the bar fills (the circular icon chord pushes
    -- bars inward on one side; see _ComputeOUFIconInsets).
    local inL_name   = frame._iconBarInsetLeft_name    or 0
    local inR_name   = frame._iconBarInsetRight_name   or 0
    local inL_health = frame._iconBarInsetLeft_health  or 0
    local inR_health = frame._iconBarInsetRight_health or 0
    local inL_power  = frame._iconBarInsetLeft_power   or 0
    local inR_power  = frame._iconBarInsetRight_power  or 0

    -- Re-anchor the name strip background to match the name chord inset.
    -- Single-anchor + SetSize keeps the non-icon edge inheriting the
    -- frame's snapped pixel (see Health/Power anchoring rationale).
    if frame._oufNameBarBg then
        frame._oufNameBarBg:ClearAllPoints()
        -- v90.4: anchor side by ICON side (see GetOUFBarAnchorSide).
        local nameAnchor = BF:GetOUFBarAnchorSide(frame, inL_name)
        frame._oufNameBarBg:SetPoint(nameAnchor, frame, nameAnchor, 0, 0)
        frame._oufNameBarBg:SetSize(BF:PixelRound(barW - inL_name - inR_name), nameH)
    end

    -- Icon cutout mask: size and anchor to the visible circular icon so
    -- the bar textures get a clean cutout instead of bleeding past the
    -- icon's curved edge (only the chord-inset rectangle gets clipped
    -- otherwise, which can leave a sliver of bar fill showing through).
    -- Active only when icon is shown AND circular AND not in model style;
    -- otherwise the mask is hidden so it has no visible effect.
    local mask = frame._oufIconCutoutMask
    if mask then
        local iconShown = frame._iconFrame and frame._iconFrame:IsShown()
        local iconShape = p.iconShape or "circular"
        local iconStyle = p.iconStyle or "classicon"
        local maskOn = iconShown and iconShape == "circular" and iconStyle ~= "model"
        if maskOn then
            -- The mask texture (Media\IconCutoutMask.tga) is 256x256 with
            -- a transparent disc of diameter 208 px (81.25% of the texture
            -- width) centered on an opaque field. The opaque border is
            -- needed because the bar textures extend past the icon, and
            -- with CLAMP wrap modes the mask reads its edge alpha past
            -- the texture extent — so we need that edge alpha to be
            -- opaque (keep bar visible) rather than transparent (erase
            -- bar). To make the transparent disc cover the iconFrame on
            -- screen, the mask must be sized larger than iconFrame by
            -- the inverse ratio (256/208 = 1.231). Centered on iconFrame.
            local iconFrameSz = frame._iconFrame:GetWidth() or 0
            if iconFrameSz < 1 then iconFrameSz = 1 end
            local DISC_TO_TEXTURE_RATIO = 256 / 208
            local maskSz = iconFrameSz * DISC_TO_TEXTURE_RATIO
            mask:SetSize(maskSz, maskSz)
            mask:ClearAllPoints()
            mask:SetPoint("CENTER", frame._iconFrame, "CENTER", 0, 0)
            mask:Show()
        else
            mask:Hide()
        end
    end

    -- ── Rounded border mode: ONE composite ring replaces all three
    -- square boxes (and the edge-dedup rules become moot). The common
    -- work above (frame levels, name strip re-anchor, icon cutout mask
    -- sizing) still applies in both modes.
    local borderMode = BF:GetOUFBorderMode()
    if BF.IsRoundedBorderStyle(borderMode) then
        fb.name._wantShown   = false
        fb.health._wantShown = false
        fb.power._wantShown  = false
        fb.name:Hide()
        fb.health:Hide()
        fb.power:Hide()
        -- v90 (owner report: "toggling off Enable Border doesn't hide
        -- the unit frame borders"): the rounded outline now honors the
        -- master enable. Global Styles' Enable Border fans out to the
        -- three <bar>BorderEnabled keys, so the ring draws while ANY of
        -- them is on and hides when all three are off — mirroring the
        -- raid rule (Container.lua: `enableBorder and rounded` — border
        -- off means no ring AND no rounding).
        if BF:IsOUFBorderEnabled() then
            BF:_ApplyOUFRoundedFrameBorder(frame, pf, borderMode)
        else
            BF:_HideOUFRoundedFrameBorder(frame)
        end
        return
    end
    -- Square: hide the ring/mask/per-bar kits if a previous rounded
    -- mode showed them. Hidden mask = masking off (oUF cutout-mask
    -- precedent); attachments stay in place for the next rounded switch.
    BF:_HideOUFRoundedFrameBorder(frame)

    ApplyBox(fb.name,   "nameBorderEnabled",   "nameBorderThickness",   "nameBorderColor",   0,                nameH,      inL_name,   inR_name)
    ApplyBox(fb.health, "healthBorderEnabled",  "healthBorderThickness", "healthBorderColor", -nameH,           healthDrawn, inL_health, inR_health)

    -- For the player frame, the power border is managed entirely by
    -- oUF_PowerBar.lua (ApplyOUFPowerBarLayout). Skip it here.
    local altBar = frame.__unit == "player" and BF.oufAltPowerBar
    local altAttached = altBar and altBar:GetParent() == frame
    if frame.__unit == "player" then
        -- Power border handled by oUF_PowerBar.lua; do not touch fb.power.
    elseif altAttached and p.showAltPowerBar and not p.altPowerBarDetached then
        local show = p.powerBorderEnabled == true
        fb.power._wantShown = show
        if show then
            BF:RefreshPixelSize()
            local thick = BF:PixelsToUI(p.powerBorderThickness or 1)
            -- Compensate for the frame's own scale so borders don't shrink
            -- below 1 physical pixel on scaled-down frames.
            local fScale = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
            if fScale > 0 and fScale < 1 then
                thick = thick / fScale
            end
            -- Enforce a minimum of 1 physical pixel.
            local minThick = BF:PixelsToUI(1)
            if fScale > 0 and fScale < 1 then minThick = minThick / fScale end
            if thick < minThick then thick = minThick end
            local bc    = p.powerBorderColor or { r=0, g=0, b=0, a=1 }
            local r, g, b, a = bc.r or 0, bc.g or 0, bc.b or 0, bc.a or 1
            -- Cache the border color so UpdateOUFAltPowerBar can restore
            -- the power-top edge on transitions without re-running layout.
            fb.power._cachedColor = { r=r, g=g, b=b, a=a }
            -- Use the same icon insets as the power bar so the border
            -- lines up with the bar's left/right edges.
            local inL_pwr = frame._iconBarInsetLeft_power  or 0
            local inR_pwr = frame._iconBarInsetRight_power or 0
            -- Anchor only to the non-icon side with offset 0 + SetSize.
            fb.power:ClearAllPoints()
            -- v90.4: anchor side by ICON side (see GetOUFBarAnchorSide).
            if BF:GetOUFBarAnchorSide(frame, inL_pwr) == "TOPRIGHT" then
                fb.power:SetPoint("TOPRIGHT", altBar, "BOTTOMRIGHT", 0, 0)
            else
                fb.power:SetPoint("TOPLEFT",  altBar, "BOTTOMLEFT",  0, 0)
            end
            fb.power:SetSize(BF:PixelRound(barW - inL_pwr - inR_pwr), powerH)
            fb.power:Show()
            fb.power.top:SetColorTexture(r, g, b, a)
            fb.power.top:ClearAllPoints()
            fb.power.top:SetPoint("TOPLEFT",  fb.power, "TOPLEFT",  0, 0)
            fb.power.top:SetPoint("TOPRIGHT", fb.power, "TOPRIGHT", 0, 0)
            fb.power.top:SetHeight(thick)
            fb.power.bottom:SetColorTexture(r, g, b, a)
            fb.power.bottom:ClearAllPoints()
            fb.power.bottom:SetPoint("BOTTOMLEFT",  fb.power, "BOTTOMLEFT",  0, 0)
            fb.power.bottom:SetPoint("BOTTOMRIGHT", fb.power, "BOTTOMRIGHT", 0, 0)
            fb.power.bottom:SetHeight(thick)
            fb.power.left:SetColorTexture(r, g, b, a)
            fb.power.left:ClearAllPoints()
            fb.power.left:SetPoint("TOPLEFT",    fb.power, "TOPLEFT",    0, 0)
            fb.power.left:SetPoint("BOTTOMLEFT", fb.power, "BOTTOMLEFT", 0, 0)
            fb.power.left:SetWidth(thick)
            fb.power.right:SetColorTexture(r, g, b, a)
            fb.power.right:ClearAllPoints()
            fb.power.right:SetPoint("TOPRIGHT",    fb.power, "TOPRIGHT",    0, 0)
            fb.power.right:SetPoint("BOTTOMRIGHT", fb.power, "BOTTOMRIGHT", 0, 0)
            fb.power.right:SetWidth(thick)
        else
            fb.power:Hide()
        end
    else
        ApplyBox(fb.power,  "powerBorderEnabled",   "powerBorderThickness",  "powerBorderColor",  -(nameH+healthBand), powerH,  inL_power,  inR_power)
    end

    -- Suppress shared edges between adjacent enabled borders to avoid
    -- double-drawing where one box's bottom meets the next box's top.
    -- v85: applies at ANY thickness (was 1 only) — the border between
    -- two bars must never read double. The surviving edge is always
    -- the LOWER box's TOP edge, so mismatched per-bar thickness
    -- settings resolve to the lower bar's weight.
    local nameBarHidden = pf.showNameBar == false
    -- Rule 1: name + health both enabled → hide name bottom edge.
    -- Skip when showNameBar is off (name border is alpha-faded to 0,
    -- leaving a gap if we hide name's bottom).
    if fb.name._wantShown and fb.health._wantShown and not nameBarHidden then
        fb.name.bottom:SetColorTexture(0, 0, 0, 0)
    end
    -- Rule 2: health + power both enabled → hide health bottom edge.
    -- Skip when the power bar is detached, when showPowerBar is off
    -- (power border is alpha-faded to 0, leaving a gap if we hide
    -- health's bottom), or when the alt power bar border is actually
    -- visible between health and power (the alt bar's own border
    -- handles the health-to-alt and alt-to-power deduplication instead).
    local powerDetached = frame.__unit == "player" and BF.GetUFDetachState and BF:GetUFDetachState("playerPowerBar")
    local powerBarHidden = pf.showPowerBar == false
    local altBetween = altAttached and p.showAltPowerBar and not p.altPowerBarDetached
    -- Only skip Rule 2 when the alt border is actually visible; when the
    -- druid mana is inactive the alt border is hidden and health/power are
    -- effectively adjacent.
    local altBorderActuallyBetween = altBetween
        and p.powerBorderEnabled == true
        and altBar and altBar._border and altBar._border:IsShown()
    if fb.health._wantShown and fb.power._wantShown and not powerDetached and not powerBarHidden and not altBorderActuallyBetween then
        fb.health.bottom:SetColorTexture(0, 0, 0, 0)
    end
    -- Rule 3: When the alt power bar is attached between health and power
    -- AND its border is actually visible (druid mana active), suppress
    -- the health bottom (alt bar top handles it) and suppress the power
    -- bar top edge (alt bar bottom handles it).
    -- When the alt bar border is hidden (druid mana inactive), the alt bar
    -- collapses and health/power are effectively adjacent again — Rule 2
    -- (above) handles that case.
    local altBorderVisible = altAttached and p.showAltPowerBar and not p.altPowerBarDetached
        and p.powerBorderEnabled == true
        and altBar and altBar._border and altBar._border:IsShown()
    if altBorderVisible then
        -- Health-to-alt: suppress health bottom edge
        if fb.health._wantShown then
            fb.health.bottom:SetColorTexture(0, 0, 0, 0)
        end
        -- Alt-to-power: suppress power bar top edge
        if fb.power._wantShown then
            fb.power.top:SetColorTexture(0, 0, 0, 0)
        end
    end
end

-- ============================================================
-- SetClassIcon
-- Sets tex to the WoW class icon for className.
-- Tries the atlas path first (same as old UnitFrames_Shared.lua),
-- falls back to the class-circles sheet.
-- Returns true on success, false/nil if className is unknown.
-- ============================================================
local _classIconCoords = {
    WARRIOR       = { 0,    0.25,  0,    0.25  },
    MAGE          = { 0.25, 0.5,   0,    0.25  },
    ROGUE         = { 0.5,  0.75,  0,    0.25  },
    DRUID         = { 0.75, 1.0,   0,    0.25  },
    HUNTER        = { 0,    0.25,  0.25, 0.5   },
    SHAMAN        = { 0.25, 0.5,   0.25, 0.5   },
    PRIEST        = { 0.5,  0.75,  0.25, 0.5   },
    WARLOCK       = { 0.75, 1.0,   0.25, 0.5   },
    PALADIN       = { 0,    0.25,  0.5,  0.75  },
    DEATHKNIGHT   = { 0.25, 0.5,   0.5,  0.75  },
    MONK          = { 0.5,  0.75,  0.5,  0.75  },
    DEMONHUNTER   = { 0.75, 1.0,   0.5,  0.75  },
    EVOKER        = { 0,    0.25,  0.75, 1.0   },
}
function BF:SetClassIcon(tex, className)
    if not className then return false end
    -- 12.x secrets: className (UnitClass token) can be a forbidden/secret
    -- string while tainted; indexing it (:lower) throws. Bail so the caller
    -- falls back to the portrait, exactly as Grid2 falls back to a default
    -- (GridShims.UnitClassSafe -> 'NONE'). Returning false triggers the
    -- SetPortraitTexture path in _UpdateOUFIcon.
    if not canaccessvalue(className) then return false end
    -- Prefer the per-class atlas (classicon-warrior etc.) -- same as old implementation
    local atlas = "classicon-" .. className:lower()
    local info = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas)
    if info and info.file then
        tex:SetTexture(info.file)
        tex:SetTexCoord(
            info.leftTexCoord   or 0,
            info.rightTexCoord  or 1,
            info.topTexCoord    or 0,
            info.bottomTexCoord or 1
        )
        return true
    end
    -- Fallback: class-circles sheet
    local coords = _classIconCoords[className]
    if not coords then return false end
    tex:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")
    tex:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
    return true
end

-- ============================================================
-- _UpdateOUFIcon
-- Called from Portrait.PostUpdate and from layout functions
-- whenever iconStyle or iconShape changes.
-- Routes between portrait texture, class icon texture, and model.
-- ============================================================
-- ============================================================
-- _LayoutOUFIconTextures
-- Pre-resolves ALL icon texture geometry in one pass. Anchors and
-- edge sizes depend only on profile values (style, shape, border
-- enabled, ring thickness) — never on the unit — so the event path
-- (_UpdateOUFIcon) never needs ClearAllPoints/SetPoint at all.
-- Called from _ApplyOUFIconBlock AFTER _ApplyOUFIconBorder, because
-- the inset reads frame._borderEnabled which that function stamps.
-- ============================================================
function BF:_LayoutOUFIconTextures(frame)
    local iconFrame = frame._iconFrame
    if not iconFrame then return end
    local p        = BF.ufDB.profile
    local style    = p.iconStyle or "classicon"
    local circular = (p.iconShape or "circular") == "circular"
    local isModel  = style == "model"
    local borderEnabled = frame._borderEnabled ~= false

    -- (2026-08-24 dead-read removal: a blizzPlayerIconBorderThickness
    -- fallback arm sat in this chain — never written, no default, and the
    -- sibling resolver below already reads classIconBorderThickness alone.)
    local ringThick = p.classIconBorderThickness or 4
    -- When the border is disabled, use inset=0 so the icon fills the full frame.
    -- When enabled, inset by ringThick so the gold ring is visible around the icon.
    local inset = (borderEnabled and circular and not isModel) and ringThick or 0

    local function AnchorInset(region)
        region:ClearAllPoints()
        region:SetPoint("TOPLEFT",     iconFrame, "TOPLEFT",      inset, -inset)
        region:SetPoint("BOTTOMRIGHT", iconFrame, "BOTTOMRIGHT", -inset,  inset)
    end

    if frame._circIconMaskedCirc  then AnchorInset(frame._circIconMaskedCirc)  end
    if frame._circIconBare        then AnchorInset(frame._circIconBare)        end
    if frame._circMask            then AnchorInset(frame._circMask)            end
    if frame._squarePortraitModel then AnchorInset(frame._squarePortraitModel) end

    local sb = frame._squareBorder
    if sb then
        AnchorInset(sb)
        local thick = ringThick
        sb.top:ClearAllPoints()
        sb.top:SetPoint("TOPLEFT",  sb, "TOPLEFT",  0, 0)
        sb.top:SetPoint("TOPRIGHT", sb, "TOPRIGHT", 0, 0)
        sb.top:SetHeight(thick)
        sb.bottom:ClearAllPoints()
        sb.bottom:SetPoint("BOTTOMLEFT",  sb, "BOTTOMLEFT",  0, 0)
        sb.bottom:SetPoint("BOTTOMRIGHT", sb, "BOTTOMRIGHT", 0, 0)
        sb.bottom:SetHeight(thick)
        sb.left:ClearAllPoints()
        sb.left:SetPoint("TOPLEFT",    sb, "TOPLEFT",    0, 0)
        sb.left:SetPoint("BOTTOMLEFT", sb, "BOTTOMLEFT", 0, 0)
        sb.left:SetWidth(thick)
        sb.right:ClearAllPoints()
        sb.right:SetPoint("TOPRIGHT",    sb, "TOPRIGHT",    0, 0)
        sb.right:SetPoint("BOTTOMRIGHT", sb, "BOTTOMRIGHT", 0, 0)
        sb.right:SetWidth(thick)
    end

    -- Style/geometry changed: force the next _UpdateOUFIcon to re-run its
    -- visibility pass (the stamp is what lets event ticks skip it).
    frame._oufIconActive = nil
end

-- Events whose Portrait Override calls change neither the texture choice
-- nor the rendered content — skipped entirely once an icon is showing.
-- Plain event strings only: no unit-derived (potentially secret) values
-- are ever compared on this path.
local COSMETIC_PORTRAIT_EVENTS = {
    UNIT_FACTION    = true,
    UNIT_CONNECTION = true,
}

-- ============================================================
-- Portrait render coalescing
--
-- Portrait events arrive in BURSTS: a target swap fires oUF's ForceUpdate
-- and then UNIT_PORTRAIT_UPDATE lands moments later when the engine has the
-- real portrait ready, and PORTRAITS_UPDATED is unitless — it blasts every
-- oUF frame at once, often on the same tick as per-unit events for the
-- same frames. Each burst member used to pay a full SetPortraitTexture /
-- model:SetUnit render (~0.8 ms each, engine-side and irreducible), and a
-- multi-frame burst could stack several of those into one render frame.
--
-- So the Override no longer renders synchronously: it marks the frame
-- dirty and a shared next-tick flush renders each dirty frame exactly
-- once. Same hoisted-flush shape as the IncomingCasts module's
-- QueueReposition — steady state allocates nothing (the only allocation is
-- C_Timer's own ticker, once per burst). One frame of portrait latency is
-- imperceptible.
--
-- The settings path (_ApplyOUFIconBlock) still calls _UpdateOUFIcon
-- directly — an options change should render immediately, and it is
-- already the full-refresh caller.
-- ============================================================
local iconDirty = {}          -- [frame] = unit token at queue time (or true)
local iconFlushQueued = false

local function FlushOUFIconUpdates()
    iconFlushQueued = false
    for frame, unit in pairs(iconDirty) do
        iconDirty[frame] = nil
        -- Prefer the frame's CURRENT unit: it can legitimately change
        -- between queue and flush (target swap), and the stamped token is
        -- only the fallback. Unit tokens are plain strings, never secret.
        BF:_UpdateOUFIcon(frame, frame.__unit or (unit ~= true and unit or nil))
    end
end

function BF:_QueueOUFIconUpdate(frame, unit, event)
    if not frame then return end
    -- The cosmetic gate runs BEFORE queueing, so those events never even
    -- allocate a timer tick.
    if event and COSMETIC_PORTRAIT_EVENTS[event] and frame._oufIconActive then
        return
    end
    iconDirty[frame] = unit or frame.__unit or true
    if not iconFlushQueued then
        iconFlushQueued = true
        C_Timer.After(0, FlushOUFIconUpdates)
    end
end

-- Render path: visibility switching + content only. ALL geometry is
-- pre-resolved by _LayoutOUFIconTextures (settings apply time), and event
-- gating/coalescing happens in _QueueOUFIconUpdate — every call that
-- reaches here is meant to render.
function BF:_UpdateOUFIcon(frame, unit)
    if not frame or not unit then return end
    local iconFrame = frame._iconFrame
    if not iconFrame then return end

    local p        = BF.ufDB.profile
    local style    = p.iconStyle or "classicon"
    local circular = (p.iconShape or "circular") == "circular"
    local isModel  = style == "model"

    local maskedCirc = frame._circIconMaskedCirc
    local bare       = frame._circIconBare
    local circMask   = frame._circMask
    local model      = frame._squarePortraitModel

    local activeRegion
    if isModel then
        activeRegion = model
    elseif circular then
        activeRegion = maskedCirc
    else
        activeRegion = bare
    end
    if not activeRegion then return end

    -- Visibility pass: only when the active region changed since the last
    -- call (style/shape settings change, or first render after layout).
    -- Steady-state event ticks skip straight to the content pass.
    if frame._oufIconActive ~= activeRegion then
        local borderEnabled = frame._borderEnabled ~= false
        maskedCirc:Hide()
        bare:Hide()
        if circMask            then circMask:Hide()            end
        if model               then model:Hide()               end
        if frame._squareBorder then frame._squareBorder:Hide() end
        if frame._iconRing then
            frame._iconRing:SetShown(circular and not isModel and borderEnabled)
        end
        if isModel then
            model:Show()
        else
            activeRegion:Show()
            if activeRegion == maskedCirc and circMask then circMask:Show() end
            if not circular and borderEnabled and frame._squareBorder then
                frame._squareBorder:Show()
            end
        end
        frame._oufIconActive = activeRegion
    end

    -- Content pass.
    if isModel then
        model:SetUnit(unit)
        model:SetCamera(1)
        -- Grid2 pattern: PlayerModel can re-enable mouse on SetUnit.
        -- Force it off so the icon frame receives clicks.
        model:EnableMouse(false)
        return
    end

    if style == "classicon" then
        local _, class = UnitClass(unit)
        if UnitIsPlayer(unit) and class and BF:SetClassIcon(activeRegion, class) then
            return
        end
        -- Non-player / no class: fall through to the portrait render on the
        -- SAME texture. (The old code had a texture-swap branch here, but its
        -- wantTex expression was identical to the initial activeTex choice,
        -- so the swap could never fire — dropped, not changed.)
    end
    SetPortraitTexture(activeRegion, unit)
    if circular then
        activeRegion:SetTexCoord(0, 1, 0, 1)
    else
        activeRegion:SetTexCoord(0.15, 0.85, 0.15, 0.85)
    end
end

-- ============================================================
-- Ping Indicator (Global > Icons/Indicators): build the ping widget on
-- every unit frame and anchor the pin per the position setting.
-- Config/layout time only -- display is driven by the Blizzard
-- UnitPingIconFrameTemplate child (see BF.CreateOUFPingWidget).
-- ============================================================
-- v96: the ping MIRROR (Blizzard-receiver polling, entry resolution,
-- BF.HasPingPinEvents / BF.GetBlizzardPingIconFrame / BF:EnsurePingMirror /
-- BF:RebuildPingMirror / BF:GetPingMirrorStatus) moved to PingMirror.lua at
-- the addon root. It drives the raid/party pins too, so it cannot live in a
-- unit-frames file: with ptfEnabled off nothing here runs. What stays below
-- is unit-frame-specific -- widget construction, anchoring and /bf pingtest.

-- Builds the ping-pin widget on an oUF frame: pin texture + background
-- sub-layered below it, plus a hidden UnitPingIconFrameTemplate child
-- that receives the real UNIT_PING_PIN_* events from Blizzard code and
-- is redirected onto our textures. Idempotent. Also used lazily by
-- /bf pingtest.
function BF.CreateOUFPingWidget(self)
    if self._bfPingIndicator then return self._bfPingIndicator end
    local pingFrame = CreateFrame("Frame", nil, self)
    pingFrame:SetFrameLevel(self:GetFrameLevel() + 16)
    pingFrame:SetAllPoints(self)
    pingFrame:EnableMouse(false)
    local pingBG = BF.Texture(pingFrame, nil, "OVERLAY", nil, 1)
    pingBG:SetSize(32, 32)
    local pingTex = BF.Texture(pingFrame, nil, "OVERLAY", nil, 2)
    pingTex:SetSize(32, 32)
    pingTex:SetPoint("CENTER", self, "CENTER", 0, 0)
    pingBG:SetPoint("CENTER", pingTex, "CENTER", 0, 0)
    pingTex.Background = pingBG
    pingTex:Hide()
    pingBG:Hide()
    -- Both are plain frame-level textures, so their visibility isn't
    -- linked; mirror the pin's state onto the background.
    pingTex.PostUpdate = function(el)
        if el.Background then el.Background:SetShown(el:IsShown()) end
    end
    self._bfPingIndicator = pingTex
    self._pingFrame = pingFrame

    return pingTex
end


-- force: skip the HasPingPinEvents gate (used by /bf pingtest).
function BF:ApplyOUFPingIndicators(force)
    if not force and not BF.HasPingPinEvents() then return end
    -- v96: this function is a CONTRIBUTOR to the shared mirror, not its
    -- owner -- Initialization.lua's PEW path creates it. Anchoring changed
    -- here can change which pins exist, so still ask for a re-resolve.
    self:RebuildPingMirror()
    local p = self.ufDB.profile
    local show = force or p.oufShowPingIndicator ~= false
    local pos  = p.oufPingIndicatorPosition or "CENTER"
    local function applyOne(f)
        local el = f and f._bfPingIndicator
        if not el then return end
        if show then
            el:ClearAllPoints()
            if pos == "CLASSICON" and f._iconFrame and f._iconFrame:IsShown() then
                el:SetPoint("CENTER", f._iconFrame, "CENTER", 0, 0)
            else -- CENTER (default; CLASSICON falls back here when the
                 -- class icon is hidden; any other saved value too)
                el:SetPoint("CENTER", f, "CENTER", 0, 0)
            end
        else
            -- The isMatch callback also checks the setting, so no new
            -- pings get through while it is off.
            el:Hide()
            if el.Background then el.Background:Hide() end
        end
    end
    applyOne(self.oufPlayer)
    applyOne(self.oufTarget)
    applyOne(self.oufFocus)
    applyOne(self.oufPet)
    applyOne(self.oufTargetOfTarget)
    applyOne(self.oufFocusTarget)
    if self.oufBoss then
        for i = 1, 5 do applyOne(self.oufBoss[i]) end
    end
end

-- ------------------------------------------------------------
-- /bf pingtest support: fakes the visual result directly on the same
-- textures the real receiver drives (Ping_Frame_BG_<kit> beneath
-- Ping_Frame_<kit>, atlas-sized). No events are touched here.
-- ------------------------------------------------------------
local OUF_PING_UNIT_FRAMES = {
    player = "oufPlayer", target = "oufTarget", focus = "oufFocus",
    pet = "oufPet", targettarget = "oufTargetOfTarget",
    focustarget = "oufFocusTarget",
}

function BF:GetOUFFrameForUnit(unit)
    local key = OUF_PING_UNIT_FRAMES[unit]
    if key then return self[key] end
    local bossIdx = unit and tonumber(unit:match("^boss(%d)$"))
    if bossIdx and self.oufBoss then return self.oufBoss[bossIdx] end
end

-- Raid/party frame carrying this unit token (e.g. "raid3", "party2").
function BF:GetRaidFrameForUnit(unit)
    if not self.activeFrames then return nil end
    for f in pairs(self.activeFrames) do
        if f.unit == unit and f.pingIndicatorTex then return f end
    end
end

-- unit: oUF unit token ("player", "target", ..., "boss1"-"boss5")
-- kit : texture kit string ("Attack", "Assist", ...) or nil to clear
-- Returns true on success, or false + reason.
function BF:DebugFakePing(unit, kit)
    local f = self:GetOUFFrameForUnit(unit)
    local isRaid = false
    if not f then
        f = self:GetRaidFrameForUnit(unit)
        isRaid = f ~= nil
    end
    if not f then return false, "no frame for unit '" .. tostring(unit) .. "'" end
    local el = isRaid and f.pingIndicatorTex or BF.CreateOUFPingWidget(f)
    if kit == "status" then
        -- v96: the lookup lives in PingMirror.lua now -- go through the
        -- BF alias, not the (gone) file-local.
        local tIcon, tRecv = BF.GetBlizzardPingIconFrame("target")
        local fIcon = BF.GetBlizzardPingIconFrame("focus")
        local cvar = GetCVar and GetCVar("showPingsOnRaidFrames")
        return true, string.format(
            "blizzReceiver=%s targetIconFrame=%s focusIconFrame=%s"
            .. " mirror=%s blizzShown=%s pings seen=%d lastKit=%s"
            .. " | compact source: inGroup=%s showPingsOnRaidFrames=%s"
            .. " resolvedEntries=%d",
            tRecv and "yes" or "no", tIcon and "yes" or "no",
            fIcon and "yes" or "no", BF:GetPingMirrorStatus(),
            tostring(tIcon and tIcon:IsShown()),
            BF._pingEventsSeen or 0, tostring(BF._lastPingKit),
            tostring(IsInGroup()), tostring(cvar),
            BF._pingEntryCount or 0)
    end
    if kit then
        el:SetAtlas("Ping_Frame_" .. kit, el.useAtlasSize)
        if el.Background then
            el.Background:SetAtlas("Ping_Frame_BG_" .. kit, el.useAtlasSize)
        end
        el:Show()
        -- Re-anchor per the user's position setting (force bypasses the
        -- build gate; nothing element-related is enabled).
        if not isRaid then self:ApplyOUFPingIndicators(true) end
    else
        el:Hide()
    end
    if el.PostUpdate then el:PostUpdate(kit) end
    return true
end

-- ============================================================
-- _ApplyOUFIconBlock
-- Shared helper: applies the Global tab's Icon Style, Icon Shape,
-- icon size, border, and anchor to any unit frame's _iconFrame.
-- Called from ApplyOUFPlayerLayout and _ApplyOUFRightFrameLayout
-- so both paths are guaranteed to use identical logic.
--
-- frame   : the oUF unit frame
-- unitKey : "player", "target", "focus", "pet", "targettarget"
-- ============================================================
function BF:_ApplyOUFIconBlock(frame, unitKey)
    if not frame._iconFrame then return end
    local p        = self.ufDB.profile
    local showIcon = p.playerShowClassIcon ~= false
    frame._iconFrame:SetShown(showIcon)
    if not showIcon then return end

    local iconSz      = p.iconSize or 51
    local ringThick   = p.classIconBorderThickness or 4
    local borderOn    = p.classIconBorderEnabled ~= false
    -- Per-frame icon scale (replaces old hardcoded pet 80% scaling).
    -- boss2..5 are laid out under their unit token ("boss2"...) while the
    -- settings live in the one "boss" sub-table -- the same normalization
    -- _ApplyOUFPowerElementState / _ApplyOUFNameBarState / the border
    -- paths do. (Without it only boss1 took the Icon Scale slider.)
    local pfKey = unitKey
    if pfKey and pfKey:match("^boss%d") then pfKey = "boss" end
    local pf = p[pfKey] or {}
    local iconScale = pf.iconScale or 1.0
    if iconScale ~= 1.0 then
        iconSz    = math.floor(iconSz    * iconScale + 0.5)
        ringThick = math.floor(ringThick * iconScale + 0.5)
    end
    -- When border is disabled the ring is hidden, so the frame only needs iconSz.
    local iconFrameSz = borderOn and (iconSz + ringThick * 2) or iconSz
    -- Cache the computed size for _ComputeOUFIconInsets — it can't rely
    -- on _iconFrame:GetWidth() because SetSize doesn't flush immediately
    -- on the same tick (e.g. first layout pass after /reload returns 0),
    -- which produces a different chord value on the first pass vs the
    -- second pass with the same profile inputs.
    frame._iconFrameSz = iconFrameSz
    frame._iconFrame:SetSize(iconFrameSz, iconFrameSz)
    frame._iconFrame:ClearAllPoints()
    local opacity = p.iconOpacity
    if opacity == nil then opacity = 1.0 end
    frame._iconFrame:SetAlpha(opacity)
    local side = BF.bluzzardIconSide[unitKey] or "RIGHT"
    BF:_AnchorOUFIconFrame(frame._iconFrame, frame, side, iconFrameSz)
    BF:_ApplyOUFIconBorder(frame)
    -- Geometry is resolved ONCE here (anchors depend only on settings),
    -- so the per-event _UpdateOUFIcon below never re-anchors anything.
    BF:_LayoutOUFIconTextures(frame)
    BF:_UpdateOUFIcon(frame, frame.__unit or unitKey)
    BF:_ApplyIconClickOverrides(frame)
end

-- ============================================================
-- _ApplyIconClickOverrides
-- When the toggle is on, removes the icon from ClickCastFrames
-- so Clique / click-casting ignores it entirely — left-click
-- targets the unit and right-click opens the unit menu (the
-- *type1/*type2 defaults set at creation time).  When the
-- toggle is off, adds the icon back so Clique controls it.
-- ============================================================
function BF:_ApplyIconClickOverrides(frame)
    local icon = frame and frame._iconFrame
    if not icon then return end
    _G.ClickCastFrames = _G.ClickCastFrames or {}
    if self.ufDB.profile.iconIgnoreClickBinds then
        _G.ClickCastFrames[icon] = nil
    else
        _G.ClickCastFrames[icon] = true
    end
end

-- ============================================================
-- _ComputeOUFIconInsets
-- Computes per-bar insets based on circular icon overlap.
-- Sets _iconTextInset* and _iconBarInset* fields on the frame.
-- Returns inL_health, inR_health, inL_power, inR_power for
-- callers that need the values as locals (health/power bar anchoring).
-- Called from _ApplyOUFRightFrameLayout and boss frame layout.
-- ============================================================
function BF:_ComputeOUFIconInsets(f, nameH, healthH, powerH, altH)
    local p = self.ufDB.profile
    altH = altH or 0

    -- Zero all cached inset fields upfront.
    f._iconTextInsetLeft        = 0
    f._iconTextInsetRight       = 0
    f._iconBarInsetLeft_name    = 0
    f._iconBarInsetRight_name   = 0
    f._iconBarInsetLeft_health  = 0
    f._iconBarInsetLeft_power   = 0
    f._iconBarInsetRight_health = 0
    f._iconBarInsetRight_power  = 0
    f._iconBarInsetLeft_alt     = 0
    f._iconBarInsetRight_alt    = 0
    -- v90.4: which side the circular icon sits on, or nil when no
    -- chord is in play — consumed by GetOUFBarAnchorSide so every bar
    -- anchors to the same (non-icon) side.
    f._iconChordSide            = nil

    -- Icon must be enabled and visible.
    if not (p.playerShowClassIcon ~= false and f._iconFrame and f._iconFrame:IsShown()) then
        return 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    end

    local iconStyle = p.iconStyle or "classicon"
    local iconShape = p.iconShape or "circular"

    -- ── Model: no bar resizing ──────────────────────────────────────────
    if iconStyle == "model" then
        return 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    end

    -- ── Square: no bar resizing (edge-flush anchoring handles it) ───────
    if iconShape ~= "circular" then
        return 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    end

    -- ── Circular: chord-based per-bar insets ─────────────────────────────
    -- Use the cached iconFrameSz set by _ApplyOUFIconBlock instead of
    -- _iconFrame:GetWidth(). GetWidth can return a stale value (0 or
    -- previous size) on the same tick as SetSize, producing different
    -- chord values across layout passes with identical profile inputs —
    -- which manifests as the bar's right edge shifting 1px between
    -- consecutive layouts (e.g. after /reload or settings toggle).
    local iconR = (f._iconFrameSz or f._iconFrame:GetWidth() or 0) / 2
    -- v91: THE FRAME HEIGHT NO LONGER DEPENDS ON THE ALT POWER BAR.
    -- The attached alt bar now takes its height out of the BOTTOM of the
    -- HEALTH band instead of adding to the frame, so nameH + healthH + powerH
    -- is invariant across a shapeshift. See the band comment in
    -- ApplyOUFPlayerLayout for why that invariance is required rather than
    -- merely tidy: f is a secure unit button, f:SetSize is protected, and a
    -- form change in combat could not apply a height change at all.
    local frameH = nameH + healthH + powerH
    -- v90.10 (owner report: "when the alt power bar is enabled there is
    -- a chunk missing at the top left of the health bar top border where
    -- it meets the class icon — it does not happen when the alt power
    -- bar is off"). _AnchorOUFIconFrame centers the icon on the frame,
    -- i.e. at -(frameH/2) + iconOffsetY; ApplyOUFPlayerLayout then
    -- nudges it DOWN by altH/2 when the attached alt bar is active. This
    -- chord math never modelled that nudge, so with the alt bar shown
    -- every inset was computed against an icon altH/2 higher than the
    -- one actually on screen.
    -- The health bar's inset is measured at its TOP edge (the edge
    -- furthest from the icon center — the narrowest chord), which is
    -- exactly where the bar's end is meant to touch the icon's curve;
    -- everything below that is carved by the cutout mask. Get the center
    -- wrong downward and that one touch point is the one place a gap
    -- opens: the top-left corner of the health bar's border, precisely
    -- as reported. Model the nudge here so the chord and the mask agree.
    -- KEEP IN SYNC with the nudge in ApplyOUFPlayerLayout.
    -- v91: the `- (altH / 2)` term is GONE with the nudge it modelled. The
    -- frame no longer grows for the alt bar, so the bar block does not shift
    -- downward and the icon stays centered on a fixed frame. This also removes
    -- the last reason a form change would have to touch _iconFrame, which is a
    -- SecureUnitButtonTemplate button and therefore unmovable in combat.
    local iconCenterY = -(frameH / 2) + (p.iconOffsetY or 0)
    local overlapBase = math.max(f._iconOverlapLeft or 0, f._iconOverlapRight or 0)
    local isLeft = (f._iconOverlapLeft or 0) > 0
    f._iconChordSide = isLeft and "left" or "right"  -- v90.4

    local function chordOverlap(barTopY, barBotY)
        local farY
        if math.abs(barTopY - iconCenterY) > math.abs(barBotY - iconCenterY) then
            farY = barTopY
        else
            farY = barBotY
        end
        local dy = math.abs(farY - iconCenterY)
        if dy < iconR then
            local chord = math.sqrt(iconR * iconR - dy * dy)
            local overlap = chord - (iconR - overlapBase)
            return math.max(0, overlap)
        end
        return 0
    end

    -- v91 BAND LAYOUT, top to bottom. altH is the ACTIVE alt-bar height (0
    -- when not in form), and it is subtracted from the health bar rather than
    -- inserted between the bars: health shrinks, the alt bar occupies the
    -- vacated strip, and the power band's top and bottom never move.
    --     name    0                        -> -nameH
    --     health  -nameH                   -> -(nameH + healthH - altH)
    --     alt     -(nameH + healthH - altH)-> -(nameH + healthH)
    --     power   -(nameH + healthH)       -> -(nameH + healthH + powerH)
    local nameTop   = 0
    local nameBot   = -nameH
    local healthTop = -nameH
    local healthBot = -nameH - healthH + altH
    local powerTop  = -nameH - healthH
    local powerBot  = -nameH - healthH - powerH

    local nameOvr   = chordOverlap(nameTop, nameBot)
    local healthOvr = chordOverlap(healthTop, healthBot)
    local powerOvr  = chordOverlap(powerTop, powerBot)

    local altOvr = 0
    if altH > 0 then
        -- Sits in the strip the health bar just gave up, directly above the
        -- power band.
        local altTop = -nameH - healthH + altH
        local altBot = -nameH - healthH
        altOvr = chordOverlap(altTop, altBot)
    end

    -- Reduce alt and power insets by a small margin so those bars extend
    -- slightly under the icon, eliminating the visible gap between the
    -- straight bar edge and the curved icon.
    local iconTuck = 2
    powerOvr = math.max(0, powerOvr - iconTuck)
    altOvr   = math.max(0, altOvr   - iconTuck)

    -- Snap each inset to the physical pixel grid. The chord values from
    -- math.sqrt are sub-pixel floats; the same inset feeds both the health
    -- container's TOPRIGHT anchor (-inR_health) and the border box's SetSize
    -- (barW - inR). WoW snaps anchor offsets and rendered widths differently,
    -- so at certain bar heights the container's right edge and the border's
    -- right edge land on different physical pixels, producing a 1px health
    -- fill spill past the border. PixelRound here guarantees both consumers
    -- see the same integer-pixel value.
    nameOvr   = BF:PixelRound(nameOvr)
    healthOvr = BF:PixelRound(healthOvr)
    powerOvr  = BF:PixelRound(powerOvr)
    altOvr    = BF:PixelRound(altOvr)

    -- Cache per-bar insets on the frame.
    local maxOvr = math.max(nameOvr, healthOvr, powerOvr, altOvr)
    f._iconTextInsetLeft  = isLeft  and maxOvr or 0
    f._iconTextInsetRight = (not isLeft) and maxOvr or 0
    f._iconBarInsetLeft_name    = isLeft  and nameOvr   or 0
    f._iconBarInsetRight_name   = (not isLeft) and nameOvr   or 0
    f._iconBarInsetLeft_health  = isLeft  and healthOvr or 0
    f._iconBarInsetLeft_power   = isLeft  and powerOvr  or 0
    f._iconBarInsetRight_health = (not isLeft) and healthOvr or 0
    f._iconBarInsetRight_power  = (not isLeft) and powerOvr  or 0
    f._iconBarInsetLeft_alt     = isLeft  and altOvr or 0
    f._iconBarInsetRight_alt    = (not isLeft) and altOvr or 0

    local inL_name    = isLeft  and nameOvr   or 0
    local inR_name    = (not isLeft) and nameOvr   or 0
    local inL_health  = isLeft  and healthOvr or 0
    local inR_health  = (not isLeft) and healthOvr or 0
    local inL_power   = isLeft  and powerOvr  or 0
    local inR_power   = (not isLeft) and powerOvr  or 0
    local inL_alt     = isLeft  and altOvr    or 0
    local inR_alt     = (not isLeft) and altOvr    or 0

    return inL_name, inR_name, inL_health, inR_health, inL_power, inR_power, inL_alt, inR_alt
end


-- ============================================================
-- _ApplyOUFRaidTargetIndicator
-- Positions and sizes the RaidTargetIndicator on a frame.
-- Uses the same outer/center/inner paradigm as _AnchorOUFIconFrame.
-- Called from ApplyOUFPlayerLayout and _ApplyOUFRightFrameLayout.
-- ============================================================
function BF:_ApplyOUFRaidTargetIndicator(frame, unitKey)
    local rt = frame.RaidTargetIndicator
    if not rt then return end
    local p    = self.ufDB.profile
    local show = p.oufShowRaidTarget ~= false
    if not show then
        rt:Hide()
        return
    end
    local sz   = p.oufRaidTargetSize     or 20
    local ox   = p.oufRaidTargetOffsetX  or 0
    local oy   = p.oufRaidTargetOffsetY  or 0
    local loc  = p.oufRaidTargetLocation or "center"
    local side = BF.bluzzardIconSide[unitKey] or "LEFT"
    rt:SetSize(sz, sz)
    rt:ClearAllPoints()
    -- Mirror _AnchorOUFIconFrame exactly: outer/center/inner use the same
    -- anchor points and offsets as the class icon for this unit's side.
    if side == "LEFT" then
        if loc == "inner" then
            rt:SetPoint("RIGHT", frame, "RIGHT", 20 + ox, oy)
        elseif loc == "center" then
            rt:SetPoint("CENTER", frame, "CENTER", ox, oy)
        else -- "outer"
            rt:SetPoint("RIGHT", frame, "LEFT", 20 + ox, oy)
        end
    else -- "RIGHT"
        local oxT = -ox
        if loc == "inner" then
            rt:SetPoint("LEFT", frame, "LEFT", -20 + oxT, oy)
        elseif loc == "center" then
            rt:SetPoint("CENTER", frame, "CENTER", oxT, oy)
        else -- "outer"
            rt:SetPoint("LEFT", frame, "RIGHT", -20 + oxT, oy)
        end
    end
    -- Do NOT call rt:Show() here. oUF's RaidTargetIndicator element manages
    -- its own visibility via RAID_TARGET_UPDATE; forcing Show() during layout
    -- when no marker is set would reveal a stale/blank texture.
end

-- ============================================================
-- _ApplyOUFPhaseIndicator
-- Positions and sizes the PhaseIndicator on a frame.
-- Shown near the icon frame (top corner of the bar).
-- Called from ApplyOUFPlayerLayout and _ApplyOUFRightFrameLayout.
-- ============================================================
function BF:_ApplyOUFPhaseIndicator(frame, unitKey)
    local pi = frame.PhaseIndicator
    if not pi then return end
    local p    = self.ufDB.profile
    local sz   = 16
    local side = BF.bluzzardIconSide[unitKey] or "LEFT"
    pi:SetSize(sz, sz)
    pi:ClearAllPoints()
    -- Position the phase icon at the inner top corner of the bar, near the
    -- portrait side. Matches the position used by Blizzard's compact frames.
    if side == "LEFT" then
        pi:SetPoint("TOPRIGHT", frame, "TOPLEFT", sz * 0.5, sz * 0.5)
    else
        pi:SetPoint("TOPLEFT", frame, "TOPRIGHT", -sz * 0.5, sz * 0.5)
    end
end

-- ============================================================
-- ApplyBlizzardFrameVisibility
-- ============================================================
function BF:ApplyBlizzardFrameVisibility()
    local p = self.ufDB.profile

    if p.hideBlizzardPlayerFrame then
        if oUF and oUF.DisableBlizzard then
            oUF:DisableBlizzard('player')
        end
    end

    if p.hideBlizzardPlayerCastBar then
        if CastingBarFrame then
            CastingBarFrame:UnregisterAllEvents()
            CastingBarFrame:Hide()
        end
    else
        if CastingBarFrame then
            CastingBarFrame:Show()
        end
    end

    if p.hideBlizzardTargetFrame then
        if oUF and oUF.DisableBlizzard then
            oUF:DisableBlizzard('target')
        end
    end

    if p.hideBlizzardFocusFrame then
        if oUF and oUF.DisableBlizzard then
            oUF:DisableBlizzard('focus')
        end
    end

    if p.hideBlizzardPetFrame then
        if PetFrame then PetFrame:UnregisterAllEvents(); PetFrame:Hide() end
    end

    if p.hideBlizzardTargetOfTargetFrame then
        if TargetFrameToT then TargetFrameToT:UnregisterAllEvents(); TargetFrameToT:Hide() end
    end

    if p.hideBlizzardBossFrames then
        for i = 1, 5 do
            if oUF and oUF.DisableBlizzard then
                oUF:DisableBlizzard('boss' .. i)
            end
        end
    end
end

-- ============================================================
-- ApplyOUFVisibility
-- ============================================================
function BF:ApplyOUFVisibility()
    local p = self.ufDB.profile
    local wantPlayer = p.ptfEnabled and p.showPlayerFrame
    local wantTarget = p.ptfEnabled and p.showTargetFrame

    -- For frames that already exist, run the full layout function instead of
    -- bare Enable()/Disable(). oUF's Enable() reinstalls a secure state driver
    -- that resets the frame's anchor, so we must re-apply position afterwards.
    -- The layout functions do this correctly; bare Enable/Disable does not.
    if self.oufPlayer then
        self:ApplyOUFPlayerLayout()
    elseif wantPlayer then
        self:BuildOUFPlayerFrame()
    end

    if self.oufTarget then
        self:ApplyOUFTargetLayout()
    elseif wantTarget then
        self:BuildOUFTargetFrame()
    end

    local wantFocus = p.ptfEnabled and p.showFocusFrame
    if self.oufFocus then
        self:ApplyOUFFocusLayout()
    elseif wantFocus then
        self:BuildOUFFocusFrame()
    end

    local wantTargetOfTarget = p.ptfEnabled and p.showTargetOfTargetFrame
    if self.oufTargetOfTarget then
        self:ApplyOUFTargetOfTargetLayout()
    elseif wantTargetOfTarget then
        self:BuildOUFTargetOfTargetFrame()
    end

    local wantFocusTarget = p.ptfEnabled and p.showFocusTargetFrame
    if self.oufFocusTarget then
        self:ApplyOUFFocusTargetLayout()
    elseif wantFocusTarget then
        self:BuildOUFFocusTargetFrame()
    end

    local wantPet = p.ptfEnabled and p.showPetFrame
    if self.oufPet then
        self:ApplyOUFPetLayout()
    elseif wantPet then
        self:BuildOUFPetFrame()
    end

    local wantBoss = p.ptfEnabled and p.showBossFrames
    if self.oufBoss then
        self:ApplyOUFBossFrameLayout()
    elseif wantBoss then
        self:BuildOUFBossFrames()
    end

    -- Build the resource bar independently when the player frame is disabled.
    -- When the player frame IS enabled, BuildOUFPlayerFrame calls this itself.
    -- When it is disabled, oufPlayer is never created so we must call it here.
    if p.ptfEnabled and not wantPlayer and p.oufResourceBarEnabled then
        self:BuildOUFResourceBar()
    end

    -- Apply tiny handle after all frames are laid out, so the setting takes
    -- effect on reload even when frames start unlocked.
    if self.db.global.tinyHandle and self.ApplyTinyHandle then
        self:ApplyTinyHandle()
    end

    -- Apply saved font overrides after all frames are laid out.
    if self.RefreshOUFFonts then self:RefreshOUFFonts() end

    -- v96: which oUF pins the shared mirror collects depends on ptfEnabled and
    -- on each frame's own show flag, so ANY visibility change has to re-resolve
    -- its pin list. This is the one place every enable toggle funnels through:
    -- the per-frame layout functions do not touch the mirror, and the
    -- ApplyOUFPlayerLayout route that used to carry it is skipped entirely
    -- when oufPlayer does not exist (showPlayerFrame off). Debounced, so the
    -- toggle storms this function sees collapse into one resolve.
    if self.RebuildPingMirror then self:RebuildPingMirror() end

    -- Raid-style twins, LAST. Every f:Enable() above is RegisterUnitWatch
    -- (Libs/oUF/ouf.lua), which would fight the "visibility" state driver
    -- ApplyTwins installs on the oUF frame, so the twin pass has to run after
    -- the last build/relayout this function triggers. The two deferred
    -- C_Timer.After(0) repositions (_ApplyOUFRightFrameLayout,
    -- ApplyOUFPlayerLayout) only re-SetPoint -- they never re-Enable -- so
    -- they cannot undo the driver swap. Guarded: UnitFrames/Twins.lua loads
    -- after this file. ApplyTwins self-defers in combat.
    if self.ApplyTwins then self:ApplyTwins() end
end
BF._bluzzardStyle = BluzzardStyle

-- ============================================================
-- Options-callback forwarders
-- ============================================================
function BF:LayoutBlizzPlayerFrame()
    if self.oufPlayer then self:ApplyOUFPlayerLayout() end
end

function BF:UpdateBlizzPlayerFrame()
    local f = self.oufPlayer
    if f then f:UpdateAllElements("Manual") end
end

function BF:LayoutBlizzTargetFrame()
    if self.oufTarget then self:ApplyOUFTargetLayout() end
end

function BF:UpdateBlizzTargetFrame()
    local f = self.oufTarget
    if f then f:UpdateAllElements("Manual") end
end

function BF:LayoutBlizzFocusFrame()
    if self.oufFocus then self:ApplyOUFFocusLayout() end
end

function BF:UpdateBlizzFocusFrame()
    local f = self.oufFocus
    if f then f:UpdateAllElements("Manual") end
end

function BF:LayoutBlizzTargetOfTargetFrame()
    if self.oufTargetOfTarget then self:ApplyOUFTargetOfTargetLayout() end
end

function BF:UpdateBlizzTargetOfTargetFrame()
    local f = self.oufTargetOfTarget
    if f then f:UpdateAllElements("Manual") end
end

-- ============================================================
-- _ApplyOUFHealthBgColor
-- Sets the health bar background color on any oUF frame.
-- Called from every layout function (player, target, focus, pet, ToT, FT, boss).
-- ============================================================
function BF:_ApplyOUFHealthBgColor(f)
    if not f or not f._oufHealthBg then return end
    local p = self.ufDB.profile
    if p.oufUseCustomBackgroundColor then
        local mode = p.oufBackgroundColorMode or "static"
        if mode == "gradient" and BF.bgGradientCurve and f.__unit then
            -- Gradient mode: alpha comes from the gradient curve (per-stop
            -- alpha interpolated by health %). The frame-level SetAlpha
            -- stays at 1 so the color-baked alpha is the final value.
            local cr, cg, cb, ca = UnitHealthPercent(f.__unit, true, BF.bgGradientCurve):GetRGBA()
            f._oufHealthBg:SetColorTexture(cr, cg, cb, ca)
            f._oufHealthBg:SetAlpha(1)
            f._bf_bgGradient = true
        elseif mode == "class" then
            -- Class mode: player units get their (darkened) class color;
            -- non-player units fall back to the configured static color.
            -- Not health-% dependent, so no per-tick path -- re-applied on
            -- unit change via the Health PostUpdate (unitChanged branch).
            -- oufBackgroundAlpha slider applies in both cases.
            local alpha = p.oufBackgroundAlpha or 0.6
            local unitIsPlayer = f.__unit and (UnitIsPlayer(f.__unit)
                or (UnitInPartyIsAI and UnitInPartyIsAI(f.__unit)))
            local painted = false
            if unitIsPlayer then
                local _, className = UnitClass(f.__unit)
                -- 12.1: secret class name cannot index a table (see _GetOUFHealthColor).
                if not canaccessvalue(className) then className = nil end
                if className then
                    local c = (self.classColors and self.classColors[className])
                           or (RAID_CLASS_COLORS and RAID_CLASS_COLORS[className])
                    if c then
                        -- Always darkened (hasCustomTexture=false), matching
                        -- the raid-frame background class mode.
                        local r, g, b = self:GetClassHealthColor(c.r, c.g, c.b, false)
                        -- Background Darkening slider: multiply RGB toward
                        -- black. Player units only; the NPC fallback below is
                        -- unaffected.
                        local d = 1 - (p.oufBgClassDarken or 0)
                        f._oufHealthBg:SetColorTexture(r * d, g * d, b * d, alpha)
                        painted = true
                    end
                end
            end
            if not painted then
                local c = p.oufBackgroundColor or { r=0.08, g=0.08, b=0.08 }
                f._oufHealthBg:SetColorTexture(c.r, c.g, c.b, alpha)
            end
            f._oufHealthBg:SetAlpha(1)
            f._bf_bgGradient = nil
        else
            -- Static mode: oufBackgroundAlpha slider still applies.
            local c = p.oufBackgroundColor or { r=0.08, g=0.08, b=0.08 }
            f._oufHealthBg:SetColorTexture(c.r, c.g, c.b, p.oufBackgroundAlpha or 0.6)
            f._oufHealthBg:SetAlpha(1)
            f._bf_bgGradient = nil
        end
    else
        f._oufHealthBg:SetColorTexture(0.08, 0.08, 0.08, 0.6)
        f._oufHealthBg:SetAlpha(1)
        f._bf_bgGradient = nil
    end
end

-- _GetOUFPowerBgColor / _ApplyOUFPowerBgColor
-- Power bar background color for any oUF frame. Deliberately simpler than
-- _ApplyOUFHealthBgColor above: the power background has no class or
-- gradient mode on either this surface or the raid frames, just a static
-- color plus an opacity.
--
-- The fallback branch reproduces the 0.08/0.6 that BluzzardStyle hardcoded
-- at creation before these keys existed, so turning the toggle off restores
-- the original look exactly.
--
-- TWO BEHAVIORAL NOTES, both surfaced in the option tooltips because they
-- differ from the health background:
--   * _powerBg is SetAllPoints(Power), so it sits behind the FILL as well as
--     the empty region. The health bg is anchored to the unfilled region
--     only, which is what makes its opacity independent of the fill.
--   * _powerBg is a child of the Power StatusBar, whose own SetAlpha carries
--     oufPowerBarOpacity -- that alpha MULTIPLIES the one set here. The raid
--     frames avoid this because their power bg lives on a separate bgFrame
--     parented to the unit button rather than to the bar.
-- Re-coloring is mask-safe: _powerBg stays the same region object, so its
-- rounded-mask and per-bar border enrolment survive.
function BF:_GetOUFPowerBgColor()
    local p = self.ufDB.profile
    if p.oufUseCustomPowerBarBgColor then
        local c = p.oufPowerBarBgColor or { r=0.08, g=0.08, b=0.08 }
        return c.r, c.g, c.b, p.oufPowerBarBgAlpha or 0.6
    end
    return 0.08, 0.08, 0.08, 0.6
end

function BF:_ApplyOUFPowerBgColor(f)
    if not f or not f._powerBg then return end
    f._powerBg:SetColorTexture(self:_GetOUFPowerBgColor())
end

-- NOTE (12.1 AuraContainer): _ApplyOUFAuraElementSettings was removed.
-- PostCreateAuraButton stamps a pooled button once at spawn, but nothing
-- is baked any more: the el._bf_buttons registry gives us the button
-- enumeration the container API lacks, so BF:RestyleOUFAuraButtons
-- re-applies border (ApplyUFAuraButtonStyle), duration/swipe
-- (ApplyUFAuraCooldownStyle) and stack text (ApplyUFAuraStackTextStyle)
-- live, and BF:_ApplyOUFAuraLiveGeometry does the same for icon size /
-- spacing / max count. No /reload for any of it.

-- ── Shared drag-handle helpers ────────────────────────────────────────────────

-- _ClampTopleftToScreen: given a desired TOPLEFT position (UIParent virtual
-- coords) and the frame's visual size, returns clamped x/y that keep the
-- entire frame on screen. Called on restore so a stale or corrupted saved
-- position can never leave the frame off-screen.
function BF:_ClampTopleftToScreen(x, y, visualW, visualH)
    local screenW = GetScreenWidth()   -- UIParent virtual width
    local screenH = GetScreenHeight()  -- UIParent virtual height
    -- TOPLEFT x: must be >= 0, and frame's right edge (x + visualW) <= screenW
    x = math.max(0, math.min(x, screenW - visualW))
    -- TOPLEFT y (measured from screen BOTTOM): frame top must be <= screenH,
    -- and frame bottom (y - visualH) must be >= 0
    y = math.max(visualH, math.min(y, screenH))
    return x, y
end

-- _SnapHandle: pin the visual handle above the frame's anchor.
-- The anchor is a 1x1 invisible frame at the frame's TOPLEFT.
-- The handle is parented to UIParent (scale=1) and sits 2px above the anchor.
-- Handle width matches the frame's visual width (logical * scale).
function BF:_SnapHandle(handle, frame)
    local anchor = frame._anchor
    if not anchor then return end
    handle:ClearAllPoints()
    handle:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 2)
    if self.db and self.db.global and self.db.global.tinyHandle then
        handle:SetWidth(5)
        handle:SetHeight(5)
    else
        local visualW = frame:GetWidth() * (frame:GetScale() or 1.0)
        handle:SetWidth(visualW)
        handle:SetHeight(14)
    end
end

-- _BuildDragHandle(f, unitKey, label)
-- Follows the EXACT same pattern as the raid/party anchor+handle system:
--
--   anchor  : 1x1 invisible frame, SetClampedToScreen(true), SetMovable(true).
--             This is what actually moves and gets screen-clamped.
--   handle  : visible drag bar, parented to UIParent (NOT the anchor).
--             Pinned "BOTTOMLEFT" to anchor "TOPLEFT" so it sits above the frame.
--             Dragging the handle calls anchor:StartMoving() -- not handle:StartMoving().
--   frame   : positioned "TOPLEFT" to anchor "TOPLEFT" so it always sits below
--             the anchor regardless of frame scale.
--
-- Saved anchorX/anchorY = anchor TOPLEFT in UIParent virtual coords
-- (stored as SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", ancX, ancY) offset).
function BF:_BuildDragHandle(f, unitKey, label)
    -- Invisible 1x1 anchor: this is what moves and is clamped to screen.
    local anchor = CreateFrame("Frame", nil, UIParent)
    anchor:SetSize(1, 1)
    anchor:SetFrameStrata("MEDIUM")
    anchor:SetFrameLevel(109)
    anchor:SetMovable(true)
    anchor:SetClampedToScreen(true)
    anchor:EnableMouse(false)

    -- Visual drag handle: parented to UIParent so clamping the anchor does NOT
    -- include the handle height in the anchor's bounding rect (same as raid pattern).
    local handle = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    handle:SetFrameStrata("MEDIUM")
    handle:SetFrameLevel(110)
    handle:SetBackdrop({ bgFile  = "Interface\\Buttons\\White8x8",
                         edgeFile = "Interface\\Buttons\\White8x8", edgeSize = 1 })
    handle:SetBackdropColor(0.1, 0.3, 0.6, 0.8)
    handle:SetBackdropBorderColor(0.2, 0.5, 0.9, 1)
    handle:EnableMouse(true)
    handle:SetMovable(false)  -- handle itself does NOT move; anchor does
    handle:RegisterForDrag("LeftButton")
    local lbl = handle:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetPoint("CENTER")
    lbl:SetText(label)
    lbl:SetTextColor(1, 1, 1)

    -- Snap handle above anchor (called from OnUpdate during drag and on layout).
    local function SnapHandleToAnchor()
        handle:ClearAllPoints()
        -- Size: only recalculate if not in tiny-handle mode.
        -- In tiny mode, ApplyTinyHandle owns the size (5x5).
        if not (BF.db and BF.db.global and BF.db.global.tinyHandle) then
            local fScale = f:GetScale() or 1.0
            local visualW = f:GetWidth() * fScale
            -- When the icon is enabled and overhangs the bar, extend the handle
            -- to cover the icon area so the grab region matches the visual footprint.
            local iconOffset = 0
            local p = BF.ufDB and BF.ufDB.profile
            if p and p.playerShowClassIcon ~= false and f._iconFrame and f._iconFrame:IsShown() then
                local side = BF.bluzzardIconSide and BF.bluzzardIconSide[unitKey]
                if side == "LEFT" then
                    -- Icon overhangs left: measure how far left it extends past the bar.
                    local barLeft  = f:GetLeft()
                    local iconLeft = f._iconFrame:GetLeft()
                    if barLeft and iconLeft and iconLeft < barLeft then
                        iconOffset = barLeft - iconLeft
                        visualW = visualW + iconOffset
                    end
                elseif side == "RIGHT" then
                    -- Icon overhangs right: extend width rightward.
                    local barRight  = f:GetRight()
                    local iconRight = f._iconFrame:GetRight()
                    if barRight and iconRight and iconRight > barRight then
                        visualW = visualW + (iconRight - barRight)
                    end
                end
            end
            if visualW > 0 then
                handle:SetSize(visualW, 14)
            end
            -- Anchor: shift left by the icon overhang so the handle starts at the icon edge.
            handle:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", -iconOffset, 2)
        else
            handle:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 2)
        end
    end
    -- Expose on anchor so layout functions can call it after repositioning.
    anchor.SnapHandle = SnapHandleToAnchor

    handle:SetScript("OnDragStart", function()
        -- Move the ANCHOR (clamped), not the handle.
        anchor:StartMoving()
        anchor:SetScript("OnUpdate", SnapHandleToAnchor)
    end)
    handle:SetScript("OnDragStop", function()
        anchor:StopMovingOrSizing()
        anchor:SetScript("OnUpdate", nil)
        SnapHandleToAnchor()
        -- Save the anchor's TOPLEFT in UIParent virtual coords.
        -- The frame is pinned "TOPLEFT" to anchor "TOPLEFT", so this is also
        -- the frame's TOPLEFT -- same coordinate space as the restore SetPoint.
        local al = anchor:GetLeft()
        local at = anchor:GetTop()
        if al and at then
            BF:SetUFAnchor(unitKey, al, at)
        end
    end)
    handle:Hide()
    f._anchor = anchor
    f._handle = handle
    return handle
end

-- ============================================================
-- POWER ELEMENT GATING
-- Two per-frame toggles drive the power bar visibility:
--   pf.showPowerBar  -- StatusBar + border + layout collapse
--   pf.showPowerText -- master switch for PowerPctText / PowerValText
--
-- showPowerBar is ALPHA-ONLY (mirrors showNameBar): the bar StatusBar
-- + border fade to alpha 0 when off, but the layout slot is reserved
-- so chord math / icon insets / bar positions stay consistent.
-- showPowerText hides the % / value FontStrings when off.
-- When BOTH are off the oUF Power element is DisableElement'd
-- (events unregistered, zero CPU on UNIT_POWER_FREQUENT etc.).
-- ============================================================
function BF:_ApplyOUFPowerElementState(f, unitKey)
    if not f then return end
    local p = self.ufDB and self.ufDB.profile
    if not p then return end
    local pfKey = unitKey
    if pfKey and pfKey:match("^boss%d") then pfKey = "boss" end
    local pf = p[pfKey] or {}
    local barOn  = pf.showPowerBar  ~= false
    local textOn = pf.showPowerText ~= false

    -- Element is only DisableElement'd when BOTH the bar and the text
    -- are off (nothing left to drive). Otherwise EnableElement (no-op
    -- if already enabled) keeps the PostUpdate firing.
    if barOn or textOn then
        if f.EnableElement and f.Power then
            f:EnableElement("Power", f.__unit)
        end
    else
        if f.DisableElement and f.Power then
            f:DisableElement("Power")
        end
        -- PostUpdate doesn't fire after DisableElement, so hide the
        -- text widgets explicitly (they're FontStrings on a textFrame
        -- sibling of f.Power so Power's alpha doesn't affect them).
        if f.PowerPctText then f.PowerPctText:Hide() end
        if f.PowerValText then f.PowerValText:Hide() end
    end

    -- StatusBar + border fade by alpha. Layout slot is unchanged.
    -- For the player frame, when the bar is DETACHED the attached
    -- f.Power widget also fades to 0 (the detached pb on UIParent
    -- handles visible rendering) -- otherwise the bar would render
    -- twice. Detach is player-only so non-player frames just follow
    -- showPowerBar.
    local detached = (pfKey == "player") and BF.IsPowerBarDetached and BF:IsPowerBarDetached() or false
    local barAlpha = (barOn and not detached) and 1 or 0
    if f.Power then f.Power:SetAlpha(barAlpha) end
    local fb = f._frameBorder
    if fb and fb.power then fb.power:SetAlpha(barAlpha) end
end

-- ============================================================
-- NAME BAR GATING
-- Two per-frame toggles drive the name strip:
--   pf.showNameBar     -- alpha-only: fades the strip background +
--                         border to 0. Layout/chord math is unchanged
--                         so health and power bars stay put.
--   pf.showNameBarText -- master switch for Name / Level / Raid text
--                         widget visibility.
-- ============================================================
function BF:_ApplyOUFNameBarState(f, unitKey)
    if not f then return end
    local p = self.ufDB and self.ufDB.profile
    if not p then return end
    local pfKey = unitKey
    if pfKey and pfKey:match("^boss%d") then pfKey = "boss" end
    local pf = p[pfKey] or {}

    -- showNameBar is alpha-only: hides the strip background + border
    -- visually but leaves the layout/chord math untouched so the health
    -- and power bars don't shift. Text widget visibility is handled by
    -- _ApplyOUFNameBarTextPositions / Health PostUpdate / RaidGroupText
    -- update, which all gate on pf.showNameBarText directly.
    local barAlpha = (pf.showNameBar ~= false) and 1 or 0
    if f._oufNameBarBg then f._oufNameBarBg:SetAlpha(barAlpha) end
    local fb = f._frameBorder
    if fb and fb.name then fb.name:SetAlpha(barAlpha) end
end

-- ============================================================
-- _ApplyOUFRightFrameLayout
-- Shared layout logic for frames whose portrait overhangs the RIGHT
-- (target and focus). Called by ApplyOUFTargetLayout and
-- ApplyOUFFocusLayout with unit-specific arguments.
--
-- unitKey       : "target" or "focus"
-- oufFrame      : BF.oufTarget or BF.oufFocus
-- defaultAnchorX: fallback anchor X (handle BOTTOMLEFT in UIParent virtual coords)
-- defaultAnchorY: fallback anchor Y (handle BOTTOMLEFT in UIParent virtual coords)
-- enableKey     : profile key that gates Enable()/Disable()
-- auraPrefix    : prefix for aura profile keys ("target" or "focus")
-- postLayout    : optional function(f, p, pf) called after common layout
--                 (used by target to position dragon/rare overlays)
-- ============================================================
-- ── Buff row push ──────────────────────────────────────────────────────────────
-- Extra distance the BUFF container is pushed below the frame so a boss cast
-- bar in the "bottom" position (directly under the power bar) sits between
-- the frame and the buff row. Zero for every other unit and position. Both
-- buff-anchoring sites -- _ApplyOUFRightFrameLayout below (boss1 and the
-- other right frames) and the boss2..5 stacker in oUF_BossFrames.lua -- add
-- this to the row's Y offset, so the two can never disagree.
function BF:GetOUFBuffRowPush(auraPrefix, p)
    if auraPrefix ~= "boss" then return 0 end
    p = p or self.ufDB.profile
    if p.bossShowCastBar == false then return 0 end
    if (p.bossCastBarPosition or "below") ~= "bottom" then return 0 end
    return (p.bossCastBarGap or 0) + 2 + (p.bossCastBarHeight or 14) + 2
end

function BF:_ApplyOUFRightFrameLayout(unitKey, oufFrame, defaultAnchorX, defaultAnchorY, enableKey, auraPrefix, postLayout, postDeferredReposition)
    local f = oufFrame
    if not f then return end
    local p = self.ufDB.profile

    local pf    = p[unitKey] or {}
    local nameH = pf.nameBarHeight   or 13
    local healthH   = pf.healthBarHeight or 22
    local powerH    = pf.powerBarHeight  or 10
    local barW      = pf.frameWidth      or 156
    local scale     = pf.frameScale      or 1.0
    local alpha     = pf.frameAlpha      or 1.0

    f:SetSize(barW, nameH + healthH + powerH)
    f:SetAlpha(alpha)
    f:SetScale(scale)
    local ufAncX, ufAncY = BF:GetUFAnchor(unitKey)
    local ancX = ufAncX or pf.anchorX or defaultAnchorX
    local ancY = ufAncY or pf.anchorY or defaultAnchorY
    -- ancX/ancY are the frame/anchor TOPLEFT in UIParent virtual coords.
    -- Clamp to screen so a stale/corrupted saved value can't hide the frame.
    local visualW = barW * scale
    local visualH = (nameH + healthH + powerH) * scale
    ancX, ancY = BF:_ClampTopleftToScreen(ancX, ancY, visualW, visualH)
    -- Position the invisible anchor at the saved TOPLEFT, then pin the frame
    -- to the anchor's TOPLEFT.  This matches the raid/party anchor pattern exactly:
    -- the anchor is what moves (and is clamped); the frame follows it.
    if f._anchor then
        f._anchor:ClearAllPoints()
        f._anchor:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", ancX, ancY)
    end
    f:ClearAllPoints()
    if f._anchor then
        f:SetPoint("TOPLEFT", f._anchor, "TOPLEFT", 0, 0)
    else
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", ancX, ancY)
    end

    -- Position icon block first so overlap values are set
    BF:_ApplyOUFIconBlock(f, unitKey)

    -- Compute per-bar insets based on circular icon overlap.
    local inL_name, inR_name, inL_health, inR_health, inL_power, inR_power = BF:_ComputeOUFIconInsets(f, nameH, healthH, powerH)

    -- Health/Power bar re-anchor (height may have changed).
    -- Anchor only to the non-icon side with offset 0 and use SetSize to
    -- shrink the bar. This preserves the offset-0 inheritance that the
    -- non-chord case relies on (bar edge = frame edge, single snap),
    -- avoiding the divergent re-snap that a non-zero SetPoint offset
    -- introduces — which produced a 1px health-fill spill past the
    -- border when the circular icon was enabled.
    --
    -- Break the SetAllPoints chain (container -> clipFrame -> Health)
    -- by anchoring each link explicitly. On the first layout pass after
    -- Spawn the chain would otherwise reflect the post-Spawn full-barW
    -- dimensions, leaving the StatusBar fill texture rendered against a
    -- stale width on the first tick — producing a 1px health-fill spill
    -- past the freshly-shrunk border that only manifests after /reload
    -- (subsequent layouts see an already-in-sync chain). Explicit
    -- SetSize on each link forces an immediate width refresh.
    if f.Health then
        local barH_w = BF:PixelRound(barW - inL_health - inR_health)
        -- v90.4: anchor side by ICON side (see GetOUFBarAnchorSide).
        local anchorPt = BF:GetOUFBarAnchorSide(f, inL_health)
        local container = f._oufHealthContainer
        local clip      = f._oufHealthClipFrame
        if container then
            container:ClearAllPoints()
            container:SetPoint(anchorPt, f, anchorPt, 0, -nameH)
            container:SetSize(barH_w, healthH)

            if clip then
                clip:ClearAllPoints()
                clip:SetPoint(anchorPt, f, anchorPt, 0, -nameH)
                clip:SetSize(barH_w, healthH)
            end
            f.Health:ClearAllPoints()
            f.Health:SetPoint(anchorPt, f, anchorPt, 0, -nameH)
            f.Health:SetSize(barH_w, healthH)
        else
            f.Health:ClearAllPoints()
            f.Health:SetPoint(anchorPt, f, anchorPt, 0, -nameH)
            f.Health:SetSize(barH_w, healthH)
        end
    end
    if f.Power then
        f.Power:ClearAllPoints()
        -- v90.4: anchor side by ICON side (see GetOUFBarAnchorSide).
        local pAnchor = BF:GetOUFBarAnchorSide(f, inL_power)
        f.Power:SetPoint(pAnchor, f, pAnchor, 0, -nameH - healthH)
        f.Power:SetSize(BF:PixelRound(barW - inL_power - inR_power), powerH)
    end

    if f.Health and f.__unit then
        local r, g, b, isGradient, gradAlpha = BF:_GetOUFHealthColor(f.__unit, pf.useClassColor, unitKey)
        local fillAlpha = BF:_GetOUFHealthBarFillAlpha(unitKey, isGradient, gradAlpha)
        f.Health:SetStatusBarColor(r, g, b, fillAlpha)
        f._bf_healthR, f._bf_healthG, f._bf_healthB = r, g, b
        f._bf_healthA = fillAlpha
        f._bf_healthGradient = isGradient
    end
    if f.Health then
        local hTex = (p.oufUseCustomHealthBarTexture and BF:ResolveBarTexture(p.oufHealthBarTexture)) or "Interface\\Buttons\\WHITE8X8"
        f.Health:SetStatusBarTexture(hTex)
    end
    -- Health bar background color
    BF:_ApplyOUFHealthBgColor(f)
    if f.Power and f.__unit then
        local r, g, b = BF:_GetOUFPowerColor(f.__unit, unitKey)
        f.Power:SetStatusBarColor(r, g, b)
    end
    if f.Power then
        local pTex = (p.oufUseCustomPowerBarTexture and BF:ResolveBarTexture(p.oufPowerBarTexture)) or "Interface\\Buttons\\WHITE8X8"
        f.Power:SetStatusBarTexture(pTex)
    end
    -- Power bar background color
    BF:_ApplyOUFPowerBgColor(f)

    BF:_ApplyOUFNameBarTextPositions(f, unitKey)

    local hFontSz = pf.healthFontSize or 8
    local pFontSz = pf.powerFontSize  or 7
    if f.HealthPctText then f.HealthPctText:SetFont(BF:GetOUFFont("oufHealthPctFont", GameFontNormalSmall:GetFont()), hFontSz, "") end
    if f.HealthValText then f.HealthValText:SetFont(BF:GetOUFFont("oufHealthValFont", GameFontNormalSmall:GetFont()), hFontSz, "") end
    if f.PowerPctText  then f.PowerPctText:SetFont(BF:GetOUFFont("oufPowerPctFont", GameFontNormalSmall:GetFont()),  pFontSz, "") end
    if f.PowerValText  then f.PowerValText:SetFont(BF:GetOUFFont("oufPowerValFont", GameFontNormalSmall:GetFont()),  pFontSz, "") end
    BF:_ApplyOUFBarTextPositions(f, unitKey)

    if f._handle then
        if f._anchor and f._anchor.SnapHandle then f._anchor.SnapHandle() end
        local locked = self.db.global.locked
        if locked == nil then locked = true end
        f._handle:SetShown(not locked)
        f:SetMovable(not locked)
    end

    -- Unit-specific post-layout (dragon overlays, etc.)
    if postLayout then postLayout(f, p, pf) end

    -- oUF Buffs. v67: size/spacing/max are no longer baked-at-spawn --
    -- _ApplyOUFAuraLiveGeometry pushes them to the engine here and returns the
    -- effective values, so the wrap-width maths below uses this pass's numbers.
    if f.Buffs then
        local show   = pf[auraPrefix.."ShowBuffs"] ~= false
        local perRow = pf[auraPrefix.."BuffsPerRow"] or 8
        local offX   = pf[auraPrefix.."BuffOffsetX"] or 0
        local offY   = (pf[auraPrefix.."BuffOffsetY"] or 0)
                     - BF:GetOUFBuffRowPush(auraPrefix, p)
        local sz, spacing = BF:_ApplyOUFAuraLiveGeometry(f.Buffs, pf, auraPrefix, "Buff")
        f.Buffs:SetFlowLayoutMaximumLineSize(perRow * (sz + spacing))
        f.Buffs:ClearAllPoints()
        f.Buffs:SetPoint("TOPLEFT", f, "BOTTOMLEFT", offX, offY)
        f.Buffs._bf_userShown = show
    end

    -- oUF Debuffs (same model as Buffs above)
    if f.Debuffs then
        local show   = pf[auraPrefix.."ShowDebuffs"] ~= false
        local perRow = pf[auraPrefix.."DebuffsPerRow"] or 8
        local offX   = pf[auraPrefix.."DebuffOffsetX"] or 0
        local offY   = pf[auraPrefix.."DebuffOffsetY"] or 0
        local sz, spacing = BF:_ApplyOUFAuraLiveGeometry(f.Debuffs, pf, auraPrefix, "Debuff")
        f.Debuffs:SetFlowLayoutMaximumLineSize(perRow * (sz + spacing))
        f.Debuffs:ClearAllPoints()
        f.Debuffs:SetPoint("BOTTOMLEFT", f, "TOPLEFT", offX, offY)
        f.Debuffs._bf_userShown = show
    end

    if f.Buffs or f.Debuffs then
        BF.UpdateOUFAuraFilters(f)  -- applies show/hide (+ filters)
        if f.Buffs and f.Buffs.ForceUpdate then f.Buffs:ForceUpdate() end
        if f.Debuffs and f.Debuffs.ForceUpdate then f.Debuffs:ForceUpdate() end
    end

    BF:_ApplyOUFFrameBorder(f)
    BF:_ApplyOUFRaidTargetIndicator(f, unitKey)
    BF:_ApplyOUFPhaseIndicator(f, unitKey)

    -- Power element + border gating (per-frame Show Power Bar toggle).
    -- Runs AFTER _ApplyOUFFrameBorder so the Hide() on fb.power wins
    -- over ApplyBox's re-show inside _ApplyOUFFrameBorder.
    BF:_ApplyOUFPowerElementState(f, unitKey)
    -- Name bar strip + text gating (per-frame Show Name Bar / Show
    -- Name Bar Text toggles). Same pattern: runs after frame border.
    BF:_ApplyOUFNameBarState(f, unitKey)

    -- Raid-style twin: this frame's visibility belongs to the secure state
    -- driver ApplyTwins installs, and Enable is literally RegisterUnitWatch
    -- (Libs/oUF/ouf.lua), which would clobber it. Every options setter reaches
    -- this function -- not just ApplyOUFVisibility -- so the skip has to live
    -- here. IsTwinActive is a pure settings read and returns false for the
    -- units that have no twin (pet, targettarget, focustarget); Twins.lua
    -- loads after this file, hence the guard.
    local twinOwns = self.IsTwinActive and self:IsTwinActive(unitKey)
    if not twinOwns then
        if p[enableKey] then f:Enable() else f:Disable() end
    elseif UnitWatchRegistered(f) and self.ApplyTwins then
        -- Twin on but the unit watch is still installed: either the driver was
        -- never set (frame built after ApplyOUFVisibility ran) or something
        -- re-Enabled the frame. Hand it back to the twin pass.
        self:ApplyTwins()
    end

    -- Re-apply position (anchor then frame) so oUF's secure state driver
    -- cannot override our placement.
    if f._anchor then
        f._anchor:ClearAllPoints()
        f._anchor:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", ancX, ancY)
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", f._anchor, "TOPLEFT", 0, 0)
    else
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", ancX, ancY)
    end
    C_Timer.After(0, function()
        if InCombatLockdown() then return end
        if not f:GetParent() then return end
        if f._anchor then
            f._anchor:ClearAllPoints()
            f._anchor:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", ancX, ancY)
            f:ClearAllPoints()
            f:SetPoint("TOPLEFT", f._anchor, "TOPLEFT", 0, 0)
        else
            f:ClearAllPoints()
            f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", ancX, ancY)
        end
        -- Post-deferred-reposition hook: runs AFTER the shared helper has
        -- re-pinned the frame to anchor TOPLEFT in this deferred closure,
        -- for a caller that positions the frame away from that pin. (The
        -- boss column used it for a grow-direction offset; boss1 sits at
        -- the anchor for every direction now, so no caller passes one
        -- today.)
        if postDeferredReposition then
            postDeferredReposition(f)
        end
        if f._anchor and f._anchor.SnapHandle and f._handle then
            f._anchor.SnapHandle()
        end
    end)

    -- Re-anchor absorb/overshield/heal prediction overlays after bar resize.
    if self.ApplyOUFAbsorbLayout then self:ApplyOUFAbsorbLayout(oufFrame) end

    -- Refresh the setup-mode test frame for this unit so it stays in sync
    -- with any size/scale/position changes applied above.
    if self._ufTestFrames and self._ufTestFrames[unitKey] then
        local g = self.db.global
        if g.setupModeActive then
            self:ShowUFTestFrames()
        end
    end
end

-- ============================================================
-- Reload prompt
-- ============================================================
StaticPopupDialogs["BUZZARDFRAMES_RELOAD_UI"] = {
    text      = "BuzzardFrames: Reload UI to apply frame visibility changes?",
    button1   = "Reload Now",
    button2   = "Later",
    OnAccept  = function() ReloadUI() end,
    timeout   = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- ============================================================
-- oUF:Spawn wrapper — REMOVED in v67 (oUF 14.0.0)
--
-- It did exactly two things, and 14.0.0 now does both itself, so the
-- wrapper had become a no-op re-parent plus a duplicate SetRolesets call
-- on every spawn:
--   1. Re-parent to UIParent. Upstream used to parent spawned frames to a
--      PetBattleFrameHider state driver, which hid our unit frames during
--      pet battles. That frame is DELETED in 14.0.0 and `oUF:Spawn` now
--      creates the object on UIParent directly (Libs/oUF/ouf.lua).
--   2. SetRolesets. The library applies the same arenaFrames/unitFrames
--      split, off the same `unit:match('arena%d?')` test, immediately
--      after creating the frame.
--
-- The method guard the wrapper carried (`if object.SetRolesets then`) is
-- also moot: it existed because the API is absent on 12.0.7, and this
-- addon is 12.1-only from v67. Note the library calls it UNGUARDED, so a
-- guard here could not have protected 12.0.7 anyway.
--
-- The `oUF:DisableBlizzard` wrapper below is a different matter and STAYS
-- — it carries per-frame profile gating that upstream has no notion of.
-- ============================================================

-- ============================================================
-- oUF:DisableBlizzard guard
-- ============================================================
do
    local origDisableBlizzard = oUF.DisableBlizzard
    oUF.DisableBlizzard = function(self, unit)
        if unit == 'player' then
            if not BF.ufDB or not BF.ufDB.profile.hideBlizzardPlayerFrame then return end
        elseif unit == 'target' then
            if not BF.ufDB or not BF.ufDB.profile.hideBlizzardTargetFrame then return end
        elseif unit == 'focus' then
            if not BF.ufDB or not BF.ufDB.profile.hideBlizzardFocusFrame then return end
        elseif unit == 'pet' then
            if not BF.ufDB or not BF.ufDB.profile.hideBlizzardPetFrame then return end
        elseif unit == 'targettarget' then
            if not BF.ufDB or not BF.ufDB.profile.hideBlizzardTargetOfTargetFrame then return end
        elseif unit == 'boss1' or unit == 'boss2' or unit == 'boss3' or unit == 'boss4' or unit == 'boss5' then
            if not BF.ufDB or not BF.ufDB.profile.hideBlizzardBossFrames then return end
        end
        return origDisableBlizzard(self, unit)
    end
end

-- ============================================================
-- /bf oufauras — aura container state probe (debug-gated)
-- Read-only dump of the live per-frame aura container state, for
-- diagnosing hostility-dependent display issues (e.g. debuffs on
-- friendly targets). Prints ONLY non-secret widget state: filters,
-- shown/enabled flags, pool sizes and shown-button counts.
-- ============================================================
function BF:_DebugOUFAuraState()
    local function dump(label, f)
        if not f then print("  " .. label .. ": no frame"); return end
        local unit = f.__unit
        print(string.format(
            "  %s unit=%s exists=%s attack=%s assist=%s visible=%s conn=%s",
            label, tostring(unit), tostring(unit and UnitExists(unit)),
            tostring(unit and UnitCanAttack("player", unit)),
            tostring(unit and UnitCanAssist and UnitCanAssist("player", unit)),
            tostring(unit and UnitIsVisible(unit)),
            tostring(unit and UnitIsConnected(unit))))
        for _, kind in ipairs({ "Buffs", "Debuffs" }) do
            local el = f[kind]
            if el then
                local gk = el._bf_groupKey
                local okc, poolN = pcall(el.GetAuraGroupFrameCount, el, gk)
                local okU, cu = pcall(el.GetUnit, el)
                local okE, en = pcall(el.IsEnabled, el)
                local regN = el._bf_buttons and #el._bf_buttons or 0
                -- v96: the old btnsShown count is GONE. An aura button's
                -- shown state is a secret aspect once auras are secret, so
                -- counting it was meaningless (or worse) in exactly the case
                -- this probe exists for -- friendly players. Nothing here
                -- reads engine aura state any more; the group set and the
                -- active group are addon-side facts.
                print(string.format(
                    "    %s: groups=%d active=%s IsShown=%s enabled=%s"
                    .. " unit=%s pool=%s reg=%d userShown=%s maxN=%s",
                    kind, el._bf_groupKeys and #el._bf_groupKeys or 0,
                    tostring(el._bf_activeGK),
                    tostring(el:IsShown()), okE and tostring(en) or "?",
                    okU and tostring(cu) or "?", okc and tostring(poolN) or "?",
                    regN, tostring(el._bf_userShown),
                    tostring(el._bf_maxN)))
            else
                print("    " .. kind .. ": nil")
            end
        end
    end
    print("|cffd3ff7dBuzzardFrames:|r oUF aura container state")
    dump("player", self.oufPlayer)
    dump("target", self.oufTarget)
    dump("focus",  self.oufFocus)
end

-- ============================================================
-- /bf ufrects -- bar/border rectangle probe (debug-gated)
-- Read-only dump of the resolved rects of every bar, kit rect and
-- attached widget on the player/target/focus frames, for diagnosing
-- alignment issues (e.g. a power bar whose edges do not match the
-- health bar's). Out-of-combat use; prints plain numbers.
-- ============================================================
function BF:_DebugUFRects()
    local function line(tag, r)
        if not r then print("    " .. tag .. ": nil"); return end
        local ok, l, b, w, h = pcall(function()
            return r:GetLeft(), r:GetBottom(), r:GetWidth(), r:GetHeight()
        end)
        if not ok or not l then
            print("    " .. tag .. ": <no rect>")
            return
        end
        local shown = r.IsShown and r:IsShown()
        -- v90.2: frame level appended (level-inversion diagnosis — a
        -- fill chain above its border host renders fill-over-border).
        local lvl = r.GetFrameLevel and r:GetFrameLevel()
        print(string.format(
            "    %s: L=%.2f R=%.2f B=%.2f T=%.2f w=%.2f h=%.2f shown=%s lvl=%s",
            tag, l, l + (w or 0), b, b + (h or 0), w or 0, h or 0,
            tostring(shown), tostring(lvl)))
    end
    local function dumpFrame(label, f)
        if not f then print("  " .. label .. ": no frame"); return end
        print("  " .. label .. ":")
        line("frame", f)
        line("nameBg", f._oufNameBarBg)
        line("healthContainer", f._oufHealthContainer)
        line("healthBar", f.Health)
        line("powerBar", f.Power)
        line("powerBg", f._powerBg)
        local rects = f._oufBarKitRects
        if rects then
            for slot, pair in pairs(rects) do
                line("kit." .. slot .. ".clip", pair.clip)
                line("kit." .. slot .. ".ext", pair.ext)
                local kit = pair.ext._bfRoundKit
                if kit then
                    line("kit." .. slot .. ".edgeHost", kit.edgeHost)
                    print("    kit." .. slot .. ".geom=" ..
                        tostring(kit._bf_geom) .. " cmaskGeom=" ..
                        tostring(kit._bf_cmaskGeom))
                end
            end
        end
    end
    print("|cffd3ff7dBuzzardFrames:|r UF rects")
    dumpFrame("player", self.oufPlayer)
    dumpFrame("target", self.oufTarget)
    dumpFrame("focus",  self.oufFocus)
    print("  player extras:")
    line("altPowerBar", self.oufAltPowerBar)
    line("resourceBar", self.oufResourceBar)
    line("detachedPowerBar", self.oufDetachedPowerBar)
    local pb = self.oufDetachedPowerBar
    if pb and pb._bfRoundKit then
        print("    detachedPB.geom=" .. tostring(pb._bfRoundKit._bf_geom))
    end
end

-- ============================================================
-- oUF factory hook
-- ============================================================
-- RefreshOUFFonts
-- Applies the global / per-element font overrides to every active
-- oUF unit frame without touching layout or positions.
-- ============================================================
function BF:RefreshOUFFonts()
    local p = self.ufDB and self.ufDB.profile
    if not p then return end

    -- v61: respect the master toggle. When Adjust Fonts is OFF this
    -- refresher must not touch anything — the layout functions restore
    -- the stock per-element fonts via GetOUFFont (which returns each
    -- call site's own default), and the options toggle triggers a full
    -- relayout for exactly that reason. The old code kept applying
    -- oufGlobalFont here even with the toggle off, re-overriding the
    -- fonts the layouts had just restored.
    if p.oufAdjustFonts == false then return end

    local separate = p.oufSeparateFonts == true

    -- Resolve a font key to a file path.
    -- When separate fonts are off, everything uses oufGlobalFont.
    -- When separate fonts are on, per-element key takes priority,
    -- falling back to oufGlobalFont, then the addon default.
    -- v61: unset keys resolve to the ADDON DEFAULT font instead of
    -- "keep whatever is currently applied" — the dropdowns display
    -- "PT Sans Narrow" for unset keys (getFont in the options), so
    -- what the Fonts page shows is now exactly what renders. This is
    -- what made per-element fonts "only change when re-selected":
    -- toggling Separate Fonts on/off left elements on their previous
    -- font because unset keys resolved to nil (= no-op).
    local function resolve(perElementKey)
        local name
        if separate and perElementKey then
            name = p[perElementKey]
        end
        if not name or name == "" then
            name = p.oufGlobalFont
        end
        if not name or name == "" then
            name = "PT Sans Narrow"
        end
        return self:ResolveFontPath(name)
    end

    local nameFont       = resolve("oufNameFont")
    local levelFont      = resolve("oufLevelFont")
    local healthPctFont  = resolve("oufHealthPctFont")
    local healthValFont  = resolve("oufHealthValFont")
    local powerPctFont   = resolve("oufPowerPctFont")
    local powerValFont   = resolve("oufPowerValFont")
    local altPowerPctFont = resolve("oufAltPowerPctFont")
    local altPowerValFont = resolve("oufAltPowerValFont")

    -- Helper: change only the font face on a FontString, preserving size and flags.
    local function applyFont(fs, fontPath)
        if not fs or not fontPath then return end
        local _, sz, flags = fs:GetFont()
        if sz then
            fs:SetFont(fontPath, sz, flags or "")
        end
    end

    -- Iterate all oUF unit frames
    local frames = {}
    if self.oufPlayer         then frames[#frames+1] = self.oufPlayer end
    if self.oufTarget         then frames[#frames+1] = self.oufTarget end
    if self.oufFocus          then frames[#frames+1] = self.oufFocus end
    if self.oufPet            then frames[#frames+1] = self.oufPet end
    if self.oufTargetOfTarget then frames[#frames+1] = self.oufTargetOfTarget end
    if self.oufFocusTarget    then frames[#frames+1] = self.oufFocusTarget end
    if self.oufBoss then
        for i = 1, 5 do
            if self.oufBoss[i] then frames[#frames+1] = self.oufBoss[i] end
        end
    end

    -- Castbars follow the GLOBAL font (no per-element key).
    local castbarFont = resolve(nil)

    for _, f in ipairs(frames) do
        applyFont(f.Name,          nameFont)
        applyFont(f.Level,         levelFont)
        applyFont(f.DeadText,      healthPctFont)
        applyFont(f.HealthPctText, healthPctFont)
        applyFont(f.HealthValText, healthValFont)
        applyFont(f.PowerPctText,  powerPctFont)
        applyFont(f.PowerValText,  powerValFont)
        -- v61: previously missed by this refresher —
        applyFont(f.RaidGroupText, nameFont)
        local cb = f.Castbar
        if cb then
            applyFont(cb.Text, castbarFont)
            applyFont(cb.Time, castbarFont)
        end
    end

    -- Alt power bar (standalone, not a child of a unit frame)
    local mb = self.oufAltPowerBar
    if mb then
        applyFont(mb._pctText, altPowerPctFont)
        applyFont(mb._valText, altPowerValFont)
    end

    -- Detached power bar texts (v61: previously missed — its layout
    -- applies the global font, but font changes without a relayout
    -- never reached it).
    local pb = self.oufDetachedPowerBar
    if pb then
        applyFont(pb._pctText, powerPctFont)
        applyFont(pb._valText, powerValFont)
    end
end

-- ============================================================
-- /bfborders — border-mode deployment diagnostic (v62)
-- Prints which border-mode code revisions are actually LOADED and the
-- live state of every standalone-bar ring kit. Exists because the
-- castbar/detached-bar rounded borders are implemented across several
-- files — if some deployed files are stale, this shows exactly which.
-- ============================================================
BF._bfBorderRevShared = "v90"
SLASH_BFBORDERS1 = "/bfborders"
-- NEVER re-assign the SlashCmdList global itself (not even
-- `SlashCmdList = SlashCmdList or {}`). Writing to that global marks it as
-- tainted by this addon, and Blizzard's ChatEdit_ParseText reads it on EVERY
-- slash command — so from load onward every slash command runs tainted, and
-- the first one that reaches a protected function (e.g. the built-in raid
-- marker command calling SetRaidTarget) throws ADDON_ACTION_FORBIDDEN naming
-- BuzzardFrames. Adding a KEY to the table is fine; the table itself always
-- exists before addons load, so the `or {}` guard bought nothing.
SlashCmdList.BFBORDERS = function()
    if not BF:IsDebugOutputEnabled() then return end
    print("|cff00ff00BuzzardFrames border diagnostic:|r")
    print("  mode = " .. BF:GetOUFBorderMode()
        .. "  |  buff border = " .. BF:GetOUFAuraBorderStyle("buffs")
        .. "  |  debuff border = " .. BF:GetOUFAuraBorderStyle("debuffs"))
    print("  code revs: oUF_Shared=" .. (BF._bfBorderRevShared or "STALE")
        .. "  oUF_Castbar=" .. (BF._bfBorderRevCastbar or "|cffff0000STALE FILE|r")
        .. "  oUF_PowerBar=" .. (BF._bfBorderRevPowerBar or "|cffff0000STALE FILE|r"))
    local function bar(name, b, kitHost)
        if not b then print("  " .. name .. ": not built") return end
        -- v90.10: a bar whose ring is owned by a per-bar SLOT builds its
        -- kit on the slot's ext rect, not on the bar, so the caller
        -- passes that host when it applies.
        local kit = (kitHost or b)._bfRoundKit
        print(("  %s: shown=%s kit=%s ringShown=%s ringTex=%s"):format(name,
            tostring(b:IsShown()), tostring(kit ~= nil),
            kit and tostring(kit.ring:IsShown()) or "-",
            kit and tostring(kit.ring._bf_lastTex) or "-"))
    end
    bar("target castbar", BF.oufTarget and BF.oufTarget.Castbar)
    bar("focus castbar", BF.oufFocus and BF.oufFocus.Castbar)
    bar("detached power bar", BF.oufDetachedPowerBar)
    bar("resource bar", BF.oufResourceBar)
    do
        local altRects = BF.oufPlayer and BF.oufPlayer._oufBarKitRects
        local altPair  = altRects and altRects.alt
        bar("alt power bar", BF.oufAltPowerBar,
            (altPair and BF.oufAltPowerBar
                and BF.oufAltPowerBar:GetParent() == BF.oufPlayer)
                and altPair.ext or nil)
    end
end

-- ============================================================
oUF:Factory(function(_ouf)
    BF._oufReady = true
end)

