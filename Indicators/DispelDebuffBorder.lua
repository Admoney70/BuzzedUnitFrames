--[[
BuzzardFrames: Indicators/DispelDebuffBorder.lua
Debuff dispellable border indicator.

Split from the monolithic DebuffHighlight.lua — this indicator is responsible
ONLY for the colored border that appears when a dispellable/harmful debuff is
on the unit. The overlay and dot are now independent indicators in
DispelDebuffOverlay.lua and DispelDebuffIndicator.lua respectively.

Bound to "debuffs" and "dispel" statuses (Grid2 pattern).
Uses EnableDeferredUpdates so double-fires from debuffs+dispel in the same
tick collapse to a single _DoUpdate.
]]

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

-- v67: UnitExists/UnitIsVisible upvalues removed with the 12.0.7 branch
-- (addon is 12.1-only) — they had no other reader.

local function PixelsToUI(n)
    local pixelSize = 768 / select(2, GetPhysicalScreenSize())
    local uiScale   = UIParent:GetEffectiveScale()
    local pixelMult = (uiScale > 0) and (pixelSize / uiScale) or 1
    return n * pixelMult
end

local function MakeEdge(parent)
    local t = BF.Texture(parent, nil, "OVERLAY")
    t:SetColorTexture(0, 0, 0, 0)
    return t
end

-- ============================================================

local DispelDebuffBorder = BF.indicatorPrototype:new("dispelDebuffBorder")

-- Per-scope cache write. Resolves blizzardDispelActive locally from
-- diP.dispelIndicatorOverlayMode (not from cache.dispelIndicatorOverlayMode)
-- to avoid step-1 read-after-write ordering issues with DispelDebuffIndicator.
function DispelDebuffBorder:UpdateDB(cache, flat, grp)
    -- v60: resolved per aura sub-category. The Buffs and Debuffs
    -- per-layout toggles are independent, so a flat's auras table can
    -- carry stale rawkeys for whichever group is currently OFF --
    -- ResolveCFGSection(..., "auras") plus an index would read them.
    local diP    = BF.ResolveCFGAurasSubcat(BF, flat, grp, "dispelIndicator") or {}
    local blizzardActive = diP.dispelIndicatorOverlayMode == "blizzard"
    cache.enableDebuffBorder       = (not blizzardActive) and (diP.enableDebuffBorder == true) or false
    cache.debuffBorderMode         = diP.debuffBorderMode or "dispellable"
    cache.debuffBorderWidth        = diP.debuffBorderWidth or 2
    cache.dispelBorderOnlyIfReady  = diP.dispelBorderOnlyIfReady or false
end

-- ============================================================
-- 12.1 CONTAINER PATH: the border is a 1-slot AuraContainer whose slot
-- button carries four edge textures, each registered with
-- AddDispelTypeTexture (PreserveAsset recolors our WHITE8x8-style edges
-- by dispel type). The engine shows the button only while the filter
-- matches an aura — the legacy eager dispel scan is not consulted.
-- Mode → filter; "all" keeps a None color so any debuff shows red.
-- ============================================================
local DISPEL_BORDER_COLOR_MAP
do
    local dtc = _G.DebuffTypeColor or {}
    local function col(key, r, g, b)
        local c = dtc[key]
        if c then return { r = c.r, g = c.g, b = c.b } end
        return { r = r, g = g, b = b }
    end
    DISPEL_BORDER_COLOR_MAP = {
        Magic   = col("Magic",   0.2, 0.6, 1.0),
        Curse   = col("Curse",   0.6, 0.0, 1.0),
        Disease = col("Disease", 0.6, 0.4, 0.0),
        Poison  = col("Poison",  0.0, 0.6, 0.0),
        Bleed   = col("Bleed",   0.8, 0.0, 0.0),
        None    = { r = 0.8, g = 0.0, b = 0.0 },  -- "all" mode fallback (legacy red)
    }
end

-- v84 (Stage 5 §9.7): the local DispelBorderFilterFor wrapper is gone with the
-- per-visual slot. Filter and candidate resolution for all three dispel visuals
-- now happens once, in the merged-slot manager, straight off
-- BF.DispelVisualFilterFor (the shared mapper this only ever delegated to).

local PRESERVE_ASSET = Enum.CustomAuraButtonDispelTypeTextureStyle
    and Enum.CustomAuraButtonDispelTypeTextureStyle.PreserveAsset or 3

-- Bind the engine dispel-recolor to the active border geometry: the
-- nine-slice RING for rounded frame styles (PreserveAsset tints the
-- white ring by dispel type — the same recipe the aura dispel borders
-- use, ContainerFactory ApplyDispelBorderBinding), or the 4 flat edges
-- for square. Inactive geometry is hidden and left unbound so the engine
-- never shows it. `ringTex` nil => square.
-- v58: the ring's texture is set by the CALLER via BF:StampRingPixelHost
-- (which pairs SetTexture with the pixel-snap re-enable) — a second
-- SetTexture here would re-trigger the global unsnap hook.
-- v84 (Stage 5 §9.7): NO ClearDispelTypeTextures here any more. The merged
-- slot's combined restamp owns exactly one clear for the whole button; a clear
-- inside a per-kind binder is precisely the collision that made three visuals
-- unable to share a button (each assumed sole ownership of the binding set).
local function BindDispelGeometry(button, edges, ring, ringTex, showNone)
    local opts = {
        style = PRESERVE_ASSET,
        showWhenHarmful = true,
        showWithoutDispelType = showNone,
        customDispelColorMap = DISPEL_BORDER_COLOR_MAP,
    }
    if ringTex and ring then
        for i = 1, 4 do edges[i]:Hide() end
        button:AddDispelTypeTexture(ring, opts)
    else
        if ring then ring:Hide() end
        for i = 1, 4 do
            edges[i]:Show()
            button:AddDispelTypeTexture(edges[i], opts)
        end
    end
end

-- The rounded ring, on its OWN pixel host inside the kind's level host.
-- v58 pixel host (see PixelPerfect.lua EnsureHighlightRing): the ring renders
-- at 1 art texel = 1 physical pixel; scale + snap are stamped by the callers
-- via BF:StampRingPixelHost. v84: created under `host` (the border kind's
-- absolute-level host frame) rather than directly under the button, so a merged
-- button's other visuals never sit inside the ring's pixel-snapped scale.
local function EnsureSlotRing(host)
    local ring = host._bf_roundRing
    if not ring then
        local ph = CreateFrame("Frame", nil, host)
        ph:SetAllPoints(host)
        ph:SetFrameLevel(host:GetFrameLevel())
        host._bf_ringHost = ph
        ring = BF.Texture(ph, nil, "OVERLAY")
        ring:SetTextureSliceMargins(BF.RoundedBorderSlice, BF.RoundedBorderSlice,
            BF.RoundedBorderSlice, BF.RoundedBorderSlice)
        ring:SetAllPoints(host)
        host._bf_roundRing = ring
    end
    return ring
end

-- v84 (Stage 5 §9.7): INIT-WINDOW build. Every region this visual can ever need
-- is created here, on the kind's level host — bindings and geometry are stamped
-- later by BindBorder / RestampBorderGeometry, which the merged-slot manager
-- drives. `button` is deliberately untouched: on a merged slot it hosts two or
-- three kinds and belongs to none of them.
local function BuildBorder(button, host, parent, ac)
    local w = PixelsToUI(ac.debuffBorderWidth or 2)
    host:ClearAllPoints()
    host:SetAllPoints(parent)
    local edges = {}
    for i = 1, 4 do
        local t = BF.Texture(host, nil, "OVERLAY")
        t:SetTexture("Interface\\Buttons\\WHITE8x8")
        edges[i] = t
    end
    edges[1]:SetPoint("TOPLEFT"); edges[1]:SetPoint("TOPRIGHT"); edges[1]:SetHeight(w)
    edges[2]:SetPoint("BOTTOMLEFT"); edges[2]:SetPoint("BOTTOMRIGHT"); edges[2]:SetHeight(w)
    edges[3]:SetPoint("TOPLEFT", 0, -w); edges[3]:SetPoint("BOTTOMLEFT", 0, w); edges[3]:SetWidth(w)
    edges[4]:SetPoint("TOPRIGHT", 0, -w); edges[4]:SetPoint("BOTTOMRIGHT", 0, w); edges[4]:SetWidth(w)
    host._bf_edges = edges
    -- The ring is baked unconditionally: a Frame/Texture created on an
    -- already-configured pooled button is unproven, so a rounded-style switch
    -- must never need new objects. Unused geometry is simply hidden + unbound.
    EnsureSlotRing(host)
end

-- Rounded ring art for this border, or nil for square edges. Gated on
-- the rounded frame border actually being DRAWN (isRoundedActive rule,
-- Container.lua:298 `enableBorder and IsRoundedStyle`): a rounded
-- borderStyle with Enable Border OFF renders nothing rounded, so the
-- dispel border reverts to its square edges — same gate
-- SetHighlightBorder and AggroHighlight apply.
local function DispelRingTex(parent, ac)
    local bp = BF:GetSectionProfileForFrame("borders", parent) or {}
    return bp.enableBorder ~= false
        and BF.IsRoundedBorderStyle(bp.borderStyle)
        and BF:GetHighlightRing(ac.debuffBorderWidth) or nil
end

-- The kind's own signature: everything that changes its BINDINGS.
local function BorderSig(parent, ac)
    local ringTex = DispelRingTex(parent, ac)
    return PixelsToUI(ac.debuffBorderWidth or 2) .. "|"
        .. tostring(ac.debuffBorderMode == "all") .. "|" .. tostring(ringTex)
end

-- Binding half of the restamp. Called INSIDE the merged slot's single
-- ClearDispelTypeTextures pass, so it must only ADD.
local function BindBorder(button, host, parent, ac)
    local edges = host and host._bf_edges
    if not edges then return end
    local w = PixelsToUI(ac.debuffBorderWidth or 2)
    local ringTex = DispelRingTex(parent, ac)
    -- Square-edge geometry kept current (used when not rounded).
    edges[1]:SetHeight(w)
    edges[2]:SetHeight(w)
    edges[3]:SetWidth(w)
    edges[3]:SetPoint("TOPLEFT", 0, -w); edges[3]:SetPoint("BOTTOMLEFT", 0, w)
    edges[4]:SetWidth(w)
    edges[4]:SetPoint("TOPRIGHT", 0, -w); edges[4]:SetPoint("BOTTOMRIGHT", 0, w)
    local ring = host._bf_roundRing
    if ring and ringTex then
        BF:StampRingPixelHost(host._bf_ringHost, ring, parent, ringTex)
    end
    BindDispelGeometry(button, edges, ring, ringTex,
        ac.debuffBorderMode == "all")
end

-- ============================================================
-- Create
-- ============================================================
function DispelDebuffBorder:Create(parent)
    -- v84 (Stage 5 §9.7): real frames own no slot of their own. The three
    -- dispel visuals are created, merged, filtered, restamped and parked by the
    -- single owner BF:SyncDispelVisualSlots (Auras/ContainerFactory.lua), which
    -- every one of the three :Update methods calls. Everything below is the
    -- PREVIEW-FRAME (legacy painter) path.
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
    if parent.dispelDebuffBorder then
        parent[self.name] = parent.dispelDebuffBorder
        return
    end

    local frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints(parent)
    frame:SetFrameLevel(parent:GetFrameLevel() + 12)
    frame:EnableMouse(false)
    frame.top    = MakeEdge(frame)
    frame.bottom = MakeEdge(frame)
    frame.left   = MakeEdge(frame)
    frame.right  = MakeEdge(frame)

    parent[self.name]         = frame
    parent.dispelDebuffBorder = frame
end

-- ============================================================
-- Layout
-- ============================================================
function DispelDebuffBorder:Layout(parent)
    local frame = parent[self.name]
    if not frame then return end
    -- v60: resolved per aura sub-category, not by resolving the whole
    -- auras table and indexing it. The Buffs and Debuffs per-layout
    -- toggles are independent, so a flat's auras table can carry stale
    -- rawkeys for whichever group is currently OFF.
    local diP = BF:GetAurasSubcatProfileForFrame("dispelIndicator", parent) or {}

    local d      = frame
    local debuffT = PixelsToUI(diP.debuffBorderWidth or 2)
    if d.top and d.bottom and d.left and d.right then
        d.top:ClearAllPoints(); d.top:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0); d.top:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0); d.top:SetHeight(debuffT)
        d.bottom:ClearAllPoints(); d.bottom:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 0); d.bottom:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0); d.bottom:SetHeight(debuffT)
        d.left:ClearAllPoints(); d.left:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0); d.left:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 0); d.left:SetWidth(debuffT)
        d.right:ClearAllPoints(); d.right:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0); d.right:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0); d.right:SetWidth(debuffT)
    end
end

-- ============================================================
-- Update — border only
-- ============================================================
-- v67: 12.0.7 branch removed (addon is 12.1-only).
function DispelDebuffBorder:Update(parent, unit)
    -- v84 §9.7: one owner for all three dispel visuals — it resolves the merge
    -- partition, ensures/parks the slots and runs the ONE combined restamp.
    -- Idempotent and change-guarded, so all three indicators calling it costs a
    -- few compares and needs no ordering assumption between them.
    BF:SyncDispelVisualSlots(parent, unit)
end

-- ── v84 §9.7: this visual's registration with the merged-slot manager ──
BF.DispelVisualDefs.dispelBorder = {
    resolve = function(parent, ac)
        local on = ac.enableDebuffBorder and true or false
        local mode = on and (ac.debuffBorderMode or "dispellable") or nil
        -- hasDebuffHighlightFeatures is the OR of the three enable toggles, so
        -- it is true whenever `on` is (kept for exact parity with the pre-v84
        -- expression).
        local show = on and ac.hasDebuffHighlightFeatures and true or false
        local ready = ac.dispelBorderOnlyIfReady and true or false
        -- Dispel-ready gating (spell cooldown data, not aura data — legal Lua).
        if show and ready
            and (mode == "dispellable" or mode == "allDispellable")
            and BF:GetDispelOnCooldownBool() then
            show = false
        end
        return on, mode, show, ready
    end,
    build = BuildBorder,
    bind  = BindBorder,
    sig   = BorderSig,
    -- Keystone recreate (plan §3.1, 2026-09-11): this kind has no live geom --
    -- every border input is in BorderSig and lands with the binding -- so its
    -- geometry signature is a constant. Declared so a set containing the
    -- border still qualifies for the geometry compare (RC.DispelGeomSig needs
    -- every kind in the set to expose one).
    geomSig = function(parent, ac) return "" end,
}

BF:RegisterIndicator(DispelDebuffBorder)
DispelDebuffBorder:EnableDeferredUpdates()
