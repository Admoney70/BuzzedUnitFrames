--[[
BuzzardFrames: Indicators/DispelDebuffIndicator.lua
Dispel indicator — shows a colored square or per-type icons when
a dispellable debuff is active on the unit.

Split from DebuffHighlight.lua — fully independent indicator with its
own Update, deferred updates, and status bindings.

Bound to "debuffs" and "dispel" statuses (Grid2 pattern).
]]

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

-- v67: UnitExists/UnitIsVisible upvalues removed with the 12.0.7 branch
-- (addon is 12.1-only) — they had no other reader.

local DispelDebuffIndicator = BF.indicatorPrototype:new("dispelDebuffIndicator")

-- Per-scope cache write. Owns the dispel-indicator master mode
-- (dispelIndicatorOverlayMode, blizzardDispelOverlayMode) AND its own
-- show flags. Sibling dispel indicators (DispelDebuffBorder,
-- DispelDebuffOverlay) read the SAME diP.dispelIndicatorOverlayMode
-- locally to resolve their own blizzardDispelActive — no read-after-write
-- dependency on cache.dispelIndicatorOverlayMode (which may not have
-- been written yet within step 1 of RebuildAuraCacheScope).
function DispelDebuffIndicator:UpdateDB(cache, flat, grp)
    -- v60: resolved per aura sub-category. The Buffs and Debuffs
    -- per-layout toggles are independent, so a flat's auras table can
    -- carry stale rawkeys for whichever group is currently OFF --
    -- ResolveCFGSection(..., "auras") plus an index would read them.
    local diP    = BF.ResolveCFGAurasSubcat(BF, flat, grp, "dispelIndicator") or {}
    local blizzardActive = diP.dispelIndicatorOverlayMode == "blizzard"
    cache.dispelIndicatorOverlayMode  = diP.dispelIndicatorOverlayMode or "custom"
    cache.blizzardDispelOverlayMode   = diP.blizzardDispelOverlayMode or 2
    cache.showDispelIndicator         = (not blizzardActive) and (diP.showDispelIndicator ~= false) or false
    cache.dispelIndicatorMode         = diP.dispelIndicatorMode or "dispellable"
    cache.dispelIndicatorStyle        = diP.dispelIndicatorStyle or "square"
    cache.dispelIndicatorOnlyIfReady  = diP.dispelIndicatorOnlyIfReady or false
    -- 2026-08-25 (owner request): the dispel VISUALS' own "dispellable by me"
    -- governors -- read by BF.DispelVisualFilterFor / BF:SyncDispelVisualSlots
    -- (Auras/ContainerFactory.lua) for all four custom kinds, not just this
    -- one. Stamped here because this is the dispelIndicator sub-category's
    -- UpdateDB; defaults match the debuff-icon pair (talented ON, long-cd
    -- OFF), so a cache that predates the keys resolves the same way.
    -- KEEP IN LOCKSTEP with the mirror block in Auras/AuraConfig.lua.
    cache.dispelVisualDispMeTalented  = diP.dispelVisualDispMeTalented ~= false
    cache.dispelVisualDispMeLongCd    = diP.dispelVisualDispMeLongCd == true
    cache.dispelIndicatorSize         = diP.dispelIndicatorSize or 10
    cache.dispelIndicatorPosition     = diP.dispelIndicatorPosition or "TOPRIGHT"
    cache.dispelIndicatorOffsetX      = diP.dispelIndicatorOffsetX or 0
    cache.dispelIndicatorOffsetY      = diP.dispelIndicatorOffsetY or 0
end

-- ── v93: shared anchor inset for the custom dispel indicator ────────────
-- The position dropdown now offers all nine anchor points (matching the
-- debuff-icon Anchor Point list). Padding is applied only on the axes the
-- chosen point actually touches: an edge gets pushed 2px inward, a centered
-- axis gets nothing. Three call sites share this (DotGeom, the preview-frame
-- :Create below, and the dummy-aura painter in Auras/DummyAuras.lua) so live
-- frames and Setup Mode agree.
local DISPEL_INSETS = {
    TOPLEFT     = {  2, -2 },
    TOP         = {  0, -2 },
    TOPRIGHT    = { -2, -2 },
    LEFT        = {  2,  0 },
    CENTER      = {  0,  0 },
    RIGHT       = { -2,  0 },
    BOTTOMLEFT  = {  2,  2 },
    BOTTOM      = {  0,  2 },
    BOTTOMRIGHT = { -2,  2 },
}

function BF:GetDispelIndicatorInset(pos)
    local t = DISPEL_INSETS[pos] or DISPEL_INSETS.TOPRIGHT
    return t[1], t[2]
end

-- ============================================================
-- 12.1 CONTAINER PATH: 1-slot container; the slot button IS the dot.
-- "square" style: WHITE8x8 recolored by dispel type (PreserveAsset).
-- "icon" style: Blizzard's per-type debuff atlases via the CustomAsset
-- dispel-texture style — the exact legacy atlas set, engine-driven.
-- Size/position baked at creation — changes prompt reload.
-- ============================================================
local DISPEL_DOT_ASSET_MAP = {
    Magic   = { asset = "RaidFrame-Icon-DebuffMagic" },
    Curse   = { asset = "RaidFrame-Icon-DebuffCurse" },
    Disease = { asset = "RaidFrame-Icon-DebuffDisease" },
    Poison  = { asset = "RaidFrame-Icon-DebuffPoison" },
    Bleed   = { asset = "RaidFrame-Icon-DebuffBleed" },
}

-- v84 (Stage 5 §9.7): INIT-WINDOW build. The dot's texture is created on the
-- kind's own absolute-level host frame, never on the button — on a merged slot
-- the button carries two or three kinds and belongs to none of them. Geometry
-- and bindings are stamped afterwards (DotGeom / BindDot).
local function BuildDot(button, host, parent, ac)
    local tex = BF.Texture(host, nil, "ARTWORK")
    tex:SetAllPoints(host)
    host._bf_dotTex = tex
end

-- Live size/position of the dot host (change-guarded; V3 class — native calls
-- on slot-button descendants work out of combat).
local function DotGeom(button, host, parent, ac)
    if not host then return end
    local size = ac.dispelIndicatorSize or 10
    local pos  = ac.dispelIndicatorPosition or "TOPRIGHT"
    local xOff, yOff = BF:GetDispelIndicatorInset(pos)
    xOff = xOff + (ac.dispelIndicatorOffsetX or 0)
    yOff = yOff + (ac.dispelIndicatorOffsetY or 0)
    local sig = size .. "|" .. pos .. "|" .. xOff .. "|" .. yOff
    if host._bf_dotSig == sig then return end
    if pcall(function()
        host:SetSize(size, size)
        host:ClearAllPoints()
        host:SetPoint(pos, parent.healthBar or parent, pos, xOff, yOff)
    end) then host._bf_dotSig = sig end
end

local function DotSig(parent, ac)
    return (ac.dispelIndicatorStyle or "square") .. "|"
        .. tostring(ac.dispelIndicatorMode == "all")
end

-- Binding half of the restamp: style square<->icon plus the mode-driven
-- typeless-debuff visibility. Called INSIDE the merged slot's single
-- ClearDispelTypeTextures pass, so it must only ADD.
local function BindDot(button, host, parent, ac)
    local tex = host and host._bf_dotTex
    if not tex then return end
    local style = ac.dispelIndicatorStyle or "square"
    if style == "icon" then
        button:AddDispelTypeTexture(tex, {
            style = Enum.CustomAuraButtonDispelTypeTextureStyle
                and Enum.CustomAuraButtonDispelTypeTextureStyle.CustomAsset or 4,
            showWhenHarmful = true,
            showWithoutDispelType = false,  -- no atlas exists for typeless
            customDispelAssetMap = DISPEL_DOT_ASSET_MAP,
        })
    else
        tex:SetTexture("Interface\\Buttons\\WHITE8x8")
        button:AddDispelTypeTexture(tex, {
            style = Enum.CustomAuraButtonDispelTypeTextureStyle
                and Enum.CustomAuraButtonDispelTypeTextureStyle.PreserveAsset or 3,
            showWhenHarmful = true,
            showWithoutDispelType = (ac.dispelIndicatorMode == "all"),
            customDispelColorMap = BF.DispelVisualColorMap,
        })
    end
end

-- ============================================================
-- Create
-- ============================================================
function DispelDebuffIndicator:Create(parent)
    -- v84 (Stage 5 §9.7): real frames own no slot of their own — the merged
    -- dispel-visual manager (BF:SyncDispelVisualSlots) owns all three. Preview
    -- frames fall through to the LEGACY frame creation below: the dummy dispel
    -- painter (_ShowDummyDispelBorders) needs parent.dispelDebuffIndicator, and
    -- containers are pointless on preview frames (no unit).
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
    if parent.dispelDebuffIndicator then
        parent[self.name] = parent.dispelDebuffIndicator
        return
    end

    -- BUGFIX (v60): these read rpDB.profile.auras.dispelIndicatorSize /
    -- .dispelIndicatorPosition -- the auras ROOT, which is the pre-v27 storage
    -- shape. Both keys have lived one level down at auras.dispelIndicator.*
    -- since v27, so both reads were always nil and the hard-coded 10 /
    -- "TOPRIGHT" fallbacks always won. It also bypassed per-layout and CFG
    -- routing entirely. Now resolved frame-scoped, per sub-category.
    -- v67: 12.0.7 branch removed (addon is 12.1-only) — everything below is
    -- now the PREVIEW-FRAME path only; real frames return above and take
    -- their geometry from the AuraCache.
    local ap = BF:GetAurasSubcatProfileForFrame("dispelIndicator", parent) or {}
    local size = ap.dispelIndicatorSize     or 10
    local pos  = ap.dispelIndicatorPosition or "TOPRIGHT"

    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(size, size)
    frame:SetFrameLevel(parent:GetFrameLevel() + 223)
    frame:EnableMouse(false)
    frame:Hide()

    local xOff, yOff = BF:GetDispelIndicatorInset(pos)
    frame:SetPoint(pos, parent.healthBar or parent, pos, xOff, yOff)

    -- Square texture (used in "square" style)
    local dot = BF.Texture(frame, nil, "ARTWORK")
    dot:SetAllPoints(frame)
    dot:SetTexture("Interface\\Buttons\\WHITE8x8")
    frame.texture = dot

    -- Per-type icon textures (used in "icon" style)
    local atlasMap = {
        magic   = "RaidFrame-Icon-DebuffMagic",
        curse   = "RaidFrame-Icon-DebuffCurse",
        disease = "RaidFrame-Icon-DebuffDisease",
        poison  = "RaidFrame-Icon-DebuffPoison",
        bleed   = "RaidFrame-Icon-DebuffBleed",
    }
    local iconNameList = { "magic", "curse", "disease", "poison", "bleed" }
    frame.iconNames = iconNameList
    frame.icons     = {}
    for i = 1, #iconNameList do
        local name    = iconNameList[i]
        local iconTex = BF.Texture(frame, nil, "ARTWORK")
        iconTex:SetAllPoints(frame)
        iconTex:SetAtlas(atlasMap[name])
        iconTex:Hide()
        frame.icons[name] = iconTex
    end

    parent[self.name]            = frame
    parent.dispelDebuffIndicator = frame
end

-- v67: DispelDebuffIndicator:Layout removed (12.1-only). The whole body sat
-- behind a container-path early return, so on 12.1 it was already an empty
-- override; geometry is baked at button init and re-stamped live in :Update.
-- indicatorPrototype:Layout (BFIndicator.lua:53-54) is itself a no-op, so
-- BF:LayoutFrameIndicators still resolves the call.

-- ============================================================
-- Update — dispel dot/icon only
-- ============================================================
-- v67: 12.0.7 branch removed (addon is 12.1-only).
function DispelDebuffIndicator:Update(parent, unit)
    -- v84 §9.7: one owner for all three dispel visuals (see the twin note in
    -- DispelDebuffBorder:Update).
    BF:SyncDispelVisualSlots(parent, unit)
end

-- ── v84 §9.7: this visual's registration with the merged-slot manager ──
BF.DispelVisualDefs.dispelDot = {
    resolve = function(parent, ac)
        local on = ac.showDispelIndicator and true or false
        local mode = on and (ac.dispelIndicatorMode or "dispellable") or nil
        local show = on
        local ready = ac.dispelIndicatorOnlyIfReady and true or false
        if show and ready
            and (mode == "dispellable" or mode == "allDispellable")
            and BF:GetDispelOnCooldownBool() then
            show = false
        end
        return on, mode, show, ready
    end,
    build = BuildDot,
    bind  = BindDot,
    sig   = DotSig,
    geom  = DotGeom,
    -- Keystone recreate (plan §3.1, 2026-09-11): what DotGeom targets, as a
    -- pure read. Inside a key DotGeom's writes are denied, so a mismatch with
    -- the geometry the button was born with requests a rebuilt slot instead.
    -- Must stay in step with DotGeom's own sig.
    geomSig = function(parent, ac)
        local size = ac.dispelIndicatorSize or 10
        local pos  = ac.dispelIndicatorPosition or "TOPRIGHT"
        local xOff, yOff = BF:GetDispelIndicatorInset(pos)
        xOff = xOff + (ac.dispelIndicatorOffsetX or 0)
        yOff = yOff + (ac.dispelIndicatorOffsetY or 0)
        return size .. "|" .. pos .. "|" .. xOff .. "|" .. yOff
    end,
}

BF:RegisterIndicator(DispelDebuffIndicator)
DispelDebuffIndicator:EnableDeferredUpdates()
