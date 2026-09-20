-- ============================================================
-- BuzzardFrames: AuraConfig.lua
-- Icon creation, style helpers, dispel curves, threshold
-- colors, and aura size/layout cache.
-- Loaded after Auras.lua defines core upvalues and state.
-- ============================================================
local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

-- Canonical default threshold colors — define once, reference everywhere.
BF.DEFAULT_THRESHOLD_COLOR   = { r = 1, g = 0.5, b = 0, a = 1 }
BF.DEFAULT_THRESHOLD2_COLOR  = { r = 1, g = 0,   b = 0, a = 1 }

local math_floor       = math.floor
local ipairs, pairs    = ipairs, pairs
local select           = select
local InCombatLockdown = InCombatLockdown
local IsInRaid         = IsInRaid
local C_Timer          = C_Timer
local wipe             = wipe
local issecretvalue    = issecretvalue or function(val) return false end
local canaccessvalue   = canaccessvalue or function(val) return true end

-- Upvalue from Auras.lua (exposed as BF.PixelPerfectSize before this file loads)
local PixelPerfectSize = BF.PixelPerfectSize
local MAX_BUFFS   = BF.MAX_BUFFS
local MAX_DEBUFFS = BF.MAX_DEBUFFS
local MAX_BIG_DEF   = 5   -- maximum pool size for Big Defensive icons
BF.MAX_BIG_DEF   = MAX_BIG_DEF

-- ============================================================
-- CREATE AURA ICON SLOT
-- Creates a single buff or debuff icon frame.
-- BACKDROP HELPER
-- ============================================================
local backdropCache = {}
local function GetBackdropTable(borderSize)
    -- Use a rounded string key so tiny floating-point differences
    -- from PixelsToUI don't create duplicate backdrop tables.
    local key = string.format("%.4f", borderSize)
    if not backdropCache[key] then
        backdropCache[key] = {
            bgFile = nil,  -- No background fill, only border edge
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            tile = false,
            tileSize = 8,
            edgeSize = borderSize,
            insets = { left = borderSize, right = borderSize, top = borderSize, bottom = borderSize },
        }
    end
    return backdropCache[key]
end

-- Wipe the backdrop cache so a UI scale change produces fresh tables.
-- Called from RefreshPixelSize (PixelPerfect.lua) via BF:RefreshPixelSize.
local function WipeBackdropCache()
    wipe(backdropCache)
end

-- only set if necessary to avoid issues
-- Returns true if the backdrop was actually changed (Grid2 pattern).
local function SetFrameBackdrop(frame, backdrop)
    if backdrop ~= frame.currentBackdrop then
        frame:SetBackdrop(backdrop)
        frame.currentBackdrop = backdrop
        return true
    end
end

-- ============================================================
-- BORDER COLOR ABSTRACTION
-- Single point of control for aura icon border coloring, exposed as
-- BF.SetIconBorderColor for the aura/indicator modules that upvalue it.
-- ============================================================
BF.SetIconBorderColor = function(icon, r, g, b, a)
    -- v62: preview icons in a ROUNDED border style route every border
    -- recolor (threshold, dispel, glow restores — all call sites) to the
    -- rounded ring instead of the hidden flat backdrop. The flag+ring are
    -- only ever set on preview icons (DummyAuras ApplyDummyIcon), so the
    -- legacy 12.0 live path costs one nil field test.
    if icon._bf_prevRoundOn and icon._bf_prevRing then
        icon._bf_prevRing:SetVertexColor(r, g, b, a or 1)
        return
    end
    icon:SetBackdropBorderColor(r, g, b, a)
end
local SetIconBorderColor = BF.SetIconBorderColor

-- v33: default border color for a feature.
-- When <feature>ColorAuraBorder is on in AuraCache, the feature's default
-- "no-threshold-override" border uses the feature's Font Color at alpha 0.8
-- (the standard border alpha). When the toggle is off, the border falls back
-- to the legacy black (0, 0, 0, 0.8).
--
-- feature must be one of: "buff", "bigDef". Other features
-- (debuff, missingRaidBuff) always use black — they either
-- don't have a *ColorAuraBorder toggle yet (debuff: out of
-- scope) or they aren't tied to a duration text Font Color (missingRaidBuff).
--
-- Returns four values r, g, b, a ready to pass to SetIconBorderColor.
function BF.GetDefaultBorderColorFor(feature, ac)
    -- v34: returns the per-feature Border Color setting (Border group in
    -- the Auras options). `ac` optional: per-frame cache for correct
    -- per-layout resolution (dummy/preview callers); defaults to the
    -- global AuraCache. The colorAuraBorder input was REMOVED (12.1 cut).
    local c = ac or BF.AuraCache
    local color = c[feature .. "BorderColor"]
    if color then
        return color.r or 0, color.g or 0, color.b or 0, color.a or 0.8
    end
    return 0, 0, 0, 0.8
end

-- ============================================================
-- BuildAuraIconFrame(parent, frameLevel)
--
-- Section-agnostic helper that builds the bare aura-icon frame
-- structure: frame + backdrop + icon texture + cooldown subframe +
-- stack count text. Identical across every aura-icon type (buff,
-- debuff, big-def, crowd-control, missing-raid-buff,
-- container).
--
-- Per-section behavior (tooltips, OVERLAY draw layer, desaturate,
-- container default border color) is applied by the calling indicator's
-- Create method or by the calling preview path after this helper
-- returns.
--
-- Mirrors Grid2's Icon_Create at modules/IndicatorIcon.lua:14-64. Like
-- Grid2's, this helper does NOT apply a defensive SetSize(24,24) before
-- cooldown creation — the icon is :Hide()-ed at the end of this function
-- and sized by ApplyAuraGeometry (or by the per-indicator Update path
-- for lazy growth slots) before being shown. The "Grid2 pattern: icon
-- must have non-zero size before cooldown creation" comment that lived
-- here pre-refactor did not match Grid2's actual code (Grid2 creates the
-- Cooldown subframe with no prior SetSize at IndicatorIcon.lua:22) and
-- the size defensiveness was unnecessary.
--
-- Tooltip OnEnter/OnLeave scripts are NOT installed here; per-indicator
-- Create methods call self:EnableFrameTooltips(icon, ...) directly
-- after BuildAuraIconFrame returns (mirrors Grid2's Icon_Create line 63
-- pattern).
-- ============================================================
function BF.BuildAuraIconFrame(parent, frameLevel)
    local icon = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    icon:EnableMouse(false)
    icon:SetMouseClickEnabled(false)
    icon:SetFrameLevel(frameLevel)

    -- Pixel-perfect border: convert 1 physical screen pixel to UI coordinates
    -- using the same PixelsToUI function that frame borders and highlight
    -- borders use (PixelPerfect.lua). This replaces the old hardcoded
    -- borderSize = 1 which produced 2+ pixel borders at most UI scales.
    local borderSize = BF:PixelsToUI(1)
    local backdrop = GetBackdropTable(borderSize)
    SetFrameBackdrop(icon, backdrop)  -- Use helper to track backdrop
    icon:SetBackdropColor(0, 0, 0, 0)  -- Transparent background
    SetIconBorderColor(icon, 0, 0, 0, 0.8)  -- Default dark border

    -- Icon texture inset by borderSize (pixel-perfect)
    local tex = BF.Texture(icon, nil, "ARTWORK")
    tex:SetPoint("TOPLEFT", borderSize, -borderSize)
    tex:SetPoint("BOTTOMRIGHT", -borderSize, borderSize)
    tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    icon.Icon = tex

    -- Cooldown swipe: FULL-BLEED, covering the backdrop border exactly.
    -- The backdrop's edge runs along the frame rect, so a frame-sized
    -- swipe lands on its outer edge with nothing beyond. Matches the flat
    -- branch of ApplyBorderInsets (Auras/ContainerFactory.lua) and Grid2
    -- (IndicatorIcons.lua:250). This builder also backs the OPTIONS
    -- PREVIEW frames, so preview and live 12.1 icons stay consistent.
    local cd = CreateFrame("Cooldown", nil, icon, "CooldownFrameTemplate")
    cd:SetAllPoints()
    cd:SetDrawSwipe(true)
    cd:SetDrawEdge(false)
    cd:SetReverse(false)
    -- Grid2 pattern: SetHideCountdownNumbers before GetCountdownFontString
    cd:SetHideCountdownNumbers(false)
    cd.timerText = cd:GetCountdownFontString()
    if cd.timerText then
        cd.timerText:SetDrawLayer("OVERLAY", 7)
        cd.timerText:SetFont("Interface\\AddOns\\BuzzardFrames\\Media\\Fonts\\RobotoCondensed-Bold.ttf", 11, "OUTLINE")
        -- Grid2 pattern: explicitly center the text. CooldownFrameTemplate's
        -- default positioning drifts off-center at small icon sizes.
        cd.timerText:ClearAllPoints()
        cd.timerText:SetPoint("CENTER", cd, "CENTER", 0, 0)
    end
    -- Store desired font settings as defaults. Layout functions stamp the
    -- real per-feature values. These fields are read by the threshold poll
    -- tick to restore text color when the threshold clears.
    cd._bf_font   = "Interface\\AddOns\\BuzzardFrames\\Media\\Fonts\\RobotoCondensed-Bold.ttf"
    cd._bf_size   = 11
    cd._bf_border = "OUTLINE"
    cd._bf_scale  = 1.0
    -- Normal (above-threshold / no-threshold) timer text color.
    cd._bf_textR  = 1
    cd._bf_textG  = 1
    cd._bf_textB  = 1
    cd._bf_textA  = 1
    icon.cooldown = cd

    -- Stack count: mirrors Grid2's IndicatorIcons approach exactly.
    local countFrame = CreateFrame("Frame", nil, icon)
    local count = countFrame:CreateFontString(nil, "OVERLAY")
    icon.count = count
    count.tframe = countFrame
    countFrame:SetAllPoints()
    countFrame:SetFrameLevel(cd:GetFrameLevel() + 2)
    -- v30: read stack text settings from the routed auraText section.
    -- GetSectionProfileForFrame resolves the correct flat for the parent
    -- frame (per-flat when the per-layout auraText toggle is ON, else
    -- the global pseudo-layout). stackText is always a sub-category
    -- table (never nil post-migration) so the metatable fallback covers
    -- any un-customized rawkeys on per-flat caches.
    local atp = BF:GetSectionProfileForFrame("auraText", parent) or {}
    local stP = atp.stackText or {}
    do
        -- Font values are LSM display names since the picker unification;
        -- ResolveFontPathOr also accepts the legacy raw paths still sitting
        -- in older profiles, so no migration is needed.
        local fontPath = BF:ResolveFontPathOr(stP.stackTextFont, "Interface\\AddOns\\BuzzardFrames\\Media\\Fonts\\RobotoCondensed-Bold.ttf")
        local fontSize = stP.stackTextSize or 9
        local fontBorder = stP.stackTextBorder or "OUTLINE"
        count:SetFont(fontPath, fontSize, fontBorder)
    end
    count:SetTextColor(1, 1, 1)
    do
        local anchor = stP.stackTextAnchor or "BOTTOMRIGHT"
        local sx = stP.stackTextX or 4
        local sy = stP.stackTextY or -3
        count:SetPoint(anchor, countFrame, anchor, sx, sy)
    end

    icon:Hide()  -- Hide AFTER setting backdrop
    return icon
end

-- Tooltip wiring moved to Auras/AuraTooltip.lua:
--   * SetIconTooltip → BF.indicatorPrototype:EnableFrameTooltips
--   * SafeSetPropagate{Mouse,Clicks} → deleted (Grid2 calls bare APIs;
--     verified safe from same secure-header init path BuzzardFrames uses)
--   * ApplyAuraTooltips(frame) → BF:DispatchTooltipSettings(frame),
--     called from scoped-refresh per-frame loops; dispatches to each
--     aura indicator's UpdateFrameSettings(frame)

-- BF:CreateAuraSlots — deleted. Aura pool creation now lives in each
-- aura indicator's :Create method (dispatched by frame:CreateIndicators
-- at BuzzardFrame_Init in BFLayout.lua:580). Per-indicator Create methods
-- live in Indicators/{DebuffIcons,BigDefIcons,
-- MissingRaidBuff,BuffsAndContainers}.lua.

-- ============================================================
-- APPLY GEOMETRY (size only, not position)
-- ============================================================
function BF:ApplyAuraGeometry(frame)
    local ac = self:GetAuraCacheForFrame(frame)
    local bSize = BF:PixelRound(ac.buffSize)
    local dSize = BF:PixelRound(ac.debuffSize)
    local bdSize = BF:PixelRound(ac.bigDefSize or 24)
    -- Pixel-perfect border: compute 1 physical pixel in the frame's own
    -- coordinate space. When a header scale is applied (scaleIndicators),
    -- GetEffectiveScale() on the frame includes that scale, so the border
    -- remains 1 physical pixel regardless of the frame scale setting.
    local frameScale = frame:GetEffectiveScale()
    local pixelSize = 768 / select(2, GetPhysicalScreenSize())
    local borderSize = (frameScale > 0) and (pixelSize / frameScale) or BF:PixelsToUI(1)
    local backdrop = GetBackdropTable(borderSize)

    if frame.buffFrames then
        for i = 1, #frame.buffFrames do
            local b = frame.buffFrames[i]
            if b then
                b:SetSize(bSize, bSize)
                if SetFrameBackdrop(b, backdrop) then
                    SetIconBorderColor(b, BF.GetDefaultBorderColorFor("buff"))
                end
                if b.Icon then
                    b.Icon:ClearAllPoints()
                    b.Icon:SetPoint("TOPLEFT", borderSize, -borderSize)
                    b.Icon:SetPoint("BOTTOMRIGHT", -borderSize, borderSize)
                end
                -- Clear Square mode flag so the next BuffIcons:Update
                -- re-applies the correct icon type (Square icons need
                -- 0,0 insets, not the bordered insets we just forced).
                b._bf_borderless = nil
            end
        end
    end
    if frame.debuffFrames then
        for i = 1, #frame.debuffFrames do
            local d = frame.debuffFrames[i]
            if d then 
                d:SetSize(dSize, dSize)
                if SetFrameBackdrop(d, backdrop) then
                    SetIconBorderColor(d, 0, 0, 0, 0.8)
                end
                if d.Icon then
                    d.Icon:ClearAllPoints()
                    d.Icon:SetPoint("TOPLEFT", borderSize, -borderSize)
                    d.Icon:SetPoint("BOTTOMRIGHT", -borderSize, borderSize)
                end
            end
        end
    end
    if frame.bigDefIcons then
        for i = 1, #frame.bigDefIcons do
            local bd = frame.bigDefIcons[i]
            bd:SetSize(bdSize, bdSize)
            if SetFrameBackdrop(bd, backdrop) then
                SetIconBorderColor(bd, BF.GetDefaultBorderColorFor("bigDef"))
            end
            if bd.Icon then
                bd.Icon:ClearAllPoints()
                bd.Icon:SetPoint("TOPLEFT", borderSize, -borderSize)
                bd.Icon:SetPoint("BOTTOMRIGHT", -borderSize, borderSize)
            end
        end
    end
    if frame.missingRaidBuffIcon then
        local mSize = BF:PixelRound(ac.missingRaidBuffSize or 12)
        frame.missingRaidBuffIcon:SetSize(mSize, mSize)
        if SetFrameBackdrop(frame.missingRaidBuffIcon, backdrop) then
            SetIconBorderColor(frame.missingRaidBuffIcon, 0, 0, 0, 0.8)
        end
        if frame.missingRaidBuffIcon.Icon then
            frame.missingRaidBuffIcon.Icon:ClearAllPoints()
            frame.missingRaidBuffIcon.Icon:SetPoint("TOPLEFT", borderSize, -borderSize)
            frame.missingRaidBuffIcon.Icon:SetPoint("BOTTOMRIGHT", -borderSize, borderSize)
        end
    end
    -- Container icons: resolve per-container size (respects override toggle
    -- and per-layout/group settings) and apply the frame-relative border.
    if frame.SF_CustomContainerIcons then
        local containers = BF.GetActiveCustomBuffContainers and BF:GetActiveCustomBuffContainers()
        local groupTypeKey = frame._bf_containerGroupTypeKey
        if containers then
            for ci, pool in pairs(frame.SF_CustomContainerIcons) do
                local c = containers[ci]
                if c then
                    -- v61: the shared resolver owns the toggle + per-Layout
                    -- lookup (BF:ResolveContainerGeometry in
                    -- AuraCustomizations.lua). This site only wants the
                    -- size, which the resolver already pixel-rounds.
                    local cSize = BF:ResolveContainerGeometry(c, groupTypeKey, ac)
                    for _, icon in ipairs(pool) do
                        icon:SetSize(cSize, cSize)
                        if SetFrameBackdrop(icon, backdrop) then
                            icon:SetBackdropColor(0, 0, 0, 0)
                        end
                        if icon.Icon and not icon._bf_borderless then
                            icon.Icon:ClearAllPoints()
                            icon.Icon:SetPoint("TOPLEFT", borderSize, -borderSize)
                            icon.Icon:SetPoint("BOTTOMRIGHT", -borderSize, borderSize)
                        end
                    end
                end
            end
        end
    end
end

-- Resolve the correct AuraCache for a frame. CFG frames use their
-- group's flat._auraCache; all other frames use BF.AuraCache.
-- Always resolved LIVE from cfgDB — never cached on the frame.
-- This eliminates staleness bugs during profile rebuilds, combat
-- transitions, and header resets. The cost is a few extra table
-- lookups per CFG frame per event (negligible for small groups).
-- Preview frames stamp _bf_auraCache directly and bypass the
-- cfgDB lookup via the fallback check.
function BF:GetAuraCacheForFrame(frame)
    if not frame then return self.AuraCache end
    -- Fallback: preview frames stamp _bf_auraCache directly.
    -- Real frames never have this set (all stamps removed).
    local ac = frame._bf_auraCache
    if ac then return ac end
    -- Live resolve from cfgDB using the parent header's group index.
    local header = frame._bf_parentHeader
    if header == nil then header = frame:GetParent() end
    if header and header.isCustomFrame then
        local gi = header.customGroupIndex
        if gi then
            local cfgp = self.cfgDB and self.cfgDB.profile
            local groups = cfgp and cfgp.customFrameGroups
            local grp = groups and groups[gi]
            local flat = grp and grp.flat
            ac = flat and flat._auraCache
            if ac then return ac end
            -- 2026-09-11 (field report 2026-09-10, reload inside a keystone):
            -- a CFG flat with no _auraCache yet used to fall through to the
            -- GLOBAL cache below. At :Create that is the wrong profile:
            -- BigDefIcons:Create read the global showBigDef, skipped the build,
            -- and the on-demand retry queues into pendingCreates, which only
            -- drains unrestricted -- so no Big Defensive (and no single buff
            -- anchored to it) on CFG frames for the whole key. Build this one
            -- scope on demand instead, the same way AddCustomFrameHeaderForGroup
            -- (BFLayout.lua) primes a missing CFG cache. Only reached while the
            -- cache is absent, so the steady-state cost is unchanged; the next
            -- UpdateAuraSizeCache still rebuilds it in place as usual.
            -- BF._RebuildAuraCacheScope: the file-local RebuildAuraCacheScope is
            -- declared far below this function, so it is read through its
            -- exported field (assigned at load, resolved here at call time).
            local rebuild = self._RebuildAuraCacheScope
            if flat and rebuild then
                ac = {}
                flat._auraCache = ac
                rebuild(ac, flat, grp)
                return ac
            end
        end
    end
    return self.AuraCache
end

-- ============================================================
-- ============================================================
-- SOLID ICON / BORDER COLOR OVERRIDES
-- Extracted to AuraCustomizations/AuraCustomizationHelpers.lua.
-- Access via BF.GetSolidIconColor, BF.GetSpellBorderColor.
-- v67: BF.GetBuffsSolidIconColor / BF.GetBuffsBorderColor removed
-- (12.0.7-only blanket "any buff" settings).
-- ============================================================

-- Applies the icon texture or solid color override to an aura icon.
-- Returns true if a solid color was applied.
-- ============================================================
-- Grid2 UpdateIconColorCurve equivalent: evaluate a solid icon's
-- color curve with a fresh durObj.  Called from ApplyIconTextureOrSolid
-- (new aura) and the custom-container fast path (same aura).
-- Registers into the unified threshold poll (Grid2 single-timer
-- pattern) so text, border, and solid icon color all share one
-- poll tick per cooldown frame.
-- ============================================================
local RegisterThresholdPoll  -- forward declaration; assigned inside do...end below
local function UpdateSolidIconColorCurve(icon, spellId, unit, auraIID)
    local colorCurve = BF.GetSolidIconColorCurve and BF.GetSolidIconColorCurve(spellId)
    if colorCurve and unit and auraIID then
        local durObj = C_UnitAuras.GetAuraDuration(unit, auraIID)
        if durObj then
            icon.Icon:SetColorTexture(durObj:EvaluateRemainingDuration(colorCurve):GetRGBA())
            -- Stamp on icon for the poll (Grid2 pattern: state on icon)
            icon._bf_solidColorCurve = colorCurve
            RegisterThresholdPoll(icon, durObj)
        else
            -- No durObj (permanent) → apply last curve point.
            local pt = colorCurve:GetPoint(colorCurve:GetPointCount())
            if pt and pt.y then
                icon.Icon:SetColorTexture(pt.y:GetRGBA())
            end
            icon._bf_solidColorCurve = nil
        end
    else
        icon._bf_solidColorCurve = nil
    end
end
BF.UpdateSolidIconColorCurve = UpdateSolidIconColorCurve

-- v67: isBuffIcon parameter and the BF.GetBuffsSolidIconColor() blanket
-- fallback removed (12.1-only; that getter no longer exists, so the call
-- threw "attempt to call a nil value" on every buff icon).
local function ApplyIconTextureOrSolid(icon, normalTexture, spellId, unit, auraIID)
    local solid = BF.GetSolidIconColor(spellId)
    if solid then
        -- SetColorTexture paints uniformly across the texture region, so the
        -- TexCoord crop is irrelevant for solid colors. We intentionally do
        -- NOT touch SetTexCoord here so the creation-time crop persists for
        -- the next regular-texture render on this slot. This mirrors the
        -- pattern in RenderContainerIcons (the pre-resolved render path).
        icon.Icon:SetColorTexture(solid.r, solid.g, solid.b, solid.a or 1)
        UpdateSolidIconColorCurve(icon, spellId, unit, auraIID)
        return true
    else
        -- TexCoord crop was set at icon creation and is never disturbed by
        -- the solid branch above, so no per-render SetTexCoord call needed.
        icon.Icon:SetTexture(normalTexture)
        icon._bf_solidColorCurve = nil
        return false
    end
end

-- ============================================================
-- DISPEL COLOR CURVES
-- ============================================================
-- FILE-LOCAL, deliberately. All three SF_Dispel* curves used to be globals,
-- but nothing outside this file has ever read them. An addon should not leak
-- names into _G without a reason: a stray global is a collision risk, and a
-- global that a Blizzard secure path happens to read is how an addon taints
-- the UI (see the SlashCmdList note in UnitFrames/oUF_Shared.lua). As
-- upvalues they are also marginally cheaper on the dispel hot path.
--
-- Declared together up front so every reader below — and
-- BF:RebuildOverlayDispelCurve, which assigns SF_DispelCurveOverlay — closes
-- over them.
local SF_DispelCurve
-- Dispellable-only curve: point 0 (non-dispellable) is fully transparent so
-- that non-dispellable debuffs produce an invisible color rather than red.
-- Used for the "dispellable" border/overlay mode to prevent red from leaking
-- through when a non-dispellable debuff is present.
local SF_DispelCurveDispellableOnly
local SF_DispelCurveOverlay
if C_CurveUtil and C_CurveUtil.CreateColorCurve and Enum.LuaCurveType then
    SF_DispelCurve = C_CurveUtil.CreateColorCurve()
    SF_DispelCurve:SetType(Enum.LuaCurveType.Step)
    SF_DispelCurve:AddPoint(0,  CreateColor(0.8, 0, 0, 1))  -- None/non-dispellable = red
    SF_DispelCurve:AddPoint(1,  DEBUFF_TYPE_MAGIC_COLOR)
    SF_DispelCurve:AddPoint(2,  DEBUFF_TYPE_CURSE_COLOR)
    SF_DispelCurve:AddPoint(3,  DEBUFF_TYPE_DISEASE_COLOR)
    SF_DispelCurve:AddPoint(4,  DEBUFF_TYPE_POISON_COLOR)
    SF_DispelCurve:AddPoint(9,  DEBUFF_TYPE_BLEED_COLOR)
    SF_DispelCurve:AddPoint(11, DEBUFF_TYPE_BLEED_COLOR)

    SF_DispelCurveDispellableOnly = C_CurveUtil.CreateColorCurve()
    SF_DispelCurveDispellableOnly:SetType(Enum.LuaCurveType.Step)
    SF_DispelCurveDispellableOnly:AddPoint(0,  CreateColor(0, 0, 0, 0))  -- None/non-dispellable = transparent
    SF_DispelCurveDispellableOnly:AddPoint(1,  DEBUFF_TYPE_MAGIC_COLOR)
    SF_DispelCurveDispellableOnly:AddPoint(2,  DEBUFF_TYPE_CURSE_COLOR)
    SF_DispelCurveDispellableOnly:AddPoint(3,  DEBUFF_TYPE_DISEASE_COLOR)
    SF_DispelCurveDispellableOnly:AddPoint(4,  DEBUFF_TYPE_POISON_COLOR)
    SF_DispelCurveDispellableOnly:AddPoint(9,  DEBUFF_TYPE_BLEED_COLOR)
    SF_DispelCurveDispellableOnly:AddPoint(11, DEBUFF_TYPE_BLEED_COLOR)
end

-- Overlay-specific dispellable curve: same as SF_DispelCurveDispellableOnly
-- but with the user's debuffOverlayAlpha baked into the dispellable color
-- points. Point 0 stays fully transparent. This lets SetVertexColor handle
-- both color and visibility in one call — no separate SetAlpha needed.
-- Rebuilt by BF:RebuildOverlayDispelCurve() when the alpha setting changes.
-- v35: debuffOverlayAlpha moved from borders → auras.dispelIndicator.
-- This function is called from inside UpdateAuraSizeCache, which has
-- already hoisted the value into BF.AuraCache.debuffOverlayAlpha, so we
-- read it straight from the cache.
-- (SF_DispelCurveOverlay is declared with the other two curves above.)
function BF:RebuildOverlayDispelCurve()
    if not (C_CurveUtil and C_CurveUtil.CreateColorCurve and Enum and Enum.LuaCurveType) then return end
    local alpha = BF.AuraCache.debuffOverlayAlpha or 0.5
    local function WithAlpha(c, a)
        local r, g, b = c:GetRGB()
        return CreateColor(r, g, b, a)
    end
    if not SF_DispelCurveOverlay then
        SF_DispelCurveOverlay = C_CurveUtil.CreateColorCurve()
    end
    SF_DispelCurveOverlay:ClearPoints()
    SF_DispelCurveOverlay:SetType(Enum.LuaCurveType.Step)
    SF_DispelCurveOverlay:AddPoint(0,  CreateColor(0, 0, 0, 0))  -- Non-dispellable = transparent
    SF_DispelCurveOverlay:AddPoint(1,  WithAlpha(DEBUFF_TYPE_MAGIC_COLOR, alpha))
    SF_DispelCurveOverlay:AddPoint(2,  WithAlpha(DEBUFF_TYPE_CURSE_COLOR, alpha))
    SF_DispelCurveOverlay:AddPoint(3,  WithAlpha(DEBUFF_TYPE_DISEASE_COLOR, alpha))
    SF_DispelCurveOverlay:AddPoint(4,  WithAlpha(DEBUFF_TYPE_POISON_COLOR, alpha))
    SF_DispelCurveOverlay:AddPoint(9,  WithAlpha(DEBUFF_TYPE_BLEED_COLOR, alpha))
    SF_DispelCurveOverlay:AddPoint(11, WithAlpha(DEBUFF_TYPE_BLEED_COLOR, alpha))
end

-- ============================================================
-- PER-TYPE DISPEL ICON CURVES
-- Each curve has ALL dispel types as points, but only the
-- target type has alpha=1 (visible), all others have alpha=0 (invisible).
-- This way GetAuraDispelTypeColor returns the right alpha to control visibility.
-- ============================================================
local function CreateDispelTypeCurve(targetType)
    if not (C_CurveUtil and C_CurveUtil.CreateColorCurve and Enum.LuaCurveType) then
        return nil
    end
    local curve = C_CurveUtil.CreateColorCurve()
    curve:SetType(Enum.LuaCurveType.Step)
    
    local allTypes = {0, 1, 2, 3, 4, 9, 11}
    for _, dispelType in ipairs(allTypes) do
        if dispelType == targetType then
            -- Target type: white with full alpha (visible)
            curve:AddPoint(dispelType, CreateColor(1, 1, 1, 1))
        else
            -- Non-target types: transparent (invisible)
            curve:AddPoint(dispelType, CreateColor(1, 1, 1, 0))
        end
    end
    
    return curve
end

-- Create curves for each dispel type
BF.DispelIconCurves = {
    magic   = CreateDispelTypeCurve(1),   -- Magic
    curse   = CreateDispelTypeCurve(2),   -- Curse
    disease = CreateDispelTypeCurve(3),   -- Disease
    poison  = CreateDispelTypeCurve(4),   -- Poison
}
BF.DispelIconCurveNames = { "magic", "curse", "disease", "poison" }

-- Special curve for bleed - responds to both Bleed (11) and Enrage (9)
if C_CurveUtil and C_CurveUtil.CreateColorCurve and Enum.LuaCurveType then
    local bleedCurve = C_CurveUtil.CreateColorCurve()
    bleedCurve:SetType(Enum.LuaCurveType.Step)
    
    local allTypes = {0, 1, 2, 3, 4, 9, 11}
    for _, dispelType in ipairs(allTypes) do
        if dispelType == 9 or dispelType == 11 then
            -- Bleed and Enrage: white with full alpha (visible)
            bleedCurve:AddPoint(dispelType, CreateColor(1, 1, 1, 1))
        else
            -- Other types: transparent (invisible)
            bleedCurve:AddPoint(dispelType, CreateColor(1, 1, 1, 0))
        end
    end
    
    BF.DispelIconCurves.bleed = bleedCurve
    BF.DispelIconCurveNames[#BF.DispelIconCurveNames + 1] = "bleed"
end


-- ============================================================
-- DISPEL COLOR CACHE  (Grid2 pattern)
--
-- GetAuraDispelTypeColor and aura field reads (dispelName, c.r/g/b/a) are
-- tainted when called from inside CompactUnitFrame_UpdateAuras.  Following
-- Grid2's DebuffsDispell approach: compute and store the color when UNIT_AURA
-- fires (a clean event handler context), then read from the cache everywhere
-- else.  The cache is keyed by unit string.
-- ============================================================
local dispelColorCache    = {}   -- unit -> {r,g,b}  (dispellable color, for indicator/border)
local dispelAllColorCache = {}   -- unit -> {r,g,b}  (any harmful aura color, for "all" mode)

-- GetDispelColor(unit, mode)
-- Returns a cached plain color table {r,g,b} for the unit's current debuff,
-- or nil if none. Populated by UpdateDispelColorCache (called from UNIT_AURA).
--   mode "dispellable" -> dispellable debuffs only
--   mode "all"         -> any harmful aura
-- ============================================================
function BF:GetDispelColor(unit, mode)
    if mode == "all" then
        return dispelAllColorCache[unit]
    end
    return dispelColorCache[unit]
end

-- ============================================================
-- DEBUFF COLOR TABLE  (module-level, allocated once)
-- ============================================================
local debuffColors = {
    Magic   = {0.20, 0.60, 1.00},
    Curse   = {0.60, 0.00, 1.00},
    Disease = {0.60, 0.40, 0.00},
    Poison  = {0.00, 0.60, 0.00},
}

-- ============================================================
-- SHARED: apply aura data onto one icon slot
-- Use pre-extracted arrays instead of aura table
-- ============================================================
function BF:ClearDispelColorCache()
    table.wipe(dispelColorCache)
    table.wipe(dispelAllColorCache)
    if self.dispelIconTypeCache then table.wipe(self.dispelIconTypeCache) end
end

-- Called from UNIT_AURA to refresh the cached colors for a unit.
-- Stores the raw color object from GetAuraDispelTypeColor directly — exactly
-- as Grid2's DebuffsDispell:UpdateCache does.  The color object may be a
-- secret value; that is fine as long as it is only ever passed to Blizzard
-- rendering APIs (SetVertexColor, SetBackdropBorderColor, etc.) and never
-- read or compared in addon Lua code.
-- dispelIconTypeCache stores a plain Lua string key ("magic", "curse", etc.)
-- determined by probing each DispelIconCurve — avoids storing secret dispelName.
function BF:UpdateDispelColorCache(unit)
    -- ── Dispellable color ────────────────────────────────────────────────────
    -- Use SF_DispelCurveDispellableOnly so that non-dispellable debuffs (point 0)
    -- produce a transparent color rather than red. This means even if a
    -- non-dispellable aura slips past the RAID_PLAYER_DISPELLABLE filter, the
    -- resulting color is invisible and will never paint a border or overlay.
    local unitCache = BF.auraMatchCache and BF.auraMatchCache[unit]
    local dispelAura = unitCache and unitCache.dispelDebuffFrames and unitCache.dispelDebuffFrames[1]
    if dispelAura and dispelAura.auraInstanceID and SF_DispelCurveDispellableOnly then
        local c = C_UnitAuras.GetAuraDispelTypeColor(unit, dispelAura.auraInstanceID, SF_DispelCurveDispellableOnly)
        dispelColorCache[unit] = c or nil

        -- Determine icon type by probing each per-type curve.
        -- Each curve returns alpha=1 only for its matching dispel type.
        -- GetRGBA() returns four secret values — we can't compare them.
        -- Instead use issecretvalue: if the alpha is secret (tainted context)
        -- we skip icon detection and leave the cache nil.
        -- In a clean UNIT_AURA context the values are plain numbers.
        -- Per-type icon colors: each curve returns alpha=1 for its type, 0 for others.
        -- Stored as secret color objects; passed to SetVertexColor at display time.
        -- This is identical to how the border color works — secret value to API only.
        if self.DispelIconCurves and self.DispelIconCurveNames then
            if not self.dispelIconColorCache then self.dispelIconColorCache = {} end
            local t = self.dispelIconColorCache[unit]
            if not t then t = {}; self.dispelIconColorCache[unit] = t end
            for i = 1, #self.DispelIconCurveNames do
                local name = self.DispelIconCurveNames[i]
                t[name] = C_UnitAuras.GetAuraDispelTypeColor(unit, dispelAura.auraInstanceID, self.DispelIconCurves[name])
            end
        end
    else
        dispelColorCache[unit] = nil
        if self.dispelIconColorCache then self.dispelIconColorCache[unit] = nil end
    end

    -- ── "All harmful" color ──────────────────────────────────────────────────
    if dispelColorCache[unit] then
        dispelAllColorCache[unit] = dispelColorCache[unit]
    else
        -- Use cached debuffFrames (populated in UNIT_AURA clean context)
        local found = nil
        local debuffFrames = unitCache and unitCache.debuffFrames
        if debuffFrames then
            for i = 1, #debuffFrames do
                local id = debuffFrames[i].auraInstanceID
                if id and SF_DispelCurve then
                    local c = C_UnitAuras.GetAuraDispelTypeColor(unit, id, SF_DispelCurve)
                    if c then found = c; break end
                end
            end
        end
        dispelAllColorCache[unit] = found
    end
end

-- ============================================================
-- THRESHOLD DURATION COLOR CURVES
--
-- Uses DurationObject:EvaluateRemainingDuration(colorCurve) to
-- change the countdown text color when an aura is about to expire.
-- A Step color curve maps remaining seconds -> color:
--   point 0           = secondary threshold color (if enabled)
--   point threshold2  = primary threshold color
--   point threshold1  = normal white
-- The lower (secondary) threshold takes priority: below threshold2
-- the text shows the secondary color, between threshold2 and
-- threshold1 it shows the primary color, above threshold1 it's white.
-- ============================================================
local thresholdCurves = {}  -- keyed: "buff", "debuff", "bigDef"

-- Helper: build a Step color curve for threshold duration coloring.
-- t1/c1 = primary threshold seconds and color (required)
-- t2Enabled = whether secondary threshold is active
-- t2/c2 = secondary threshold seconds and color
-- aboveColor = {r,g,b} table for the above-threshold color (the normal
--              timer text color when no threshold is active). Passed through
--              from the per-feature Font Color in AuraCache so both the
--              static timer color and the threshold curve's above-threshold
--              output agree (Grid2 unified-curve pattern). Defaults to white
--              if nil for backwards compat.
-- Returns a ColorCurveObject, or nil if the API is unavailable.
-- v86 PERF: memoised. This is a PURE function of its seven arguments, so a
-- settings change simply produces a different key -- there is nothing to
-- invalidate (GetSolidIconColorCurve is keyed by its inputs the same way).
--
-- Why it matters beyond the obvious allocation saving: ButtonSpecSig
-- (Auras/ContainerFactory.lua) folds `tostring(spec.durationCurve)` into the
-- button-spec signature. A freshly built curve has a fresh table address
-- every call, so the signature could NEVER match and
-- ApplyAuraGridButtonSpec / ApplyAuraGridGroupButtonSpec fell through their
-- change guard into the full restyle walk on every pass -- measured at
-- 0.78 ms per call and 603 ms of a 1211 ms raid join. Returning the SAME
-- object for the same inputs makes that signature stable, which is what
-- lets the guard do its job. Anything that changes the curve's appearance
-- also changes the key, so the signature still moves when it should.
local _thresholdCurveCache = {}
local _thresholdCurveCount = 0
local THRESHOLD_CURVE_CACHE_MAX = 256

local function ColorKey(c)
    if type(c) ~= "table" then return "-" end
    return (c.r or 0) .. "," .. (c.g or 0) .. "," .. (c.b or 0) .. "," .. (c.a or 1)
end

local function BuildThresholdColorCurve(t1, c1, t2Enabled, t2, c2, aboveColor, hideAbove1Min)
    if not (C_CurveUtil and C_CurveUtil.CreateColorCurve and Enum and Enum.LuaCurveType) then
        return nil
    end
    local key = tostring(t1) .. "|" .. ColorKey(c1)
             .. "|" .. tostring(t2Enabled and true or false) .. "|" .. tostring(t2)
             .. "|" .. ColorKey(c2) .. "|" .. ColorKey(aboveColor)
             .. "|" .. tostring(hideAbove1Min and true or false)
    local hit = _thresholdCurveCache[key]
    if hit then return hit end

    local aR = aboveColor and aboveColor.r or 1
    local aG = aboveColor and aboveColor.g or 1
    local aB = aboveColor and aboveColor.b or 1
    local aA = aboveColor and aboveColor.a or 1
    local curve = C_CurveUtil.CreateColorCurve()
    curve:SetType(Enum.LuaCurveType.Step)
    if t2Enabled and t2 and c2 and t2 < t1 then
        curve:AddPoint(0,  CreateColor(c2.r, c2.g, c2.b, c2.a or 1))
        curve:AddPoint(t2, CreateColor(c1.r, c1.g, c1.b, c1.a or 1))
        curve:AddPoint(t1, CreateColor(aR, aG, aB, aA))
    else
        curve:AddPoint(0,  CreateColor(c1.r, c1.g, c1.b, c1.a or 1))
        curve:AddPoint(t1, CreateColor(aR, aG, aB, aA))
    end
    -- Hide duration text above 1 minute: add an alpha-0 point at 60s.
    -- When remaining > 59s the curve evaluates to alpha 0, making the
    -- text invisible via SetTextColor without needing to branch on
    -- secret duration values.
    if hideAbove1Min then
        curve:AddPoint(60, CreateColor(aR, aG, aB, 0))
    end

    -- Bounded: a color-picker drag can mint a lot of distinct keys. Wiping
    -- wholesale is fine -- the next call simply rebuilds what it needs.
    if _thresholdCurveCount >= THRESHOLD_CURVE_CACHE_MAX then
        for k in pairs(_thresholdCurveCache) do _thresholdCurveCache[k] = nil end
        _thresholdCurveCount = 0
    end
    _thresholdCurveCache[key] = curve
    _thresholdCurveCount = _thresholdCurveCount + 1
    return curve
end
BF._BuildThresholdColorCurve = BuildThresholdColorCurve

-- v86 PERF: the "hide duration text above 1 minute" curve, for the case where
-- threshold coloring is OFF but hideAbove1Min is ON. Two call sites in
-- AuraCustomizations.lua built this inline with a fresh CreateColorCurve every
-- time, with the same signature-instability consequence described above.
-- Memoised on the only thing it varies by: the above-threshold color.
local _hideAboveCurveCache = {}

function BF._BuildHideAbove1MinCurve(aboveColor)
    if not (C_CurveUtil and C_CurveUtil.CreateColorCurve and Enum and Enum.LuaCurveType) then
        return nil
    end
    local key = ColorKey(aboveColor)
    local hit = _hideAboveCurveCache[key]
    if hit then return hit end
    local aR = aboveColor and aboveColor.r or 1
    local aG = aboveColor and aboveColor.g or 1
    local aB = aboveColor and aboveColor.b or 1
    local aA = aboveColor and aboveColor.a or 1
    local curve = C_CurveUtil.CreateColorCurve()
    curve:SetType(Enum.LuaCurveType.Step)
    curve:AddPoint(0,  CreateColor(aR, aG, aB, aA))
    curve:AddPoint(60, CreateColor(aR, aG, aB, 0))
    _hideAboveCurveCache[key] = curve
    return curve
end

-- Grid2 pattern (GridUtils.lua): single combined curve for both text and border.
-- Above threshold: white(1,1,1) with alpha=0.
-- Text uses SetTextColor(r,g,b,1) → white above threshold (invisible on white timer).
-- Border uses SetBackdropBorderColor(r,g,b,a) → alpha=0 above threshold (invisible).
-- One EvaluateRemainingDuration call serves both text and border.
-- Combined curve removed: text and border need different above-threshold colors
-- (text = white/invisible, border = default black). Always use separate curves.

-- Helper: read threshold settings from a common prefix and build a curve.
-- prefix: e.g. "global", "buff", "debuff", "bigDef"
-- aboveColor: {r,g,b} table for the above-threshold color (the feature's
--             Font Color from AuraCache). Passed through to
--             BuildThresholdColorCurve so threshold-enabled text matches
--             the static Font Color above the threshold.
local function BuildCurveFromProfile(db, prefix, aboveColor)
    local enabled = db[prefix .. "ThresholdColorEnabled"] == true
    local hideAbove1Min = db[prefix .. "HideDurationAbove1Min"] == true
    if not enabled and not hideAbove1Min then return nil, false end
    if not enabled and hideAbove1Min then
        -- No threshold coloring, but hide above 1 min is on.
        -- Build a minimal curve: font color below 60s, alpha 0 at 60s+.
        --
        -- v86 PERF: third and last inline CreateColorCurve site, now routed
        -- through the memoised builder. This one feeds ac.expiringCurve*, and
        -- from there spec.durationCurve, which ButtonSpecSig stringifies -- so
        -- a fresh object here re-broke the button-spec signature after every
        -- aura-cache rebuild (six per raid join).
        local curve = BF._BuildHideAbove1MinCurve and BF._BuildHideAbove1MinCurve(aboveColor)
        if not curve then return nil, false end
        return curve, true
    end
    local t1 = db[prefix .. "ThresholdColorThreshold"] or 8
    local c1 = db[prefix .. "ThresholdColor"] or BF.DEFAULT_THRESHOLD_COLOR
    local t2Enabled = db[prefix .. "Threshold2ColorEnabled"] == true
    local t2 = db[prefix .. "Threshold2ColorThreshold"] or 4
    local c2 = db[prefix .. "Threshold2Color"] or BF.DEFAULT_THRESHOLD2_COLOR
    return BuildThresholdColorCurve(t1, c1, t2Enabled, t2, c2, aboveColor, hideAbove1Min), hideAbove1Min
end
-- Exposed for Phase 2 per-indicator UpdateDB methods.
BF.BuildCurveFromProfile = BuildCurveFromProfile

-- Build combined curve from profile — REMOVED.
-- Text and border need different above-threshold colors (text = white,
-- border = default black 0.8). Always use separate text + border curves.

function BF:RebuildExpiringColorCurves()
    -- No teardown of the active poll set. Icons in _thresholdIcons keep
    -- their current colorCurveObject references (still valid curve objects
    -- that evaluate correctly). When RefreshAllAuras follows a real
    -- settings change, Layout re-stamps icon.colorCurveObject with the
    -- new curve and UpdateIconCooldown re-registers with the poll.
    -- Icons whose curve goes nil self-clean: the poll's Update already
    -- checks `if not curve and not solidCurve then icons[icon] = nil end`.
    -- This avoids the old pattern where every UpdateAuraSizeCache call
    -- (options open, tab navigation, preview rebuild, etc.) would wipe
    -- the poll and reset text to alpha=1, breaking hide-duration-above-
    -- 1-min until the next UNIT_AURA event re-registered icons.

    -- v30: route through the active flat so per-layout auraText
    -- customizations are consumed here. When the per-layout toggle is
    -- OFF, GetSectionProfile returns the global rpDB.profile.auraText.
    -- When ON, returns flat.auraText for the active (rendering) flat.
    -- Each sub-category (global/buffs/debuffs/bigDef) is extracted with
    -- `or {}` for nil-safety; the two-tier metatable fallback (wired
    -- by WireAuraTextSubCategoryFallbacks in RehydrateFlats) ensures
    -- un-materialized sub-categories on per-flat caches resolve
    -- through to the global sub-category's default values.
    local isRaid = self:ResolveActiveIsRaid()
    local activeFlat = isRaid and self:GetRaidProfile() or self:GetActivePartyProfile()
    local db = self:GetSectionProfile("auraText", activeFlat) or {}
    local useGlobal = db.globalAuraTextConfig ~= false
    local dbGlobal  = db.global or {}
    local dbBuff    = db.buffs  or {}
    local dbDebuff  = db.debuffs or {}
    local dbBigDef  = db.bigDef or {}

    -- BuildCurveFromProfile and BuildBorderCurveFromProfile concatenate
    -- `prefix` with "ThresholdColorEnabled" etc. The nested default
    -- shape keeps the original key names inside each sub-category
    -- (e.g. buffThresholdColorEnabled lives at auraText.buffs.
    -- buffThresholdColorEnabled), so passing the sub-category table +
    -- original prefix works unmodified.
    -- Above-threshold color for the text curve comes from the per-feature
    -- Font Color hoisted into AuraCache by UpdateAuraSizeCache. Under
    -- useGlobal the four features share gColor (all four AuraCache
    -- font-color fields were stamped with the same gColor); under per-type
    -- each feature gets its own color.
    if useGlobal then
        local curve, hides = BuildCurveFromProfile(dbGlobal, "global", BF.AuraCache.buffFontColor)
        thresholdCurves.buff         = curve
        thresholdCurves.debuff       = curve
        thresholdCurves.bigDef       = curve
        BF.AuraCache.curveHidesBuff         = hides
        BF.AuraCache.curveHidesDebuff       = hides
        BF.AuraCache.curveHidesBigDef       = hides
    else
        local curve, hides
        curve, hides = BuildCurveFromProfile(dbBuff,   "buff",   BF.AuraCache.buffFontColor)
        thresholdCurves.buff = curve
        BF.AuraCache.curveHidesBuff = hides
        curve, hides = BuildCurveFromProfile(dbDebuff, "debuff", BF.AuraCache.debuffFontColor)
        thresholdCurves.debuff = curve
        BF.AuraCache.curveHidesDebuff = hides
        curve, hides = BuildCurveFromProfile(dbBigDef, "bigDef", BF.AuraCache.bigDefFontColor)
        thresholdCurves.bigDef = curve
        BF.AuraCache.curveHidesBigDef = hides
        -- v69: the crowdControl curve (debuff-curve fallback +
        -- hideDurationAbove1Min) was removed with the dedicated CC feature.
    end

    -- Cache references in AuraCache for fast access in ScanAndDisplay
    BF.AuraCache.expiringCurveBuff         = thresholdCurves.buff
    BF.AuraCache.expiringCurveDebuff       = thresholdCurves.debuff
    BF.AuraCache.expiringCurveBigDef       = thresholdCurves.bigDef

    -- Grid2 unified-curve pattern: one threshold curve per feature drives both
    -- text and (optionally) border. The per-feature ColorAuraBorder toggle is
    -- consulted at the call site to decide whether to also color the border;
    -- when on, the border uses the SAME curve result as the text (same RGB,
    -- same alpha). No separate border curves exist -- and per-spell / blanket
    -- buff border curves are no longer needed either: when threshold coloring
    -- is enabled and ColorAuraBorder is on, the threshold curve's output wins
    -- over any custom border color painted at icon render. When ColorAuraBorder
    -- is off (or threshold is disabled), the icon's render-time border stands.
end

-- ============================================================
-- THRESHOLD COLOR POLLING
-- ScanAndDisplay only fires on UNIT_AURA events, so threshold color
-- transitions that occur between events (e.g. secondary threshold)
-- would be missed. A lightweight ticker re-evaluates the color
-- curves on all active threshold-colored cooldown frames ~2x/sec.
-- ============================================================
-- Grid2 GridUtils.lua lines 401-444: exact pattern.
do
    local timer
    local icons = {}
    local function ApplyColors(icon, r, g, b, a)
        if icon.colorCurveText then
            -- Debuff-specific: dispel color owns text unless curve overrides
            if not icon._bf_useDispelColor or icon._bf_curveOverridesDispel then
                icon.colorCurveText:SetTextColor(r, g, b, a)
            end
        end
        if icon.colorCurveBorder then
            SetIconBorderColor(icon, r, g, b, a)
        end
    end
    local function Update()
        for icon, durationObject in pairs(icons) do
            if icon:IsVisible() then
                local curve = icon.colorCurveObject
                local solidCurve = icon._bf_solidColorCurve
                if curve then
                    ApplyColors(icon, durationObject:EvaluateRemainingDuration(curve):GetRGBA())
                end
                if solidCurve then
                    icon.Icon:SetColorTexture(durationObject:EvaluateRemainingDuration(solidCurve):GetRGBA())
                end
                -- Remove stale entries: icon is visible but curves were
                -- cleared since registration. Avoids polling dead icons.
                if not curve and not solidCurve then
                    icons[icon] = nil
                end
            else
                icons[icon] = nil
            end
        end
        -- v67: the expiration-glow and bounce piggy-back hooks are gone.
        -- Expiration glow is presence-only now (no threshold poll) and
        -- Bounce was deleted entirely, so this tick has a single consumer
        -- again: the threshold color curves in `icons`.
        if not next(icons) then
            timer:Stop()
        end
    end
    local timerFrame = CreateFrame("Frame")
    timer = timerFrame:CreateAnimationGroup()
    timer:SetLooping("REPEAT")
    local anim = timer:CreateAnimation()
    anim:SetDuration(0.2)
    BF._ThresholdPollOnTick = Update
    timer:SetScript("OnLoop", function() BF._ThresholdPollOnTick() end)

    -- v67: BF.StartExpirationGlowTimer and BF.StartBounceTimer removed.
    -- Both were "start the shared 0.2s timer" entry points for poll sets
    -- that no longer exist (ExpirationGlow is presence-only; Bounce.lua
    -- is deleted). Neither had any remaining caller.

    function BF.UpdateIconColorCurve(icon, durationObject)
        local curve = icon.colorCurveObject
        if durationObject then
            if not timer:IsPlaying() then timer:Play() end
            icons[icon] = durationObject
            ApplyColors(icon, durationObject:EvaluateRemainingDuration(curve):GetRGBA())
        else
            ApplyColors(icon, curve:GetPoint(curve:GetPointCount()).y:GetRGBA())
        end
    end

    function BF.RemoveIconColorCurve(icon)
        icons[icon] = nil
    end

    -- Expose for profiler wrapping and RebuildExpiringColorCurves
    BF._thresholdIcons = icons
    BF._thresholdTimer = timer

    RegisterThresholdPoll = function(icon, durationObject)
        if not timer:IsPlaying() then timer:Play() end
        icons[icon] = durationObject
    end
end

-- Grid2 IndicatorIcons.lua lines 64-87: shared cooldown + color curve.
-- Called by every icon indicator's Update for each visible icon.
local GetAuraDuration = C_UnitAuras.GetAuraDuration
function BF.UpdateIconCooldown(icon, unit, exp, dur, iid)
    local cd = icon.cooldown
    -- showCool
    local durObj
    if canaccessvalue(exp) then
        cd:SetCooldownFromExpirationTime(exp, dur)
    else
        durObj = GetAuraDuration(unit, iid)
        if durObj then
            cd:SetCooldownFromDurationObject(durObj)
        end
    end
    -- needDur (Grid2: showColors)
    if icon.colorCurveObject then
        durObj = durObj or GetAuraDuration(unit, iid)
        BF.UpdateIconColorCurve(icon, durObj)
    end
end

-- ============================================================
-- SIZE / LAYOUT CACHE
-- ============================================================
BF.AuraCache = {
    -- Geometry (fed by UpdateAuraSizeCache, consumed by ApplyAuraGeometry / ScanAndDisplay)
    buffSize    = 12,
    debuffSize  = 12,
    -- (v93: the `db` field is GONE. It held a reference to the whole
    -- BF.db.profile, and because every per-flat _auraCache lives INSIDE a
    -- saved profile, that reference dragged a nested copy of the entire main
    -- profile into SavedVariables once per flat, and into every profile
    -- export. Its one reader, BF:GetDefaultBuffGroupConfig in
    -- AuraGroupHelpers.lua, now reads BF.db.profile directly. Do not
    -- reintroduce it, and do not park anything else non-trivial on a cache
    -- that is reachable from a profile table.)
    -- v93: `isRaid` removed. It was written per scope by UpdateCrossSectionCache
    -- and read by exactly one place -- a comparison in BF:UpdateStandardAuras
    -- that was unreachable (see there). Write-only field; do not reintroduce it
    -- without a reader. (A table-literal `= nil` stored nothing anyway; the
    -- entry was documentation.)

    -- Buff display settings
    showBuffDuration  = true,
    disableBuffSwipe  = false,
    disableBuffSpark  = false,
    reverseBuffSwipe  = false,
    buffTimerScale    = 0.5,

    -- Debuff display settings
    showDebuffDuration  = true,
    disableDebuffSwipe  = false,
    disableDebuffSpark  = false,
    reverseDebuffSwipe  = false,
    debuffTimerScale    = 0.5,
    -- v67: privateAuraAnchorPoint and extraDebuffYOffset removed with the
    -- Private Auras feature. The offset was only ever non-zero under
    -- separatePrivateAurasInRaid/InParty, which no options widget ever wrote,
    -- so it was already 0 for every real profile; DebuffIcons.lua no longer
    -- reads it.

    -- Big-defensive display settings
    showBigDef           = false,
    bigDefAnchor         = "CENTER",
    showBigDefDuration   = false,
    bigDefTimerScale     = 0.6,
    bigDefMaxCount       = 1,
    bigDefGrowDirection  = "RIGHT",
    bigDefIconsPerRow    = 5,
    bigDefSpacing        = 1,
    bigDefRowSpacing     = 1,

    -- v69: the Crowd Control icon display seed block was removed with the
    -- dedicated CC feature (now a seeded custom debuff container).

    -- v67: the whole private aura layout seed block was removed with the
    -- Private Auras feature (its renderer, PrivateAuras.lua, is gone).
}

-- BF.OffsetCache DELETED by Phase 2. The global cache now writes its
-- own _buffOffsets/_debuffOffsets/etc. via RebuildAuraCacheScope, and
-- all 5 consumers read ac._*Offsets directly without a fallback.

-- ============================================================
-- PER-CFG AURA CACHE
--
-- Populate a per-CFG aura cache table from the CFG flat's section
-- profiles. Called from UpdateAuraSizeCache after the global
-- BF.AuraCache is fully built. Each per-CFG cache is a plain table
-- with NO metatable fallback — every key an indicator might read is
-- explicitly rawset here. (v93: the global-only key copy block is gone with
-- PopulateCFGAuraCache -- `db`, `hasBuffHighlightConfigs` and `isRaid` no
-- longer exist.)
--
-- Section resolution mirrors GetSectionProfileForFrame's CFG branch. v65
-- §6.3: the override flag alone decides, whatever the section's per-Layout
-- toggle says.
--   - Override flag ON  -> read from CFG flat
--   - Override flag OFF -> read from the ACTIVE Layout's flat (§6.3a),
--                          falling back to the global (rpDB.profile) when
--                          there is no active flat.
-- ============================================================
local function ResolveCFGSection(self, flat, grp, section)
    -- v60 guard: mirror of the one in GetSectionProfile. The auras section
    -- cannot be resolved as a whole -- use ResolveCFGAurasSubcat below.
    if section == "auras" then
        error("BuzzardFrames: ResolveCFGSection(..., \"auras\") is not supported -- "
              .. "use BF.ResolveCFGAurasSubcat(self, flat, grp, subcat) instead", 2)
    end
    -- 2026-09-13: one resolver for every Custom Frame Group read --
    -- BF:GetCFGSectionProfile (Core_ProfileAPI.lua), which carries the v65
    -- §6.3 rule (the override flag alone decides) and the per-subtab split.
    -- When grp is nil (a per-Layout flat, not a group) there is no flag to
    -- consult and it falls through to GetSectionProfile, as before.
    if grp then
        return BF:GetCFGSectionProfile(section, grp, flat)
    end
    return self:GetSectionProfile(section, flat)
end
-- Exposed for Phase 2 per-indicator UpdateDB methods.
BF.ResolveCFGSection = ResolveCFGSection

-- ============================================================
-- ResolveCFGAurasSubcat(self, flat, grp, subcat)
--
-- v60: the aura-section counterpart of ResolveCFGSection, resolving ONE
-- sub-category instead of the whole auras table.
--
-- The "Auras" per-layout toggle was split in two (aurasBuffs governs
-- buffs/bigDef, aurasDebuffs governs debuffs/dispelIndicator),
-- so the two halves of a flat's auras table
-- can have different per-layout answers at the same time. Resolving
-- flat.auras once and indexing sub-categories off it -- what this file
-- used to do -- would hand back a flat's stale sub-table for whichever
-- group is currently OFF. Resolving per sub-category is correct
-- regardless of what rawkeys a flat happens to be carrying, so no
-- pruning or normalization of saved data is required.
--
-- Mirrors ResolveCFGSection's CFG-override branch exactly, substituting
-- the per-subcat helpers for the per-section ones. Storage is unchanged:
-- rpDB.profile.auras.<subcat> / flat.auras.<subcat>.
-- ============================================================
local function ResolveCFGAurasSubcat(self, flat, grp, subcat)
    if grp then
        -- v60: the override flag is per aura GROUP, not per section — see
        -- BF.AURAS_GROUP_CFG_FLAG (Core_FlatDefaults.lua). A CFG can override
        -- its Buffs data while still inheriting global Debuffs data.
        local group = BF.AURAS_SUBCAT_GROUP[subcat]
        local section_flag = group and BF.AURAS_GROUP_CFG_FLAG[group]
        -- v65 §6.3: the flag alone decides -- the old test also required
        -- the sub-category NOT to be per-Layout. See ResolveCFGSection above.
        if section_flag then
            if grp[section_flag] then
                local gp = self.rpDB and self.rpDB.profile and self.rpDB.profile.auras
                local flatAuras = type(flat) == "table" and rawget(flat, "auras")
                local sub = type(flatAuras) == "table" and flatAuras[subcat]
                if type(sub) == "table" then return sub end
                return gp and gp[subcat]
            end
            -- Override OFF: follow the active Layout (§6.3a). A nil active
            -- flat resolves to the global sub-category inside
            -- GetAurasSubcatProfile.
            return self:GetAurasSubcatProfile(subcat, self:GetActiveContextFlat())
        end
    end
    return self:GetAurasSubcatProfile(subcat, flat)
end
BF.ResolveCFGAurasSubcat = ResolveCFGAurasSubcat

-- v93: PopulateCFGAuraCache DELETED (351 lines). It was the pre-Phase-2
-- CFG-specific cache builder, superseded by RebuildAuraCacheScope below:
-- per-indicator UpdateDB pass -> UpdateAuraTextSettings ->
-- UpdateCrossSectionCache -> offsets -> border stamps -> glow params.
--
-- It had no caller anywhere in the addon. Only comments referenced it, and
-- several cited it as the justification for LIVE behavior, which is how it
-- survived through v93 edits: it was maintained while dead.
--
-- There is no separate CFG path. CFG flats, per-layout flats and the global
-- cache all take the identical RebuildAuraCacheScope(cache, flat, grp); a CFG
-- differs only by `grp`, which carries its per-section override flags -- see
-- ResolveCFGSection, which falls through to GetSectionProfile when grp is nil.

-- Forward declaration so UpdateAuraSizeCache can reference it for
-- per-CFG offset precomputation. Assigned in CalcAuraOffsets definition below.
local CalcAuraOffsets

-- ============================================================
-- cfgBorderColor — hoisted to file-local scope (Phase 2).
-- Pre-Phase-2 this was a closure inside UpdateAuraSizeCache's body,
-- invisible to other functions. RebuildAuraCacheScope calls it, so it
-- must be reachable from outside the UpdateAuraSizeCache call frame.
-- Pure function: only reads its `c` argument and the feature string.
-- ============================================================
local function cfgBorderColor(c, feature)
    -- v34: sourced from the per-feature Border Color setting (Border group
    -- in the Auras options). The colorAuraBorder (font-color border) input
    -- was REMOVED with that setting (12.1 cut).
    local color = c[feature .. "BorderColor"]
    if color then
        c["_defBorder_" .. feature .. "_r"] = color.r or 0
        c["_defBorder_" .. feature .. "_g"] = color.g or 0
        c["_defBorder_" .. feature .. "_b"] = color.b or 0
        c["_defBorder_" .. feature .. "_a"] = color.a or 0.8
    else
        c["_defBorder_" .. feature .. "_r"] = 0
        c["_defBorder_" .. feature .. "_g"] = 0
        c["_defBorder_" .. feature .. "_b"] = 0
        c["_defBorder_" .. feature .. "_a"] = 0.8
    end
end

-- ============================================================
-- PER-FLAT AURA CACHE DIRTY LIST
-- ============================================================
-- Each flat (CFG flat OR per-layout flat) gets its own _auraCache. A
-- rebuild is expensive (RebuildAuraCacheScope runs every indicator's
-- UpdateDB plus the cross-section passes), so
-- we only rebuild flats whose cached values may have gone stale.
--
-- _flatCacheDirty maps flat -> true; UpdateAuraSizeCache rebuilds every
-- flat in the set then clears it. _allFlatsDirty is the escape hatch
-- when we can't enumerate the affected flats cheaply (spec change,
-- talent change, profile switch, per-layout toggle flip) -- the next
-- UpdateAuraSizeCache pass rebuilds every flat unconditionally.
--
-- _allFlatsDirty starts true so the first UpdateAuraSizeCache after
-- addon load builds every flat's cache from scratch (same eager-build
-- semantics CFGs had before this refactor).
local _flatCacheDirty = setmetatable({}, { __mode = "k" })  -- weak keys
local _allFlatsDirty  = true

function BF:InvalidateFlatAuraCache(flat)
    if flat then _flatCacheDirty[flat] = true end
end

function BF:InvalidateAllFlatAuraCaches()
    _allFlatsDirty = true
end

-- Pixel grid moved after the caches were built (PixelPerfect's
-- RefreshPixelSize; see the note there): every pre-rounded size in every
-- scope is off by up to a pixel, so rebuild them all, synchronously. Pure
-- table work, safe at any point of the load; guarded so an early grid change
-- (before the profile is up) is simply ignored -- the first regular
-- UpdateAuraSizeCache rounds on the settled grid anyway.
function BF:OnPixelGridChanged()
    if not (self.db and self.db.profile and self.AuraCache) then return end
    if self._pixelGridRebuilding then return end
    self._pixelGridRebuilding = true
    _allFlatsDirty = true
    local ok, err = pcall(self.UpdateAuraSizeCache, self)
    self._pixelGridRebuilding = nil
    if not ok then geterrorhandler()("BuzzardFrames OnPixelGridChanged: " .. tostring(err)) end
end

-- ============================================================
-- BF:InvalidateCFGAuraCachesFollowingActiveLayout()  (v65 §6.3a)
-- ============================================================
-- Called when the ACTIVE Layout flat may have changed. Under §6.3a a Custom
-- Frame Group whose aura override flag is OFF resolves its aura values against
-- the active flat, so those values go stale the moment the active flat moves.
--
-- The section path needs nothing here: InvalidateRaidProfileCache already
-- wipes every CFG flat's _sectionCache and is already called on exactly this
-- event. The aura path is the gap -- InvalidateRaidProfileCache deliberately
-- does NOT touch _auraCache (it is a derived structure that must stay
-- complete; only UpdateAuraSizeCache may rebuild it atomically), so the CFG
-- caches must instead be marked DIRTY and left populated until the rebuild.
--
-- Narrow on purpose. InvalidateAllFlatAuraCaches() would be one line, but it
-- forces a full RebuildAuraCacheScope for every per-Layout flat and every CFG
-- flat on every context flip -- and a group with both override flags ON never
-- reads the active flat at all, so its cache cannot have gone stale. Only
-- groups with at least one aura override OFF are marked.
-- The non-aura sections a group's _auraCache is built from. See the note
-- inside InvalidateCFGAuraCachesFollowingActiveLayout.
local CFG_AURA_CACHE_SECTIONS = { "auraText", "healthPower", "tooltips" }

function BF:InvalidateCFGAuraCachesFollowingActiveLayout()
    local cfgp = self.cfgDB and self.cfgDB.profile
    local groups = cfgp and cfgp.customFrameGroups
    if not groups then return end
    for _, grp in ipairs(groups) do
        local flat = grp and grp.flat
        if flat then
            -- One _auraCache holds both pages' values, so either flag being
            -- OFF is enough to make the whole cache follow-the-active-Layout.
            local followsActive = false
            for _, flag in pairs(BF.AURAS_GROUP_CFG_FLAG) do
                if not grp[flag] then followsActive = true end
            end
            -- 2026-09-13: the cache is ALSO built from auraText (UpdateAuraTextSettings),
            -- healthPower (UpdateCrossSectionCache) and tooltips (DebuffIcons
            -- UpdateDB), each of which follows the active Layout while its
            -- own master is off -- or, for healthPower, while any of its
            -- subtabs is. Deciding from the aura flags alone left those
            -- values stale on every context flip.
            for i = 1, #CFG_AURA_CACHE_SECTIONS do
                if self:CFGSectionFollowsActiveLayout(grp, CFG_AURA_CACHE_SECTIONS[i]) then
                    followsActive = true
                end
            end
            if followsActive then _flatCacheDirty[flat] = true end
        end
    end
end

-- Called when a global section setting changes. When per-layout is OFF
-- for that section, every flat falls through to the global setting, so
-- every flat's cache must rebuild. When per-layout is ON, no flat reads
-- the global -- the write is a no-op for the live caches.
function BF:InvalidateGlobalSectionFlatCaches(section)
    if self:IsPerLayoutSection(section) then return end
    _allFlatsDirty = true
end

-- ============================================================
-- Phase 2 helpers — shared cross-section/auraText cache writes.
-- Called by RebuildAuraCacheScope after the per-indicator UpdateDB
-- pass. See Docs/AURAICON_CONSTRUCTOR_UNIFICATION_PLAN.md Phase 2.
-- ============================================================

-- Pre-resolved at file load. Body originally lifted from the pre-Phase-2 CFG
-- builder's useGlobal branch (that function is deleted; this is the only copy) (constraint A: when globalAuraTextConfig is on, all
-- five aura-icon indicators get IDENTICAL font/border/color/timer/swipe
-- values from the global atGlobal sub-section). Resolving in a shared
-- helper avoids 5x duplicate useGlobal resolution + identical writes.
--
-- Per-indicator fields that *also* live in auraText (like buffColorAuraBorder,
-- bigDefColorAuraBorder, debuffDurationDispelColor) are owned by each
-- indicator's own UpdateDB — v67: the two privateAura* entries in this
-- list went away with the Private Auras feature —
-- those indicators do their own one-time useGlobal check. This helper
-- only writes the cross-coupled fields where useGlobal produces the
-- same value for every section.
local _defaultATFont = "Interface\\AddOns\\BuzzardFrames\\Media\\Fonts\\RobotoCondensed-Bold.ttf"
local _defaultATColor = { r = 1, g = 1, b = 1 }

function BF:UpdateAuraTextSettings(cache, flat, grp)
    local atp = ResolveCFGSection(self, flat, grp, "auraText") or {}
    local atGlobalP = atp.global       or {}
    local atBuffP   = atp.buffs        or {}
    local atDebuffP = atp.debuffs      or {}
    local atBigDefP = atp.bigDef       or {}
    local useGlobal = atp.globalAuraTextConfig ~= false

    if useGlobal then
        local gFont   = BF:ResolveFontPathOr(atGlobalP.globalDurationFont, _defaultATFont)
        local gBorder = atGlobalP.globalDurationBorder or "OUTLINE"
        local gColor  = atGlobalP.globalFontColor or _defaultATColor
        local gShow   = atGlobalP.globalDurationShow ~= false
        local gAuto   = atGlobalP.globalAutoScale == true
        local gScale  = atGlobalP.globalTimerScale or 1.0
        local gSize   = atGlobalP.globalFontSize or 11
        local gSwipe  = atGlobalP.globalDisableSwipe or false
        local gSpark  = atGlobalP.globalDisableSpark or false
        local gRev    = atGlobalP.globalReverseSwipe == true
        -- v34: hide-above-1-min flags (container duration formatter; the
        -- engine textColor curve ignores alpha — PTR).
        local gHide   = atGlobalP.globalHideDurationAbove1Min == true
        cache.hideDurAbove1MinBuff         = gHide
        cache.hideDurAbove1MinDebuff       = gHide
        cache.hideDurAbove1MinBigDef       = gHide

        cache.showBuffDuration    = gShow
        cache.buffAutoScale       = gAuto
        cache.buffTimerScale      = gScale
        cache.buffFontSize        = gSize
        cache.buffDurationFont    = gFont
        cache.buffDurationBorder  = gBorder
        cache.buffFontColor       = gColor
        cache.disableBuffSwipe    = gSwipe
        cache.disableBuffSpark    = gSpark
        cache.reverseBuffSwipe    = gRev

        cache.showDebuffDuration  = gShow
        cache.debuffAutoScale     = gAuto
        cache.debuffTimerScale    = gScale
        cache.debuffFontSize      = gSize
        cache.debuffDurationFont  = gFont
        cache.debuffDurationBorder = gBorder
        cache.debuffFontColor     = gColor
        cache.disableDebuffSwipe  = gSwipe
        cache.disableDebuffSpark  = gSpark
        cache.reverseDebuffSwipe  = gRev

        cache.showBigDefDuration    = gShow
        cache.bigDefAutoScale       = gAuto
        cache.bigDefTimerScale      = gScale
        cache.bigDefFontSize        = gSize
        cache.bigDefDurationFont    = gFont
        cache.bigDefDurationBorder  = gBorder
        cache.bigDefFontColor       = gColor
        cache.disableBigDefSwipe    = gSwipe
        cache.disableBigDefSpark    = gSpark
        cache.reverseBigDefSwipe    = gRev

    else
        cache.showBuffDuration    = atBuffP.showBuffDuration ~= false
        cache.buffAutoScale       = atBuffP.buffAutoScale == true
        cache.buffTimerScale      = atBuffP.buffTimerScale or 1.0
        cache.buffFontSize        = atBuffP.buffFontSize or 11
        cache.buffDurationFont    = BF:ResolveFontPathOr(atBuffP.buffDurationFont, _defaultATFont)
        cache.buffDurationBorder  = atBuffP.buffDurationBorder or "OUTLINE"
        cache.buffFontColor       = atBuffP.buffFontColor or _defaultATColor
        -- v34: per-type hide-above-1-min flags (container duration formatter).
        cache.hideDurAbove1MinBuff         = atBuffP.buffHideDurationAbove1Min == true
        cache.hideDurAbove1MinDebuff       = atDebuffP.debuffHideDurationAbove1Min == true
        cache.hideDurAbove1MinBigDef       = atBigDefP.bigDefHideDurationAbove1Min == true
        cache.disableBuffSwipe    = atBuffP.disableBuffSwipe or false
        cache.disableBuffSpark    = atBuffP.disableBuffSpark or false
        cache.reverseBuffSwipe    = atBuffP.reverseBuffSwipe == true

        cache.showDebuffDuration  = atDebuffP.showDebuffDuration ~= false
        cache.debuffAutoScale     = atDebuffP.debuffAutoScale == true
        cache.debuffTimerScale    = atDebuffP.debuffTimerScale or 1.0
        cache.debuffFontSize      = atDebuffP.debuffFontSize or 11
        cache.debuffDurationFont  = BF:ResolveFontPathOr(atDebuffP.debuffDurationFont, _defaultATFont)
        cache.debuffDurationBorder = atDebuffP.debuffDurationBorder or "OUTLINE"
        cache.debuffFontColor     = atDebuffP.debuffFontColor or _defaultATColor
        cache.disableDebuffSwipe  = atDebuffP.disableDebuffSwipe or false
        cache.disableDebuffSpark  = atDebuffP.disableDebuffSpark or false
        cache.reverseDebuffSwipe  = atDebuffP.reverseDebuffSwipe == true

        cache.showBigDefDuration    = atBigDefP.showBigDefDuration or false
        cache.bigDefAutoScale       = atBigDefP.bigDefAutoScale == true
        cache.bigDefTimerScale      = atBigDefP.bigDefTimerScale or 1.0
        cache.bigDefFontSize        = atBigDefP.bigDefFontSize or 11
        cache.bigDefDurationFont    = BF:ResolveFontPathOr(atBigDefP.bigDefDurationFont, _defaultATFont)
        cache.bigDefDurationBorder  = atBigDefP.bigDefDurationBorder or "OUTLINE"
        cache.bigDefFontColor       = atBigDefP.bigDefFontColor or _defaultATColor
        cache.disableBigDefSwipe    = atBigDefP.disableBigDefSwipe or false
        cache.disableBigDefSpark    = atBigDefP.disableBigDefSpark or false
        cache.reverseBigDefSwipe    = atBigDefP.reverseBigDefSwipe == true

    end

    -- Expiring color curves. The per-(buff/debuff/...) FontColor fields
    -- above are read by BuildCurveFromProfile via aboveColor parameter.
    if useGlobal then
        local curve, hides = BuildCurveFromProfile(atGlobalP, "global", cache.buffFontColor)
        cache.expiringCurveBuff         = curve
        cache.expiringCurveDebuff       = curve
        cache.expiringCurveBigDef       = curve
        cache.curveHidesBuff         = hides
        cache.curveHidesDebuff       = hides
        cache.curveHidesBigDef       = hides
    else
        local curve, hides
        curve, hides = BuildCurveFromProfile(atBuffP,   "buff",   cache.buffFontColor)
        cache.expiringCurveBuff = curve
        cache.curveHidesBuff = hides
        curve, hides = BuildCurveFromProfile(atDebuffP, "debuff", cache.debuffFontColor)
        cache.expiringCurveDebuff = curve
        cache.curveHidesDebuff = hides
        curve, hides = BuildCurveFromProfile(atBigDefP, "bigDef", cache.bigDefFontColor)
        cache.expiringCurveBigDef = curve
        cache.curveHidesBigDef = hides
    end

    -- Stack text settings (from auraText.stackText). Shared by every
    -- aura indicator's Update body AND by BF:ApplyStackTextSpec, which
    -- folds them into every 12.1 container button spec.
    local stP = atp.stackText or {}
    cache.showStackText   = stP.showStackText ~= false
    cache.stackAutoScale  = stP.stackAutoScale == true
    cache.stackTimerScale = stP.stackTimerScale or 1.0
    cache.stackTextFont   = stP.stackTextFont
    cache.stackTextSize   = stP.stackTextSize or 9
    cache.stackTextBorder = stP.stackTextBorder or "OUTLINE"
    cache.stackTextAnchor = stP.stackTextAnchor or "BOTTOMRIGHT"
    cache.stackTextX      = stP.stackTextX or 4
    cache.stackTextY      = stP.stackTextY or -3
end

-- ============================================================
-- STACK TEXT: container button spec fields
-- ============================================================
-- Aura Text > Stack Text drives the stack count on every aura type, but
-- the 12.1 container path baked Roboto 9 OUTLINE at BOTTOMRIGHT into
-- ContainerFactory's button creation body, stored the FontString as
-- button._bf_count, and then never read it again -- no restyle step, no
-- spec fields, no signature terms. BF:ApplyStackTextStyle (Auras.lua)
-- could not reach it either: it walks the legacy frame.buffFrames /
-- debuffFrames / bigDefIcons / SF_CustomContainerIcons pools looking for
-- icon.count, which the container path does not populate. Net effect:
-- every Stack Text setting was dead on 12.1 auras.
--
-- Every container button spec now carries these fields, and
-- ContainerFactory's ApplyStackCountStyle stamps them at creation AND on
-- every restyle walk.
local STACK_DEFAULT_FONT = "Interface\\AddOns\\BuzzardFrames\\Media\\Fonts\\RobotoCondensed-Bold.ttf"
function BF:ApplyStackTextSpec(spec, ac, size)
    if not spec then return spec end
    ac = ac or BF.AuraCache or {}
    spec.showStacks  = ac.showStackText ~= false
    spec.stackFont   = BF:ResolveFontPathOr(ac.stackTextFont, STACK_DEFAULT_FONT)
    spec.stackSize   = ac.stackTextSize or 9
    spec.stackBorder = ac.stackTextBorder or "OUTLINE"
    spec.stackAnchor = ac.stackTextAnchor or "BOTTOMRIGHT"
    spec.stackX      = ac.stackTextX or 4
    spec.stackY      = ac.stackTextY or -3
    -- Mirrors the legacy pool and the options preview (Auras.lua
    -- ApplyToIcon / DummyAuras.lua): the configured size is kept and
    -- auto-scale multiplies it by the icon's deviation from the 12px
    -- baseline, rather than swapping in a fixed base size the way the
    -- duration text does.
    spec.stackScale  = (ac.stackAutoScale == true)
        and ((size or 12) / 12 * (ac.stackTimerScale or 1.0)) or 1
    return spec
end

-- ============================================================
-- BF:UpdateCrossSectionCache(cache, flat, grp)
--
-- Owns the cross-section fields not owned by any single indicator:
--   - aurasAbovePowerBar (read by 5 indicators)
--   - hasDebuffHighlightFeatures (derived OR of dispel indicator gates)
--
-- Runs AFTER per-indicator UpdateDB pass (step 3 in RebuildAuraCacheScope)
-- so it can read indicator-owned fields like cache.enableDebuffBorder,
-- cache.debuffSize.
--
-- Notes:
--   - v67: the rpDB.profile.layouts (lpp) read went away with the Private
--     Auras feature; nothing here consults layouts any more.
-- ============================================================
function BF:UpdateCrossSectionCache(cache, flat, grp)
    local hpP = ResolveCFGSection(self, flat, grp, "healthPower") or {}
    -- Global context.
    -- v93: `cache.db = self.db.profile` was here. Removed — a per-flat
    -- _auraCache lives inside a saved profile, so that one line put a nested
    -- copy of the whole main profile in SavedVariables for every flat and in
    -- every export. The single reader (BF:GetDefaultBuffGroupConfig,
    -- AuraGroupHelpers.lua) reads BF.db.profile directly now; the value is
    -- identical, since this only ever held self.db.profile.
    -- aurasAbovePowerBar (shared layout gate).
    cache.aurasAbovePowerBar = hpP.aurasAbovePowerBar and true or false

    -- v67: the extraDebuffYOffset derivation was removed here with the
    -- Private Auras feature (it read cache.privateAuraAnchorPoint /
    -- cache.privateAuraSize, both gone). Nothing reads the field now.

    -- hasDebuffHighlightFeatures derived gate (OR of the dispel toggles).
    local hasDH = false
    if cache.enableDebuffBorder then hasDH = true end
    if cache.enableDebuffOverlay then hasDH = true end
    if cache.showDispelIndicator then hasDH = true end
    if cache.enableDebuffHealthColor then hasDH = true end
    cache.hasDebuffHighlightFeatures = hasDH

    -- v93: hasBuffHighlightConfigs DELETED. The field had no reader anywhere in
    -- the addon -- its last one, Indicators/BuffHighlight.lua, went with the v67
    -- 12.1 cut -- and the `cache == self.AuraCache` test that guarded its
    -- derivation was the ONLY scope-identity branch in the builder. Removing it
    -- makes every scope take the same path here, and drops the unwritten rule
    -- that per-flat scopes had to be rebuilt AFTER the global (the else arm read
    -- BF.AuraCache; BFLayout's direct _RebuildAuraCacheScope call leaned on it).
    -- Do not reintroduce the field without a reader.
end

-- ============================================================
-- RebuildAuraCacheScope(cache, flat, grp) — file-local.
--
-- Rebuilds one aura cache scope (global BF.AuraCache OR a per-CFG flat's
-- _auraCache OR a per-layout flat's _auraCache). Replaces the per-flat
-- RebuildFlatCache and the per-scope writes the legacy UpdateAuraSizeCache
-- did inline.
--
-- 7-step pipeline:
--   1. Wipe cache (no metatable fallback — flat self-contained).
--   2. Iterate BF._auraIndicatorsOrdered, calling each :UpdateDB(cache, flat, grp).
--      Owns per-indicator section/auraText writes (sizes, anchors, show toggles,
--      *ColorAuraBorder, debuffDurationDispelColor, dispel gates with local
--      blizzardDispelActive, etc.). v67: privateAuraGeometryKey removed.
--   3. BF:UpdateAuraTextSettings — cross-coupled font/border/color/timer/
--      swipe/spark/curve fields (5 indicators get identical values under
--      useGlobal).
--   4. BF:UpdateCrossSectionCache — aurasAbovePowerBar,
--      hasDebuffHighlightFeatures.
--   5. Offset stamps via CalcAuraOffsets. Reads cache._rounded*Size +
--      spacing + perRow + growDir + anchor (all written by step 1).
--   6. cfgBorderColor stamps for buff/bigDef. Reads
--      cache.*ColorAuraBorder (step 1) and cache.*FontColor (step 3).
--   7. _cacheGen bump.
-- ============================================================
local function RebuildAuraCacheScope(cache, flat, grp)
    -- 1. Wipe + reset (no metatable fallback — flat is self-contained).
    -- Preserve the generation counter across the wipe. The wipe below
    -- clears every key including _cacheGen; if we let it reset to nil the
    -- increment in step 7 always produces 1, so the counter never advances
    -- and BuildAuraGroupCtx's generation guard (pool._gen == gen) never
    -- detects a rebuild — leaving stale ctx (font/swipe/showDur/etc.) on
    -- icons until a /reload. Carry the prior value so step 7 increments it
    -- monotonically.
    local prevGen = cache._cacheGen
    for k in pairs(cache) do cache[k] = nil end
    if getmetatable(cache) then setmetatable(cache, nil) end
    cache._cacheGen = prevGen

    -- 2. Per-indicator UpdateDB pass.
    local ordered = BF._auraIndicatorsOrdered
    if ordered then
        for i = 1, #ordered do
            local ind = ordered[i]
            if ind.UpdateDB then ind:UpdateDB(cache, flat, grp) end
        end
    end

    -- 3. Cross-coupled auraText fields (font/border/color/curve/etc).
    BF:UpdateAuraTextSettings(cache, flat, grp)

    -- 4. Cross-section fields (aurasAbovePowerBar, dispel gates).
    BF:UpdateCrossSectionCache(cache, flat, grp)

    -- 5. Offset stamps. Derived from per-indicator size/spacing/perRow/
    --    growDir/anchor fields written in step 2.
    if CalcAuraOffsets then
        cache._buffOffsets         = CalcAuraOffsets(cache._roundedBuffSize or 12, cache.buffSpacing or 1, cache.buffRowSpacing or 1, cache.buffsPerRow or 3, cache.buffGrowDir or "LEFT", cache.buffAnchor or "BOTTOMRIGHT")
        cache._debuffOffsets       = CalcAuraOffsets(cache._roundedDebuffSize or 12, cache.debuffSpacing or 1, cache.debuffRowSpacing or 1, cache.debuffsPerRow or 3, cache.debuffGrowDir or "RIGHT", cache.debuffAnchor or "BOTTOMLEFT")
        cache._bigDefOffsets       = CalcAuraOffsets(cache._roundedBigDefSize or 24, cache.bigDefSpacing or 1, cache.bigDefRowSpacing or 1, cache.bigDefIconsPerRow or 5, cache.bigDefGrowDirection or "RIGHT", cache.bigDefAnchor or "CENTER")
    end

    -- 6. Border-color stamps. Reads cache.*ColorAuraBorder (step 2) and
    --    cache.*FontColor (step 3). Unified mechanism per Constraint C —
    --    same path for global and per-flat scopes.
    cfgBorderColor(cache, "buff")
    cfgBorderColor(cache, "bigDef")

    -- 7. Generation counter.
    cache._cacheGen = (cache._cacheGen or 0) + 1
end

-- ============================================================
-- BF:IterateAuraCacheScopes(callback)
--
-- Yields (cache, flat, grp) for every aura cache scope:
--   * Global:        cache = BF.AuraCache, flat = active raid/party flat, grp = nil
--   * CFG flat:      cache = flat._auraCache,  flat = the CFG flat,  grp = CFG group config
--   * Per-layout:    cache = flat._auraCache,  flat = the per-layout flat, grp = nil
-- ============================================================
function BF:IterateAuraCacheScopes(callback)
    -- Global scope: pick the live active flat.
    local isRaid = self:ResolveActiveIsRaid()
    local activeFlat = isRaid and self:GetRaidProfile() or self:GetActivePartyProfile()
    callback(self.AuraCache, activeFlat, nil)
    -- CFG flats.
    local cfgp = self.cfgDB and self.cfgDB.profile
    local groups = cfgp and cfgp.customFrameGroups
    if groups then
        for _, grp in ipairs(groups) do
            local flat = grp and grp.flat
            if flat then
                flat._auraCache = flat._auraCache or {}
                callback(flat._auraCache, flat, grp)
            end
        end
    end
    -- Per-layout flats.
    local lp = self.rpDB and self.rpDB.profile and self.rpDB.profile.layouts
    local flatLayouts = lp and lp.flatLayouts
    if flatLayouts then
        for _, flat in pairs(flatLayouts) do
            if type(flat) == "table" then
                flat._auraCache = flat._auraCache or {}
                callback(flat._auraCache, flat, nil)
            end
        end
    end
end

-- Exposed for the dispatcher switch in UpdateAuraSizeCache.
BF._RebuildAuraCacheScope = RebuildAuraCacheScope

-- ============================================================
-- BF:UpdateAuraSizeCache() — Phase 2 dispatcher.
--
-- Pre-Phase-2: ~680-line inline function that walked every section,
-- wrote every cache field, derived cross-section gates, and rebuilt
-- per-flat caches via a local PopulateCFGAuraCache helper (deleted v93).
--
-- Post-Phase-2: shrinks to dispatch. Per-indicator UpdateDB methods
-- (BF._auraIndicatorsOrdered) own their own section reads. Shared
-- helpers UpdateAuraTextSettings + UpdateCrossSectionCache own the
-- cross-coupled and cross-section fields. RebuildAuraCacheScope
-- orchestrates per scope. IterateAuraCacheScopes walks every scope.
--
-- Side effects this function still owns (NOT cache rebuilds):
--   * Wipe dirty flags after rebuild.
--   * Re-stamp preview-frame _bf_auraCache pointers (per-layout flats only).
--   * Invalidate CFG container settings cache.
-- ============================================================
function BF:UpdateAuraSizeCache()
    -- ── Instrumentation (perf plan §T5.3 #3 and §L5.1) ──────────────
    -- uLoad is nil once the login harness has sealed, and uDbg is false
    -- unless db.global.debugTiming is on, so a shipped install pays one
    -- table lookup here and nothing else.
    local uLoad = self.LoadUASCBegin and self:LoadUASCBegin() or nil
    local uDbg  = self.db and self.db.global and self.db.global.debugTiming
    local uT0   = uLoad or (uDbg and debugprofilestop()) or nil
    local uAllDirty, uScopes = _allFlatsDirty, 1  -- the global scope always rebuilds

    -- Global scope always rebuilt (per pre-Phase-2 semantics — every
    -- UpdateAuraSizeCache call refreshed the global cache fully).
    -- Pick the active flat for the global scope.
    local isRaid = self:ResolveActiveIsRaid()
    local activeFlat = isRaid and self:GetRaidProfile() or self:GetActivePartyProfile()
    RebuildAuraCacheScope(self.AuraCache, activeFlat, nil)

    -- Per-flat scopes: only rebuild dirty flats (preserves pre-Phase-2
    -- dirty-flag perf invariant).
    local cfgp = self.cfgDB and self.cfgDB.profile
    local groups = cfgp and cfgp.customFrameGroups
    if groups then
        for _, grp in ipairs(groups) do
            local flat = grp and grp.flat
            if flat and (_allFlatsDirty or _flatCacheDirty[flat]) then
                flat._auraCache = flat._auraCache or {}
                RebuildAuraCacheScope(flat._auraCache, flat, grp)
                uScopes = uScopes + 1
            end
        end
    end
    local lp = self.rpDB and self.rpDB.profile and self.rpDB.profile.layouts
    local flatLayouts = lp and lp.flatLayouts
    if flatLayouts then
        for _, flat in pairs(flatLayouts) do
            if type(flat) == "table" and (_allFlatsDirty or _flatCacheDirty[flat]) then
                flat._auraCache = flat._auraCache or {}
                RebuildAuraCacheScope(flat._auraCache, flat, nil)
                uScopes = uScopes + 1
            end
        end
    end

    wipe(_flatCacheDirty)
    _allFlatsDirty = false

    -- Re-stamp _bf_auraCache on every per-layout preview frame so any
    -- preview frame whose flat just had its cache rebuilt picks up the
    -- new cache pointer. CFG preview frames re-resolve their cache from
    -- the CFG flat at RefreshPreview time (see Options_PreviewSystem.lua
    -- ~line 1007) so they don't need re-stamping here.
    if BF._previewFrames and flatLayouts then
        for flatID, pf in pairs(BF._previewFrames) do
            local pfFlat = flatLayouts[flatID]
            pf._bf_auraCache = pfFlat and pfFlat._auraCache or nil
        end
    end

    -- Invalidate the container settings cache for CFG keys so containers
    -- pick up the new buffSize/spacing/etc from the rebuilt per-CFG caches.
    if BF.InvalidateContainerSettingsCacheCFGOnly then
        BF:InvalidateContainerSettingsCacheCFGOnly()
    end

    -- ── Instrumentation tail ────────────────────────────────────────
    -- §T5.3 #3: per-flip pass counter. `_uascFlipCount` is reset at the top
    -- of SetSectionPerLayout, so `#n` reads as "nth pass caused by THIS
    -- toggle" -- the number that proves (or kills) the multi-pass claim.
    if uDbg then
        self._uascFlipCount = (self._uascFlipCount or 0) + 1
        print(("|cff11ace9BF|r   UASC #%d scopes=%d (1 global + cfg + flats) allDirty=%s %7.1f ms")
            :format(self._uascFlipCount, uScopes, tostring(uAllDirty),
                    debugprofilestop() - uT0))
    end
    -- §L5.1: per-call-site count + total ms for the login passes.
    if uLoad then self:LoadUASCEnd(uLoad) end
end

-- Pre-Phase-2 UpdateAuraSizeCache monolith deleted; see git history
-- and Docs/AURAICON_CONSTRUCTOR_UNIFICATION_PLAN.md for the field
-- ownership audit. Per-indicator UpdateDB methods + UpdateAuraTextSettings
-- + UpdateCrossSectionCache + RebuildAuraCacheScope now own everything
-- the legacy body did.

-- Shared offset calculator used by RebuildAuraCacheScope (per-scope) and ShowDummyAuras (preview).
-- growDir controls which direction the grid expands, exactly like private auras:
--   LEFT/RIGHT = primary step direction is horizontal; perRow = icons per row; rows wrap UP
--   UP/DOWN    = primary step direction is vertical;   perRow = icons per column; columns wrap in secondary dir
-- iconSpacing  = gap between icons along the primary direction (within a row/column)
-- rowSpacing   = gap between rows/columns (the wrap direction)
-- Returns the 1px inward nudge (x, y) for a given anchor point so icons sit
-- 1 pixel away from the frame edge rather than flush against it.

local function AnchorNudge(anchor)
    local pm = BF:PixelsToUI(1)
    local x = anchor:find("LEFT")  and  pm or anchor:find("RIGHT")  and -pm or 0
    local y = anchor:find("TOP")   and -pm or anchor:find("BOTTOM") and  pm or 0
    return x, y
end

-- Returns a table of {x, y} signed pixel offsets relative to the anchor point.
-- All offsets are nudged 1 physical pixel inward from the anchor edge so icons
-- never sit flush against the frame border.
-- ============================================================
-- v34 TWO-AXIS GROW DIRECTIONS
-- Grow direction values are now explicit "PRIMARY_SECONDARY" tokens
-- (e.g. "RIGHT_UP" = fill right, wrap upward): RIGHT/LEFT primary with
-- UP/DOWN secondary, and UP/DOWN primary with LEFT/RIGHT secondary.
-- Legacy single-axis values ("RIGHT" etc.) are normalized on read with
-- the SAME anchor-derived secondary the old CalcAuraOffsets used, so
-- existing profiles keep their exact appearance.
-- ============================================================

-- Default grow direction per anchor point (owner-specified table; the
-- options anchor setters auto-apply this when the anchor changes).
BF.GROW_DEFAULT_FOR_ANCHOR = {
    BOTTOM      = "RIGHT_UP",
    BOTTOMLEFT  = "RIGHT_UP",
    BOTTOMRIGHT = "LEFT_UP",
    CENTER      = "RIGHT_DOWN",
    LEFT        = "RIGHT_DOWN",
    RIGHT       = "LEFT_DOWN",
    TOP         = "RIGHT_DOWN",
    TOPLEFT     = "RIGHT_DOWN",
    TOPRIGHT    = "LEFT_DOWN",
}

-- Normalize a stored grow direction to the two-axis form. Legacy values
-- derive their secondary from the anchor exactly like the pre-v34
-- CalcAuraOffsets wrap rule (TOP anchors wrapped down, others up;
-- RIGHT anchors wrapped left, others right) — appearance-preserving.
function BF.NormalizeGrowDirection(dir, anchor)
    if not dir then return nil end
    if dir:find("_", 1, true) then return dir end
    anchor = anchor or ""
    if dir == "RIGHT" or dir == "LEFT" then
        return dir .. (anchor:find("TOP") and "_DOWN" or "_UP")
    elseif dir == "UP" or dir == "DOWN" then
        return dir .. (anchor:find("RIGHT") and "_LEFT" or "_RIGHT")
    end
    return dir
end

-- True when the primary axis is vertical (drives the Per Column /
-- Column Spacing option labels).
function BF.GrowDirectionIsVertical(dir)
    return dir ~= nil and (dir:sub(1, 3) == "UP_" or dir:sub(1, 5) == "DOWN_")
end

CalcAuraOffsets = function(size, iconSpacing, rowSpacing, perRow, growDir, anchor)
    local offsets = {}
    -- Pixel-round size and spacing so every step lands on a pixel boundary.
    local rSize    = BF:PixelRound(size)
    local rSpacing = BF:PixelRound(iconSpacing)
    local rRowSp   = BF:PixelRound(rowSpacing)
    local primaryStep = rSize + rSpacing
    local wrapStep    = rSize + rRowSp
    -- v34: explicit two-axis direction (legacy values normalized with
    -- the historical anchor-derived secondary).
    local dir = BF.NormalizeGrowDirection(growDir or "RIGHT_DOWN", anchor)
    local prim, sec = dir:match("^(%u+)_(%u+)$")
    if not prim then prim, sec = "RIGHT", "DOWN" end
    local stepX = (prim == "RIGHT" and primaryStep) or (prim == "LEFT" and -primaryStep) or 0
    local stepY = (prim == "UP"    and primaryStep) or (prim == "DOWN" and -primaryStep) or 0
    local wrapX = (sec == "RIGHT" and wrapStep) or (sec == "LEFT" and -wrapStep) or 0
    local wrapY = (sec == "UP"    and wrapStep) or (sec == "DOWN" and -wrapStep) or 0
    -- NOTE (v34 divergence): the old perRow<=1 special case (stack along
    -- the PRIMARY direction) is gone — with perRow 1 every icon wraps, so
    -- icons advance along the SECONDARY axis. This matches the 12.1
    -- container flow layout exactly (line size = one element → every
    -- element starts a new line along the cross axis).
    if not perRow or perRow < 1 then perRow = 1 end
    -- 1px inward nudge baked into every offset so both real and dummy paths benefit
    local nx, ny = AnchorNudge(anchor)
    for i = 1, 10 do
        local slot  = i - 1
        local major = slot % perRow          -- position within current row/column
        local minor = math_floor(slot / perRow) -- which row/column
        offsets[i] = {
            x = major * stepX + minor * wrapX + nx,
            y = major * stepY + minor * wrapY + ny,
        }
    end
    return offsets
end

-- ============================================================
-- EXPOSE FOR SPLIT FILES
-- These are consumed by ScanAndDisplay.lua and DummyAuras.lua
-- at load time as local upvalues.
-- ============================================================

BF.AnchorNudge               = AnchorNudge
BF.CalcAuraOffsets            = CalcAuraOffsets
BF.GetBackdropTable           = GetBackdropTable
BF.SetFrameBackdrop           = SetFrameBackdrop
-- BF.GetSpellBorderColor is set in
-- AuraCustomizations/AuraCustomizationHelpers.lua
-- v67: BF.GetBuffsBorderColor removed (12.0.7-only blanket setting).
BF.ApplyIconTextureOrSolid    = ApplyIconTextureOrSolid
-- BF.ApplyIconTooltip deleted — tooltip wiring lives in Auras/AuraTooltip.lua
-- (BF.indicatorPrototype:EnableFrameTooltips). Consumers call
-- BF.indicators.<name>:EnableFrameTooltips(icon, ...) directly.
BF.WipeAuraBackdropCache      = WipeBackdropCache
