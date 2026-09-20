-- ============================================================
-- BuzzardFrames: AuraCustomizations/PreviewIconEffects.lua
--
-- Dedicated, preview-frame-only renderer for the per-spell Icon
-- Effects (v84) shown on the Aura Customizations → Icon Effects subtab.
--
-- WHY THIS EXISTS (and why it does not share the live render path):
--   * The live path drives engine-owned aura buttons with gates tuned
--     for combat performance (BF.playerSpecID-keyed resolvers). Reusing
--     it for preview required mutating global state — every such leak
--     risks visible bugs on real frames.
--   * This module reads the per-spec config DIRECTLY from
--     acDB.profile.specSpellIconEffect (v84) keyed on the
--     currently-previewed spec. It never touches BF.playerSpecID
--     and never sets any global flag the live render path consults.
--
-- ISOLATION CONTRACT:
--   * All preview art is self-contained (own textures + animation
--     groups created on the preview icon); nothing here reads or
--     writes the live render path's per-icon fields.
--
-- v67: the preview Bounce path is gone (private driver, active set,
-- Start/StopBounceOnIcon, BOUNCE_* constants and the GetBounceCfg stub).
-- GetBounceCfg had already been reduced to `return nil`, so nothing could
-- ever start a preview bounce; AuraCustomizations/Bounce.lua — the live
-- counterpart this mirrored — has been deleted too.
--
-- The Options panel calls a single entry point — Apply(frame, sid, specId)
-- — for each preview frame whenever the user enters the Icon Effects
-- subtab OR edits any glow option. ClearAll() runs on subtab exit /
-- spell change / preview clear, sweeping every preview icon this module
-- has touched.
-- ============================================================

local BF  = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local pairs, ipairs = pairs, ipairs

-- ============================================================
-- TRACKED ICON SET
-- Every icon that this module has started a glow on lives here
-- until torn down. The set is the sole source of truth for
-- ClearAll — we never walk preview frames blindly.
-- ============================================================
local _touchedIcons = {}  -- icon -> true

-- ============================================================
-- v67: BOUNCE start/stop removed (see the header note).
-- ============================================================
-- ICON RESOLUTION
-- For a given preview frame and (sid, specId), return the icon
-- widget that represents the previewed spell — or nil if the
-- spell is currently untracked (no icon to attach effects to).
--
-- Mirrors the routing logic in ShowSingleSpellPreview:
--   container-assigned → frame.SF_CustomContainerIcons[ci][1]
--   default-assigned   → frame.buffFrames[1]
--   untracked          → nil
-- ============================================================
local function ResolvePreviewIcon(frame, sid, specId)
    if not frame then return nil end
    local acp = BF.acDB and BF.acDB.profile
    if not acp then return nil end

    -- Determine assignment for this spell on this spec.
    local assign = acp.spellAssign and acp.spellAssign[specId] and acp.spellAssign[specId][sid]
    local containerIndex
    local isUntracked = false
    if assign == "untracked" then
        isUntracked = true
    elseif type(assign) == "string" then
        local n = tonumber(assign:match("^c:(%d+)$"))
        if n then containerIndex = n end
    end
    if not assign then
        -- Fall back to DEFAULT_UNTRACKED list from SPEC_SPELLS.
        local specSpells = BF.SPEC_SPELLS and BF.SPEC_SPELLS[specId] or {}
        for _, s in ipairs(specSpells) do
            if s.id == sid and s.untracked then
                isUntracked = true
                break
            end
        end
    end
    if isUntracked then return nil end

    if containerIndex then
        local pool = frame.SF_CustomContainerIcons and frame.SF_CustomContainerIcons[containerIndex]
        local icon = pool and pool[1]
        if icon and icon:IsShown() then return icon end
        return nil
    end

    -- Default-assigned: slot 1 of the buff pool.
    local icon = frame.buffFrames and frame.buffFrames[1]
    if icon and icon:IsShown() then return icon end
    return nil
end

-- ============================================================
-- CONFIG READ (preview spec, NOT BF.playerSpecID)
-- ============================================================
-- v84 (Stage 5 §9.9): the Icon Effects entry (replaces the retired
-- specSpellExpirationGlow read). Preview-spec keyed, NOT BF.playerSpecID.
local function GetIconEffectCfg(sid, specId)
    local p = BF.acDB and BF.acDB.profile
    local sg = p and p.specSpellIconEffect and p.specSpellIconEffect[specId]
    local e = sg and sg[sid]
    if not e or e.enabled == false then return nil end
    return e
end

-- ============================================================
-- v84 (Stage 5 §9.9): PREVIEW PAINTERS
--
-- Preview icons are ORDINARY frames built by BF.BuildAuraIconFrame — not
-- engine-owned aura buttons — so none of the live path's restrictions apply
-- here: textures and animation groups can be created and played at any time,
-- and there is no forbidden partition. The art is nevertheless reproduced with
-- the SAME assets, texcoords and proportions as the live path, because the
-- point of the preview is to look like the result.
--
-- PANDEMIC IS DELIBERATELY NOT PREVIEWED: the ENGINE decides when a pandemic
-- region renders, from the aura's secret remaining duration. A dummy icon has
-- no aura and therefore no window, and faking one would advertise a threshold
-- the live path cannot honor.
local PREVIEW_FX_DEFAULT_COLOR = { 1, 0.82, 0.25, 1 }

-- Build (once per icon) the preview art. Mirrors the live init-window bake.
local function EnsurePreviewFx(icon)
    if icon._bf_pvFx then return icon._bf_pvFx end
    local host = CreateFrame("Frame", nil, icon)
    host:SetAllPoints(icon)
    host:SetFrameLevel(icon:GetFrameLevel() + 4)

    local ring = BF.Texture(host, nil, "OVERLAY")
    ring:SetTexture("Interface\\SpellActivationOverlay\\IconAlert")
    ring:SetTexCoord(0.00781250, 0.50781250, 0.27734375, 0.52734375)
    ring:Hide()
    local ringAG = ring:CreateAnimationGroup()
    ringAG:SetLooping("REPEAT")
    local gIn = ringAG:CreateAnimation("Alpha")
    gIn:SetOrder(1); gIn:SetDuration(0.6); gIn:SetFromAlpha(0.35); gIn:SetToAlpha(1)
    local gOut = ringAG:CreateAnimation("Alpha")
    gOut:SetOrder(2); gOut:SetDuration(0.6); gOut:SetFromAlpha(1); gOut:SetToAlpha(0.35)

    local ants = BF.Texture(host, nil, "OVERLAY", nil, 2)
    ants:SetTexture("Interface\\SpellActivationOverlay\\IconAlertAnts")
    ants:Hide()
    local antsAG = ants:CreateAnimationGroup()
    antsAG:SetLooping("REPEAT")
    local fb = antsAG:CreateAnimation("FlipBook")
    fb:SetDuration(0.7)
    fb:SetFlipBookRows(5); fb:SetFlipBookColumns(5); fb:SetFlipBookFrames(22)
    -- 48px frames on a 256px sheet: without explicit frame dimensions the
    -- flipbook divides the FULL sheet into 5ths and every frame samples
    -- off-grid (the ants visibly jump).
    if fb.SetFlipBookFrameWidth then
        fb:SetFlipBookFrameWidth(48)
        fb:SetFlipBookFrameHeight(48)
    end

    local flash = BF.Texture(host, nil, "OVERLAY", nil, 3)
    flash:SetTexture("Interface\\Buttons\\WHITE8x8")
    -- v94: LayoutPreviewFx owns the rect and the blend mode now (it has to --
    -- both depend on whether this icon is currently a Square (Color by
    -- Duration), which changes per repaint). These creation-time values match
    -- its "button" branch so its change-guards start in a true state.
    flash:SetBlendMode("ADD")
    flash:SetAllPoints(icon)
    flash:SetAlpha(0)
    flash:Hide()
    local flashAG = flash:CreateAnimationGroup()
    flashAG:SetLooping("REPEAT")
    local fIn = flashAG:CreateAnimation("Alpha")
    fIn:SetOrder(1); fIn:SetDuration(0.4); fIn:SetFromAlpha(0); fIn:SetToAlpha(0.5)
    local fOut = flashAG:CreateAnimation("Alpha")
    fOut:SetOrder(2); fOut:SetDuration(0.4); fOut:SetFromAlpha(0.5); fOut:SetToAlpha(0)

    local recolor = BF.Texture(icon, nil, "ARTWORK", nil, 2)
    recolor:SetTexture("Interface\\Buttons\\WHITE8x8")
    if icon.Icon then recolor:SetAllPoints(icon.Icon) else recolor:SetAllPoints(icon) end
    recolor:Hide()

    icon._bf_pvFx = {
        host = host, ring = ring, ringAG = ringAG, gIn = gIn, gOut = gOut,
        ants = ants, antsAG = antsAG,
        flash = flash, flashAG = flashAG, fIn = fIn, fOut = fOut,
        recolor = recolor,
    }
    return icon._bf_pvFx
end

-- Geometry parity with ApplyGlowGeometry: both read the shared constants
-- at the top of Auras/ContainerFactory.lua. These were hardcoded 0.2 /
-- 1.19 while the live ring pad had moved to 0.34, so this preview drew a
-- visibly smaller ring than the icons it was previewing.
local function LayoutPreviewFx(icon, fx)
    local w = icon:GetWidth() or 24
    if not w or w <= 0 then w = 24 end
    local pad = w * BF.AURA_GLOW_PAD
    fx.ring:ClearAllPoints()
    fx.ring:SetPoint("TOPLEFT", icon, "TOPLEFT", -pad, pad)
    fx.ring:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", pad, -pad)
    local aw = w * BF.AURA_ANTS_SCALE
    fx.ants:ClearAllPoints()
    fx.ants:SetPoint("CENTER", icon, "CENTER", 0, 0)
    fx.ants:SetSize(aw, aw)

    -- ── v94: FLASH on a Square (Color by Duration) ────────────────────────
    -- The preview draws that icon type as a real glyph over an ALPHA-0 icon
    -- region now, so it inherits the two corrections v93 made on the live
    -- path (ContainerFactory.lua, the flash rect / blend block) -- without
    -- them a square previews with exactly the two bugs those fixed.
    --
    -- (a) RECT: anchored to the button, the flash covers a region whose art
    --     is invisible, and the glyph's ink does not fill the em box -- live
    --     showed a 1px line rather than a lit square. Anchor to the GLYPH,
    --     with the same measured 1px correction: glyph ink cannot be
    --     pixel-snapped and there is no API to read where it landed, so the
    --     offset is measured, not derived. Explicit corner points, not
    --     SetAllPoints, so it rides in the target's own scaled space.
    -- (b) BLEND: ADD renders `underlying + flash x alpha`, right over dark
    --     icon ART but wrong over a square that is already a saturated
    --     duration-curve color -- the channels clip toward white and the
    --     configured Effect Color barely reads. BLEND shows the chosen
    --     color at the chosen alpha.
    --
    -- The marker is the flag the square painter stamps (_bf_sbSquareText),
    -- which is set and cleared in lockstep with the glyph itself; the TARGET is
    -- that painter's own FontString (_bf_sbSquareGlyph), never the engine
    -- countdown string -- the square exists precisely BECAUSE the countdown is
    -- suppressed for this icon type, so anchoring to it would size the flash
    -- off a hidden, stale, digit-count-dependent rect. Live anchors to its
    -- equivalent (button._bf_duration) for the same reason.
    local glyph = icon._bf_sbSquareText and icon._bf_sbSquareGlyph or nil
    local wantRect = glyph and "glyph" or "button"
    if icon._bf_pvFlashRect ~= wantRect then
        if pcall(function()
            fx.flash:ClearAllPoints()
            if glyph then
                local px = BF:PixelsToUI(1)
                fx.flash:SetPoint("TOPLEFT",     glyph, "TOPLEFT",     -px, -px)
                fx.flash:SetPoint("BOTTOMRIGHT", glyph, "BOTTOMRIGHT", -px, -px)
            else
                fx.flash:SetAllPoints(icon)
            end
        end) then
            icon._bf_pvFlashRect = wantRect
        end
    end
    local wantBlend = glyph and "BLEND" or "ADD"
    if icon._bf_pvFlashBlend ~= wantBlend then
        if pcall(fx.flash.SetBlendMode, fx.flash, wantBlend) then
            icon._bf_pvFlashBlend = wantBlend
        end
    end
end

-- SINGLE PASS: resolve everything, apply once. Never tear down and re-apply --
-- that restarts the animations visibly.
local function ApplyPreviewFx(icon, e)
    local fx = EnsurePreviewFx(icon)
    LayoutPreviewFx(icon, fx)
    local kind = e and e.effect or nil
    local c = (e and e.color) or nil
    local cr = c and (c.r or 1) or PREVIEW_FX_DEFAULT_COLOR[1]
    local cg = c and (c.g or 0.82) or PREVIEW_FX_DEFAULT_COLOR[2]
    local cb = c and (c.b or 0.25) or PREVIEW_FX_DEFAULT_COLOR[3]
    local ca = c and (c.a or 1) or PREVIEW_FX_DEFAULT_COLOR[4]

    if kind == "glow" then
        -- Tint on the vertex color, STRENGTH on object alpha -- live parity
        -- with ApplyGlowCore (Auras/ContainerFactory.lua); vertex-color alpha
        -- is inert on these ring assets.
        fx.ring:SetVertexColor(cr, cg, cb)
        fx.ring:SetAlpha(ca)
        fx.ring:Show()
        if e.glowStyle == "pulse" then
            fx.gIn:SetFromAlpha(ca * 0.35); fx.gIn:SetToAlpha(ca)
            fx.gOut:SetFromAlpha(ca); fx.gOut:SetToAlpha(ca * 0.35)
            if not fx.ringAG:IsPlaying() then fx.ringAG:Play() end
        else
            -- Stop() restores the baked alpha (1); re-stamp the configured one.
            if fx.ringAG:IsPlaying() then fx.ringAG:Stop() end
            fx.ring:SetAlpha(ca)
        end
    else
        if fx.ringAG:IsPlaying() then fx.ringAG:Stop() end
        fx.ring:Hide()
    end

    if kind == "ants" then
        fx.ants:SetVertexColor(cr, cg, cb)
        fx.ants:SetAlpha(ca)
        fx.ants:Show()
        if not fx.antsAG:IsPlaying() then fx.antsAG:Play() end
    else
        if fx.antsAG:IsPlaying() then fx.antsAG:Stop() end
        fx.ants:Hide()
    end

    if kind == "flash" then
        fx.flash:SetVertexColor(cr, cg, cb)
        fx.fIn:SetToAlpha(ca)
        fx.fOut:SetFromAlpha(ca)
        fx.flash:Show()
        if not fx.flashAG:IsPlaying() then fx.flashAG:Play() end
    else
        if fx.flashAG:IsPlaying() then fx.flashAG:Stop() end
        fx.flash:Hide()
    end

    local tex = icon.Icon
    if tex then tex:SetDesaturated(e and e.desaturate and true or false) end

    if e and e.recolor then
        local rc = e.recolorColor
        fx.recolor:SetVertexColor(rc and (rc.r or 1) or 1,
            rc and (rc.g or 1) or 1, rc and (rc.b or 1) or 1,
            rc and (rc.a or 0.5) or 0.5)
        fx.recolor:Show()
    else
        fx.recolor:Hide()
    end
end

local function ClearPreviewFx(icon)
    local fx = icon._bf_pvFx
    if not fx then return end
    if fx.ringAG:IsPlaying() then fx.ringAG:Stop() end
    if fx.antsAG:IsPlaying() then fx.antsAG:Stop() end
    if fx.flashAG:IsPlaying() then fx.flashAG:Stop() end
    fx.ring:Hide(); fx.ants:Hide(); fx.flash:Hide(); fx.recolor:Hide()
    if icon.Icon then icon.Icon:SetDesaturated(false) end
end

-- v67: GetBounceCfg stub removed — it was already an unconditional
-- `return nil`, so the preview bounce branch it fed was unreachable.

-- ============================================================
-- SHARED FX PAINTER (container Icon Effect previews)
--
-- DummyAuras' _paintPreviewContainerIcon paints the per-CONTAINER Icon
-- Effect (BF:ResolveContainerIconEffect — same entry shape as the
-- per-spell config this module reads) on its own preview-only icon
-- pools through these two exports, so the container preview and the
-- per-spell preview can never drift on what an entry looks like.
--
-- Deliberately NOT tracked in _touchedIcons: that set belongs to the
-- per-spell preview's ClearAll lifecycle (subtab exit / spell change).
-- Container preview icons live in DummyAuras' own pools, which clear
-- the fx themselves on repaint and on slot hide.
-- ============================================================
function BF.PaintPreviewIconEffectFx(icon, e)
    if not icon then return end
    ApplyPreviewFx(icon, e)
end

function BF.ClearPreviewIconEffectFx(icon)
    if not icon then return end
    ClearPreviewFx(icon)
end

-- v94: the TRACKED variant, for the Buff List preview (DummyAuras'
-- _PaintSingleBuffDummy).
--
-- Same paint, but the icon joins _touchedIcons. The container preview above
-- can go untracked because its own repaint clears the fx on every pass and on
-- slot hide; the Buff List pass has an extra exit its pools do not cover --
-- LEAVING the subtab, which changes the preview MODE and so stops the pass
-- from running at all. Nothing would then repaint those icons, and a glow the
-- entry no longer owns would sit on a pooled icon until something else reused
-- it. ClearAll walks this set and nothing else, so membership is what makes
-- that teardown reach them.
function BF.PaintPreviewIconEffectFxTracked(icon, e)
    if not icon then return end
    _touchedIcons[icon] = true
    ApplyPreviewFx(icon, e)
end

-- ============================================================
-- PUBLIC: Apply / ApplyToAllFrames / ClearAll
-- ============================================================

-- Apply the per-spell glow config to the single preview icon on
-- `frame`. Stops whatever this module previously attached before
-- starting the new effect, so a recolor / type change /
-- enable-disable just calls Apply again. The glow is presence-only
-- (matching the live path) — no threshold is consulted.
function BF:PreviewIconEffects_Apply(frame, sid, specId)
    if not frame or not sid or not specId then return end

    local icon = ResolvePreviewIcon(frame, sid, specId)
    if not icon then
        -- Spell is untracked or the icon hasn't been rendered yet.
        -- Nothing to attach to; nothing to clean (Apply only ever
        -- attaches via the start helpers, which gate on icon != nil).
        return
    end

    -- v84 §9.9: Icon Effects (glow / ants / flash / desaturate / recolor).
    -- Pandemic is live-only — the engine owns its window.
    local e = GetIconEffectCfg(sid, specId)
    _touchedIcons[icon] = true
    ApplyPreviewFx(icon, e)
end

-- Apply to every visible preview frame for the currently-previewed
-- spell. Reads preview state via the existing BF helpers so the
-- caller doesn't have to pass anything.
function BF:PreviewIconEffects_ApplyToAllFrames()
    if not BF:IsPreviewingSpell() then return end
    local sid    = BF:GetPreviewSpellID()
    local specId = BF:GetPreviewSpecID()
    if not sid or not specId then return end

    if BF._previewFrames then
        for _, f in pairs(BF._previewFrames) do
            if f:IsShown() then
                BF:PreviewIconEffects_Apply(f, sid, specId)
            end
        end
    end
    if BF._previewCFFrames then
        for _, cf in ipairs(BF._previewCFFrames) do
            if cf and cf:IsShown() then
                BF:PreviewIconEffects_Apply(cf, sid, specId)
            end
        end
    end
end

-- Tear down every effect this module ever started. Called when the
-- user leaves the Icon Effects subtab, switches to a different spell,
-- or exits the spell page entirely. Walking _touchedIcons (not preview
-- frames) means we only do work proportional to icons we actually
-- modified — and we never look at live frames.
function BF:PreviewIconEffects_ClearAll()
    for icon in pairs(_touchedIcons) do
        ClearPreviewFx(icon)
        _touchedIcons[icon] = nil
    end
end

-- Perf plan §L5.1 load-time mark: opens options run 2 (.toc 152-158).
if BuzzardFrames then BuzzardFrames:LoadMark("chunk:preOptions2") end
