-- ============================================================
-- BuzzardFrames: PixelPerfect.lua
--
-- Pixel-perfect rendering utilities.
--
-- This file contains ONLY:
--   1. Pixel math (Scale, PixelRound, PixelSnap, PixelsToUI, SnapAnchor)
--   2. Backdrop table management (BuildBackdrop)
--   3. Profile cache (RefreshProfileCache, GetActiveProfile)
--   4. Border/edge helpers (SetBorderColor, MakeEdge, DisablePixelSnapRegion)
--   5. ResolveFontPath + LSM font picker helpers (LSMFontValues,
--      NormalizeFontName, ResolveFontPathOr)
--   7. The region creation funnel (BF.Texture, BF.MaskTexture,
--      BF.StatusBar, BF.WatchBar, BF.UnsnapTree) -- EVERY region this
--      addon creates goes through it, so pixel snapping is disabled in
--      exactly one place and no widget outside Buzzard Frames is touched
--
-- Widget geometry is handled by Indicators/*.lua.
-- LayoutFrame.lua retains shared helpers, caches, and RefreshAll*.
-- ============================================================

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local floor = math.floor
local max   = math.max
local pairs = pairs
local type  = type
local CreateFrame = CreateFrame
local GetPhysicalScreenSize = GetPhysicalScreenSize
local UIParent = UIParent
local InCombatLockdown = InCombatLockdown
local hooksecurefunc = hooksecurefunc

-- ============================================================
-- 1. PIXEL MATH
-- ============================================================

local pixelSize, pixelMult = 1, 1
local pixelInitialized = false

local lastUIScale = nil

local function RefreshPixelSize()
    local _, physH = GetPhysicalScreenSize()
    pixelSize = 768 / physH
    local uiScale = UIParent:GetEffectiveScale()
    local prevMult, wasInit = pixelMult, pixelInitialized
    pixelMult = (uiScale > 0) and (pixelSize / uiScale) or 1
    lastUIScale = uiScale
    pixelInitialized = true
    -- 2026-09-11 (in-key field run): the aura caches pre-round every icon
    -- size (_roundedBuffSize & co.) with the pixelMult of the moment they are
    -- built, and the first builds happen while UIParent still carries its
    -- pre-cvar effective scale. Once the scale settles, everything created
    -- from those caches is born a fraction off the real grid, and the first
    -- Layout -- which reads a cache rebuilt later -- restyles every container
    -- on every frame. Inside a keystone a restyle is a full rebuild, so that
    -- cost ~8 rebuilt objects per frame on load. Re-round the caches HERE, the
    -- moment the grid moves, so whatever creates next reads settled sizes.
    -- The state above is committed first, so the rebuild's own PixelRound
    -- calls see a fresh grid and never re-enter this branch.
    if wasInit and prevMult ~= pixelMult and BF.OnPixelGridChanged then
        BF:OnPixelGridChanged()
    end
end

-- v93: cheap staleness check for the hot path. PixelRound runs 500-1000 times
-- per full raid layout pass (and again on every aura-size slider tick), so it
-- must not pay for GetPhysicalScreenSize on each call. UIParent's effective
-- scale is the one input that changes without an addon-side event hookup
-- (there is no DISPLAY_SIZE_CHANGED / UI_SCALE_CHANGED registration anywhere
-- in the addon), and a resolution change always moves it, so comparing it
-- costs exactly the one API call the pre-v93 PixelRound already made while
-- keeping the same self-correcting behavior.
local function EnsurePixelSize()
    if not pixelInitialized or UIParent:GetEffectiveScale() ~= lastUIScale then
        RefreshPixelSize()
    end
end

-- Truncate x to the nearest pixel boundary toward zero.
-- Never rounds UP — prevents 1px borders from rendering as 2px.
local function Scale(x)
    if pixelMult == 1 or x == 0 then return x end
    local abs_x = x < 0 and -x or x
    local snapped = abs_x - (abs_x % pixelMult)
    return x < 0 and -snapped or snapped
end

-- Convert a screen-pixel count to UI coordinates.
-- borderThickness=1 in profile means "1 physical pixel" = 1 * pixelMult UI units.
local function PixelsToUI(n)
    return n * pixelMult
end

-- Expose on BF for other files
function BF:Scale(x) return Scale(x) end
function BF:PixelSnap(v) return Scale(v) end

function BF:PixelsToUI(n)
    if not pixelInitialized then RefreshPixelSize() end
    return n * pixelMult
end

-- ── Frame-space <-> UIParent-space coordinates ─────────────────
--
-- A SCALED frame answers GetLeft()/GetTop()/GetWidth() in its OWN units,
-- not in screen units: a header at SetScale(0.8) sitting 500 UIParent units
-- from the left edge reports 625. So a number is only meaningful together
-- with the frame it came from, and mixing two frames' numbers in one
-- min/max -- or handing a stored UIParent coordinate straight to a scaled
-- frame's SetPoint -- is off by the scale ratio.
--
-- Both directions live here, named, because the conversion was five
-- hand-rolled expressions across three files and the one place that forgot
-- it (UpdateSize's header walk) is exactly the bug this pair exists to stop
-- recurring.
--
--   ToUIUnits    a coordinate READ from `frame`, expressed in UIParent units
--   FromUIUnits  a UIParent-unit coordinate, expressed in `frame`'s units,
--                ready for frame:SetPoint
--
-- A missing frame or a zero scale returns the value untouched: a caller
-- mid-teardown gets its own number back rather than a nan.
local function EffScale(frame)
    local s = frame and frame.GetEffectiveScale and frame:GetEffectiveScale()
    return (s and s > 0) and s or nil
end

function BF:ToUIUnits(v, frame)
    if v == nil then return v end
    local fs, us = EffScale(frame), EffScale(UIParent)
    if not (fs and us) then return v end
    return v * fs / us
end

function BF:FromUIUnits(v, frame)
    if v == nil then return v end
    local fs, us = EffScale(frame), EffScale(UIParent)
    if not (fs and us) then return v end
    return v * us / fs
end

-- v93: snap to the TRUE device-pixel grid (pixelMult), not to
-- 1/UIParent:GetEffectiveScale().
--
-- The old grid was the legacy 768-line coordinate space. On a 2160px-tall
-- display at UI scale 0.67 that grid step is 1/0.67 = 1.4925 UI units, while
-- one real screen pixel is pixelSize/uiScale = 0.5307 UI units -- a grid
-- 2.8x coarser than a pixel. Rounding frame dimensions onto it collapsed
-- roughly one slider notch in three (owner-reported: Frame Width 107 and 108
-- both rendered identically, as did 110 and 111), because those widths
-- differed by less than one grid step even though they differed by ~1.9
-- actual pixels.
--
-- pixelMult is the same unit Scale / PixelSnap / PixelsToUI (and therefore
-- the border code) have always used, so this brings PixelRound in line with
-- the rest of the pixel math. The grid only ever gets FINER, so no existing
-- geometry becomes coarser -- values either stay put or land closer to a
-- real pixel edge. Rounds to nearest (unlike Scale, which truncates toward
-- zero to keep 1px borders from rendering as 2px).
-- 2026-09-11 (diag): the current grid as one string -- "mult@physH/uiScale".
-- Stamped on aura containers at creation and printed by the in-key size
-- rebuild reason, so a creation-vs-Layout size disagreement names the input
-- that moved. Reads the cached values after the same staleness check
-- PixelRound makes; no extra API calls when nothing changed.
function BF:PixelGridTag()
    EnsurePixelSize()
    return string.format("%.4f@%d/%.3f", pixelMult,
        floor(768 / pixelSize + 0.5), lastUIScale or 0)
end

function BF:PixelRound(x)
    EnsurePixelSize()
    if pixelMult <= 0 then return x end
    return floor(x / pixelMult + 0.5) * pixelMult
end

-- ── SnapScaleForSize ────────────────────────────────────────────
-- v93: single implementation of the "snap a requested frame scale so the
-- scaled dimensions land on whole screen pixels" math. Previously this
-- five-line block was copy-pasted in nine places (ComputeHeaderScale,
-- SetupMode's SnapHeaderScale, and seven custom-frame-group / pet header
-- sites), which is how the grid change reached only two of them.
--
-- Two invariants this must preserve, both of which the old copies broke:
--   * The dimensions are rounded HERE, on the same grid the caller's frames
--     are sized to. Snapping raw dimensions and then applying the result on
--     top of already-rounded ones applies the correction twice, which makes
--     on-screen width non-monotonic in the slider (a smaller Frame Width
--     could render WIDER -- owner-reported at 108 -> 107).
--   * The grid is the DEVICE-pixel grid (pixelMult), not 1/effectiveScale.
-- Consequence at requestedScale == 1: w/px is a whole number by
-- construction, so this returns exactly 1.0 and the frame is left at
-- PixelRound(w). Idempotent -- safe to pass already-rounded dimensions.
function BF:SnapScaleForSize(requestedScale, w, h)
    EnsurePixelSize()
    w = self:PixelRound(w)
    h = self:PixelRound(h)
    if pixelMult <= 0 or w <= 0 or h <= 0 then return requestedScale end
    local sW = (floor(w * requestedScale / pixelMult + 0.5) * pixelMult) / w
    local sH = (floor(h * requestedScale / pixelMult + 0.5) * pixelMult) / h
    local errW = sW - requestedScale; if errW < 0 then errW = -errW end
    local errH = sH - requestedScale; if errH < 0 then errH = -errH end
    return (errW <= errH) and sW or sH
end

-- v93: moved onto the device-pixel grid so an anchor's POSITION snaps on the
-- same lattice as the frames' SIZE (PixelRound). While this used
-- 1/effectiveScale and PixelRound used pixelMult, a raid block's extent
-- landed on real pixel edges while its origin sat on a grid ~2.8x coarser,
-- leaving up to ~1.4 physical px of residual -- enough to make the border
-- read a pixel thicker on one side of the block. The half-unit bias is kept:
-- these offsets are measured from UIParent's CENTER, which itself sits on a
-- half-pixel when the screen has an odd pixel dimension.
function BF:SnapAnchor(v)
    EnsurePixelSize()
    if pixelMult <= 0 then return v end
    return floor((v - 0.5) / pixelMult + 0.5) * pixelMult + 0.5
end

function BF:GetFrameSize()
    if self._contextIsRaid == nil then
        print("|cffff0000[BF] WARNING: GetFrameSize called before ApplyProfile set context|r")
        self:ResolveContext()
    end
    return self:ComputeFrameSize()
end

function BF:PixelInset()
    if not self.db or not self.db.profile then return 0 end
    local prof = self.db.profile
    if prof.enableBorder == false then return 0 end
    local n = prof.borderThickness or 1
    RefreshPixelSize()
    return n * pixelMult
end

function BF:PixelDebug()
    RefreshPixelSize()
    local _, physH = GetPhysicalScreenSize()
    local uiScale = UIParent:GetEffectiveScale()
    local borderN = (self.db.profile.enableBorder ~= false) and (self.db.profile.borderThickness or 1) or 0
    print("|cff00ff00BF PixelPerfect Debug:|r")
    print("  physicalHeight: " .. physH)
    print("  pixelSize (768/physH): " .. string.format("%.6f", pixelSize))
    print("  UIParent:GetEffectiveScale(): " .. string.format("%.6f", uiScale))
    print("  pixelMult (pixelSize/uiScale): " .. string.format("%.6f", pixelMult))
    print("  borderThickness (profile): " .. borderN)
    print("  PixelsToUI(1) = 1px: " .. string.format("%.6f", borderN * pixelMult))
    print("  PixelsToUI(2) = 2px: " .. string.format("%.6f", 2 * pixelMult))
    print("  Scale(1) [snap UI val]: " .. string.format("%.6f", Scale(1)))
    print("  Scale(2) [snap UI val]: " .. string.format("%.6f", Scale(2)))
    print("  pixelMult (1 screen pixel in UI units): " .. string.format("%.6f", pixelMult))
end

-- ============================================================
-- 2. BACKDROP TABLE
-- ============================================================

local frameBackdrop = nil
local cachedBorderN = -1

local function BuildBackdrop(borderN)
    if borderN == cachedBorderN then return end
    cachedBorderN = borderN
    if borderN > 0 then
        local edge = PixelsToUI(borderN)
        frameBackdrop = {
            bgFile   = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            edgeSize = edge,
            insets   = { left = edge, right = edge, top = edge, bottom = edge },
        }
    else
        frameBackdrop = nil
    end
end

-- Expose for InitFrame.lua and LayoutFrame.lua
function BF:GetFrameBackdrop()
    return frameBackdrop
end

function BF:RebuildBackdrop()
    RefreshPixelSize()
    local p = self.db and self.db.profile
    local thickness = (p and p.enableBorder ~= false) and (p and p.borderThickness or 1) or 0
    cachedBorderN = -1
    BuildBackdrop(thickness)
    return frameBackdrop
end

function BF:GetPixelMult()
    return pixelMult
end

-- The raw 768/physicalHeight factor, WITHOUT the UIParent scale divide that
-- GetPixelMult applies. Callers that snap against some other frame's
-- effective scale need this one -- e.g. IncomingCasts' rounded border kit,
-- which is scaled against the unit frame it was reparented onto, not
-- against UIParent. Reads the same cache RefreshPixelSize maintains, so it
-- stays correct across resolution and UI-scale changes; the ten call sites
-- that inline `768 / select(2, GetPhysicalScreenSize())` re-read the C API
-- every time instead.
function BF:GetPixelSize()
    if not pixelInitialized then RefreshPixelSize() end
    return pixelSize
end

function BF:RefreshPixelSize()
    RefreshPixelSize()
end

-- ============================================================
-- 3. PROFILE CACHE
-- ============================================================

local p = {}

function BF:RefreshProfileCache()
    p = self.db.profile
    if self.UpdateAuraSizeCache then self:UpdateAuraSizeCache() end
    -- §L5.1 [REV3]: this bolt-on UpdateAuraSizeCache fires three times on the
    -- login path (OnEnable, ApplyProfile, LoadLayout). One mark, three
    -- entries in /bf loadreport -- this is what sizes Stage 0e.
    self:LoadMarkD("uasc:refreshProfileCache")
    RefreshPixelSize()
    -- Wipe the aura icon backdrop cache so icons get fresh pixel-perfect
    -- backdrop tables when UI scale changes.
    if self.WipeAuraBackdropCache then self:WipeAuraBackdropCache() end
    local thickness = (p.enableBorder ~= false) and (p.borderThickness or 1) or 0
    cachedBorderN = -1
    BuildBackdrop(thickness)
end

-- Returns the cached profile table for file-local use by other files.
-- Other files call this once at load time to get p, or hook RefreshProfileCache.
function BF:GetCachedProfile()
    return p
end

-- Active profile cache (party vs raid context resolution)
local activeProfile = nil
local isRaidContext = false

function BF:InvalidateActiveProfileCache()
    activeProfile = nil
end

function BF:WipeLayoutSizeCache()
    -- Every registered frame: the size cache is stamped at build time on
    -- spares too.
    for _, frame in next, self.registeredFrames or {} do
        frame._layoutW = nil
        frame._layoutH = nil
    end
end

function BF:GetActiveProfile()
    if activeProfile then return activeProfile, isRaidContext end
    if self._contextIsRaid == nil then
        print("|cffff0000[BF] WARNING: GetActiveProfile called before context set|r")
        self:ResolveContext()
    end
    local rp = self:GetRaidProfile()
    if self._contextIsParty then
        activeProfile = self:GetActivePartyProfile()
        isRaidContext = false
    else
        activeProfile = rp
        isRaidContext = true
    end
    return activeProfile, isRaidContext
end

-- ============================================================
-- 4. BORDER / EDGE HELPERS
-- ============================================================

function BF:SetBorderColor(borderFrame, r, g, b, a)
    if not borderFrame then return end
    a = a or 1
    if borderFrame.top    then borderFrame.top:SetColorTexture(r, g, b, a)    end
    if borderFrame.bottom then borderFrame.bottom:SetColorTexture(r, g, b, a) end
    if borderFrame.left   then borderFrame.left:SetColorTexture(r, g, b, a)   end
    if borderFrame.right  then borderFrame.right:SetColorTexture(r, g, b, a)  end
end

-- Ensure `borderFrame` carries a nine-slice ring texture for the rounded
-- border styles (target / aggro-border / dispel highlights). Created
-- lazily the first time a rounded style is applied; anchored to the
-- highlight frame so it layers exactly where the 4 square edges do.
-- Idempotent — returns the ring.
function BF:EnsureHighlightRing(borderFrame)
    local ring = borderFrame.roundRing
    if not ring then
        -- v58 pixel host: the ring lives on a child frame whose scale is
        -- stamped (in SetHighlightBorder) so 1 art texel = 1 physical
        -- pixel — highlight ring widths render as exact pixel counts,
        -- matching the square edges' PixelsToUI guarantee.
        local host = CreateFrame("Frame", nil, borderFrame)
        host:SetAllPoints(borderFrame)
        host:SetFrameLevel(borderFrame:GetFrameLevel())
        borderFrame.roundRingHost = host
        ring = BF.Texture(host, nil, "OVERLAY")
        ring:SetTextureSliceMargins(BF.RoundedBorderSlice, BF.RoundedBorderSlice,
            BF.RoundedBorderSlice, BF.RoundedBorderSlice)
        ring:SetAllPoints(borderFrame)
        ring:Hide()
        borderFrame.roundRing = ring
    end
    return ring
end

-- Stamp the pixel-host scale + snap for a highlight ring. Shared by
-- SetHighlightBorder and the slot-button ring sites (dispel border /
-- frame-effects border). Change-guarded on both the scale and the
-- texture path, so steady-state repeat calls cost two compares.
-- `scaleFrame` provides the effective scale (the unit frame / the
-- highlight frame — anything in the frame's unscaled child chain).
function BF:StampRingPixelHost(host, ring, scaleFrame, texPath)
    if host and scaleFrame then
        local eff = scaleFrame:GetEffectiveScale()
        if not pixelInitialized then RefreshPixelSize() end
        local k = (eff > 0) and (pixelSize / eff) or 1
        if host._bf_k ~= k then
            host:SetScale(k)
            host._bf_k = k
        end
    end
    if ring and texPath and ring._bf_lastTex ~= texPath then
        ring:SetTexture(texPath)
        -- The creation funnel (BF.Texture, section 7) unsnapped this
        -- ring; re-snap so its texel edges land on whole pixels.
        ring:SetSnapToPixelGrid(true)
        ring:SetTexelSnappingBias(0)
        ring._bf_lastTex = texPath
    end
end

-- ============================================================
-- SPELL-ICON BORDER KIT
--
-- Shared by both cast bars (Indicators/CastBar.lua and the Incoming
-- Casts module) so the border style and color chosen for the BAR also
-- apply to the spell icon beside it.
--
-- Mirrors BF:_ApplyOUFCastbarIconBorder (UnitFrames/oUF_Castbar.lua),
-- which does the same job for the unit frame cast bar's icon, and uses
-- the same art as the aura icons -- a stretched (not nine-sliced)
-- IconMask to clip the icon and an IconBorder ring just outside it.
--
-- VOCABULARY: callers pass the FRAME/BAR style ("square" | "rounded" |
-- "rounded_thick"). The aura family's "flat" is the same thing as
-- "square" here; the mapping is done inside so callers never have to
-- know both enums exist.
--
-- The outer offset IS the visible side thickness for the rounded art
-- (aura v59 rethin): 0.5 for Rounded, 1.0 for Rounded Thick. Rounded
-- band weight is baked into the texture, so borderThickness applies to
-- the square style only.
--
-- GEOMETRY NOTE: the square edges are drawn INSIDE the icon frame's
-- rect, not 1px outside it as the old Incoming Casts icon border was.
-- Two reasons: it matches _ApplyOUFCastbarIconBorder, and both cast bars
-- reserve exactly the icon's width when insetting the bar -- an outside
-- border would make the icon overhang that reserve by its thickness and
-- push past the frame edge.
-- ============================================================
local ICON_RING_TEX       = "Interface\\AddOns\\BuzzardFrames\\Media\\IconBorder"
local ICON_RING_THICK_TEX = "Interface\\AddOns\\BuzzardFrames\\Media\\IconBorderThick"
local ICON_MASK_TEX       = "Interface\\AddOns\\BuzzardFrames\\Media\\IconMask"

-- The ROUNDED half of the kit: mask + ring. Split out and created lazily
-- because the mask requires SetBlockingLoadsRequested(true) -- a
-- SYNCHRONOUS texture load. Creating it eagerly for every frame meant a
-- multi-second client stall whenever a settings change re-laid-out 40
-- raid frames at once, and for nothing: the default border style is
-- square, which never touches the mask or the ring.
local function EnsureIconRoundParts(iconFrame, iconTex, kit)
    if kit.mask then return end

    -- BLOCKING LOAD is mandatory: the mask is shown live on a style
    -- switch, and an async CLAMPTOBLACKADDITIVE mask reads BLACK (i.e.
    -- erases the icon) until it finishes loading.
    local mask = BF.MaskTexture(iconFrame)
    if mask.SetBlockingLoadsRequested then mask:SetBlockingLoadsRequested(true) end
    mask:SetTexture(ICON_MASK_TEX, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(iconFrame)
    mask:Hide()
    iconTex:AddMaskTexture(mask)
    kit.mask = mask

    local ring = BF.Texture(iconFrame, nil, "OVERLAY", nil, 3)
    ring:Hide()
    kit.ring = ring
end

-- Build the cheap half of the kit (four edge textures) and cache it on
-- the icon frame. `iconTex` is the spell icon texture the mask clips.
function BF:EnsureIconBorderKit(iconFrame, iconTex)
    if not iconFrame or not iconTex then return nil end
    local kit = iconFrame._bfIconBorder
    if kit then return kit end

    local edges = {}
    local function mk()
        local t = BF.Texture(iconFrame, nil, "OVERLAY", nil, 2)
        t:SetColorTexture(0, 0, 0, 1)
        t:Hide()
        return t
    end
    edges.top    = mk(); edges.top:SetPoint("TOPLEFT", iconFrame, "TOPLEFT");        edges.top:SetPoint("TOPRIGHT", iconFrame, "TOPRIGHT")
    edges.bottom = mk(); edges.bottom:SetPoint("BOTTOMLEFT", iconFrame, "BOTTOMLEFT"); edges.bottom:SetPoint("BOTTOMRIGHT", iconFrame, "BOTTOMRIGHT")
    edges.left   = mk(); edges.left:SetPoint("TOPLEFT", iconFrame, "TOPLEFT");        edges.left:SetPoint("BOTTOMLEFT", iconFrame, "BOTTOMLEFT")
    edges.right  = mk(); edges.right:SetPoint("TOPRIGHT", iconFrame, "TOPRIGHT");     edges.right:SetPoint("BOTTOMRIGHT", iconFrame, "BOTTOMRIGHT")

    -- mask + ring are NOT created here -- see EnsureIconRoundParts.
    kit = { edges = edges }
    iconFrame._bfIconBorder = kit
    return kit
end

-- Apply a border style/color to a spell icon.
--   style     -- "square" | "rounded" | "rounded_thick"
--   color     -- { r, g, b, a }
--   thickness -- pixels, square style only
--   show      -- false parks the whole kit (border turned off)
function BF:ApplyIconBorder(iconFrame, iconTex, style, color, thickness, show)
    local kit = self:EnsureIconBorderKit(iconFrame, iconTex)
    if not kit then return end
    local e = kit.edges
    local c = color or { r = 0, g = 0, b = 0, a = 1 }
    local r, g, b, a = c.r or 0, c.g or 0, c.b or 0, (c.a ~= nil) and c.a or 1

    if show == false then
        e.top:Hide(); e.bottom:Hide(); e.left:Hide(); e.right:Hide()
        -- mask/ring may never have been created (square style only).
        if kit.ring then kit.ring:Hide() end
        if kit.mask then kit.mask:Hide() end
        return
    end

    if BF.IsRoundedBorderStyle and BF.IsRoundedBorderStyle(style) then
        e.top:Hide(); e.bottom:Hide(); e.left:Hide(); e.right:Hide()
        -- First rounded use on this icon: build the mask + ring now.
        EnsureIconRoundParts(iconFrame, iconTex, kit)
        local thick = (style == "rounded_thick")
        local path  = thick and ICON_RING_THICK_TEX or ICON_RING_TEX
        if kit.ring._bf_lastTex ~= path then
            kit.ring:SetTexture(path)
            kit.ring._bf_lastTex = path
        end
        local o = thick and 1 or 0.5
        kit.ring:ClearAllPoints()
        kit.ring:SetPoint("TOPLEFT", iconFrame, "TOPLEFT", -o, o)
        kit.ring:SetPoint("BOTTOMRIGHT", iconFrame, "BOTTOMRIGHT", o, -o)
        kit.ring:SetVertexColor(r, g, b, a)
        kit.ring:Show()
        kit.mask:Show()
    else
        -- Square style: mask/ring may not exist at all, and if the icon has
        -- never been rounded they never will.
        if kit.ring then kit.ring:Hide() end
        -- Hidden mask = clipping off; the AddMaskTexture attachment stays
        -- for the next switch back, same as the frame and bar rings.
        if kit.mask then kit.mask:Hide() end
        local n = thickness or 1
        if n <= 0 then
            e.top:Hide(); e.bottom:Hide(); e.left:Hide(); e.right:Hide()
            return
        end
        local px = self:PixelsToUI(n)
        e.top:SetHeight(px); e.bottom:SetHeight(px)
        e.left:SetWidth(px); e.right:SetWidth(px)
        e.top:SetColorTexture(r, g, b, a)
        e.bottom:SetColorTexture(r, g, b, a)
        e.left:SetColorTexture(r, g, b, a)
        e.right:SetColorTexture(r, g, b, a)
        e.top:Show(); e.bottom:Show(); e.left:Show(); e.right:Show()
    end
end

-- Rounded-aware companion to SetBorderColor. When the unit frame's
-- border style is a rounded one, tints a nine-slice ring and hides the 4
-- square edges; otherwise restores the square edges and colors them
-- exactly as SetBorderColor did. `parent` is the unit frame (border-
-- style lookup + ring anchor). `width` is the highlight's own pixel
-- width (its slider) — the ring art is chosen to match it, concentric
-- with the base border, growing inward like the square edges. nil width
-- falls back to a medium ring. Runtime-safe: texture/color/Show-Hide
-- only — same call class as the square-edge path.
function BF:SetHighlightBorder(borderFrame, parent, r, g, b, a, width)
    if not borderFrame then return end
    a = a or 1
    local bp = BF:GetSectionProfileForFrame("borders", parent)
    local style = bp and bp.borderStyle or "square"
    -- Gate on the rounded frame border actually being DRAWN: a rounded
    -- borderStyle with Enable Border OFF renders nothing rounded, so
    -- the highlight reverts to its square edges (the isRoundedActive
    -- rule — Container.lua:298 `enableBorder and IsRoundedStyle`;
    -- owner report: highlight stayed rounded after disabling the
    -- border in Global Styles). AggroHighlight's blizzard/glow
    -- coercion already applies this same gate.
    local roundedActive = BF.IsRoundedBorderStyle(style)
        and not (bp and bp.enableBorder == false)
    if roundedActive then
        local ring = BF:EnsureHighlightRing(borderFrame)
        if borderFrame.top    then borderFrame.top:Hide()    end
        if borderFrame.bottom then borderFrame.bottom:Hide() end
        if borderFrame.left   then borderFrame.left:Hide()   end
        if borderFrame.right  then borderFrame.right:Hide()  end
        -- v58: pixel-host scale + snapped texture (change-guarded — the
        -- SetTexture is also skipped when the width didn't change, which
        -- the old unconditional SetTexture wasn't).
        BF:StampRingPixelHost(borderFrame.roundRingHost, ring,
            borderFrame, BF:GetHighlightRing(width))
        ring:SetVertexColor(r, g, b, a)
        -- SECRET-SAFE: `a` can be a secret number in combat (the legacy
        -- dispel path feeds status-color alpha straight through — 1565x
        -- assert spam field report), so it must never be compared. Alpha
        -- is the visibility channel (v63/v65 doctrine): keep the ring
        -- shown and let a==0 render nothing — clear calls pass literal 0.
        -- SetVertexColor is a property setter and accepts secrets.
        ring:Show()
    else
        if borderFrame.roundRing then borderFrame.roundRing:Hide() end
        -- Restore edges (a previous rounded state hid them) and color.
        if borderFrame.top    then borderFrame.top:Show()    end
        if borderFrame.bottom then borderFrame.bottom:Show() end
        if borderFrame.left   then borderFrame.left:Show()   end
        if borderFrame.right  then borderFrame.right:Show()  end
        BF:SetBorderColor(borderFrame, r, g, b, a)
    end
end

function BF:MakeEdge(parent)
    local t = BF.Texture(parent, nil, "OVERLAY")
    t:SetColorTexture(0, 0, 0, 1)
    return t
end

function BF:DisablePixelSnapRegion(region)
    if not region then return end
    if region.SetSnapToPixelGrid then
        region:SetSnapToPixelGrid(false)
        region:SetTexelSnappingBias(0)
    end
end

-- ============================================================
-- 5. FONT PATH RESOLVER
-- ============================================================

function BF:ResolveFontPath(value)
    if not value or value == "" or value == "DEFAULT" then
        value = "PT Sans Narrow"
    end
    if not value:find("[\\/]") then
        local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
        local path = LSM and LSM:Fetch("font", value)
        if path then return path end
        return "Interface\\AddOns\\BuzzardFrames\\Media\\Fonts\\PTSansNarrow.ttf"
    end
    return value
end

-- ============================================================
-- 5b. LSM FONT PICKER HELPERS (single source of truth)
-- ============================================================
-- Every font dropdown in the addon feeds AceGUI's LSM30_Font widget,
-- which resolves the preview font for a row like this:
--
--     local font = list[key] ~= key and list[key] or LSM:Fetch("font", key)
--
-- so the `values` table MUST be name -> path, i.e. LibSharedMedia's own
-- HashTable shape. Both of the shapes that were in use before this
-- helper render wrong:
--
--   * name -> name  sends the widget down the Fetch branch, so a row
--     only previews once the client has loaded that font (this is what
--     the OpenOptions font primer was working around).
--   * path -> name  makes list[key] ~= key true, so the widget hands
--     the DISPLAY NAME to SetFont as if it were a file path; the call
--     fails and the row keeps the inherited UI font -- i.e. every row
--     renders identically.
--
-- Buzzard Auras has always passed the HashTable shape, which is why its
-- pickers preview correctly. Route every picker through this builder so
-- the shape cannot drift per-file again.
function BF:LSMFontValues()
    local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
    if not LSM then
        return { ["PT Sans Narrow"] = "Interface\\AddOns\\BuzzardFrames\\Media\\Fonts\\PTSansNarrow.ttf" }
    end
    return LSM:HashTable("font")
end

-- Stored font values are LSM display names. Profiles written before the
-- unification (and everything the aura-text / aura-customization
-- pickers ever wrote) hold a raw file path or the "DEFAULT" sentinel
-- instead. AceConfigDialog drops any value that is not a KEY of the
-- values table (`if not values[value] then value = nil end`) and
-- LSM30_Font renders a nil value as an empty box -- that is the blank
-- picker. Every font get() routes through here so legacy values map
-- back onto a real key with no SavedVariables migration.
function BF:NormalizeFontName(value, fallback)
    fallback = fallback or "PT Sans Narrow"
    local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
    if type(value) ~= "string" or value == "" or value == "DEFAULT" then
        return fallback
    end
    if not value:find("[\\/]") then
        -- Already a name. Only hand it back if LSM still knows it: an
        -- unregistered name blanks the picker exactly like a path does.
        if not LSM or LSM:IsValid("font", value) then return value end
        return fallback
    end
    -- Raw path: reverse-map onto the LSM name that owns it.
    if LSM then
        local lower = value:lower()
        for name, path in pairs(LSM:HashTable("font")) do
            if type(path) == "string" and path:lower() == lower then return name end
        end
    end
    return fallback
end

-- Runtime counterpart of NormalizeFontName, for the aura and cast paths
-- that stamp a path straight into SetFont and carry their own bundled
-- default rather than PT Sans Narrow. Accepts an LSM name, a legacy
-- path, nil or "DEFAULT" and always returns a usable path.
function BF:ResolveFontPathOr(value, fallbackPath)
    if type(value) ~= "string" or value == "" or value == "DEFAULT" then
        return fallbackPath
    end
    if value:find("[\\/]") then return value end
    local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
    local path = LSM and LSM:Fetch("font", value)
    return path or fallbackPath
end

-- Resolve a statusbar texture name to a texture path via LibSharedMedia.
-- If the value is already a path (contains \ or /), return it as-is.
-- Grid2 equivalent: Grid2:MediaFetch("statusbar", name, "Gradient")
function BF:ResolveBarTexture(value)
    if not value or value == "" then
        return "Interface\\Buttons\\WHITE8X8"
    end
    if not value:find("[\\/]") then
        local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
        -- noDefault=true: without it Fetch NEVER returns nil for a
        -- missing name — it returns LSM's default statusbar ("Blizzard",
        -- Interface\TargetingFrame\UI-StatusBar), so the solid fallback
        -- below was dead code and missing textures rendered ugly.
        -- WHITE8X8 is the same file as LSM's "Solid".
        local path = LSM and LSM:Fetch("statusbar", value, true)
        if path then return path end
        return "Interface\\Buttons\\WHITE8X8"
    end
    return value
end

-- ============================================================
-- 6. SAFE SetFont HOOK
--
-- Guards every FontString:SetFont() call against invalid font
-- file paths ("asset not found"). If SetFont fails, falls back
-- to the bundled PT Sans Narrow and retries. This prevents a
-- missing font addon (e.g. SharedMedia_MyFonts was removed) from
-- producing hundreds of errors and locking the user out of the
-- options panel.
-- ============================================================
-- SetFont safety is handled per-call-site via ResolveFontPath() and
-- nil guards.  No global metatable hook — BuzzardFrames does not
-- intercept other addons' font calls.

-- ============================================================
-- 7. REGION CREATION FUNNEL
--
-- WoW's pixel-grid snapping rounds a region's edges to whole physical
-- pixels, which makes fractional bar fills and icon borders jump by a
-- pixel as they animate. Every Buzzard Frames region therefore wants
-- SetSnapToPixelGrid(false) + SetTexelSnappingBias(0) once. The flag is
-- persistent per region, so a single call at creation lasts for the
-- region's life -- no hook is needed to keep it applied.
--
-- This was previously done with hooksecurefunc on the SHARED widget
-- metatables, which fired for every texture call in the entire UI and
-- tainted Blizzard's own regions by writing to them; see
-- _to_delete/PixelPerfect_globalhooks_2026-09-08/README.md for the
-- blocked-SetAttribute report that produced. The helpers below replace
-- that wholesale: they touch only regions this addon creates, so nothing
-- outside Buzzard Frames is ever written to or called.
--
-- USE THESE INSTEAD OF THE RAW WIDGET CALLS:
--   BF.Texture(parent, ...)           not parent:CreateTexture(...)
--   BF.MaskTexture(parent, ...)       not parent:CreateMaskTexture(...)
--   BF.StatusBar(name, parent, tmpl)  not CreateFrame("StatusBar", ...)
--
-- A StatusBar's FILL texture does not exist at creation and is replaced
-- on every texture change, so BF.StatusBar cannot unsnap it once and be
-- done. BF.WatchBar installs a hook on that ONE BAR INSTANCE -- our own
-- frame, never a shared metatable -- which unsnaps the fill after every
-- SetStatusBarTexture, including the runtime texture swaps driven by the
-- options panel.
-- ============================================================

-- Unsnap a StatusBar's fill texture now and after every future
-- SetStatusBarTexture. Idempotent: the guard flag lives on our own bar.
function BF.WatchBar(bar)
    if not bar or not bar.GetStatusBarTexture then return end
    if bar._bfBarWatched then return end
    bar._bfBarWatched = true
    BF:DisablePixelSnapRegion(bar:GetStatusBarTexture())
    hooksecurefunc(bar, "SetStatusBarTexture", function(self)
        BF:DisablePixelSnapRegion(self:GetStatusBarTexture())
    end)
end

-- parent:CreateTexture(...) + unsnap. Takes the parent as the first
-- argument so a call site is a straight substitution:
--   local bg = frame:CreateTexture(nil, "BACKGROUND")
--   local bg = BF.Texture(frame, nil, "BACKGROUND")
function BF.Texture(parent, ...)
    if not parent then return nil end
    local tex = parent:CreateTexture(...)
    BF:DisablePixelSnapRegion(tex)
    return tex
end

-- parent:CreateMaskTexture(...) + unsnap. Same substitution shape.
function BF.MaskTexture(parent, ...)
    if not parent then return nil end
    local tex = parent:CreateMaskTexture(...)
    BF:DisablePixelSnapRegion(tex)
    return tex
end

-- CreateFrame("StatusBar", name, parent, template) + WatchBar.
function BF.StatusBar(name, parent, template)
    local bar = CreateFrame("StatusBar", name, parent, template)
    BF.WatchBar(bar)
    return bar
end

-- One-shot sweep over a frame this addon spawned, for the regions and
-- bars the vendored oUF library creates internally (which cannot go
-- through the funnel because Libs/oUF stays a pristine upstream copy).
-- Depth-capped as a cheap guard against deep nesting.
--
-- The tree is NOT entirely ours. The 12.1 aura containers hanging off
-- the unit frames are engine-owned, and so is every aura button inside
-- them (Blizzard_AuraContainerFrameProviders). While an addon
-- restriction is active -- an active Mythic+ keystone run is one, in or
-- out of combat -- those buttons are forbidden objects and GetRegions()
-- on one THROWS ("Attempt to access forbidden object"). This runs from
-- the oUF style function inside PLAYER_ENTERING_WORLD, before
-- GroupChanged, so the throw took down the whole load: no unit frames,
-- no party frames, until the key ended (field report 2026-09-10).
-- Two guards: a container marked _bf_unsnapStop is never entered (its
-- buttons are unsnapped one by one in FlatInitButton, through the
-- funnel), and the two engine calls are pcall'd so an unforeseen
-- forbidden descendant degrades to "that subtree stays snapped" instead
-- of aborting the spawn.
function BF.UnsnapTree(frame, depth)
    if type(frame) ~= "table" then return end
    if frame._bf_unsnapStop then return end
    depth = depth or 0
    if depth > 6 then return end
    if frame.GetStatusBarTexture then
        BF.WatchBar(frame)
    end
    if frame.GetRegions then
        pcall(function()
            local regions = { frame:GetRegions() }
            for i = 1, #regions do
                BF:DisablePixelSnapRegion(regions[i])
            end
        end)
    end
    if frame.GetChildren then
        local ok, children = pcall(function() return { frame:GetChildren() } end)
        if ok then
            for i = 1, #children do
                BF.UnsnapTree(children[i], depth + 1)
            end
        end
    end
end
