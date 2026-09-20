-- ============================================================
-- BuzzardFrames: PreviewSystem.lua
--
-- Preview frame engine: creation, layout, positioning, lifecycle.
-- Look here when preview frames aren't appearing, are positioned
-- wrong, or the refresh lifecycle is broken.
--
-- Depends on: PreviewData.lua (ApplyPreview* functions)
-- ============================================================
local BF = _G["BuzzardFrames"]

-- rpDB sub-table accessors (live reads, safe in any scope)
local function _rpDB() return BF.rpDB and BF.rpDB.profile or {} end
-- Text-section reads in this file are all per-flat (resolved inside the OOR
-- alpha block via GetSectionProfile). The _rp_text helper was removed as
-- part of the v25 text per-layout rollout.
-- healthPower-section reads are also all per-flat (v28). Resolved inline
-- via BF:GetSectionProfileForFrame on a frame, or via
-- BF:GetSectionProfile on a flat table. No module-level _rp_healthPower
-- helper; using one would require a module-local _currentPreviewFlat
-- tracker, which this file doesn't have (the Apply* functions in
-- PreviewData.lua own that state).
-- v29: borders-section reads follow the same per-frame resolution pattern
-- as healthPower. Resolved inline via BF:GetSectionProfileForFrame("borders",
-- frame) at each call site so preview frames see their own per-flat
-- borders values. The old module-level _rp_borders helper was removed.
local function _rp_layouts() return _rpDB().layouts or {} end


-- Imports from PreviewData.lua
local _pv = BF._preview or {}
local EnabledCFGroups              = function(...) return BF._preview.EnabledCFGroups(...) end
local ApplyPreviewHealthBar        = function(...) return BF._preview.ApplyPreviewHealthBar(...) end
local ApplyPreviewName             = function(...) return BF._preview.ApplyPreviewName(...) end
local ApplyPreviewHealthText       = function(...) return BF._preview.ApplyPreviewHealthText(...) end
local ApplyPreviewPowerBar         = function(...) return BF._preview.ApplyPreviewPowerBar(...) end
local ApplyPreviewRoleIcon         = function(...) return BF._preview.ApplyPreviewRoleIcon(...) end
local ApplyPreviewHighlights       = function(...) return BF._preview.ApplyPreviewHighlights(...) end
local ApplyPreviewAggro            = function(...) return BF._preview.ApplyPreviewAggro(...) end
local ApplyPreviewStatus           = function(...) return BF._preview.ApplyPreviewStatus(...) end
local ApplyPreviewStatusIcons      = function(...) return BF._preview.ApplyPreviewStatusIcons(...) end
local ApplyPreviewAbsorbOverlay    = function(...) return BF._preview.ApplyPreviewAbsorbOverlay(...) end
local ApplyPreviewHealPrediction   = function(...) return BF._preview.ApplyPreviewHealPrediction(...) end
local ApplyPreviewHealAbsorb       = function(...) return BF._preview.ApplyPreviewHealAbsorb(...) end
local ApplyPreviewReducedMaxHealth = function(...) return BF._preview.ApplyPreviewReducedMaxHealth(...) end
local ApplyAllPreviewDummyData     = function(...) return BF._preview.ApplyAllPreviewDummyData(...) end


-- ============================================================
-- Helpers
-- ============================================================

-- OOR fade + darken for preview frames: BF:ApplyRangeEffects
-- (Indicators/RangeAlpha.lua) is the ONE shared writer for both
-- effects, live and preview. The old BF:DarkenPreviewFrame here was a
-- second, divergent darken implementation (it wrote the overlay
-- TEXTURE's alpha; the live path writes the overlay FRAME's alpha) —
-- removed so the two mechanisms cannot drift apart again.

-- The host frame the preview containers anchor to.
--
-- There is ONE preview engine and ONE set of preview frames, parented to
-- the options panel. The panel claims the previews by setting itself as
-- the host immediately before it runs a full refresh sweep, and clears the
-- host when it closes.
BF._previewHostFrame = nil

-- nil is a legitimate argument: it means "no panel claims the previews", which
-- is what a closing panel says.
function BF:SetPreviewHost(frame)
    BF._previewHostFrame = frame
end

local function GetOptionsFrame()
    local host = BF._previewHostFrame
    -- A host that has since been hidden is stale -- the panel that set it was
    -- closed by something that never told us (ESC, another addon) -- so it is
    -- ignored rather than trusted, and the panel frame itself is asked.
    if host and host:IsShown() then return host end
    local panel = _G.BuzzardPanel_BuzzardFrames
    return panel and panel:IsShown() and panel or nil
end

-- Cleans up all dummy aura visuals on a preview frame.
-- Called from various preview refresh/hide paths below.
function BF:HideDummyAuras(frame)
    if not frame then return end
    -- 12.1: re-enable live aura containers suspended by ShowDummyAuras.
    -- v67: 12.0.7 branch removed (addon is 12.1-only).
    if self.ResumeFrameAuraContainers then
        self:ResumeFrameAuraContainers(frame)
    end
    if frame.SF_DummyRestartTimer then
        frame.SF_DummyRestartTimer:Cancel()
        frame.SF_DummyRestartTimer = nil
    end
    if self.HideDummyContainerAuras then self:HideDummyContainerAuras(frame) end
    -- v70: also clear the general-container preview icons (SF_PreviewContainerIcons).
    if self.HideGeneralContainerPreviews then self:HideGeneralContainerPreviews(frame) end
    if frame.buffFrames then
        for _, icon in ipairs(frame.buffFrames) do if icon:IsShown() then icon:Hide() end end
    end
    if frame.debuffFrames then
        for _, icon in ipairs(frame.debuffFrames) do if icon:IsShown() then icon:Hide() end end
    end
    if frame.bigDefIcons then
        for _, icon in ipairs(frame.bigDefIcons) do if icon:IsShown() then icon:Hide() end end
    end
    if frame.dispelDebuffBorder then self:SetHighlightBorder(frame.dispelDebuffBorder, frame, 0, 0, 0, 0) end
    if frame.dispelDebuffOverlay and frame.dispelDebuffOverlay:IsShown() then frame.dispelDebuffOverlay:Hide() end
    if frame.dispelDebuffIndicator and frame.dispelDebuffIndicator:IsShown() then frame.dispelDebuffIndicator:Hide() end
    if frame.dispelHealthColorTex and frame.dispelHealthColorTex:IsShown() then frame.dispelHealthColorTex:Hide() end
    -- Clear per-spell preview effects applied by ShowSingleSpellPreview
    if frame.buffOverlay and frame.buffOverlay:IsShown() then frame.buffOverlay:Hide() end
    if frame.buffColorOverlay and frame.buffColorOverlay:IsShown() then frame.buffColorOverlay:Hide() end
    -- v67: the dummyPrivateAuras teardown was removed with the Private Auras
    -- feature (the slots are no longer created).
end

local function MakeLabel(parent)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetTextColor(0.8, 0.8, 0.8)
    fs:SetJustifyH("LEFT")
    return fs
end

-- ============================================================
-- FRAME POOL
-- ============================================================
-- _previewFrames[flatID]  — one frame per distinct flat that's
--                           currently in the active preview set
-- _previewLabels[flatID]  — one FontString label per frame
-- ============================================================
-- The active preview set is:
--     { _modifyingFlat } ∪ (pinned flats)
-- deduplicated, with _modifyingFlat always first. See
-- ComputeActivePreviewSet.
--
-- Frames are created lazily on first appearance of a flat ID in
-- the active set (see EnsurePreviewFrameForFlat). Flats that
-- drop out of the set are Hide()n but not destroyed — they sit
-- dormant in _previewFrames and are reused when that flat
-- returns to the set.
-- ============================================================
local PREVIEW_VERSION = 12 -- frame pool restructured from per-tier to per-flat

-- Label color per flat type. party-typed flats get green, raid
-- green-ish-blue. Applied in RefreshPreview's label render.
local TYPE_COLORS = {
    party = "|cffaaffaa",
    raid  = "|cffaaccff",
}

local MAX_CF_PREVIEWS = 4
local CF_PREVIEW_COLOR = "|cffffcc88"
local CF_FAKE_UNIT_DEFAULTS = {
    { name = "CFBuzzard1", class = "PALADIN",     hp = 0.90, role = "TANK"    },
    { name = "CFBuzzard2", class = "DRUID",        hp = 0.65, role = "HEALER"  },
    { name = "CFBuzzard3", class = "ROGUE",        hp = 0.45, role = "DAMAGER" },
    { name = "CFBuzzard4", class = "DEATHKNIGHT",  hp = 0.30, role = "TANK"    },
}

-- Preview frames are standalone visual dummies for the options panel.
-- They are NOT real unit frames: no header parent, no unit assignment,
-- no UpdateIndicators. They only need widgets to exist so that
-- LayoutPreviewFrame and ApplyAllPreviewDummyData can position and
-- fill them with fake data.
--
-- We mix in the prototype solely to call CreateIndicators() which
-- iterates all registered indicators and calls indicator:Create(frame).
-- Layout and updates are handled entirely by LayoutPreviewFrame /
-- ApplyAllPreviewDummyData — the prototype's Layout() and
-- UpdateIndicators() are never called on preview frames.
local function MakePreviewFrame(name, parent, w, h)
    local f = CreateFrame("Frame", name, parent, "BackdropTemplate")
    -- No strata/level pin: inherit from the preview container, which is
    -- re-parented onto the options panel in LayoutPreview* below. Pinning
    -- "DIALOG" here put previews under every FULLSCREEN_DIALOG frame --
    -- the strata the options panel uses -- and strata beats level, so the
    -- old 121 could never bring them forward.
    f:SetFrameLevel(parent:GetFrameLevel() + 1)
    f:SetSize(w, h)
    f._isPreviewFrame = true

    -- Create the container texture before indicators, matching BuzzardFrame_Init
    -- (BFLayout.lua line 491). Real frames use CreateTexture() with no layer arg
    -- (defaults to ARTWORK). This must happen before Container:Create runs, so
    -- that it finds parent.container already exists and skips creating one in
    -- the BACKGROUND layer.
    f.container = BF.Texture(f)

    -- Use the real indicator Create methods to build all widgets.
    -- This guarantees the preview frame hierarchy exactly matches
    -- the real raid/party frames.
    local indicators = BF:GetIndicatorsSorted()
    if indicators then
        for i = 1, #indicators do
            local ind = indicators[i]
            if ind.CanCreate then
                if ind:CanCreate(f) then
                    ind:Create(f)
                end
            else
                ind:Create(f)
            end
        end
    end

    -- Borders — these aren't created by any indicator, so we create them
    -- manually (same as BuzzardFrame_Init in BFLayout.lua).
    if not f.aggroHighlight then
        local function MakeEdge(par)
            local t = BF.Texture(par, nil, "OVERLAY")
            t:SetColorTexture(0, 0, 0, 0)
            return t
        end
        local function MakeBorder(par, lvl)
            local b = CreateFrame("Frame", nil, par)
            b:SetAllPoints(par)
            b:SetFrameLevel(par:GetFrameLevel() + lvl)
            b:EnableMouse(false)
            b.top = MakeEdge(b); b.bottom = MakeEdge(b); b.left = MakeEdge(b); b.right = MakeEdge(b)
            return b
        end
        f.aggroHighlight = MakeBorder(f, 11)
        -- Blizzard style: 8 parts (4 fixed corners + 4 one-axis edges),
        -- mirroring Indicators/AggroHighlight.lua:Create.
        local bzp = {}
        for _, key in ipairs({ "tl", "tr", "bl", "br", "top", "bottom", "left", "right" }) do
            local t = BF.Texture(f.aggroHighlight, nil, "OVERLAY")
            t:SetAlpha(0)
            bzp[key] = t
        end
        -- TexCoords (flips + the 32px-tile content crop) are stamped by
        -- ApplyPreviewAggro, where the width is known.
        f.aggroHighlight.blizzardParts = bzp
        f.aggroHighlight.glowBorder = BF.Texture(f.aggroHighlight, nil, "OVERLAY")
        f.aggroHighlight.glowBorder:SetAllPoints(f.aggroHighlight)
        f.aggroHighlight.glowBorder:SetAlpha(0)
        local cornersFrame = CreateFrame("Frame", nil, f)
        cornersFrame:SetFrameLevel(f:GetFrameLevel() + 14)
        cornersFrame:EnableMouse(false)
        local inset = -(BF.PixelsToUI and BF:PixelsToUI(1) or 1)
        cornersFrame:SetPoint("TOPLEFT", f, "TOPLEFT", inset, -inset)
        cornersFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -inset, inset)
        f.aggroHighlight.cornersTex = BF.Texture(cornersFrame, nil, "OVERLAY")
        f.aggroHighlight.cornersTex:SetAllPoints(cornersFrame)
        f.aggroHighlight.cornersTex:SetTexture("Interface\\AddOns\\BuzzardFrames\\Media\\aggro_corners_lg")
        f.aggroHighlight.cornersTex:SetAlpha(0)
        local arrowTex = BF.Texture((f.textFrame or f.aggroHighlight), nil, "OVERLAY")
        arrowTex:SetTexture("Interface\\AddOns\\BuzzardFrames\\Media\\aggro_arrow")
        arrowTex:SetSize(16, 16)
        arrowTex:SetAlpha(0)
        f.aggroHighlight.arrowTex = arrowTex
        f.dispelDebuffBorder = MakeBorder(f, 12)
        f.targetHighlight = MakeBorder(f, 12)
    end

    -- Debuff overlay — created by legacy code, not an indicator
    if not f.dispelDebuffOverlay and f.healthBar then
        local dispelDebuffOverlay = BF.Texture(f.healthBar, nil, "OVERLAY", nil, 1)
        dispelDebuffOverlay:SetPoint("TOPLEFT", f.healthBar, "TOPLEFT", 0, 0)
        dispelDebuffOverlay:SetPoint("TOPRIGHT", f.healthBar, "TOPRIGHT", 0, 0)
        dispelDebuffOverlay:SetHeight((f.healthBar:GetHeight() or 20) * 0.5)
        dispelDebuffOverlay:SetTexture("Interface\\AddOns\\BuzzardFrames\\Media\\debuff_overlay_gradient")
        dispelDebuffOverlay:Hide()
        f.dispelDebuffOverlay = dispelDebuffOverlay
    end

    -- Debuff Health Color Change tint -- the preview twin of the engine's
    -- dispelHealthColor visual kind (Indicators/DispelDebuffOverlay.lua):
    -- a texture over the health FILL, stamped with the bar's own texture
    -- at paint time so a custom bar keeps its shading through the tint.
    -- Below the debuff overlay (sublayer 0 vs its 1), as the level order
    -- has it at runtime. Painted by _ShowDummyDispelBorders.
    if not f.dispelHealthColorTex and f.healthBar then
        local hcTex = BF.Texture(f.healthBar, nil, "OVERLAY", nil, 0)
        hcTex:Hide()
        f.dispelHealthColorTex = hcTex
    end

    -- Status icon stubs — not created by any indicator
    if not f.resIcon then
        local ip = BF.rpDB and BF.rpDB.profile and BF.rpDB.profile.icons or {}
        local siSize = ip.statusIconSize or 24
        local siPos = ip.statusIconPosition or { point = "CENTER", x = 0, y = 0 }
        local statusIconFrame = CreateFrame("Frame", nil, f)
        statusIconFrame:SetAllPoints(f)
        statusIconFrame:SetFrameLevel(f:GetFrameLevel() + 221)
        statusIconFrame:EnableMouse(false)
        local STATUS_ICON_TEXTURES = {
            resIcon        = "Interface\\RaidFrame\\Raid-Icon-Rez",
            phasedIcon     = "Interface\\TargetingFrame\\UI-PhasingIcon",
            summonIcon     = "Interface\\RaidFrame\\Raid-Icon-SummonPending",
            rezPendingIcon = "Interface\\RaidFrame\\Raid-Icon-Rez",
            vehicleIcon    = "Interface\\Vehicles\\UI-VEHICLES-RAID-ICON",
        }
        for _, key in ipairs({"resIcon", "phasedIcon", "summonIcon", "rezPendingIcon", "vehicleIcon"}) do
            local ico = BF.Texture(statusIconFrame, nil, "OVERLAY")
            ico:SetSize(siSize, siSize)
            ico:SetPoint(siPos.point, f, siPos.point, siPos.x, siPos.y)
            if STATUS_ICON_TEXTURES[key] then
                ico:SetTexture(STATUS_ICON_TEXTURES[key])
            end
            ico:Hide()
            f[key] = ico
        end
        local rcFrame = CreateFrame("Frame", nil, statusIconFrame)
        rcFrame:SetSize(siSize, siSize)
        rcFrame:SetPoint(siPos.point, f, siPos.point, siPos.x, siPos.y)
        rcFrame:Hide()
        local rcTex = BF.Texture(rcFrame, nil, "ARTWORK")
        rcTex:SetAllPoints(rcFrame)
        f.readyCheckIcon = rcFrame
        f.readyCheckIconTexture = rcTex
    end

    -- v67: the f.dummyPrivateAuras slot build was removed with the Private
    -- Auras feature (12.0.7-only icons; the addon is 12.1-only now).

    -- Pre-resolved per-frame anchor + power-bar visibility for the
    -- unified aura render path (RenderAuraGroup reads both).
    -- container, not healthBar.clipFrame — matches the live stamp in
    -- BFLayout.lua (the clip narrows under reduced max health, which
    -- dragged lifted auras left with the health fill).
    f._bf_auraAnchorTarget = f.container or (f.healthBar and (f.healthBar.clipFrame or f.healthBar)) or f
    f._bf_powerBarShown    = false  -- preview frames never lift; readers just need a non-nil bool

    return f
end
-- ============================================================
-- EnsurePreviewFramesContainer
-- Creates the outer container frame + CF container + arrow.
-- Does NOT create any flat-specific preview frames — those are
-- created lazily on demand by EnsurePreviewFrameForFlat.
--
-- PREVIEW_VERSION gates full recreation: if the version has
-- advanced since last call, all existing preview frames are
-- destroyed so they can be rebuilt fresh.
-- ============================================================
local function EnsurePreviewFramesContainer()
    if BF._previewContainer and BF._previewVersion == PREVIEW_VERSION then return end

    if BF._previewContainer then
        -- Recursively destroy all child frames and regions
        local function DestroyFrame(frame)
            if not frame then return end
            local children = { frame:GetChildren() }
            for _, child in ipairs(children) do
                DestroyFrame(child)
            end
            local regions = { frame:GetRegions() }
            for _, region in ipairs(regions) do
                region:Hide()
                region:SetParent(nil)
            end
            frame:Hide()
            frame:UnregisterAllEvents()
            frame:ClearAllPoints()
            frame:SetParent(nil)
        end
        DestroyFrame(BF._previewContainer)
        BF._previewContainer = nil
        BF._previewFrames    = nil
        BF._previewLabels    = nil
        BF._previewArrow     = nil
        if BF._previewCFContainer then
            DestroyFrame(BF._previewCFContainer)
            BF._previewCFContainer = nil
        end
        BF._previewCFFrames = nil
        BF._previewCFLabels = nil
    end
    BF._previewVersion = PREVIEW_VERSION

    -- Parented to UIParent only until the options panel exists; the layout
    -- pass re-parents onto it so strata/level track the panel.
    local c = CreateFrame("Frame", nil, UIParent)
    c:Hide()
    BF._previewContainer = c
    BF._previewFrames = {}
    BF._previewLabels = {}

    -- Arrow indicator showing which preview frame matches the
    -- currently-editing flat. Positioned next to that frame
    -- during PositionPreviewFrames.
    local arrow = CreateFrame("Frame", nil, c)
    arrow:SetSize(16, 16)
    arrow:SetFrameLevel(c:GetFrameLevel() + 5)
    local arrowTex = BF.Texture(arrow, nil, "OVERLAY")
    arrowTex:SetAllPoints(arrow)
    arrowTex:SetTexture("Interface\\AddOns\\BuzzardFrames\\Media\\arrow_right")
    arrowTex:SetVertexColor(0.3, 0.7, 1.0, 1)  -- sky blue
    arrow:Hide()
    BF._previewArrow = arrow

    -- Custom Frame Group preview frames (right side of panel).
    -- Still a fixed pool of MAX_CF_PREVIEWS (CF system is unchanged).
    local cfc = CreateFrame("Frame", nil, UIParent)
    cfc:Hide()
    BF._previewCFContainer = cfc

    BF._previewCFFrames = {}
    BF._previewCFLabels = {}
    for i = 1, MAX_CF_PREVIEWS do
        local cf = MakePreviewFrame("BuzzardFramesPreviewCF" .. i, cfc, 70, 40)
        cf._previewTier = "cf" .. i
        BF._previewCFFrames[i] = cf
        local cl = MakeLabel(cfc)
        cl:SetPoint("BOTTOMLEFT", cf, "TOPLEFT", 0, 3)
        BF._previewCFLabels[i] = cl
    end
end

-- ============================================================
-- EnsurePreviewFrameForFlat(flatID)
-- Returns the preview frame for the given flat ID, creating it
-- lazily if it doesn't already exist. Returns nil if the
-- container hasn't been created yet.
-- ============================================================
local function EnsurePreviewFrameForFlat(flatID)
    if not flatID then return nil end
    if BF._previewFrames and BF._previewFrames[flatID] then
        return BF._previewFrames[flatID]
    end

    local c = BF._previewContainer
    if not c then return nil end

    local fl = BF.rpDB and BF.rpDB.profile and BF.rpDB.profile.layouts
               and BF.rpDB.profile.layouts.flatLayouts or {}
    local flat = fl[flatID]
    if not flat then return nil end

    local isRaid = (flat.type == "raid")
    local defaultW = isRaid and 70 or 100
    local defaultH = isRaid and 40 or 68

    -- 1x1 anchor point so SetScale on the preview frame doesn't shift position
    local anchor = CreateFrame("Frame", nil, c)
    anchor:SetSize(1, 1)
    local f = MakePreviewFrame("BuzzardFramesPreview_" .. flatID, c, defaultW, defaultH)
    f._flatID    = flatID
    f._anchor1x1 = anchor
    -- Stamp _bf_auraCache so GetAuraCacheForFrame routes party/raid
    -- preview frames at this flat's _auraCache (which was built by
    -- UpdateAuraSizeCache for the preview-target layout, not the
    -- currently-active layout). If the flat's cache hasn't been built
    -- yet (e.g. addon just loaded), the stamp is nil and the resolver
    -- falls through to BF.AuraCache; the very next UpdateAuraSizeCache
    -- re-stamps every preview frame so this stays consistent.
    f._bf_auraCache = flat._auraCache or nil
    f:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", 0, 0)

    local lbl = MakeLabel(c)
    lbl:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 0, 3)

    BF._previewFrames[flatID] = f
    BF._previewLabels[flatID] = lbl
    return f
end

-- ============================================================
-- GetFlatProfile(flatID)
-- Returns the flat table directly from flatLayouts.
-- ============================================================
local function GetFlatProfile(flatID)
    local fl = BF.rpDB and BF.rpDB.profile and BF.rpDB.profile.layouts
               and BF.rpDB.profile.layouts.flatLayouts or {}
    return fl[flatID]
end

-- ============================================================
-- ComputeActivePreviewSet
-- Walks every flat in flatLayouts minus any the user has explicitly
-- unpinned (via the "Hide this preview" button on the Preview Units
-- tab), deduplicates, and returns:
--   order    : array of flat IDs in display order
--              (seeded flats first, then alphabetical extras)
--   setByFlat: map flatID -> true (for quick membership checks)
--
-- Pinning model: all flats are pinned by default. The explicit
-- unpin set lives at BF.rpDB.profile._unpinnedPreviewFlats; a flat
-- is pinned whenever it has no entry there. The editing flat is
-- NOT forced into the set — unpinning the flat the user is
-- currently editing hides it immediately.
--
-- The order is purely STRUCTURAL — seeded flats in fixed order
-- (flat_party, flat_raid20, flat_raid30, flat_raid40), then any
-- remaining flats alphabetically. This keeps the rendered frame
-- stack stable as the user switches which flat they are editing.
--
-- Must match the order the options panel's Preview page lists the
-- flats in (Pages_Preview.lua) so the page and the preview frames stay
-- in lockstep.
-- ============================================================
local function ComputeActivePreviewSet()
    local lp = BF.rpDB and BF.rpDB.profile and BF.rpDB.profile.layouts or {}
    local fl = lp.flatLayouts or {}
    local unpinned = (BF.rpDB and BF.rpDB.profile and BF.rpDB.profile._unpinnedPreviewFlats) or {}

    -- Active set: every flat not explicitly unpinned.
    local active = {}
    for id in pairs(fl) do
        if not unpinned[id] then active[id] = true end
    end

    local order = {}
    local set   = {}

    local preferred = { "flat_party", "flat_raid20", "flat_raid30", "flat_raid40" }
    for _, id in ipairs(preferred) do
        if active[id] and not set[id] then
            order[#order + 1] = id
            set[id]           = true
        end
    end
    local extras = {}
    for id in pairs(active) do
        if not set[id] then extras[#extras + 1] = id end
    end
    table.sort(extras)
    for _, id in ipairs(extras) do
        order[#order + 1] = id
        set[id]           = true
    end

    return order, set
end

-- Export so PreviewData.lua can resolve a flat's position in
-- the preview order when computing its preset baseline (see
-- GetFlatTypeDefault in that file). Data.lua loads before System.lua,
-- so it looks this up lazily at call time rather than capturing it at
-- module load.
BF._preview = BF._preview or {}
BF._preview.ComputeActivePreviewSet = ComputeActivePreviewSet

-- ============================================================
-- ApplyPreviewDummyAuras
-- Shows or hides dummy auras on a single preview frame using
-- the frame's flat profile directly. Called from RefreshPreview
-- and RefreshPreviewDummyAuras.
--
-- Under the flat model there is no per-tier aura canonicalization —
-- each flat has its own aura settings stored directly on the
-- flat table (same fields as old-style tier sub-tables).
-- ============================================================
local function ApplyPreviewDummyAuras(frame, isRaid, p, flatID)
    if not BF:ShouldShowPreviewAuras() then
        BF:HideDummyAuras(frame)
        return
    end
    -- CFG preview frames: use the stamped _cfgFlat directly since
    -- CFG flats aren't stored in rpDB.profile.layouts.flatLayouts.
    local flat = frame._cfgFlat or GetFlatProfile(flatID)
    if not flat then
        BF:HideDummyAuras(frame)
        return
    end
    -- ShowDummyAuras(frame, isRaid, raidProfile, overridePartyProfile)
    if isRaid then
        BF:ShowDummyAuras(frame, true, flat, nil)
    else
        BF:ShowDummyAuras(frame, false, nil, flat)
    end
end

-- ============================================================
-- LayoutPreviewFrame
-- Self-contained layout for preview frames. Reads dimensions
-- and scale directly from the flat table. Does NOT call
-- BF:LayoutFrame or touch _resolvedProfile / _contextIsRaid /
-- GetRaidProfile — preview frames are completely independent
-- of the real frame machinery.
-- ============================================================
local function LayoutPreviewFrame(frame, flatID)
    local flat = GetFlatProfile(flatID)
    if not flat then return end
    local isRaid = (flat.type == "raid")
    local p = BF.db.profile

    local w = flat.frameWidth  or (isRaid and 70 or 100)
    local h = flat.frameHeight or (isRaid and 40 or 68)

    local uiScale = UIParent:GetEffectiveScale()
    if uiScale > 0 then
        w = math.floor(w * uiScale + 0.5) / uiScale
        h = math.floor(h * uiScale + 0.5) / uiScale
    end

    if flat.enableFrameScale then
        local scale = flat.frameScale or 1.0
        local scaleIndicators = flat.scaleIndicators ~= false
        if scaleIndicators then
            local screenW = math.floor(w * scale * uiScale + 0.5)
            local screenH = math.floor(h * scale * uiScale + 0.5)
            local sW = screenW / (w * uiScale)
            local sH = screenH / (h * uiScale)
            local snapped = (math.abs(sW - scale) <= math.abs(sH - scale)) and sW or sH
            frame:SetScale(snapped)
        else
            frame:SetScale(1.0)
            w = math.floor(w * (flat.frameScale or 1.0) * uiScale + 0.5) / uiScale
            h = math.floor(h * (flat.frameScale or 1.0) * uiScale + 0.5) / uiScale
        end
    else
        frame:SetScale(1.0)
    end

    frame:SetSize(w, h)

    local bp = BF:GetSectionProfileForFrame("borders", frame) or {}
    local borderN = BF:EffectiveBorderPixels(bp)
    local borderUI = BF:PixelsToUI(borderN)
    -- v28: resolve healthPower per-frame so preview frames see per-flat
    -- values for the power-bar visibility/height reads below.
    local hp = BF:GetSectionProfileForFrame("healthPower", frame) or {}
    local anyPowerBar = hp.showAllPowerBars or hp.showPowerBarHealers or hp.showPowerBarBloodDK
    local powerH = anyPowerBar and BF:Scale(hp.powerBarHeight or 4) or 0

    -- Update backdrop border to match current thickness/color/opacity.
    -- Rounded styles: NO square backdrop edge — the real
    -- Container:Layout below draws the ring + mask on this frame.
    if BF.IsRoundedBorderStyle(bp.borderStyle) then
        frame:SetBackdrop(nil)
    elseif borderN > 0 then
        local edge = borderUI
        frame:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            edgeSize = edge,
            insets   = { left = edge, right = edge, top = edge, bottom = edge },
        })
        local bc = bp.borderColor or { r=0, g=0, b=0 }
        local ba = bp.borderOpacity or 1.0
        frame:SetBackdropBorderColor(bc.r, bc.g, bc.b, ba)
        frame:SetBackdropColor(0, 0, 0, 0)
    else
        frame:SetBackdrop(nil)
    end

    -- Sync frameWidth/frameHeight on the parent container so that
    -- indicator Layout methods (which read parent:GetParent().frameWidth)
    -- see the correct current dimensions.
    do
        local par = frame:GetParent()
        if par then par.frameWidth = w; par.frameHeight = h end
    end

    -- Run every indicator's Layout on this frame — the exact same code
    -- path that real frames use (BuzzardFramePrototype:Layout in BFLayout.lua).
    local indicators = BF:GetIndicatorsEnabled()
    if indicators then
        for i = 1, #indicators do
            local ind = indicators[i]
            if BF:ShouldLayoutIndicator(ind, frame) then
                ind:Layout(frame)
            end
        end
    end
end

-- ============================================================
-- LayoutPreviewCFFrame
-- Same pattern as LayoutPreviewFrame but reads from a custom
-- frame group table (cfFrameWidth, cfFrameHeight, etc.).
-- ============================================================
local function LayoutPreviewCFFrame(frame, cfGroup)
    local p = BF.db.profile
    local flat = cfGroup.flat

    -- Read size from the CFG flat (same as live headers / setup mode).
    -- When useActiveLayoutSize is on, read from the active RP flat.
    local sizeFlat = flat
    if cfGroup.useActiveLayoutSize then
        local isRaid = BF:ResolveActiveIsRaid()
        local activeFlat = isRaid and BF:GetRaidProfile() or BF:GetActivePartyProfile()
        if activeFlat then sizeFlat = activeFlat end
    end
    local w = (sizeFlat and sizeFlat.frameWidth)  or 70
    local h = (sizeFlat and sizeFlat.frameHeight) or 40

    local uiScale = UIParent:GetEffectiveScale()
    if uiScale > 0 then
        w = math.floor(w * uiScale + 0.5) / uiScale
        h = math.floor(h * uiScale + 0.5) / uiScale
    end

    if flat and flat.enableFrameScale and flat.frameScale then
        if flat.scaleIndicators ~= false then
            local screenW = math.floor(w * flat.frameScale * uiScale + 0.5)
            local screenH = math.floor(h * flat.frameScale * uiScale + 0.5)
            local sW = screenW / (w * uiScale)
            local sH = screenH / (h * uiScale)
            local snapped = (math.abs(sW - flat.frameScale) <= math.abs(sH - flat.frameScale)) and sW or sH
            frame:SetScale(snapped)
        else
            frame:SetScale(1.0)
            w = math.floor(w * flat.frameScale * uiScale + 0.5) / uiScale
            h = math.floor(h * flat.frameScale * uiScale + 0.5) / uiScale
        end
    else
        frame:SetScale(1.0)
    end

    frame:SetSize(w, h)

    -- Now that _cfgFlat is stamped, GetSectionProfileForFrame resolves
    -- per-section overrides against the CFG flat correctly.
    local bp = BF:GetSectionProfileForFrame("borders", frame) or {}
    local borderN = BF:EffectiveBorderPixels(bp)
    local borderUI = BF:PixelsToUI(borderN)
    local hp = BF:GetSectionProfileForFrame("healthPower", frame) or {}
    local anyPowerBar = hp.showAllPowerBars or hp.showPowerBarHealers or hp.showPowerBarBloodDK
    local powerH = anyPowerBar and BF:Scale(hp.powerBarHeight or 4) or 0

    -- Rounded styles: skip the square backdrop edge (real
    -- Container:Layout draws the ring + mask).
    if BF.IsRoundedBorderStyle(bp.borderStyle) then
        frame:SetBackdrop(nil)
    elseif borderN > 0 then
        local edge = borderUI
        frame:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            edgeSize = edge,
            insets   = { left = edge, right = edge, top = edge, bottom = edge },
        })
        local bc = bp.borderColor or { r=0, g=0, b=0 }
        local ba = bp.borderOpacity or 1.0
        frame:SetBackdropBorderColor(bc.r, bc.g, bc.b, ba)
        frame:SetBackdropColor(0, 0, 0, 0)
    else
        frame:SetBackdrop(nil)
    end

    do
        local par = frame:GetParent()
        if par then par.frameWidth = w; par.frameHeight = h end
    end

    local indicators = BF:GetIndicatorsEnabled()
    if indicators then
        for i = 1, #indicators do
            local ind = indicators[i]
            if BF:ShouldLayoutIndicator(ind, frame) then
                ind:Layout(frame)
            end
        end
    end
end

-- ============================================================
-- IsCFPreviewHidden(tierKey)
-- Returns true if the user has clicked Remove on this CF preview
-- slot in the Options panel. Checked by all CF rendering paths
-- so a hidden preview neither lays out, shows a frame, nor
-- appears in positioning.
-- ============================================================
local function IsCFPreviewHidden(tierKey)
    local hidden = BF.rpDB and BF.rpDB.profile and BF.rpDB.profile._hiddenCFPreviewSlots
    return hidden and hidden[tierKey] == true
end

-- ============================================================
-- MatchContainerToUIScale(container, panelFrame)
-- The preview containers are CHILDREN of the options panel so
-- its strata and level carry them -- but the panel draws at its
-- own scale, and the previews must not: they exist to show the
-- REAL size the frames draw at in game. Counter-scale the
-- container so its effective scale is exactly UIParent's,
-- whatever scale the panel wears. Returns the factor that turns
-- a length in the PANEL's units into the container's units.
-- ============================================================
local function MatchContainerToUIScale(container, panelFrame)
    local pEff = panelFrame:GetEffectiveScale()
    local uEff = UIParent:GetEffectiveScale()
    if not (pEff and uEff) or pEff <= 0 or uEff <= 0 then return 1 end
    local want = uEff / pEff
    local have = container:GetScale() or 1
    if math.abs(have - want) > 0.0001 then
        container:SetScale(want)
    end
    return pEff / uEff
end

-- ============================================================
-- PositionPreviewCFFrames
-- Stacks enabled CF preview frames on the RIGHT side of the
-- options panel. Hides the container when no CF groups are shown.
-- ============================================================
local function PositionPreviewCFFrames(p)
    local panelFrame = GetOptionsFrame()
    if not panelFrame or not BF._previewCFContainer then return end

    local cfc = BF._previewCFContainer
    local enabledCFs = EnabledCFGroups()

    -- Hide all CF frames first
    for i = 1, MAX_CF_PREVIEWS do
        if BF._previewCFFrames[i] then BF._previewCFFrames[i]:Hide() end
        if BF._previewCFLabels[i] then BF._previewCFLabels[i]:Hide() end
    end

    if #enabledCFs == 0 then
        cfc:Hide()
        return
    end

    local GAP     = 7
    local TOP_PAD = 30
    local BOX_GAP = 48

    -- Find max width among enabled CF frames
    local maxW = 0
    for slot, entry in ipairs(enabledCFs) do
        local f = BF._previewCFFrames[slot]
        if f then
            local fw = f:GetWidth()
            if fw > maxW then maxW = fw end
        end
    end

    cfc:ClearAllPoints()
    -- Bind to the panel: a child inherits its strata and moves with its
    -- level, so no other addon's options panel can draw over the previews.
    if cfc:GetParent() ~= panelFrame then
        cfc:SetParent(panelFrame)
        cfc:SetFrameLevel(panelFrame:GetFrameLevel() + 1)
    end
    -- At the REAL in-game size, whatever scale the panel wears.
    local toC = MatchContainerToUIScale(cfc, panelFrame)
    cfc:SetPoint("TOPLEFT", panelFrame, "TOPRIGHT", GAP, 0)
    cfc:SetHeight(panelFrame:GetHeight() * toC)
    cfc:SetWidth(maxW > 0 and maxW or 100)

    local prevFrame = nil
    for slot, entry in ipairs(enabledCFs) do
        local tierKey = "cf" .. slot
        if not IsCFPreviewHidden(tierKey) then
            local f = BF._previewCFFrames[slot]
            local l = BF._previewCFLabels[slot]
            if f then
                f:ClearAllPoints()
                if not prevFrame then
                    f:SetPoint("TOPLEFT", cfc, "TOPLEFT", 0, -TOP_PAD)
                else
                    f:SetPoint("TOPLEFT", prevFrame, "BOTTOMLEFT", 0, -BOX_GAP)
                end
                f:Show()
                if l then l:Show() end
                prevFrame = f
            end
        end
    end

    -- Hide the CF container entirely when every enabled slot has been
    -- manually removed by the user. Prevents an empty container frame
    -- from sitting on the right side of the options panel.
    if prevFrame == nil then
        cfc:Hide()
        return
    end

    cfc:Show()
end
-- ============================================================
-- PositionPreviewFrames(activeOrder)
-- Stacks preview frames top-to-bottom in the given order.
-- Hides any preview frames not in activeOrder. Positions the
-- arrow indicator next to the currently-editing flat's frame.
-- ============================================================
local function PositionPreviewFrames(activeOrder)
    local panelFrame = GetOptionsFrame()
    if not panelFrame or not BF._previewContainer then return end

    local c = BF._previewContainer
    local GAP     = 7
    local TOP_PAD = 30
    local BOX_GAP = 48

    -- Find max width among the active frames (determines container width)
    local maxW = 0
    for _, flatID in ipairs(activeOrder) do
        local f = BF._previewFrames and BF._previewFrames[flatID]
        if f then
            local w = f:GetWidth()
            if w > maxW then maxW = w end
        end
    end

    c:ClearAllPoints()
    if c:GetParent() ~= panelFrame then
        c:SetParent(panelFrame)
        c:SetFrameLevel(panelFrame:GetFrameLevel() + 1)
    end
    -- At the REAL in-game size, whatever scale the panel wears.
    local toC = MatchContainerToUIScale(c, panelFrame)
    c:SetPoint("TOPRIGHT", panelFrame, "TOPLEFT", -GAP, 0)
    c:SetHeight(panelFrame:GetHeight() * toC)
    c:SetWidth(maxW > 0 and maxW or 1)

    -- Hide every pooled frame first (dormant ones stay hidden; active
    -- ones get Shown again in the loop below)
    if BF._previewFrames then
        for _, f in pairs(BF._previewFrames) do f:Hide() end
    end
    if BF._previewLabels then
        for _, lbl in pairs(BF._previewLabels) do lbl:Hide() end
    end

    -- Stack active frames. The 1x1 anchor points are never scaled,
    -- so SetScale on the preview frame doesn't shift anything.
    local yOff = -TOP_PAD
    for _, flatID in ipairs(activeOrder) do
        local f = BF._previewFrames and BF._previewFrames[flatID]
        local a = f and f._anchor1x1
        local lbl = BF._previewLabels and BF._previewLabels[flatID]
        if a then
            a:ClearAllPoints()
            a:SetPoint("TOPRIGHT", c, "TOPRIGHT", 0, yOff)
            a:Show()
        end
        if f then f:Show() end
        if lbl then lbl:Show() end
        if f then
            local visualH = f:GetHeight() * (f:GetScale() or 1)
            yOff = yOff - visualH - BOX_GAP
        end
    end

    c:Show()

    -- Position arrow next to the currently-editing flat's frame
    if BF._previewArrow then
        local editing = BF._modifyingFlat
        local target = editing and BF._previewFrames and BF._previewFrames[editing]
        if target and target:IsShown() then
            BF._previewArrow:ClearAllPoints()
            BF._previewArrow:SetPoint("RIGHT", target, "LEFT", -4, 0)
            BF._previewArrow:Show()
        else
            BF._previewArrow:Hide()
        end
    end
end

-- A single shared C_Timer that restarts dummy aura cooldowns on
-- all preview frames every 30 seconds. Only runs when the preview
-- pane is open (ShouldShowPreviewAuras).
-- ============================================================
local function CancelPreviewAuraTimer()
    if BF._previewAuraTimer then
        BF._previewAuraTimer:Cancel()
        BF._previewAuraTimer = nil
    end
end

function BF:ShouldShowPreviewAuras()
    -- v70: the old on/off db.global.showPreviewAuras gate is gone. The per-tab
    -- Preview dropdown always shows SOMETHING; "no preview auras at all" is now
    -- expressed by the master showPreview toggle (checked below), which hides
    -- the whole preview pane.
    if not self.db then return false end
    if not self._previewContainer or not self._previewContainer:IsShown() then
        if BF._debugContainerPreview then print("|cffff0000[BF ShouldShow]|r previewContainer nil or not shown, container=", self._previewContainer and "exists" or "NIL", "shown=", self._previewContainer and self._previewContainer:IsShown()) end
        return false
    end
    local sec = self._currentSection
    if sec ~= "auras" and sec ~= "auraText" and sec ~= "dispelDebuffBorder"
       and sec ~= "customAuras" and sec ~= "previewAuras"
       and sec ~= "customFrameAuras" and sec ~= "customFrameAuraText" then
        if BF._debugContainerPreview then print("|cffff0000[BF ShouldShow]|r section not in allowlist, sec=", tostring(sec)) end
        return false
    end
    if not self.db.global.showPreview then
        if BF._debugContainerPreview then print("|cffff0000[BF ShouldShow]|r showPreview is false") end
        return false
    end
    -- Either options panel hosting the previews is enough; GetOptionsFrame is
    -- the one place that decides which one that is.
    if not GetOptionsFrame() then
        if BF._debugContainerPreview then print("|cffff0000[BF ShouldShow]|r no options panel open") end
        return false
    end
    if BF._debugContainerPreview then print("|cff00ff00[BF ShouldShow]|r returning TRUE, sec=", sec) end
    return true
end
-- ============================================================
-- Hide
-- ============================================================
local function HidePreviewFrames()
    CancelPreviewAuraTimer()
    -- Cancel individual frame timers and hide auras on every pooled frame
    if BF._previewFrames then
        for _, f in pairs(BF._previewFrames) do BF:HideDummyAuras(f) end
    end
    if BF._previewCFFrames then
        for _, cf in ipairs(BF._previewCFFrames) do BF:HideDummyAuras(cf) end
    end
    if BF._previewContainer then BF._previewContainer:Hide() end
    if BF._previewCFContainer then BF._previewCFContainer:Hide() end
end

-- ============================================================
-- GUARD HELPER
-- Returns true if the preview pane should be rendering right now.
-- ============================================================
local function PreviewGuard()
    if not BF._previewContainer or not BF._previewContainer:IsShown() then return false end
    if not BF.db or not BF.db.global.showPreview then return false end
    return true
end

-- ============================================================
-- RefreshPreview: full refresh
-- Walks the active preview set (editing flat + pinned flats),
-- creates/lays out/labels each frame, applies dummy data, and
-- positions them. Also updates CF preview frames (unchanged).
-- ============================================================
local function RefreshPreview(self, _unused)
    local panelFrame = GetOptionsFrame()
    local p = self.db.profile
    if not panelFrame or not BF.db.global.showPreview then
        HidePreviewFrames()
        return
    end

    EnsurePreviewFramesContainer()

    local order, _setByFlat = ComputeActivePreviewSet()

    -- Layout + label each active flat
    for _, flatID in ipairs(order) do
        local f = EnsurePreviewFrameForFlat(flatID)
        if f then
            LayoutPreviewFrame(f, flatID)
            local flat = GetFlatProfile(flatID)
            local isRaid = (flat and flat.type == "raid") or false

            -- Stamp the containerGroupTypeKey BEFORE applying aura dummy data.
            -- CustomAuras.lua (File 13) reads this key as the flat ID and
            -- looks up groupSettings[flatID] / per-flat visibility.
            f._bf_containerGroupTypeKey = flatID

            ApplyAllPreviewDummyData(f, isRaid, p, flatID)

            -- Label: "flat_name  W × H" colored by flat type
            local lbl = BF._previewLabels and BF._previewLabels[flatID]
            if lbl and flat then
                local color = TYPE_COLORS[flat.type] or "|cffffffff"
                local w = flat.frameWidth  or f:GetWidth()
                local h = flat.frameHeight or f:GetHeight()
                local displayName = flat.name or flatID
                lbl:SetText(string.format("%s%s|r  %d \195\151 %d",
                    color, displayName, w, h))
            end
        end
    end

    PositionPreviewFrames(order)

    -- Custom Frame Group previews (right side). Hidden slots
    -- (user clicked Remove on the Preview Units tab) are skipped:
    -- their frames are Hide()n at the top of PositionPreviewCFFrames
    -- so the layout work below would be wasted for them anyway.
    local enabledCFs = EnabledCFGroups()
    for slot, entry in ipairs(enabledCFs) do
        local tierKey = "cf" .. slot
        if not IsCFPreviewHidden(tierKey) then
            local cf = BF._previewCFFrames and BF._previewCFFrames[slot]
            if cf then
                -- Stamp CFG context so GetSectionProfileForFrame resolves
                -- per-section overrides against the CFG flat, not the global.
                cf._cfgFlat      = entry.group.flat
                cf._cfgGroup     = entry.group
                cf._cfGroupIndex = entry.index
                cf._cfSlot       = slot
                cf._cfGroup      = entry.group
                -- Stamp per-CFG aura cache so dummy aura rendering respects
                -- CFG-specific aura text settings (spark, swipe, duration, etc.)
                cf._bf_auraCache = entry.group.flat and entry.group.flat._auraCache or nil
                LayoutPreviewCFFrame(cf, entry.group)
                ApplyAllPreviewDummyData(cf, true, p, tierKey)
            end
        end
    end
    for slot, entry in ipairs(enabledCFs) do
        local tierKey = "cf" .. slot
        if not IsCFPreviewHidden(tierKey) then
            local cl = BF._previewCFLabels and BF._previewCFLabels[slot]
            local cf = BF._previewCFFrames and BF._previewCFFrames[slot]
            if cl and cf then
                local g = entry.group
                local lW = cf:GetWidth()
                local lH = cf:GetHeight()
                local name = g.name or ("Group " .. entry.index)
                cl:SetText(string.format("%s%s|r  %d \195\151 %d",
                    CF_PREVIEW_COLOR, name, lW, lH))
            end
        end
    end
    -- Hide unused CF slots
    for i = #enabledCFs + 1, MAX_CF_PREVIEWS do
        if BF._previewCFFrames and BF._previewCFFrames[i] then BF._previewCFFrames[i]:Hide() end
        if BF._previewCFLabels and BF._previewCFLabels[i] then BF._previewCFLabels[i]:Hide() end
    end
    PositionPreviewCFFrames(p)

    -- Reapply OOR alpha and desaturation across all active previews
    if BF._previewOOR then
        local isOffline = BF._previewStatus == "offline"
        -- healthPower range-fade/desaturate keys are per-flat under the
        -- healthPower per-layout toggle. fadeOfflineFrames is in the same
        -- section (its widget is on the Health & Power tab). Resolve
        -- per-frame via GetSectionProfile so each preview respects its
        -- own flat's settings.
        if BF._previewFrames then
            for flatID, f in pairs(BF._previewFrames) do
                if f:IsShown() then
                    local flat = GetFlatProfile(flatID)
                    local hp   = BF:GetSectionProfile("healthPower", flat) or {}
                    local fadeOff      = hp.fadeOfflineFrames
                    local fadeAlpha    = hp.rangeFadeAlpha or 0.4
                    local rangeEnabled = hp.enableRangeFade
                    local desat = hp.enableRangeDesaturate and (hp.rangeDesaturation or 0.5) or 0
                    local alpha = rangeEnabled
                        and ((isOffline and not fadeOff) and 1.0 or fadeAlpha)
                        or 1.0
                    -- state=false simulates OOR; one shared writer for both effects.
                    BF:ApplyRangeEffects(f, false, true, alpha, desat)
                end
            end
        end
        -- CF previews aren't per-flat; fall back to the global via nil-flat.
        local cfHP     = BF:GetSectionProfile("healthPower", nil) or {}
        local cfFadeOff = cfHP.fadeOfflineFrames
        local cfFade   = cfHP.rangeFadeAlpha or 0.4
        local cfRange  = cfHP.enableRangeFade
        local cfDesat  = cfHP.enableRangeDesaturate and (cfHP.rangeDesaturation or 0.5) or 0
        local cfAlpha  = cfRange
            and ((isOffline and not cfFadeOff) and 1.0 or cfFade)
            or 1.0
        if BF._previewCFFrames then
            for i = 1, #enabledCFs do
                local cf = BF._previewCFFrames[i]
                if cf then
                    BF:ApplyRangeEffects(cf, false, true, cfAlpha, cfDesat)
                end
            end
        end
    else
        -- OOR disabled: reset alpha and desaturation on all previews
        if BF._previewFrames then
            for _, f in pairs(BF._previewFrames) do
                if f:IsShown() then
                    BF:ApplyRangeEffects(f, true, true, 1, 0)  -- reset
                end
            end
        end
        if BF._previewCFFrames then
            for i = 1, #enabledCFs do
                local cf = BF._previewCFFrames[i]
                if cf then
                    BF:ApplyRangeEffects(cf, true, true, 1, 0)  -- reset
                end
            end
        end
    end

    -- Preview dummy auras: show on all active preview frames when the
    -- Auras section is open and showPreviewAuras is enabled.
    CancelPreviewAuraTimer()
    if BF:ShouldShowPreviewAuras() then
        for _, flatID in ipairs(order) do
            local f = BF._previewFrames and BF._previewFrames[flatID]
            if f then
                local flat = GetFlatProfile(flatID)
                local isRaid = (flat and flat.type == "raid") or false
                ApplyPreviewDummyAuras(f, isRaid, p, flatID)
            end
        end
        if BF._previewCFFrames then
            local enabledCFsForAuras = EnabledCFGroups()
            for slot, entry in ipairs(enabledCFsForAuras) do
                local cf = BF._previewCFFrames[slot]
                if cf and cf:IsShown() then
                    -- v61: CFG container scopes are keyed by the CFG flat's
                    -- stable cfgFlatID, so the preview stamp must match what
                    -- BF:ResolveGroupTypeKey produces for live frames.
                    cf._bf_containerGroupTypeKey = (entry.group and entry.group.flat and entry.group.flat.cfgFlatID)
                        or (BF.GetCFGFlatID and BF:GetCFGFlatID(entry.index))
                    ApplyPreviewDummyAuras(cf, true, p, "cf" .. slot)
                end
            end
        end
        BF._previewAuraTimer = C_Timer.NewTimer(30, function()
            BF._previewAuraTimer = nil
            if BF:ShouldShowPreviewAuras() then
                BF:RefreshPreviewDummyAuras()
            end
        end)
    else
        -- Auras section not active — ensure any stale auras are cleaned up
        if BF._previewFrames then
            for _, f in pairs(BF._previewFrames) do BF:HideDummyAuras(f) end
        end
        if BF._previewCFFrames then
            for _, cf in ipairs(BF._previewCFFrames) do BF:HideDummyAuras(cf) end
        end
    end

    -- §T5.3 #2: set sizes for the previewSweep timing line. Two integer
    -- writes, no allocation, so they stay unconditional.
    BF._previewLastFlats = #order
    BF._previewLastCFGs  = #enabledCFs
end

-- ============================================================
-- Public methods
-- ============================================================

function BF:HidePreviewFrames()
    HidePreviewFrames()
end

-- Legacy signature kept (some call sites still pass a group-type arg);
-- the arg is now ignored — every refresh recomputes the full active set.
function BF:RefreshPreviewFrames(_unused)
    RefreshPreview(BF)
end

-- Light-weight refresh: re-layout each active preview frame without
-- reapplying dummy data. The active set is recomputed from scratch;
-- the `_unused` parameter is ignored (was groupType under old model).
function BF:RefreshPreviewLayout(_unused)
    if not PreviewGuard() then return end

    local order = ComputeActivePreviewSet()
    for _, flatID in ipairs(order) do
        local f = EnsurePreviewFrameForFlat(flatID)
        if f then LayoutPreviewFrame(f, flatID) end
    end
    PositionPreviewFrames(order)
end

-- ============================================================
-- Standalone preview frames
-- A preview frame that lives OUTSIDE the panel-anchored preview container,
-- for a caller that positions it itself -- today the boss preview
-- (UnitFrames/oUF_BossPreview.lua), which stands one in for the boss
-- raid-style twin at the twin's own spot. Same construction and the same
-- paint pipeline as the Preview section's frames (MakePreviewFrame /
-- LayoutPreviewFrame / ApplyAllPreviewDummyData / ShowDummyAuras), so the
-- two can never look different. These frames are NOT in BF._previewFrames:
-- the section refreshers and the aura restart timer do not touch them, and
-- the caller repaints them itself (it hooks RefreshPreviewFrames).
-- `parent` carries the scale: LayoutPreviewFrame stamps frameWidth /
-- frameHeight onto it the way it does the container.
-- ============================================================
function BF:MakeStandalonePreviewFrame(name, parent)
    local f = MakePreviewFrame(name, parent, 100, 68)
    f._bf_standalonePreview = true
    return f
end

-- withAuras: paint the dummy buff/debuff rows regardless of which section
-- is open (ApplyPreviewDummyAuras gates on ShouldShowPreviewAuras; a
-- standalone caller decides for itself).
-- unit: this frame's OWN fake unit -- { name, class, hp, role } -- so
-- nothing is borrowed from the flat's fake player: class nil paints the
-- non-player health color and the static name color, role "NONE"
-- hides the role icon (GetFakeUnit / ApplyPreviewRoleIcon,
-- PreviewData.lua). Abbreviate / capitalize apply to the name as
-- to any. Omit it to paint the flat's fake player as the Preview section
-- does.
function BF:PaintStandalonePreviewFrame(f, flatID, withAuras, unit)
    local flat = GetFlatProfile(flatID)
    if not (f and flat) then return end
    local isRaid = (flat.type == "raid")
    f._flatID                   = flatID
    f._bf_containerGroupTypeKey = flatID
    f._bf_auraCache             = flat._auraCache or nil
    f._bf_previewUnit           = unit
    LayoutPreviewFrame(f, flatID)
    ApplyAllPreviewDummyData(f, isRaid, self.db.profile, flatID)
    if withAuras then
        if isRaid then
            self:ShowDummyAuras(f, true, flat, nil)
        else
            self:ShowDummyAuras(f, false, nil, flat)
        end
    else
        self:HideDummyAuras(f)
    end
    -- The painters leave this frame as the module's current context;
    -- a GetFakeUnit from outside a painter must not see its unit.
    local clear = BF._preview and BF._preview.ClearPreviewContext
    if clear then clear() end
end

function BF:HideStandalonePreviewFrame(f)
    if not f then return end
    self:HideDummyAuras(f)
    f:Hide()
end

-- Re-anchor the preview containers without touching their contents. The new
-- options panel calls this after a resize, so the containers pick up the
-- panel's current height and frame level without re-laying-out or re-painting
-- anything: both positioners read the host frame through GetOptionsFrame and
-- set the anchors, height and level from it. PositionPreviewCFFrames ignores
-- the profile table it is handed today, but it is passed for symmetry with
-- every other call site.
function BF:RepositionPreviewFrames()
    if not PreviewGuard() then return end
    PositionPreviewFrames(ComputeActivePreviewSet())
    PositionPreviewCFFrames(BF.db.profile)
end

-- Iterate all currently-visible preview frames with fn(frame, isRaid, p, flatID).
-- Used by the lightweight refresh methods below (RefreshPreviewHealthBar etc.)
-- to reapply a single indicator's data without a full rebuild.
local function ForAllFrames(fn)
    if not PreviewGuard() then return end
    local p = BF.db.profile

    if BF._previewFrames then
        for flatID, f in pairs(BF._previewFrames) do
            if f:IsShown() then
                local flat = GetFlatProfile(flatID)
                if flat then
                    local isRaid = (flat.type == "raid")
                    fn(f, isRaid, p, flatID)
                end
            end
        end
    end

    if BF._previewCFFrames then
        local enabledCFs = EnabledCFGroups()
        for slot in ipairs(enabledCFs) do
            local cf = BF._previewCFFrames[slot]
            if cf and cf:IsShown() then fn(cf, true, p, "cf" .. slot) end
        end
    end
end

function BF:RefreshPreviewHealthBar()   ForAllFrames(ApplyPreviewHealthBar)   end
function BF:RefreshPreviewName()        ForAllFrames(ApplyPreviewName)        end
function BF:RefreshPreviewHealthText()  ForAllFrames(ApplyPreviewHealthText)  end
function BF:RefreshPreviewRoleIcon()    ForAllFrames(ApplyPreviewRoleIcon)    end
function BF:RefreshPreviewStatusIcons() ForAllFrames(ApplyPreviewStatusIcons) end
function BF:RefreshPreviewStatus()      ForAllFrames(ApplyPreviewStatus)      end
-- v29: granular refresh for highlight/overlay/dispel color/alpha edits
-- (border color, aggro style, target highlight color/opacity/width, debuff
-- overlay alpha/height, etc.). ApplyPreviewHighlights calls _setPreviewFlat
-- so per-flat borders values resolve correctly. For geometry-affecting
-- edits (enableBorder / borderThickness / borderOpacity) use
-- RefreshPreviewLayout instead.
function BF:RefreshPreviewHighlights()  ForAllFrames(ApplyPreviewHighlights)  end
function BF:RefreshPreviewAggro()       ForAllFrames(ApplyPreviewAggro)       end

function BF:RefreshPreviewHealAbsorb()
    local p = BF.db and BF.db.profile
    if not p then return end
    if BF._previewFrames then
        for flatID, f in pairs(BF._previewFrames) do
            if f:IsShown() then
                local flat = GetFlatProfile(flatID)
                local isRaid = (flat and flat.type == "raid") or false
                ApplyPreviewHealAbsorb(f, isRaid, p, flatID)
            end
        end
    end
    if BF._previewCFFrames then
        local enabledCFs = EnabledCFGroups()
        for slot in ipairs(enabledCFs) do
            local cf = BF._previewCFFrames[slot]
            if cf and cf:IsShown() then ApplyPreviewHealAbsorb(cf, true, p, "cf" .. slot) end
        end
    end
end

-- v27: granular refresh entry points for the other three absorbs Apply*
-- functions. Called from Options_Absorbs.lua setters so a color/texture
-- edit doesn't trigger a full preview rebuild. Each passes flatID/tier so
-- ApplyPreview* can _setPreviewFlat and resolve the per-flat absorbs
-- profile correctly.
function BF:RefreshPreviewAbsorbOverlay()
    local p = BF.db and BF.db.profile
    if not p then return end
    if BF._previewFrames then
        for flatID, f in pairs(BF._previewFrames) do
            if f:IsShown() then
                local flat = GetFlatProfile(flatID)
                local isRaid = (flat and flat.type == "raid") or false
                ApplyPreviewAbsorbOverlay(f, isRaid, p, flatID)
            end
        end
    end
    if BF._previewCFFrames then
        local enabledCFs = EnabledCFGroups()
        for slot in ipairs(enabledCFs) do
            local cf = BF._previewCFFrames[slot]
            if cf and cf:IsShown() then ApplyPreviewAbsorbOverlay(cf, true, p, "cf" .. slot) end
        end
    end
end

function BF:RefreshPreviewHealPrediction()
    local p = BF.db and BF.db.profile
    if not p then return end
    if BF._previewFrames then
        for flatID, f in pairs(BF._previewFrames) do
            if f:IsShown() then
                local flat = GetFlatProfile(flatID)
                local isRaid = (flat and flat.type == "raid") or false
                ApplyPreviewHealPrediction(f, isRaid, p, flatID)
            end
        end
    end
    if BF._previewCFFrames then
        local enabledCFs = EnabledCFGroups()
        for slot in ipairs(enabledCFs) do
            local cf = BF._previewCFFrames[slot]
            if cf and cf:IsShown() then ApplyPreviewHealPrediction(cf, true, p, "cf" .. slot) end
        end
    end
end

function BF:RefreshPreviewReducedMaxHealth()
    local p = BF.db and BF.db.profile
    if not p then return end
    if BF._previewFrames then
        for flatID, f in pairs(BF._previewFrames) do
            if f:IsShown() then
                local flat = GetFlatProfile(flatID)
                local isRaid = (flat and flat.type == "raid") or false
                ApplyPreviewReducedMaxHealth(f, isRaid, p, flatID)
            end
        end
    end
    if BF._previewCFFrames then
        local enabledCFs = EnabledCFGroups()
        for slot in ipairs(enabledCFs) do
            local cf = BF._previewCFFrames[slot]
            if cf and cf:IsShown() then ApplyPreviewReducedMaxHealth(cf, true, p, "cf" .. slot) end
        end
    end
end

function BF:RefreshPreviewPowerBar()
    if not PreviewGuard() then return end
    local p = BF.db.profile
    if BF._previewFrames then
        for flatID, f in pairs(BF._previewFrames) do
            if f:IsShown() then
                local flat = GetFlatProfile(flatID)
                local isRaid = (flat and flat.type == "raid") or false
                LayoutPreviewFrame(f, flatID)
                ApplyPreviewPowerBar(f, isRaid, p, flatID)
            end
        end
    end
    if BF._previewCFFrames then
        local enabledCFs = EnabledCFGroups()
        for slot, entry in ipairs(enabledCFs) do
            local cf = BF._previewCFFrames[slot]
            if cf and cf:IsShown() then
                LayoutPreviewCFFrame(cf, entry.group)
                ApplyPreviewPowerBar(cf, true, p, "cf" .. slot)
            end
        end
    end
end

function BF:RefreshPreviewDummyAuras()
    if not PreviewGuard() then
        CancelPreviewAuraTimer()
        return
    end
    local p = BF.db.profile
    if not BF:ShouldShowPreviewAuras() then
        if BF._previewFrames then
            for _, f in pairs(BF._previewFrames) do BF:HideDummyAuras(f) end
        end
        if BF._previewCFFrames then
            for _, cf in ipairs(BF._previewCFFrames) do BF:HideDummyAuras(cf) end
        end
        CancelPreviewAuraTimer()
        return
    end
    -- Show auras on all currently-visible preview frames
    if BF._previewFrames then
        for flatID, f in pairs(BF._previewFrames) do
            if f:IsShown() then
                local flat = GetFlatProfile(flatID)
                local isRaid = (flat and flat.type == "raid") or false
                f._bf_containerGroupTypeKey = flatID
                ApplyPreviewDummyAuras(f, isRaid, p, flatID)
            end
        end
    end
    if BF._previewCFFrames then
        local enabledCFs = EnabledCFGroups()
        for slot, entry in ipairs(enabledCFs) do
            local cf = BF._previewCFFrames[slot]
            if cf and cf:IsShown() then
                -- v61: see the matching stamp in RefreshPreview -- CFG
                -- container scopes are keyed by cfgFlatID, not array position.
                cf._bf_containerGroupTypeKey = (entry.group and entry.group.flat and entry.group.flat.cfgFlatID)
                    or (BF.GetCFGFlatID and BF:GetCFGFlatID(entry.index))
                ApplyPreviewDummyAuras(cf, true, p, "cf" .. slot)
            end
        end
    end
    CancelPreviewAuraTimer()
    BF._previewAuraTimer = C_Timer.NewTimer(30, function()
        BF._previewAuraTimer = nil
        if BF:ShouldShowPreviewAuras() then
            BF:RefreshPreviewDummyAuras()
        end
    end)
end

-- ============================================================
-- Per-type dummy-aura refresh entry points.
--
-- Each iterates every currently-visible preview frame (flat + CF)
-- and invokes BF:ShowDummy<Type> so only that aura type repaints.
-- Used by Options_AuraText.lua setters so a buff-font-color edit
-- only repaints the preview dummy buffs (and similar for debuffs,
-- bigDef, stack text).
-- (v67: the privateAuras entry point was removed with that feature.)
--
-- The monolithic BF:ShowDummyAuras owns the 30s dummy-cooldown
-- restart timer; per-type refreshes do NOT touch that timer. When
-- a per-type refresh runs, the preview is already active (options
-- panel open on the Aura Text section) which means a prior
-- ApplyPreviewDummyAuras call has already scheduled the 30s timer.
--
-- Each refresh guards on PreviewGuard + ShouldShowPreviewAuras so
-- the calls are free no-ops when the options panel is closed.
-- ============================================================

local function _ForEachShownPreviewFrameAuraCtx(fn)
    if not PreviewGuard() then return end
    if not BF:ShouldShowPreviewAuras() then return end
    if BF._previewFrames then
        for flatID, f in pairs(BF._previewFrames) do
            if f:IsShown() then
                local flat = GetFlatProfile(flatID)
                if flat then
                    local isRaid = (flat.type == "raid")
                    -- v92 §B7.2: stamp the container scope key here too, not
                    -- only in RefreshPreview / RefreshPreviewDummyAuras. A
                    -- per-type refresh is no longer container-agnostic:
                    -- BF:ShowDummyDebuffs resolves the debuff-container CLAIM
                    -- map and the Debuffs-anchored inline icons through this
                    -- key, so a type-only repaint that ever ran before a full
                    -- pass would resolve them against the wrong Layout.
                    f._bf_containerGroupTypeKey = flatID
                    fn(f, isRaid, flat)
                end
            end
        end
    end
    if BF._previewCFFrames then
        local enabledCFs = EnabledCFGroups()
        for slot, entry in ipairs(enabledCFs) do
            local cf = BF._previewCFFrames[slot]
            if cf and cf:IsShown() then
                -- v61: CFG container scopes are keyed by cfgFlatID, not array
                -- position -- same expression as RefreshPreviewDummyAuras.
                cf._bf_containerGroupTypeKey = (entry.group and entry.group.flat and entry.group.flat.cfgFlatID)
                    or (BF.GetCFGFlatID and BF:GetCFGFlatID(entry.index))
                -- CF previews render as raid-typed with a flat looked up by
                -- tierKey ("cf" .. slot). Under the flat model there is no CF
                -- flat in flatLayouts, so we pass nil for raidProfile and let
                -- ShowDummy<Type> fall back to GetRaidProfile(). This matches
                -- what ApplyPreviewDummyAuras does for CF frames (it calls
                -- ShowDummyAuras with flat=nil so GetRaidProfile fires).
                fn(cf, true, nil)
            end
        end
    end
end

function BF:RefreshPreviewDummyBuffs()
    _ForEachShownPreviewFrameAuraCtx(function(frame, isRaid, flat)
        if isRaid then
            BF:ShowDummyBuffs(frame, true, flat, nil)
        else
            BF:ShowDummyBuffs(frame, false, nil, flat)
        end
    end)
end

function BF:RefreshPreviewDummyDebuffs()
    _ForEachShownPreviewFrameAuraCtx(function(frame, isRaid, flat)
        if isRaid then
            BF:ShowDummyDebuffs(frame, true, flat, nil)
        else
            BF:ShowDummyDebuffs(frame, false, nil, flat)
        end
    end)
end

function BF:RefreshPreviewDummyBigDef()
    _ForEachShownPreviewFrameAuraCtx(function(frame, isRaid, flat)
        if isRaid then
            BF:ShowDummyBigDef(frame, true, flat, nil)
        else
            BF:ShowDummyBigDef(frame, false, nil, flat)
        end
    end)
end

-- v64: RefreshPreviewDummyImportant removed with the Important feature.

-- v67: RefreshPreviewDummyPrivateAuras removed with the Private Auras feature.
-- v69: RefreshPreviewDummyCrowdControl removed with the dedicated Crowd
-- Control feature (now a seeded custom debuff container).

function BF:RefreshPreviewDummyStackText()
    _ForEachShownPreviewFrameAuraCtx(function(frame, isRaid, flat)
        if isRaid then
            BF:ShowDummyStackText(frame, true, flat, nil)
        else
            BF:ShowDummyStackText(frame, false, nil, flat)
        end
    end)
end

-- Batch refresh used by the globalAuraTextConfig (Duration Text) sub-category
-- setters: when the user is in "global" mode, each setter drives the duration
-- settings for buffs + debuffs + bigDef at once, so
-- the preview needs every non-stack type repainted. (v67: private auras dropped.)
-- Stack text is excluded because it has its own subcategory (stackText) that
-- is independent of globalAuraTextConfig.
-- Shared type flags table (reused, avoids per-call allocation)
local _globalTypeFlags = {
    buffs = true, debuffs = true, bigDef = true,
    -- v67: the privateAuras flag was removed with the Private Auras feature.
    -- v69: the crowdControl flag was removed with the dedicated CC feature.
}

function BF:RefreshPreviewDummyGlobal()
    _ForEachShownPreviewFrameAuraCtx(function(frame, isRaid, flat)
        if isRaid then
            BF:ShowDummyBatch(frame, true, flat, nil, _globalTypeFlags)
        else
            BF:ShowDummyBatch(frame, false, nil, flat, _globalTypeFlags)
        end
    end)
end

-- Per-container preview refresh used by the options panel's container
-- pages for threshold/color slider + picker edits. Repaints
-- ONLY the custom container icons on each visible preview frame, not the
-- full dummy aura set. Mirrors the RefreshPreviewDummyBuffs pattern: a
-- cheap per-type helper that avoids the monolithic ApplyPreviewDummyAuras
-- -> BF:ShowDummyAuras rebuild (which re-renders all seven aura types +
-- owns the 30s restart timer) that BF:RefreshAllCustomContainers was
-- triggering on every coalesced slider write.
--
-- Cheap because BF:ShowDummyContainerAuras only builds fake aura lists
-- for the container currently being previewed and feeds them to
-- UpdateCustomBuffContainers; all the other aura types on the preview
-- frame keep their existing icons and skip repaint entirely. When
-- EnsureContainerSettings rebuilds its ctx (we wiped its cache in
-- DebouncedCCRefresh), the new threshold/color values flow through on
-- the next display pass.
function BF:RefreshPreviewDummyContainers()
    -- Called from DebouncedCCRefresh in the Container Management tab when
    -- a slider/color setter fires. Fallback ON: the user is on a specific
    -- container's settings, and the refresh should re-render whatever the
    -- container preview was already showing (which uses the fallback spec
    -- when the current spec has no assignments).
    _ForEachShownPreviewFrameAuraCtx(function(frame, isRaid, flat)
        if isRaid then
            BF:ShowDummyContainerAuras(frame, true, flat, nil, true)
        else
            BF:ShowDummyContainerAuras(frame, false, nil, flat, true)
        end
    end)
end
-- Perf plan §L5.1 load-time mark: closes the preview engine parse.
if BuzzardFrames then BuzzardFrames:LoadMark("chunk:postPreview") end
