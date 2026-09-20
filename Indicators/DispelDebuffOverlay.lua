--[[
BuzzardFrames: Indicators/DispelDebuffOverlay.lua
Debuff color overlay — a colored gradient overlaying the health bar
when a dispellable/harmful debuff is active on the unit.

Split from DebuffHighlight.lua — fully independent indicator with its
own Update, deferred updates, and status bindings.

Bound to "debuffs" and "dispel" statuses (Grid2 pattern).
]]

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

-- v67: UnitExists/UnitIsVisible upvalues and TEST_OVERLAY_COLOR removed with
-- the 12.0.7 branch (addon is 12.1-only) — they had no other reader.

local DispelDebuffOverlay = BF.indicatorPrototype:new("dispelDebuffOverlay")

-- Per-scope cache write. Resolves blizzardDispelActive locally.
function DispelDebuffOverlay:UpdateDB(cache, flat, grp)
    -- v60: resolved per aura sub-category. The Buffs and Debuffs
    -- per-layout toggles are independent, so a flat's auras table can
    -- carry stale rawkeys for whichever group is currently OFF --
    -- ResolveCFGSection(..., "auras") plus an index would read them.
    local diP    = BF.ResolveCFGAurasSubcat(BF, flat, grp, "dispelIndicator") or {}
    local blizzardActive = diP.dispelIndicatorOverlayMode == "blizzard"
    cache.enableDebuffOverlay      = (not blizzardActive) and (diP.enableDebuffOverlay == true) or false
    cache.debuffOverlayMode        = diP.debuffOverlayMode or "dispellable"
    cache.debuffOverlayAlpha       = diP.debuffOverlayAlpha or 0.5
    cache.debuffOverlayHeight      = diP.debuffOverlayHeight or 0.7
    cache.debuffOverlayFillOnly    = diP.debuffOverlayFillOnly == true
    cache.dispelOverlayOnlyIfReady = diP.dispelOverlayOnlyIfReady or false
    -- Debuff Health Color Change (owner): dispellable-debuff-triggered health
    -- bar tint -- the dispelHealthColor kind of the merged dispel-visual slot,
    -- registered at the bottom of this file. Cached from the same
    -- dispelIndicator sub-category, and forced off in blizzard mode exactly
    -- like the overlay above (the options section hides then too).
    cache.enableDebuffHealthColor      = (not blizzardActive) and (diP.enableDebuffHealthColor == true) or false
    cache.debuffHealthColorMode        = diP.debuffHealthColorMode or "dispellable"
    -- Owner: the tint's color is the DISPEL TYPE color (engine-applied, like
    -- the overlay); the user controls only its opacity.
    cache.debuffHealthColorAlpha       = diP.debuffHealthColorAlpha or 0.7
    cache.dispelHealthColorOnlyIfReady = diP.dispelHealthColorOnlyIfReady or false
end

-- ============================================================
-- 12.1 CONTAINER PATH: 1-slot container; the slot button carries the
-- gradient texture anchored over the health bar, recolored by dispel
-- type engine-side (PreserveAsset). alpha/height/fillOnly are baked at
-- creation (button children immutable post-config) — changes prompt
-- reload. Test-mode divergence: shows real dispel colors, not the
-- legacy fixed blue.
-- ============================================================
-- Dispel color map with the overlay opacity baked into each color's
-- alpha: the engine re-applies these as vertex colors on every aura
-- update, making opacity robust even if region SetAlpha on the bound
-- texture is denied/stomped post-PEW.
local function OverlayColorMap(alpha)
    local m = {}
    for k, v in pairs(BF.DispelVisualColorMap) do
        m[k] = { r = v.r, g = v.g, b = v.b, a = alpha }
    end
    return m
end

-- v84 (Stage 5 §9.7): INIT-WINDOW build. The gradient lives on the overlay
-- kind's own absolute-level host frame, never on the button — on a merged slot
-- the button carries two or three kinds and belongs to none of them. The round
-- mask is a BINDING and is therefore attached here, in the init window, once.
-- The health bar's height as the overlay sees it. The slot is built in the
-- frame build pass, BEFORE the first Layout sizes the bar, so GetHeight() is
-- 0 there; fall back to the health area's DESIGNED height (the same arithmetic
-- Container:Layout is about to anchor the bar by), so the height baked at
-- creation and the height the first Layout measures agree. Inside a keystone
-- that agreement is what keeps the slot from being rebuilt once per frame on
-- load (2026-09-11 field run: "dispel" x1 on every frame).
--
-- Rounded to 1/100 of a unit: a measured GetHeight() is the engine's float
-- and differs from the designed value in the 6th decimal (55.721392 vs
-- 55.721398 in the field), which is invisible on screen but was enough to
-- fail the keystone geometry signature on every frame at load.
local function OverlayBarHeight(parent, hBar)
    local h = hBar and hBar:GetHeight() or 0
    if (not h or h <= 0) and BF.ComputeFrameContentSize then
        local _, ch = BF.ComputeFrameContentSize(parent)
        h = ch or 0
    end
    h = h or 0
    return math.floor(h * 100 + 0.5) / 100
end

local function BuildOverlay(button, host, parent, ac)
    local hBar = parent.healthBar
    if not hBar then return end
    local hFill = hBar:GetStatusBarTexture()
    local anchorTo = (ac.debuffOverlayFillOnly and hFill) and hFill or hBar
    host:ClearAllPoints()
    host:SetPoint("TOPLEFT",  anchorTo, "TOPLEFT",  0, 0)
    host:SetPoint("TOPRIGHT", anchorTo, "TOPRIGHT", 0, 0)
    local h0 = OverlayBarHeight(parent, hBar) * (ac.debuffOverlayHeight or 0.7)
    host:SetHeight(h0)
    host._bf_ovH = (h0 > 0) and h0 or nil

    local tex = BF.Texture(host, nil, "OVERLAY", nil, 1)
    tex:SetAllPoints(host)
    tex:SetTexture("Interface\\AddOns\\BuzzardFrames\\Media\\debuff_overlay_gradient")
    tex:SetAlpha(ac.debuffOverlayAlpha or 0.5)
    host._bf_ovTex = tex
    -- Rounded border style: clip to the frame's rounded shape. Attach-once at
    -- init (mask hidden = inert); survives the engine's dispel-type rebinds
    -- since those reuse this same texture object.
    BF:AttachFrameRoundMask(parent, tex)
end

local function OverlaySig(parent, ac)
    return tostring(ac.debuffOverlayFillOnly and true or false) .. "|"
        .. tostring(ac.debuffOverlayMode == "all") .. "|"
        .. tostring(ac.debuffOverlayAlpha or 0.5)
end

-- Binding half of the restamp. Called INSIDE the merged slot's single
-- ClearDispelTypeTextures pass, so it must only ADD. The fillOnly anchor moves
-- with it because the anchor and the binding share one signature.
local function BindOverlay(button, host, parent, ac)
    local tex = host and host._bf_ovTex
    if not tex then return end
    local hBar = parent.healthBar
    if hBar then
        local hFill = hBar:GetStatusBarTexture()
        local anchorTo = (ac.debuffOverlayFillOnly and hFill) and hFill or hBar
        host:ClearAllPoints()
        host:SetPoint("TOPLEFT",  anchorTo, "TOPLEFT",  0, 0)
        host:SetPoint("TOPRIGHT", anchorTo, "TOPRIGHT", 0, 0)
        host._bf_ovH = nil  -- force the height re-stamp in OverlayGeom
    end
    button:AddDispelTypeTexture(tex, {
        style = Enum.CustomAuraButtonDispelTypeTextureStyle
            and Enum.CustomAuraButtonDispelTypeTextureStyle.PreserveAsset or 3,
        showWhenHarmful = true,
        showWithoutDispelType = (ac.debuffOverlayMode == "all"),
        -- opacity baked into the engine-applied colors
        customDispelColorMap = OverlayColorMap(ac.debuffOverlayAlpha or 0.5),
    })
end

-- Live, non-binding geometry. The baked init height derives from
-- healthBar:GetHeight(), which can be 0 if the button was created before the
-- frame was laid out (invisible overlay) and changes with frame resizes.
-- Change-guarded, pcall (V3 class).
local function OverlayGeom(button, host, parent, ac)
    if not host then return end
    local hBar = parent.healthBar
    if not hBar then return end
    local h = OverlayBarHeight(parent, hBar) * (ac.debuffOverlayHeight or 0.7)
    if h > 0 and host._bf_ovH ~= h then
        if pcall(host.SetHeight, host, h) then host._bf_ovH = h end
    end
    local a = ac.debuffOverlayAlpha or 0.5
    if host._bf_ovTex and host._bf_ovA ~= a then
        if pcall(host._bf_ovTex.SetAlpha, host._bf_ovTex, a) then host._bf_ovA = a end
    end
end

-- ============================================================
-- Create
-- ============================================================
function DispelDebuffOverlay:Create(parent)
    -- v84 (Stage 5 §9.7): real frames own no slot of their own — the merged
    -- dispel-visual manager (BF:SyncDispelVisualSlots) owns all three.
    -- Everything below is the PREVIEW-FRAME (legacy painter) path.
    if not parent._isPreviewFrame then
        -- v85: build the dispel slots HERE, in the frame build pass, exactly as
        -- every other aura object is built (and as this feature did before v84
        -- moved creation onto the :Update path). Create-only -- no unit yet, so the
        -- show gate is left to the first :Update. The in-service guard mirrors the
        -- pre-v84 :Create: a frame that has never carried a unit builds nothing and
        -- picks the slots up on its first render pass instead.
        if not BF:ShouldDeferFrameAuraContainers(parent) then
            BF:SyncDispelVisualSlots(parent)
        end
        return
    end
    if parent.dispelDebuffOverlay then
        parent[self.name] = parent.dispelDebuffOverlay
        return
    end

    local hBar = parent.healthBar
    if not hBar then return end

    local tex = BF.Texture(hBar, nil, "OVERLAY", nil, 1)
    tex:SetPoint("TOPLEFT",  hBar, "TOPLEFT",  0, 0)
    tex:SetPoint("TOPRIGHT", hBar, "TOPRIGHT", 0, 0)
    tex:SetHeight(hBar:GetHeight() * 0.5)
    tex:SetTexture("Interface\\AddOns\\BuzzardFrames\\Media\\debuff_overlay_gradient")
    tex:Hide()
    -- Rounded border style: clip to the frame's rounded shape (attach-once;
    -- inert while the mask is hidden).
    BF:AttachFrameRoundMask(parent, tex)

    parent[self.name]         = tex
    parent.dispelDebuffOverlay = tex
end

-- v67: DispelDebuffOverlay:Layout removed (12.1-only). The whole body sat
-- behind a container-path early return, so on 12.1 it was already an empty
-- override; geometry is baked at button init and re-stamped live in :Update.
-- indicatorPrototype:Layout (BFIndicator.lua:53-54) is itself a no-op, so
-- BF:LayoutFrameIndicators still resolves the call.

function DispelDebuffOverlay:GetFrame(parent)
    return parent[self.name]
end

-- ============================================================
-- Update — overlay only
-- ============================================================
-- v67: 12.0.7 branch removed (addon is 12.1-only).
function DispelDebuffOverlay:Update(parent, unit)
    -- v84 §9.7: one owner for all three dispel visuals (see the twin note in
    -- DispelDebuffBorder:Update).
    BF:SyncDispelVisualSlots(parent, unit)
end

-- ── v84 §9.7: this visual's registration with the merged-slot manager ──
BF.DispelVisualDefs.dispelOverlay = {
    resolve = function(parent, ac)
        -- No health bar, nothing to overlay: the kind stands down entirely
        -- (the pre-v84 :Create returned before building its slot).
        local on = ac.enableDebuffOverlay and parent.healthBar and true or false
        local mode = on and (ac.debuffOverlayMode or "dispellable") or nil
        local show = on and ac.hasDebuffHighlightFeatures and true or false
        local ready = ac.dispelOverlayOnlyIfReady and true or false
        if show and ready
            and (mode == "dispellable" or mode == "allDispellable")
            and BF:GetDispelOnCooldownBool() then
            show = false
        end
        return on, mode, show, ready
    end,
    build = BuildOverlay,
    bind  = BindOverlay,
    sig   = OverlaySig,
    geom  = OverlayGeom,
    -- Keystone recreate (plan §3.1, 2026-09-11): what OverlayGeom targets, as
    -- a pure read (see the twin on dispelDot). An unmeasured bar is "-", the
    -- height OverlayGeom would skip, so a slot born before the first Layout
    -- rebuilds once the bar has a size.
    geomSig = function(parent, ac)
        local hBar = parent.healthBar
        local h = hBar and (OverlayBarHeight(parent, hBar) * (ac.debuffOverlayHeight or 0.7)) or 0
        return (h > 0 and tostring(h) or "-") .. "|" .. tostring(ac.debuffOverlayAlpha or 0.5)
    end,
}

-- ── Debuff Health Color Change: the dispelHealthColor visual kind ──────────
-- (owner) A dispellable-debuff-triggered HEALTH BAR TINT. Renders exactly like
-- the per-spell buff "Change Health Color" effect (RestampFxHealth,
-- Indicators/BuffsAndContainers.lua): the kind's host is anchored over the
-- health FILL at health bar + 3 (DISPEL_VISUAL_LEVEL.dispelHealthColor = 3),
-- and its texture is stamped with the
-- profile's own health bar texture so a custom bar texture keeps its shading
-- through the tint. TRIGGERS like the other kinds on this slot: the engine
-- shows the shared button while a debuff matching the Mode is present (the
-- host is a child of the button, so the tint rides its visibility), with the
-- same optional "only while my dispel is ready" gate.
--
-- Owner (v2): the tint's COLOR is the debuff's DISPEL TYPE color, applied
-- engine-side via AddDispelTypeTexture exactly like the overlay kind -- the
-- user controls only its OPACITY, which is baked into the custom color map's
-- alphas (same robustness rationale as OverlayColorMap above). PreserveAsset
-- keeps the health-bar texture file the geom stamps.
local HC_SOLID_TEX = "Interface\\Buttons\\WHITE8x8"

-- Dispel color map with the tint opacity baked into each color's alpha.
-- Twin of OverlayColorMap above.
local function HealthColorMap(alpha)
    local m = {}
    for k, v in pairs(BF.DispelVisualColorMap) do
        m[k] = { r = v.r, g = v.g, b = v.b, a = alpha }
    end
    return m
end

local function BuildHealthColor(button, host, parent, ac)
    local tex = BF.Texture(host, nil, "OVERLAY", nil, 1)
    tex:SetAllPoints(host)
    host._bf_hcTex = tex
    -- Rounded border style: clip to the frame's rounded shape (attach-once;
    -- inert while the mask is hidden). Same call the overlay kind makes.
    BF:AttachFrameRoundMask(parent, tex)
end

local function HealthColorSig(parent, ac)
    return "hc" .. tostring(ac.debuffHealthColorMode == "all") .. "|"
        .. tostring(ac.debuffHealthColorAlpha or 0.7)
end

-- Binding half. Called inside the merged slot's single
-- ClearDispelTypeTextures pass, so it must only ADD (twin of BindOverlay).
local function BindHealthColor(button, host, parent, ac)
    local tex = host and host._bf_hcTex
    if not tex then return end
    button:AddDispelTypeTexture(tex, {
        style = Enum.CustomAuraButtonDispelTypeTextureStyle
            and Enum.CustomAuraButtonDispelTypeTextureStyle.PreserveAsset or 3,
        showWhenHarmful = true,
        showWithoutDispelType = (ac.debuffHealthColorMode == "all"),
        -- opacity baked into the engine-applied colors
        customDispelColorMap = HealthColorMap(ac.debuffHealthColorAlpha or 0.7),
    })
end

-- Live, non-binding geometry. Mirrors RestampFxHealth's anchoring: host over
-- the health FILL texture, tint stamped with the bar's own texture file (the
-- engine's PreserveAsset color pass tints it per dispel type). Sig-guarded
-- and pcall'd (V3 class).
--
-- Opacity is stamped HERE on the HOST FRAME, not the texture: the engine's
-- per-update dispel-color pass re-stamps the BOUND texture's properties
-- (owner-observed: the tint rendered fully opaque with the alpha in the
-- color map, and again with region SetAlpha on the texture -- both are
-- engine-stomped). The host frame is BF-owned and untouched by the rebinds,
-- and frame alpha multiplies onto child regions, so it survives every
-- engine pass. The map alphas stay as a harmless extra.
local function HealthColorGeom(button, host, parent, ac)
    local hBar = parent.healthBar
    local tex = host and host._bf_hcTex
    if not (tex and hBar) then return end
    local hp = BF:GetSectionProfileForFrame("healthPower", parent)
    local hbTex = (hp and hp.useCustomHealthBarTexture)
        and BF:ResolveBarTexture(hp.healthBarTexture) or HC_SOLID_TEX
    if host._bf_hcSig ~= hbTex then
        if pcall(function()
            local hFill = hBar:GetStatusBarTexture()
            local anchorTo = hFill or hBar
            host:ClearAllPoints()
            host:SetPoint("TOPLEFT",     anchorTo, "TOPLEFT",     0, 0)
            host:SetPoint("BOTTOMRIGHT", anchorTo, "BOTTOMRIGHT", 0, 0)
            tex:SetTexture(hbTex)
            tex:SetTexCoord(0, 1, 0, 1)
            tex:SetAllPoints(host)
        end) then host._bf_hcSig = hbTex end
    end
    local a = ac.debuffHealthColorAlpha or 0.7
    if host._bf_hcA ~= a then
        if pcall(host.SetAlpha, host, a) then host._bf_hcA = a end
    end
end

BF.DispelVisualDefs.dispelHealthColor = {
    resolve = function(parent, ac)
        -- No health bar, nothing to tint (same stand-down as the overlay).
        local on = ac.enableDebuffHealthColor and parent.healthBar and true or false
        local mode = on and (ac.debuffHealthColorMode or "dispellable") or nil
        local show = on and ac.hasDebuffHighlightFeatures and true or false
        local ready = ac.dispelHealthColorOnlyIfReady and true or false
        if show and ready
            and (mode == "dispellable" or mode == "allDispellable")
            and BF:GetDispelOnCooldownBool() then
            show = false
        end
        return on, mode, show, ready
    end,
    build = BuildHealthColor,
    bind  = BindHealthColor,
    sig   = HealthColorSig,
    geom  = HealthColorGeom,
    -- Keystone recreate (plan §3.1, 2026-09-11): what HealthColorGeom
    -- targets (bar texture file + host alpha), as a pure read.
    geomSig = function(parent, ac)
        local hp = BF:GetSectionProfileForFrame("healthPower", parent)
        local hbTex = (hp and hp.useCustomHealthBarTexture)
            and BF:ResolveBarTexture(hp.healthBarTexture) or HC_SOLID_TEX
        return tostring(hbTex) .. "|" .. tostring(ac.debuffHealthColorAlpha or 0.7)
    end,
}

BF:RegisterIndicator(DispelDebuffOverlay)
DispelDebuffOverlay:EnableDeferredUpdates()
