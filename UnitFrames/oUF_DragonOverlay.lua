-- ============================================================
-- BuzzardFrames: oUF_DragonOverlay.lua
-- Elite / rare-elite / worldboss dragon border overlay for
-- unit frames. Manages the gold/silver dragon frame, rare
-- indicator icon, skull icon, and level text visibility.
--
-- Used by: target, focus, targettarget, focustarget.
-- NOT used by: player, pet, boss frames.
-- ============================================================
local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local UnitExists          = UnitExists
local UnitClassification  = UnitClassification
local UnitLevel           = UnitLevel
local CreateFrame         = CreateFrame
local C_Texture           = C_Texture
local ipairs              = ipairs
local math_floor          = math.floor

-- ============================================================
-- _BuildOUFDragonOverlay
-- Creates dragon frame, rare indicator, and event listener.
-- Called once from each unit frame's Build function.
-- unit      : "target", "focus", "targettarget", "focustarget"
-- events    : list of events to register (e.g. { "PLAYER_TARGET_CHANGED" })
-- ============================================================
function BF:_BuildOUFDragonOverlay(f, unit, events)
    -- Dragon frame
    -- Parented to the unit frame (not UIParent) so it inherits the frame's
    -- SetScale from the overall Scale slider. Its frame level is set relative
    -- to f below, so the stacking order is unchanged by the reparent.
    local dragonFrame = CreateFrame("Frame", nil, f)
    dragonFrame:SetFrameStrata("MEDIUM")
    dragonFrame:SetFrameLevel(f:GetFrameLevel() + 9)
    dragonFrame:EnableMouse(false)
    dragonFrame:Hide()
    local dragonTex = BF.Texture(dragonFrame, nil, "OVERLAY", nil, 1)
    dragonTex:SetAllPoints(dragonFrame)
    f._dragonFrame = dragonFrame
    f._dragonTex   = dragonTex

    -- Rare indicator icon
    -- Parented to the unit frame for the same scale-inheritance reason as the
    -- dragon frame above.
    local rareFrame = CreateFrame("Frame", nil, f)
    rareFrame:SetFrameStrata("MEDIUM")
    rareFrame:SetFrameLevel(f:GetFrameLevel() + 10)
    rareFrame:EnableMouse(false)
    rareFrame:Hide()
    local rareTex = BF.Texture(rareFrame, nil, "OVERLAY", nil, 2)
    rareTex:SetAllPoints(rareFrame)
    rareTex:SetAtlas("nameplates-icon-elite-silver")
    f._rareFrame = rareFrame
    f._rareTex   = rareTex

    -- Store the unit so the shared update function knows which unit to query.
    f._dragonUnit = unit

    -- Geometry + atlas caches, populated by _LayoutOUFDragonOverlay and read
    -- (not recomputed) by the per-target-change _UpdateOUFDragonOverlay hot
    -- path. Allocated once here and overwritten in place on each layout to
    -- avoid GC churn during rapid option changes (e.g. icon-size slider).
    f._dragonGeo   = { regDsz = 0, regOffX = 0, wingW = 0, wingH = 0, wingOffX = 0 }
    f._dragonAtlas = {}   -- [atlasName] = { file, l, r, t, b }; file=false => use SetAtlas fallback

    -- Event listener
    local listener = CreateFrame("Frame")
    listener:SetScript("OnEvent", function()
        BF:_UpdateOUFDragonOverlay(f)
    end)
    for _, ev in ipairs(events) do
        listener:RegisterEvent(ev)
    end
    listener:RegisterUnitEvent("UNIT_CLASSIFICATION_CHANGED", unit)
    f._dragonListener = listener
end

-- ============================================================
-- Shared helpers
-- ============================================================

-- Returns true when the dragon overlay should be hidden due to
-- profile-level settings (icon off, model style, square shape,
-- or showEliteDragonBorder toggled off).
local function ShouldHideDragon(p)
    if p.playerShowClassIcon == false then return true end
    if (p.iconStyle or "classicon") == "model"   then return true end
    if (p.iconShape or "circular")  ~= "circular" then return true end
    if p.showEliteDragonBorder == false then return true end
    return false
end

-- Reads icon dimensions from profile and returns computed values.
--
-- Everything the dragon art needs (padding and horizontal offset) is
-- expressed as a fixed FRACTION of iconFrameSz, calibrated against the
-- size where the art lines up correctly: iconSz 58 + ring 2 = 62, where
-- the tuned values are dragonPad 9 and outer offset 6. Because the art
-- scales uniformly, keeping these as fractions of iconFrameSz makes the
-- dragon look proportionally identical at every icon size instead of
-- drifting (right gap when small, too-far-left when large) the way the
-- old fixed-pixel constants did.
--
-- When the icon border is disabled the ring is hidden, so iconFrameSz is
-- just iconSz (mirroring _ApplyOUFIconBlock). Basing the fractions on the
-- true iconFrameSz then also removes the gap that appeared when the
-- border was off but the dragon still sized itself as if a ring existed.
local DRAGON_CAL          = 62        -- iconFrameSz at the calibration point
local DRAGON_PAD_FRAC     = 9  / DRAGON_CAL
local DRAGON_OFF_FRAC     = 6  / DRAGON_CAL   -- regular, "outer", border ON
-- With the border off the icon has no ring, so the dragon needs a slightly
-- smaller rightward offset; without this it sits a hair too far right and
-- leaves a small gap on the icon's right edge at larger icon sizes.
local DRAGON_OFF_FRAC_NB  = 5.5 / DRAGON_CAL  -- regular, "outer", border OFF
local DRAGON_OFF_INNER    = -2 / DRAGON_CAL   -- regular, "inner" (art flipped)
local DRAGON_WOFF_FRAC    = 4  / DRAGON_CAL   -- winged, "outer"
local DRAGON_WOFF_INNER   = -4 / DRAGON_CAL   -- winged, "inner"
local DRAGON_WNUDGE_FRAC  = 11 / DRAGON_CAL   -- winged extra horizontal nudge

-- Derives the dragon's padding from the icon frame size. The icon frame
-- size is NOT recomputed here: it is read from frame._iconFrameSz, which
-- _ApplyOUFIconBlock (oUF_Shared.lua) already computed and cached for this
-- frame. That cached value is the single source of truth -- it accounts
-- for the border-on/off ring AND the per-frame iconScale, both of which
-- this code previously ignored. _ApplyOUFIconBlock always runs before the
-- dragon layout (oUF_Shared.lua: _ApplyOUFIconBlock at 3241, postLayout ->
-- _LayoutOUFDragonOverlay at 3338), so the cache is populated in time.
local function GetDragonPad(iconFrameSz)
    -- Floor (not round-to-nearest) the padding: at sizes where the padding
    -- raw value lands just over an integer (e.g. iconFrameSz 46 -> 6.68,
    -- 80 -> 11.61) round-to-nearest steps it up a whole pixel, inflating
    -- the dragon so its inner opening pulls ~1px off the icon's right edge
    -- and leaves a gap. Flooring biases the dragon slightly smaller so the
    -- opening stays on the icon. At the calibration point (iconFrameSz 62
    -- -> exactly 9) floor and round agree, so the tuned look is unchanged.
    return math_floor(iconFrameSz * DRAGON_PAD_FRAC)
end

-- Horizontal offset for the regular (square) dragon, scaled to icon size.
-- borderOn selects the calibrated outer offset; with the border off a
-- slightly smaller fraction is used so the dragon doesn't drift right.
--
-- The offset is a whole number of pixels, so round-to-nearest can land
-- ~half a pixel too far right at some sizes, leaving a tiny gap on the
-- icon's right edge (this happens with the border on OR off). For both
-- outer cases we truncate (round toward the icon) instead of rounding to
-- nearest, so the dragon never sits too far right; any residual error
-- becomes a sub-pixel overlap, which is invisible, rather than a visible
-- gap. Truncation is identical to round-to-nearest at the calibration
-- point (iconFrameSz 62 -> exactly 6), so the tuned look is preserved.
-- The "inner" case keeps round-to-nearest (its offset is small and the
-- art is mirrored, so it has no right-edge gap to correct).
local function DragonOffsetX(iconFrameSz, loc, borderOn)
    if loc == "inner" then
        return math_floor(iconFrameSz * DRAGON_OFF_INNER + 0.5)
    end
    local frac = borderOn and DRAGON_OFF_FRAC or DRAGON_OFF_FRAC_NB
    return math_floor(iconFrameSz * frac)
end

-- Horizontal offset for the winged boss dragon, scaled to icon size.
local function WingedOffsetX(iconFrameSz, loc)
    local frac = (loc == "inner") and DRAGON_WOFF_INNER or DRAGON_WOFF_FRAC
    local base  = iconFrameSz * frac
    local nudge = iconFrameSz * DRAGON_WNUDGE_FRAC
    return math_floor(base + nudge + 0.5)
end

-- The three dragon atlases. Fixed set, so the per-frame atlas cache has at
-- most these three entries. Names must match the atlas strings selected by
-- classification in _UpdateOUFDragonOverlay.
local DRAGON_ATLASES = {
    "UI-HUD-UnitFrame-Target-PortraitOn-Boss-Gold-Winged",
    "UI-HUD-UnitFrame-Target-PortraitOn-Boss-Gold",
    "UI-HUD-UnitFrame-Target-PortraitOn-Boss-Silver",
}

-- Builds f._dragonGeo (sizes + offsets) and f._dragonAtlas (texture file +
-- final texcoords, inner-flip baked in) from the cached icon frame size.
-- Called only from _LayoutOUFDragonOverlay (cold path: option change /
-- profile switch / reload), so the per-target-change update path can read
-- these without any arithmetic or GetAtlasInfo call. Mirrors Grid2's
-- IndicatorShape, which resolves GetAtlasInfo once at DB-update time and
-- stores iconPath + iconCoord for its hot path.
--
-- INVARIANT: every profile field consumed here (iconFrameSz via
-- _ApplyOUFIconBlock, iconLocation, classIconBorderEnabled) must trigger a
-- relayout when changed, NOT just _UpdateOUFDragonOverlay -- otherwise these
-- caches go stale. The nil-guard in the hot path only covers an unbuilt
-- cache, not a stale one. All current option setters call relayoutAll, so
-- this holds; new ones must preserve it.
local function BuildDragonCache(f, p, iconFrameSz)
    local loc      = p.iconLocation or "outer"
    local borderOn = p.classIconBorderEnabled ~= false
    local dragonPad = GetDragonPad(iconFrameSz)

    local geo = f._dragonGeo
    -- Regular (square) dragon.
    geo.regDsz  = math_floor((iconFrameSz + dragonPad * 2) * 1.05 + 0.5)
    geo.regOffX = DragonOffsetX(iconFrameSz, loc, borderOn)
    -- Winged boss dragon (99x81 atlas: wider than tall). Stored fractional,
    -- exactly as the old per-update code passed to SetSize.
    local baseH = iconFrameSz + dragonPad * 2
    geo.wingW    = baseH * (99 / 81) * 1.07
    geo.wingH    = baseH * 1.05
    geo.wingOffX = WingedOffsetX(iconFrameSz, loc)

    -- Atlas table: resolve each atlas once, baking the inner/outer flip into
    -- the stored texcoords. file=false signals "GetAtlasInfo failed, use the
    -- SetAtlas(name) fallback" so we never SetTexture(nil).
    local cache = f._dragonAtlas
    for i = 1, #DRAGON_ATLASES do
        local name = DRAGON_ATLASES[i]
        local entry = cache[name]
        if not entry then
            entry = {}
            cache[name] = entry
        end
        local info = C_Texture.GetAtlasInfo(name)
        if info then
            entry.file = info.file
            local l, r = info.leftTexCoord, info.rightTexCoord
            local t, b = info.topTexCoord,  info.bottomTexCoord
            if loc == "inner" then
                entry.l, entry.r, entry.t, entry.b = r, l, t, b
            else
                entry.l, entry.r, entry.t, entry.b = l, r, t, b
            end
        else
            entry.file = false
        end
    end
end

-- ============================================================
-- _LayoutOUFDragonOverlay
-- Positions and sizes the dragon and rare frames relative to
-- f._iconFrame.  Called from each frame's postLayout callback.
-- ============================================================
function BF:_LayoutOUFDragonOverlay(f)
    if not f._dragonFrame then return end
    local p = self.ufDB.profile

    -- Visibility conditions: hide if icon is off, model, square, or option off.
    -- Also require the cached icon frame size from _ApplyOUFIconBlock.
    local iconFrameSz = f._iconFrameSz
    if ShouldHideDragon(p) or not f._iconFrame or not iconFrameSz then
        f._dragonFrame:Hide()
        if f._rareFrame then f._rareFrame:Hide() end
        return
    end

    -- Compute geometry + atlas data once and cache it; the per-target-change
    -- update path reads these without recomputing. Size/anchor of the dragon
    -- frame itself is applied in _UpdateOUFDragonOverlay because it depends on
    -- runtime classification (winged worldboss vs square elite).
    BuildDragonCache(f, p, iconFrameSz)
    f._dragonFrame:Show()

    -- Rare icon: position at the bottom-center of the icon frame
    if f._rareFrame and f._iconFrame then
        local rareSz = math_floor(iconFrameSz * 0.45 + 0.5)
        f._rareFrame:ClearAllPoints()
        f._rareFrame:SetSize(rareSz, rareSz)
        f._rareFrame:SetPoint("TOP", f._iconFrame, "BOTTOM", 0, rareSz * 0.35)
    end

    -- Refresh the atlas / visibility for the current unit.
    self:_UpdateOUFDragonOverlay(f)
end

-- ============================================================
-- _UpdateOUFDragonOverlay
-- Atlas selection, inner flip, winged boss sizing, skull icon,
-- show/hide.  Called by the event listener and at the end of
-- _LayoutOUFDragonOverlay.
-- ============================================================
function BF:_UpdateOUFDragonOverlay(f)
    if not f or not f._dragonFrame or not f._dragonTex then return end
    local unit = f._dragonUnit or f.__unit
    if not unit then return end

    local p = self.ufDB.profile

    -- Always hide rare icon by default; shown only for "rare" below.
    if f._rareFrame then f._rareFrame:Hide() end

    -- Visibility conditions (same as _LayoutOUFDragonOverlay).
    if ShouldHideDragon(p) then
        f._dragonFrame:Hide()
        return
    end

    if not UnitExists(unit) then
        f._dragonFrame:Hide()
        f._dragonTex:Hide()
        if f._skullIcon then f._skullIcon:Hide() end
        return
    end

    local cls   = UnitClassification(unit)
    local level = UnitLevel(unit)
    local atlas
    if cls == "worldboss" or (cls == "elite" and level == -1) then
        atlas = "UI-HUD-UnitFrame-Target-PortraitOn-Boss-Gold-Winged"
    elseif cls == "elite" then
        atlas = "UI-HUD-UnitFrame-Target-PortraitOn-Boss-Gold"
    elseif cls == "rareelite" then
        atlas = "UI-HUD-UnitFrame-Target-PortraitOn-Boss-Silver"
    elseif cls == "rare" then
        f._dragonFrame:Hide()
        f._dragonTex:Hide()
        if f._rareFrame then f._rareFrame:Show() end
        return
    end

    if atlas then
        -- Geometry + atlas data are precomputed by BuildDragonCache at layout
        -- time; this hot path only reads them. If the cache is not yet built
        -- (an event fired before the first layout) build it now from the
        -- cached icon frame size. This guards the nil case only -- staleness
        -- is prevented by every relevant option change triggering a relayout.
        local entry = f._dragonAtlas[atlas]
        if not entry then
            local iconFrameSz = f._iconFrameSz
            if not iconFrameSz then
                f._dragonFrame:Hide()
                f._dragonTex:Hide()
                return
            end
            BuildDragonCache(f, p, iconFrameSz)
            entry = f._dragonAtlas[atlas]
        end

        local geo = f._dragonGeo
        -- Size/anchor MUST be set every update: the shared dragon frame flips
        -- between winged (wide) and square on classification changes.
        f._dragonFrame:ClearAllPoints()
        if cls == "worldboss" or (cls == "elite" and level == -1) then
            f._dragonFrame:SetSize(geo.wingW, geo.wingH)
            f._dragonFrame:SetPoint("CENTER", f._iconFrame, "CENTER", geo.wingOffX, 0)
        else
            f._dragonFrame:SetSize(geo.regDsz, geo.regDsz)
            f._dragonFrame:SetPoint("CENTER", f._iconFrame, "CENTER", geo.regOffX, 0)
        end

        -- Apply cached atlas texture + texcoords (inner-flip already baked in).
        -- Always SetTexture+SetTexCoord rather than SetAtlas, because SetAtlas
        -- after a manual SetTexCoord does not reliably reset tex coords. If the
        -- atlas could not be resolved at build time (entry.file == false), fall
        -- back to SetAtlas so we never SetTexture(nil).
        if entry and entry.file then
            f._dragonTex:SetTexture(entry.file)
            f._dragonTex:SetTexCoord(entry.l, entry.r, entry.t, entry.b)
        else
            f._dragonTex:SetAtlas(atlas)
        end
        f._dragonFrame:Show()
        f._dragonTex:Show()
    else
        -- Normal mob, no classification badge.
        f._dragonFrame:Hide()
        f._dragonTex:Hide()
    end

    -- Skull icon: show for boss-level units (level == -1), hide level text.
    local isBoss = level == -1
    if f._skullIcon then
        f._skullIcon:SetShown(isBoss)
    end
    if f.Level then
        local unitKey = unit
        if unitKey and unitKey:match("^boss%d") then unitKey = "boss" end
        local pf = p[unitKey] or {}
        f.Level:SetShown(not isBoss and (pf.showLevel ~= false))
    end
end
