-- BuzzardFrames: oUF_ResourceBar.lua
-- Pip-style resource bar (Holy Power, Combo Points, Soul Shards,
-- Arcane Charges, Chi, Essence, Maelstrom Weapon).
-- Hidden for classes/specs with no pip resource.
--
-- Attached: parented to the oUF player frame, anchored below its
--           power bar. Width tracks the player frame width.
-- Detached: re-parented to UIParent, freely positionable, uses its
--           own saved anchor and an explicit bar width setting.
local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local RESOURCE_COLORS = {
    [4]  = { r=1.00, g=0.96, b=0.41 }, -- Combo Points
    [5]  = { r=0.77, g=0.12, b=0.23 }, -- Runes (Death Knight)
    [7]  = { r=0.80, g=0.10, b=0.10 }, -- Soul Shards
    [9]  = { r=1.00, g=0.61, b=0.04 }, -- Holy Power
    [12] = { r=0.00, g=1.00, b=0.60 }, -- Chi
    [16] = { r=0.58, g=0.51, b=0.79 }, -- Arcane Charges
    [19] = { r=0.00, g=0.80, b=1.00 }, -- Essence
    [26] = { r=0.00, g=0.82, b=1.00 }, -- Maelstrom Weapon
}

-- Theoretical maximum pip count per resource.
local PIP_RESOURCES = {
    [4]  = 5,  -- Combo Points
    [5]  = 6,  -- Runes (Death Knight)
    [7]  = 5,  -- Soul Shards
    [9]  = 5,  -- Holy Power
    [12] = 5,  -- Chi
    [16] = 4,  -- Arcane Charges
    [19] = 6,  -- Essence
    [26] = 10, -- Maelstrom Weapon
}

-- ClassPower uses string power types; map to the numeric IDs used by
-- RESOURCE_COLORS and PIP_RESOURCES.
--
-- RUNES is NOT a ClassPower type — oUF's ClassPower element has no DEATHKNIGHT
-- branch (Libs/oUF/elements/classpower.lua:116-309) because runes are
-- cooldown-based rather than point-based, so oUF ships them as a separate
-- `Runes` element. The entry exists here purely so the rune path can reuse the
-- same geometry/color lookups; nothing in ClassPower ever produces it.
local CLASSPOWER_TYPE_MAP = {
    COMBO_POINTS   = 4,
    RUNES          = 5,
    SOUL_SHARDS    = 7,
    HOLY_POWER     = 9,
    CHI            = 12,
    ARCANE_CHARGES = 16,
    ESSENCE        = 19,
    MAELSTROM      = 26,
}

local RUNE_TYPE  = 5
local RUNE_COUNT = 6

-- ── Fractional pip fill ───────────────────────────────────────────────
-- Two pip resources can sit part-way between whole points:
--
--   ESSENCE      - regenerates on a timer. ClassPower reports it as a whole
--                  number (classpower.lua:162-169 -> GetGenericPower), so the
--                  fraction comes from UnitPartialPower, read live.
--   SOUL_SHARDS  - Destruction only, where a shard is 10 fragments. oUF ALREADY
--                  computes a fractional `cur` for that spec (classpower.lua:289,
--                  UnitPower(..., true) / UnitPowerDisplayMod); the plain
--                  `i <= cur` render simply discarded it.
--
-- When one of these is active the per-pip StatusBars below own the bright fill
-- outright and _fill is demoted to the dim empty backing -- the same division
-- of labour the DK rune pips already use. Every other resource keeps the plain
-- two-state _fill and builds no StatusBars at all.
local ESSENCE_TYPE  = 19
local SHARD_TYPE    = 7
local ESSENCE_POWER = (Enum and Enum.PowerType and Enum.PowerType.Essence) or 19
local ESSENCE_PARTIAL_MAX = 1000
local SPEC_WARLOCK_DESTRUCTION = _G.SPEC_WARLOCK_DESTRUCTION or 3

-- Soul Shards are only fractional for Destruction; Affliction and Demonology
-- spend whole shards and never need the bars.
local function PartialCapable(numericType)
    if numericType == ESSENCE_TYPE then
        return true
    elseif numericType == SHARD_TYPE then
        return C_SpecializationInfo.GetSpecialization() == SPEC_WARLOCK_DESTRUCTION
    end
    return false
end

-- Fill texture for pips and DK rune bars: follows the unit frames'
-- power bar texture setting (same expression as oUF_PowerBar.lua:228).
-- Applied at LAYOUT time only; the update paths (UpdateOUFResourceBar /
-- UpdateOUFRuneBar) touch color exclusively via SetVertexColor —
-- SetColorTexture there would stomp the file texture back to a solid
-- (Grid2 split: texture at layout, color on update).
local function PowerBarFillTexture(p)
    return (p.oufUseCustomPowerBarTexture
        and BF:ResolveBarTexture(p.oufPowerBarTexture))
        or "Interface\\Buttons\\WHITE8X8"
end

-- Rounded pip art (v59): the aura-icon treatment — STRETCHED (unsliced)
-- 256px IconMask clips each pip's fill (and the DK rune fill), and a
-- stretched IconBorder ring is drawn just OUTSIDE the pip (the outer
-- offset IS the visible side thickness — HET pattern; v59 rethin:
-- Rounded offset 0.5, Rounded (Thick) offset 1). Same assets and
-- geometry as Auras/ContainerFactory.lua; stretched art radius scales
-- with pip size, matching the aura icons. Pips are wider than tall, so
-- the stretched radius reads slightly elliptical — dedicated PipMask/
-- PipBorder art is the planned fallback if this reads wrong at ≤12px
-- pips (decide on PTR; see UnitFrames_Rounded_Borders_Plan.md).
-- (Pip/bar ring art: the shared UF bar pair in oUF_Shared.lua is now the
-- frame-weight BarBorder/BarBorderThick set, so no per-call override is
-- needed here anymore; ApplyUFBarRoundBorder still accepts one.)
local ROUND_PIP_RING_TEX       = "Interface\\AddOns\\BuzzardFrames\\Media\\IconBorder"
local ROUND_PIP_RING_THICK_TEX = "Interface\\AddOns\\BuzzardFrames\\Media\\IconBorderThick"
local ROUND_PIP_MASK_TEX       = "Interface\\AddOns\\BuzzardFrames\\Media\\IconMask"

-- Resolved on first use and cached. oUF itself calls UnitClassBase at file load
-- (classpower.lua:50), so load-time would very likely work too; this is just
-- belt-and-braces. The only real caller is BuildOUFResourceBar, which runs from
-- oUF:Factory (PLAYER_LOGIN or later) where the value is certainly valid.
local isDK
local function PlayerIsDK()
    if isDK == nil then
        local class = UnitClassBase("player")
        if not class then return false end  -- too early; don't cache
        isDK = (class == "DEATHKNIGHT")
    end
    return isDK
end

function BF:BuildOUFResourceBar()
    if self.oufResourceBar then return end

    local f = self.oufPlayer or UIParent
    local rb = CreateFrame("Frame", "BuzzardFrames_oUFResourceBar", f)
    rb:SetFrameLevel(f:GetFrameLevel() + 5)
    rb:SetFrameStrata("MEDIUM")
    rb:EnableMouse(false)
    rb:SetMovable(true)
    rb:SetClampedToScreen(true)
    rb:Hide()

    -- Background
    local bg = BF.Texture(rb, nil, "BACKGROUND", nil, -1)
    bg:SetAllPoints(rb)
    bg:SetColorTexture(0.08, 0.08, 0.08, 1)
    rb._bg = bg

    local barBorderFrame = CreateFrame("Frame", nil, rb)
    barBorderFrame:SetAllPoints(rb)
    barBorderFrame:SetFrameLevel(rb:GetFrameLevel() + 3)
    barBorderFrame:EnableMouse(false)
    barBorderFrame:Hide()
    local function MakeBarEdge()
        local t = BF.Texture(barBorderFrame, nil, "OVERLAY", nil, 3)
        t:SetColorTexture(0, 0, 0, 1)
        return t
    end
    barBorderFrame.top    = MakeBarEdge()
    barBorderFrame.bottom = MakeBarEdge()
    barBorderFrame.left   = MakeBarEdge()
    barBorderFrame.right  = MakeBarEdge()
    rb._barBorder = barBorderFrame

    rb._pips = {}
    -- Death Knight only: StatusBars that oUF's Runes element owns and drives.
    -- One per pip, filling that pip exactly, so ALL of the existing pip geometry
    -- (width, gap, the last-pip TOPRIGHT anchor, borders) applies to runes for
    -- free via _OUFResourceBarRebuildGeometry.
    rb._runes = PlayerIsDK() and {} or nil
    local pipBaseLevel = rb:GetFrameLevel() + 1
    for i = 1, 10 do
        local pipFrame = CreateFrame("Frame", nil, rb)
        pipFrame:SetFrameLevel(pipBaseLevel)
        pipFrame:EnableMouse(false)
        pipFrame:Hide()

        local fill = BF.Texture(pipFrame, nil, "ARTWORK", nil, 0)
        fill:SetTexture("Interface\\Buttons\\WHITE8X8")
        fill:SetAllPoints(pipFrame)
        pipFrame._fill = fill

        -- For a DK, _fill stays as the dim "empty" backing and this StatusBar
        -- draws the bright portion on top, growing as the rune recharges. oUF
        -- does the driving (runes.lua:140-149): a ready rune is SetValue(1) with
        -- its OnUpdate detached; a recharging one gets an OnUpdate that ticks the
        -- fill and is removed the moment it completes. We never poll.
        if rb._runes and i <= RUNE_COUNT then
            local sb = BF.StatusBar(nil, pipFrame)
            sb:SetFrameLevel(pipBaseLevel + 1)  -- above _fill, below _border (+2)
            sb:SetAllPoints(pipFrame)
            sb:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
            sb:EnableMouse(false)
            sb:SetMinMaxValues(0, 1)
            sb:SetValue(1)
            rb._runes[i] = sb
        end

        local bf = CreateFrame("Frame", nil, pipFrame)
        bf:SetAllPoints(pipFrame)
        bf:SetFrameLevel(pipBaseLevel + 2)
        bf:EnableMouse(false)
        local function MakePipEdge()
            local t = BF.Texture(bf, nil, "OVERLAY", nil, 2)
            t:SetColorTexture(0, 0, 0, 1)
            return t
        end
        bf.top    = MakePipEdge()
        bf.bottom = MakePipEdge()
        bf.left   = MakePipEdge()
        bf.right  = MakePipEdge()
        pipFrame._border = bf

        -- Rounded pip mask + ring (v59): created for EVERY pip at build
        -- (textures can't be destroyed — ContainerFactory precedent for
        -- always-created rounded widgets) and ATTACHED here at init,
        -- once per region. Hidden mask = masking off (oUF cutout-mask
        -- precedent), so square mode is untouched; a rounded border
        -- mode just Shows them and stamps geometry/tint in
        -- _ApplyOUFResourceBarBorder. BLOCKING LOAD on the mask: it is
        -- shown live on a mode switch, and an async-loading
        -- CLAMPTOBLACKADDITIVE mask reads BLACK (erases the pip fill)
        -- until it finishes.
        local rmask = BF.MaskTexture(pipFrame)
        if rmask.SetBlockingLoadsRequested then
            rmask:SetBlockingLoadsRequested(true)
        end
        rmask:SetTexture(ROUND_PIP_MASK_TEX,
            "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        rmask:SetAllPoints(pipFrame)
        rmask:Hide()
        fill:AddMaskTexture(rmask)
        if rb._runes and rb._runes[i] then
            -- DK: the oUF-driven rune StatusBar paints over _fill; its
            -- fill texture needs the same rounded clip.
            local runeFill = rb._runes[i]:GetStatusBarTexture()
            if runeFill then runeFill:AddMaskTexture(rmask) end
        end
        pipFrame._roundMask = rmask
        -- Regions the per-pip ROUNDED KIT mask must clip (same set the
        -- legacy stretched mask covered). Both masks can stay attached:
        -- a hidden mask is inert.
        pipFrame._bfPipMaskRegions = { fill }
        if rb._runes and rb._runes[i] then
            local runeFill = rb._runes[i]:GetStatusBarTexture()
            if runeFill then pipFrame._bfPipMaskRegions[2] = runeFill end
        end

        -- Ring on the pip's border frame (above fill + rune bar), same
        -- sublevel as the square edges so it layers identically.
        local rring = BF.Texture(bf, nil, "OVERLAY", nil, 3)
        rring:Hide()
        pipFrame._roundRing = rring

        rb._pips[i] = pipFrame
    end

    local handle = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    handle:SetFrameStrata("MEDIUM")
    handle:SetFrameLevel(110)
    handle:SetBackdrop({ bgFile="Interface\\Buttons\\White8x8",
                         edgeFile="Interface\\Buttons\\White8x8", edgeSize=1 })
    handle:SetBackdropColor(0.1, 0.3, 0.6, 0.8)
    handle:SetBackdropBorderColor(0.2, 0.5, 0.9, 1)
    handle:EnableMouse(true)
    handle:SetMovable(false)
    handle:RegisterForDrag("LeftButton")
    local lbl = handle:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetPoint("CENTER")
    lbl:SetText("Resource Bar")
    lbl:SetTextColor(1, 1, 1)
    handle:SetScript("OnDragStart", function() rb:StartMoving() end)
    handle:SetScript("OnDragStop", function()
        rb:StopMovingOrSizing()
        local x, y   = rb:GetCenter()
        local ux, uy = UIParent:GetCenter()
        BF:SetUFAnchor("playerResourceBar", x - ux, y - uy)
        BF:_SnapOUFResourceBarHandle()
    end)
    handle:Hide()
    rb._handle = handle

    rb._lastPowerType = nil
    rb._lastPipCount  = 0
    rb._partial       = nil  -- lazily built; see _EnsurePartialPipBars

    self.oufResourceBar = rb

    -- If no player frame exists, spawn a minimal invisible oUF frame
    -- to host ClassPower. RegisterUnitWatch keeps it "shown" so oUF's
    -- event handler fires; alpha 0 makes it invisible on screen.
    if not self.oufPlayer then
        self:_EnsureClassPowerHost()
    end

    -- Attach the Runes element now that both the pips and a host exist. No-op
    -- for non-DKs. If _EnsureClassPowerHost deferred to PLAYER_LOGIN there is no
    -- host yet, and this no-ops; that path re-calls us once the host is spawned.
    self:_EnsureRunesElement()

    self:ApplyOUFResourceBarLayout()
end

-- v86 (event refactor stage 3): deferred-build listener owner.
local buildEvents = BF:EventOwner("oufClassPowerHostBuild")

function BF:_EnsureClassPowerHost()
    if self._classPowerHost then return end
    if not self._oufReady then
        -- v86 (event refactor stage 3): was a private CreateFrame per call.
        -- SubOnce self-unsubscribes on the first fire; the IsSubscribed
        -- guard stops a second call before PLAYER_LOGIN adding a second
        -- listener, which the old frame-per-call form did.
        if not buildEvents:IsSubscribed("PLAYER_LOGIN") then
            buildEvents:SubOnce("PLAYER_LOGIN", function()
                BF:_EnsureClassPowerHost()
                -- Deferred path: the host did not exist when
                -- BuildOUFResourceBar ran, so the runes element could not
                -- be attached then.
                BF:_EnsureRunesElement()
            end)
        end
        return
    end

    local oUF = self.oUF
    oUF:SetActiveStyle("BuzzardClassPowerHost")
    local host = oUF:Spawn("player", "BuzzardFrames_ClassPowerHost")
    host:SetAlpha(0)
    host:SetSize(1, 1)
    host:EnableMouse(false)
    host:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -100, 100)
    self._classPowerHost = host
end

-- ============================================================
-- ClassPower / Runes ownership
--
-- oUF drops every element event on a frame that is not visible
-- (Libs/oUF/events.lua onEvent gates on self:IsVisible()), so the frame that
-- owns ClassPower and Runes has to be one that is actually shown. That is the
-- oUF player frame when it is enabled, and the alpha-0 -- but shown --
-- BuzzardFrames_ClassPowerHost when it is not: either showPlayerFrame is off,
-- or the player raid-style twin has taken the frame's place (the twin carries
-- the raid engine's own resource display, not oUF's ClassPower).
-- ============================================================
function BF:_ClassPowerNeedsHost()
    local p = self.ufDB and self.ufDB.profile
    if not p then return false end
    if not p.showPlayerFrame then return true end
    -- Twins.lua loads after this file; pure settings read, no frame needed.
    if self.IsTwinActive and self:IsTwinActive("player") then return true end
    return false
end

function BF:_ClassPowerOwner()
    if self:_ClassPowerNeedsHost() then
        return self._classPowerHost
    end
    return self.oufPlayer or self._classPowerHost
end

-- Moves ClassPower and Runes onto whichever of the two frames is currently
-- shown. Idempotent, change-guarded, and only does anything once the oUF
-- player frame exists -- when it does not, BuildOUFResourceBar's own
-- `if not self.oufPlayer` host spawn already put them in the right place.
-- Insecure (EnableElement/DisableElement), so it is safe in combat, but its
-- callers are the out-of-combat layout paths.
function BF:SyncClassPowerHost()
    if not self.oufPlayer then return end
    if self:_ClassPowerNeedsHost() then self:_EnsureClassPowerHost() end

    local owner = self:_ClassPowerOwner()
    if not owner then return end
    local other = (owner == self.oufPlayer) and self._classPowerHost or self.oufPlayer
    if other == owner then other = nil end

    -- Give up the old owner first: two enabled ClassPower elements would both
    -- feed BF:UpdateOUFResourceBar. Runes has to be disabled before its table
    -- is unhooked -- oUF's Disable reads self.Runes to hide the pips.
    if other and other.IsElementEnabled then
        if other:IsElementEnabled("ClassPower") then
            other:DisableElement("ClassPower")
        end
        if other.Runes then
            if other:IsElementEnabled("Runes") then
                other:DisableElement("Runes")
            end
            other.Runes = nil
        end
    end

    if owner.IsElementEnabled and not owner:IsElementEnabled("ClassPower") then
        owner:EnableElement("ClassPower", "player")
        if owner.ClassPower and owner.ClassPower.ForceUpdate then
            owner.ClassPower:ForceUpdate()
        end
    end
    -- Re-attaches the pips to the new owner (no-op for non-DKs, and a no-op
    -- when the owner already has them).
    self:_EnsureRunesElement()
end

-- ============================================================
-- Runes (Death Knight)
--
-- oUF already implements the entire rune bar in Libs/oUF/elements/runes.lua:
-- cooldown reads, smooth recharge fill, per-rune OnUpdate attach/detach,
-- RUNE_POWER_UPDATE registration, sorting and spec coloring. It only needs a
-- table of StatusBars at frame.Runes; we supply the ones built into the pips.
--
-- The element cannot be attached in BuildClassPowerWidget (oUF_Shared.lua) the
-- way ClassPower is, because the pips live on oufResourceBar, which does not
-- exist at style time. Instead we attach after the bar is built and enable the
-- element explicitly — oUF supports post-spawn enabling (Libs/oUF/ouf.lua:93),
-- as already used for Castbar (oUF_Castbar.lua:537) and Power (oUF_Shared.lua:3133).
-- ============================================================
function BF:_EnsureRunesElement()
    if not PlayerIsDK() then return end
    local rb = self.oufResourceBar
    if not rb or not rb._runes then return end

    local host = self:_ClassPowerOwner()
    if not host then return end
    if host.Runes then return end  -- already attached

    local runes = rb._runes

    -- oUF calls UpdateColor with the PARENT frame, not the element
    -- (runes.lua:105-113), hence the `frame` parameter. Overriding it keeps BF's
    -- profile color options authoritative instead of oUF's colors.power.RUNES.
    runes.UpdateColor = function(frame)
        local element = frame.Runes
        if not element then return end
        local p = BF.ufDB.profile
        local rc
        if p.oufResourceBarUseTypeColor ~= false then
            rc = RESOURCE_COLORS[RUNE_TYPE]
        else
            rc = p.oufResourceBarColor or RESOURCE_COLORS[RUNE_TYPE]
        end
        for i = 1, #element do
            element[i]:SetStatusBarColor(rc.r, rc.g, rc.b, 1)
        end
    end

    -- Runes has no PostVisibility (unlike ClassPower), so the bar's show/hide
    -- has to ride on PostUpdate — this is the only genuinely new logic.
    runes.PostUpdate = function()
        BF:UpdateOUFRuneBar()
    end

    host.Runes = runes
    if host.EnableElement then
        host:EnableElement("Runes", "player")
    end
    if host.Runes and host.Runes.ForceUpdate then
        host.Runes:ForceUpdate()
    end
end

-- Rune equivalent of UpdateOUFResourceBar. oUF owns the fill values, so this
-- only handles what oUF does not: the profile enable gate, pip geometry, the
-- dim empty backing, and showing the bar.
function BF:UpdateOUFRuneBar()
    local rb = self.oufResourceBar
    if not rb or not rb._runes then return end
    local p = self.ufDB.profile

    if p.oufResourceBarEnabled ~= true then
        rb:Hide()
        if rb._handle then rb._handle:Hide() end
        return
    end

    -- oUF hides the individual rune bars in a vehicle (runes.lua:136-137) but
    -- still calls PostUpdate, which would leave us showing an empty shell of dim
    -- backing + borders. Every other class gets the bar hidden outright via
    -- ClassPower's PostVisibility, so match that.
    --
    -- ...unless ClassPower is legitimately driving the bar. Its vehicle branch
    -- (classpower.lua:438-443) has NO class check, so a DK in a vehicle that
    -- grants combo points gets a real COMBO_POINTS bar. Runes' AllPath runs after
    -- ClassPower's VisibilityPath in __elements (we EnableElement post-Spawn, so
    -- we're appended later), and rune regen continues in vehicles, so an
    -- unconditional Hide here would blank the combo bar on entry and re-blank it
    -- on every RUNE_POWER_UPDATE. Return either way — we must not rebuild the
    -- geometry to 6 rune pips over ClassPower's combo display.
    if UnitHasVehicleUI("player") then
        -- v67 / oUF 14.0.0: ClassPower.__isEnabled was internalised; ask oUF's
        -- public element registry instead (BF:GetOUFClassPowerState).
        local host = self:_ClassPowerOwner()
        if not BF:GetOUFClassPowerState(host) then
            rb:Hide()
        end
        return
    end

    if rb._lastPipCount ~= RUNE_COUNT or rb._lastPowerType ~= RUNE_TYPE then
        rb._lastPipCount  = RUNE_COUNT
        rb._lastPowerType = RUNE_TYPE
        self:_OUFResourceBarRebuildGeometry()
    end

    local rc
    if p.oufResourceBarUseTypeColor ~= false then
        rc = RESOURCE_COLORS[RUNE_TYPE]
    else
        rc = p.oufResourceBarColor or RESOURCE_COLORS[RUNE_TYPE]
    end
    local showEmpty  = p.oufResourceBarShowEmpty ~= false
    local dimFactor  = p.oufResourceBarEmptyDim or 0.2

    -- _fill is the dim backing; the StatusBar oUF drives paints over it.
    -- SetVertexColor, NOT SetColorTexture: the fill carries the power
    -- bar texture (layout-time), which SetColorTexture would stomp.
    for i = 1, RUNE_COUNT do
        local pipFrame = rb._pips[i]
        if pipFrame then
            if showEmpty then
                pipFrame._fill:SetVertexColor(rc.r * dimFactor, rc.g * dimFactor, rc.b * dimFactor, 0.8)
            else
                pipFrame._fill:SetVertexColor(0, 0, 0, 0)
            end
        end
    end

    rb:Show()
end

-- ============================================================
-- Fractional pip fill (Essence recharge / Destruction shard fragments)
-- ============================================================

-- One StatusBar per pip, built the first time a fractional resource is actually
-- active and never rebuilt afterwards. Sits at pip level + 1 -- above _fill,
-- below _border at + 2 -- exactly where the rune bars sit, and carries the same
-- rounded-clip wiring.
--
-- Pre-resolved per pip rather than one bar moved to whichever pip is part-full:
-- rb is parented to the oUF player frame, protection is inherited by children,
-- and a SetParent on a pip mid-combat is an action-blocked risk.
--
-- No-op for a DK: rb._runes already owns bars at that level.
function BF:_EnsurePartialPipBars(numericType)
    local rb = self.oufResourceBar
    if not rb or rb._runes or rb._partial then return end

    local cap = PIP_RESOURCES[numericType]
    if not cap then return end

    local fillTex = PowerBarFillTexture(self.ufDB.profile)
    rb._partial = {}
    for i = 1, cap do
        local pipFrame = rb._pips[i]
        if not pipFrame then break end

        local sb = BF.StatusBar(nil, pipFrame)
        sb:SetFrameLevel(pipFrame:GetFrameLevel() + 1)
        sb:SetAllPoints(pipFrame)
        sb:SetStatusBarTexture(fillTex)
        sb:EnableMouse(false)
        sb:SetMinMaxValues(0, 1)
        sb:SetValue(0)
        sb:Hide()

        -- The legacy stretched mask is attached directly; the ROUNDED KIT set
        -- is driven off _bfPipMaskRegions, so append there and re-stamp the
        -- border once at the end (SetRegionCornerMasks tracks per region, so
        -- the regions already masked are untouched).
        local sbTex = sb:GetStatusBarTexture()
        if sbTex then
            if pipFrame._roundMask then
                sbTex:AddMaskTexture(pipFrame._roundMask)
            end
            local regions = pipFrame._bfPipMaskRegions
            if regions then regions[#regions + 1] = sbTex end
        end

        rb._partial[i] = sb
    end

    self:_ApplyOUFResourceBarBorder()
end

-- Spread a fractional resource total across the pips: pip i shows the part of
-- `total` that falls between i-1 and i, so 2.7 lights two pips and fills the
-- third to 70%. One rule covers both resources and every pip state -- full,
-- part-full and empty -- so there is nothing to infer and no special case for
-- the pip on the boundary.
local function ApplyPartialFill(rb, total, count)
    local bars = rb._partial
    if not bars then return end

    for i = 1, #bars do
        local sb = bars[i]
        if i <= count then
            local v = total - (i - 1)
            if v < 0 then v = 0 elseif v > 1 then v = 1 end
            if sb._bfValue ~= v then
                sb._bfValue = v
                sb:SetValue(v)
            end
            sb:Show()
        else
            sb:Hide()
        end
    end
end

-- Essence as a single fractional number: whole essences plus progress toward
-- the next one, read from UnitPartialPower (0-1000 toward the next essence).
--
-- The one thing UnitPartialPower gets wrong is a SPEND: the game keeps the
-- progress already made toward the next essence, but the API restarts its count
-- from zero, which emptied the pip and then took a full recharge to refill it.
-- Since partial climbs by exactly 1 over one full recharge, carrying the
-- progress across the spend as a head start restores both -- the pip keeps its
-- fill, and it completes after exactly the time that was really left.
--
-- Returns nil when the values cannot be trusted, in which case the caller
-- leaves the display alone.
local essLastCur   -- last whole-essence count seen, to spot spends and gains
local essOffset = 0 -- progress carried across a spend
local essFrac   = 0 -- fraction last shown, i.e. what a spend carries over

local function EssenceTotal()
    local cur = UnitPower("player", ESSENCE_POWER)
    local max = UnitPowerMax("player", ESSENCE_POWER)
    if not cur or not max or max == 0 then return nil end
    if issecretvalue and (issecretvalue(cur) or issecretvalue(max)) then return nil end

    if essLastCur then
        if cur < essLastCur then
            essOffset = essFrac      -- spent: keep what was on screen
        elseif cur > essLastCur then
            essOffset = 0            -- gained: the carry has been paid out
        end
    end
    essLastCur = cur

    -- At max nothing is charging, so drop any carry: spending from full has to
    -- start a fresh recharge rather than inherit stale progress.
    if cur >= max then
        essOffset, essFrac = 0, 0
        return cur, max
    end

    local partial = 0
    if UnitPartialPower then
        local raw = UnitPartialPower("player", ESSENCE_POWER)
        if raw and not (issecretvalue and issecretvalue(raw)) then
            partial = raw / ESSENCE_PARTIAL_MAX
            if partial < 0 then partial = 0 end
        end
    end

    local frac = partial + essOffset
    if frac > 1 then frac = 1 end
    essFrac = frac

    return cur + frac, max
end

local partialFrame

-- Essence is the only resource here that moves between power events, so it is
-- the only one that needs a per-frame pass. Both halves of the total are
-- re-read every frame, so this can never disagree with the game state or race
-- the power event that ClassPower is handling: a spend, a gain and a tick all
-- just produce a new total on the next frame.
local function PartialOnUpdate(self)
    local rb = BF.oufResourceBar
    if not rb or not rb._partial or not rb._partialLive then
        self:SetScript("OnUpdate", nil)
        return
    end

    local total, max = EssenceTotal()
    if not total then return end

    ApplyPartialFill(rb, total, rb._partialCount or 0)

    -- Capped: nothing left to animate until the next power event brings us back.
    if total >= max then
        rb._partialLive = false
        self:SetScript("OnUpdate", nil)
    end
end

function BF:_EnsurePartialTicker()
    if not partialFrame then partialFrame = CreateFrame("Frame") end
    return partialFrame
end

-- Stop the per-frame pass. The renderer owns Show/Hide; this only ends the
-- animation, and the next update re-arms it if the resource is still filling.
function BF:_StopOUFPartialFill()
    local rb = self.oufResourceBar
    if rb then rb._partialLive = false end
    if partialFrame then partialFrame:SetScript("OnUpdate", nil) end
end

function BF:_SnapOUFResourceBarHandle()
    local rb = self.oufResourceBar
    if not rb or not rb._handle then return end
    local handle = rb._handle
    handle:ClearAllPoints()
    handle:SetPoint("BOTTOMLEFT", rb, "TOPLEFT", 0, 2)
    if self.db and self.db.global and self.db.global.tinyHandle then
        handle:SetWidth(5)
        handle:SetHeight(5)
    else
        local w = rb:GetWidth()
        if not w or w <= 0 then w = 80 end
        handle:SetWidth(w)
        handle:SetHeight(14)
    end
end

function BF:ApplyOUFResourceBarLayout()
    local rb = self.oufResourceBar
    if not rb then return end
    local p = self.ufDB.profile

    local show = p.oufResourceBarEnabled == true
    if not show then
        rb:Hide()
        if rb._handle then rb._handle:Hide() end
        return
    end

    local playerFrame = self.oufPlayer
    local detached = self:GetUFDetachState("playerResourceBar") or (not playerFrame)
    local locked   = self.db.global.locked
    if locked == nil then locked = true end

    local h    = p.oufResourceBarHeight or 10
    local pf   = p.player or {}
    local barW = detached and (p.oufResourceBarWidth or pf.frameWidth or 156)
                           or (pf.frameWidth or 156)

    rb:SetHeight(h)
    rb:SetWidth(barW)

    if detached then
        local wasAttached = (rb:GetParent() ~= UIParent)
        if wasAttached then
            local cx, cy = rb:GetCenter()
            if (not cx or not cy) and playerFrame and playerFrame.Power then
                cx, cy = playerFrame.Power:GetCenter()
            end
            local ux, uy = UIParent:GetCenter()
            if cx and cy and ux and uy then
                local existX, existY = BF:GetUFAnchor("playerResourceBar")
                if not existX then
                    BF:SetUFAnchor("playerResourceBar", cx - ux, cy - uy)
                end
            end
            rb:SetParent(UIParent)
            rb:SetFrameStrata("MEDIUM")
            rb:SetFrameLevel(10)
            local rbAncX, rbAncY = BF:GetUFAnchor("playerResourceBar")
            rb:ClearAllPoints()
            rb:SetPoint("CENTER", UIParent, "CENTER",
                rbAncX or -400,
                rbAncY or -340)
        else
            local rbAncX2, rbAncY2 = BF:GetUFAnchor("playerResourceBar")
            if rbAncX2 then
                rb:ClearAllPoints()
                rb:SetPoint("CENTER", UIParent, "CENTER", rbAncX2, rbAncY2)
            end
        end

        rb._handle:SetShown(not locked)
        if not locked then self:_SnapOUFResourceBarHandle() end
    else
        if playerFrame and rb:GetParent() ~= playerFrame then
            rb:SetParent(playerFrame)
        end
        if playerFrame then
            local base = playerFrame:GetFrameLevel()
            rb:SetFrameLevel(base + 2)
            if rb._border then rb._border:SetFrameLevel(base + 3) end
        end
        rb._handle:Hide()

        local gap = p.oufResourceBarGap or 0
        rb:ClearAllPoints()
        if playerFrame and playerFrame.Power then
            rb:SetPoint("TOPLEFT",  playerFrame.Power, "BOTTOMLEFT",  0, -gap)
            rb:SetPoint("TOPRIGHT", playerFrame.Power, "BOTTOMRIGHT", 0, -gap)
        end
    end

    local bgC = p.oufResourceBarBgColor or { r=0.08, g=0.08, b=0.08, a=1 }
    if rb._bg then
        rb._bg:SetColorTexture(bgC.r, bgC.g, bgC.b, 1)
        rb._bg:SetAlpha(bgC.a or 1)
        -- v85: Show Background toggle (default on).
        rb._bg:SetShown(p.oufResourceBarShowBg ~= false)
    end

    -- Pip/rune fill texture (power bar texture setting). Layout-time
    -- only; update paths recolor via SetVertexColor/SetStatusBarColor.
    local fillTex = PowerBarFillTexture(p)
    for i = 1, 10 do
        rb._pips[i]._fill:SetTexture(fillTex)
    end
    if rb._runes then
        for i = 1, RUNE_COUNT do
            rb._runes[i]:SetStatusBarTexture(fillTex)
        end
    end
    if rb._partial then
        for i = 1, #rb._partial do
            rb._partial[i]:SetStatusBarTexture(fillTex)
        end
    end

    self:_OUFResourceBarRebuildGeometry()
    self:_ApplyOUFResourceBarBorder()

    -- Don't force-show here; ClassPower's PostVisibility will show the
    -- bar when an active class resource is detected. If ClassPower has
    -- already fired (e.g. layout re-apply), force an update now.
    local host = self:_ClassPowerOwner()
    -- v67 / oUF 14.0.0: __isEnabled/__cur/__max/__powerType were internalised.
    -- GetOUFClassPowerState combines the public IsElementEnabled check with the
    -- values our own ClassPower PostUpdate caches on the host frame.
    local cpOn, cpCur, cpMax, cpType = BF:GetOUFClassPowerState(host)
    if cpOn then
        rb:Show()
        self:UpdateOUFResourceBar(cpCur, cpMax, cpType)
    elseif host and host.IsElementEnabled and host:IsElementEnabled("Runes") then
        -- DK: ClassPower is never enabled for us (oUF has no DEATHKNIGHT branch),
        -- so without this the bar stays hidden until the next RUNE_POWER_UPDATE.
        -- NOTE: do NOT test Runes.__isEnabled here — that field is not part of
        -- oUF's element contract. Only classpower.lua and additionalpower.lua set
        -- it; runes.lua's Enable (runes.lua:199-223) sets __owner and ForceUpdate
        -- only, so __isEnabled would be nil forever and this branch dead.
        -- IsElementEnabled reads oUF's activeElements, which EnableElement
        -- populates (Libs/oUF/ouf.lua:100-101). Same idiom as oUF_Castbar.lua:519.
        -- ForceUpdate re-runs oUF's rune update, whose PostUpdate calls
        -- UpdateOUFRuneBar and shows the bar.
        if host.Runes and host.Runes.ForceUpdate then host.Runes:ForceUpdate() end
    end
end

function BF:_ApplyOUFResourceBarBorder()
    local rb = self.oufResourceBar
    if not rb then return end
    local p = self.ufDB.profile

    -- Rounded border mode (v59): bar-level ring+mask from the shared
    -- Frame* art (the resource bar hangs below the composite block, so
    -- it is a standalone bar), plus the aura-icon treatment on every
    -- pip below. ApplyUFBarRoundBorder hides the kit itself when the
    -- mode is square, so this single call handles both directions.
    local rounded = BF:ApplyUFBarRoundBorder(rb, { rb._bg },
        rb:GetFrameLevel() + 5)
    -- Rounded: the Border settings stay live (owner request) -- the
    -- bar ring follows Enable Border and tints with the bar Border
    -- Color instead of the shared frame ring color. The MASK always
    -- stays on (it rounds the bar content to match the mode).
    if rounded and rb._bfRoundKit then
        if p.oufResourceBarBorderEnabled == true then
            local bc = p.oufResourceBarBorderColor or { r = 0, g = 0, b = 0, a = 1 }
            rb._bfRoundKit.ring:SetVertexColor(bc.r or 0, bc.g or 0, bc.b or 0, bc.a or 1)
        else
            rb._bfRoundKit.ring:Hide()
        end
    end

    local bbf = rb._barBorder
    if bbf then
        if rounded or p.oufResourceBarBorderEnabled ~= true then
            bbf:Hide()
        else
            bbf:SetFrameLevel(rb:GetFrameLevel() + 5)
            local thick = p.oufResourceBarBorderThickness or 1
            local bc    = p.oufResourceBarBorderColor or { r=0, g=0, b=0, a=1 }
            local r, g, b, a = bc.r or 0, bc.g or 0, bc.b or 0, bc.a or 1

            bbf.top:SetColorTexture(r, g, b, a)
            bbf.top:ClearAllPoints()
            bbf.top:SetPoint("TOPLEFT",  rb, "TOPLEFT",  0, 0)
            bbf.top:SetPoint("TOPRIGHT", rb, "TOPRIGHT", 0, 0)
            bbf.top:SetHeight(thick)

            bbf.bottom:SetColorTexture(r, g, b, a)
            bbf.bottom:ClearAllPoints()
            bbf.bottom:SetPoint("BOTTOMLEFT",  rb, "BOTTOMLEFT",  0, 0)
            bbf.bottom:SetPoint("BOTTOMRIGHT", rb, "BOTTOMRIGHT", 0, 0)
            bbf.bottom:SetHeight(thick)

            bbf.left:SetColorTexture(r, g, b, a)
            bbf.left:ClearAllPoints()
            bbf.left:SetPoint("TOPLEFT",    rb, "TOPLEFT",    0, 0)
            bbf.left:SetPoint("BOTTOMLEFT", rb, "BOTTOMLEFT", 0, 0)
            bbf.left:SetWidth(thick)

            bbf.right:SetColorTexture(r, g, b, a)
            bbf.right:ClearAllPoints()
            bbf.right:SetPoint("TOPRIGHT",    rb, "TOPRIGHT",    0, 0)
            bbf.right:SetPoint("BOTTOMRIGHT", rb, "BOTTOMRIGHT", 0, 0)
            bbf.right:SetWidth(thick)

            bbf:Show()
        end
    end

    -- ── Pips ─────────────────────────────────────────────────────────
    -- Rounded: every pip carries its own sliced bar-art kit
    -- (ApplyUFBarRoundBorder: pixel host + short-dimension cap), so the
    -- ring band is the constant frame weight at any pip size. Ring
    -- visibility/tint follow the Pip Border settings; the kit mask
    -- always rounds the fill. Square: the classic 4 inset edges.
    local pipShow  = p.oufResourceBarPipBorderEnabled == true
    local pipThick = pipShow and (p.oufResourceBarPipBorderThickness or 1) or 0
    local pbc      = p.oufResourceBarPipBorderColor or { r=0, g=0, b=0, a=1 }
    local pr, pg, pb, pa = pbc.r or 0, pbc.g or 0, pbc.b or 0, pbc.a or 1

    for i = 1, 10 do
        local pipFrame = rb._pips[i]
        if pipFrame and pipFrame._border then
            local bf = pipFrame._border
            if rounded then
                bf.top:Hide()
                bf.bottom:Hide()
                bf.left:Hide()
                bf.right:Hide()
                -- Per-pip SLICED bar-art kit (pixel host + short-dimension
                -- cap) replaces the stretched IconBorder art: the stretched
                -- band scaled with pip size (6.25%/12.5% per side -- far too
                -- thick at real pip sizes), the sliced band is the constant
                -- 1/1.5px frame weight at any size, and the kit mask's
                -- corner radius matches its ring by construction. The ring
                -- follows the Pip Border settings (Enable + Color, owner
                -- request); the mask always rounds the pip fill.
                BF:ApplyUFBarRoundBorder(pipFrame, pipFrame._bfPipMaskRegions,
                    pipFrame._border:GetFrameLevel())
                local kit = pipFrame._bfRoundKit
                if kit then
                    if pipShow then
                        kit.ring:SetVertexColor(pr, pg, pb, pa)
                    else
                        kit.ring:Hide()
                    end
                end
                -- Legacy stretched widgets: retired (kept created -- textures
                -- can't be destroyed; hidden mask = inert).
                if pipFrame._roundRing then pipFrame._roundRing:Hide() end
                if pipFrame._roundMask then pipFrame._roundMask:Hide() end
            elseif not pipShow or pipThick == 0 then
                if pipFrame._bfRoundKit then
                    pipFrame._bfRoundKit.ring:Hide()
                    pipFrame._bfRoundKit.mask:Hide()
                end
                if pipFrame._roundRing then pipFrame._roundRing:Hide() end
                if pipFrame._roundMask then pipFrame._roundMask:Hide() end
                bf.top:Hide()
                bf.bottom:Hide()
                bf.left:Hide()
                bf.right:Hide()
            else
                if pipFrame._bfRoundKit then
                    pipFrame._bfRoundKit.ring:Hide()
                    pipFrame._bfRoundKit.mask:Hide()
                end
                if pipFrame._roundRing then pipFrame._roundRing:Hide() end
                if pipFrame._roundMask then pipFrame._roundMask:Hide() end
                bf.top:SetColorTexture(pr, pg, pb, pa)
                bf.top:ClearAllPoints()
                bf.top:SetPoint("TOPLEFT",  pipFrame, "TOPLEFT",  0, 0)
                bf.top:SetPoint("TOPRIGHT", pipFrame, "TOPRIGHT", 0, 0)
                bf.top:SetHeight(pipThick)
                bf.top:Show()

                bf.bottom:SetColorTexture(pr, pg, pb, pa)
                bf.bottom:ClearAllPoints()
                bf.bottom:SetPoint("BOTTOMLEFT",  pipFrame, "BOTTOMLEFT",  0, 0)
                bf.bottom:SetPoint("BOTTOMRIGHT", pipFrame, "BOTTOMRIGHT", 0, 0)
                bf.bottom:SetHeight(pipThick)
                bf.bottom:Show()

                bf.left:SetColorTexture(pr, pg, pb, pa)
                bf.left:ClearAllPoints()
                bf.left:SetPoint("TOPLEFT",    pipFrame, "TOPLEFT",    0, 0)
                bf.left:SetPoint("BOTTOMLEFT", pipFrame, "BOTTOMLEFT", 0, 0)
                bf.left:SetWidth(pipThick)
                bf.left:Show()

                bf.right:SetColorTexture(pr, pg, pb, pa)
                bf.right:ClearAllPoints()
                bf.right:SetPoint("TOPRIGHT",    pipFrame, "TOPRIGHT",    0, 0)
                bf.right:SetPoint("BOTTOMRIGHT", pipFrame, "BOTTOMRIGHT", 0, 0)
                bf.right:SetWidth(pipThick)
                bf.right:Show()
            end
        end
    end
end

function BF:_OUFResourceBarRebuildGeometry()
    local rb = self.oufResourceBar
    if not rb then return end
    local p        = self.ufDB.profile
    local pipCount = rb._lastPipCount or 0

    local barW = rb:GetWidth()
    if not barW or barW <= 0 then
        local pf = p.player or {}
        barW = (BF:GetUFDetachState("playerResourceBar") and p.oufResourceBarWidth)
               or pf.frameWidth or 156
    end

    local gap = p.oufResourceBarPipGap or 2

    if pipCount > 0 then
        -- v85 EDGE-FLUSH pips (owner request): the FIRST pip's left edge
        -- sits exactly on the bar's left edge and the LAST pip's right
        -- edge exactly on the bar's right edge (= the health bar edges
        -- in attached mode). Every pip keeps the SAME width (nearest
        -- whole px to the ideal), and the GAP absorbs the rounding
        -- remainder as a FRACTIONAL value — the spacing slider is a
        -- target, not an exact promise. (The previous scheme floored the
        -- pip width and parked the remainder as symmetric edge padding,
        -- which visibly inset the last pip from the bar edge at some
        -- spacing values; before that, the last pip absorbed the whole
        -- remainder and ran wider than its siblings.)
        local pipW = (barW - gap * (pipCount - 1)) / pipCount
        pipW = math.max(1, math.floor(pipW + 0.5))
        local effGap = pipCount > 1
            and (barW - pipW * pipCount) / (pipCount - 1)
            or 0
        for i = 1, 10 do
            local pipFrame = rb._pips[i]
            if i <= pipCount then
                pipFrame:ClearAllPoints()
                if i == pipCount and pipCount > 1 then
                    -- Last pip: RIGHT-anchored, so its right edge is
                    -- flush with the bar edge by construction — immune
                    -- to fractional-gap accumulation drift.
                    pipFrame:SetPoint("TOPRIGHT",    rb, "TOPRIGHT",    0, 0)
                    pipFrame:SetPoint("BOTTOMRIGHT", rb, "BOTTOMRIGHT", 0, 0)
                else
                    local xOff = (i - 1) * (pipW + effGap)
                    pipFrame:SetPoint("TOPLEFT",    rb, "TOPLEFT",    xOff, 0)
                    pipFrame:SetPoint("BOTTOMLEFT", rb, "BOTTOMLEFT", xOff, 0)
                end
                pipFrame:SetWidth(pipW)
                pipFrame:Show()
            else
                pipFrame:Hide()
            end
        end
    else
        for i = 1, 10 do rb._pips[i]:Hide() end
    end
end

-- Called by ClassPower's PostVisibility when the active class resource
-- changes (e.g. spec swap, entering/leaving vehicle).
function BF:UpdateOUFResourceBarVisibility(isVisible)
    local rb = self.oufResourceBar
    if not rb then return end

    if self.ufDB.profile.oufResourceBarEnabled ~= true then
        rb:Hide()
        if rb._handle then rb._handle:Hide() end
        return
    end

    -- On a DK the Runes element owns this bar; ClassPower must not touch it.
    -- ClassPower's Enable has NO class check (classpower.lua:562-589), so it
    -- activates for a DK too, immediately finds no matching playerClass branch
    -- (classpower.lua:116-309), resolves powerType = nil, and fires
    -- PostVisibility(false) -> here -> rb:Hide(). Today that only fails to break
    -- runes because of statement ordering (rb is still nil on the oufPlayer path;
    -- on the _classPowerHost path _EnsureRunesElement's ForceUpdate happens to
    -- re-show it a few lines later). Ignore it explicitly rather than rely on that.
    if rb._runes then return end

    if not isVisible then
        self:_StopOUFPartialFill()
        rb:Hide()
    end
    -- When isVisible is true, the next PostUpdate will show the bar.
end

-- Called by ClassPower's PostUpdate with current/max values and the
-- string power type. Pure renderer — no detection or event logic.
function BF:UpdateOUFResourceBar(cur, max, powerType)
    local rb = self.oufResourceBar
    if not rb then return end
    local p = self.ufDB.profile

    if p.oufResourceBarEnabled ~= true then
        self:_StopOUFPartialFill()
        rb:Hide()
        if rb._handle then rb._handle:Hide() end
        return
    end

    -- ClassPowerDisable passes nil cur/max
    if not cur or not max or max == 0 then
        self:_StopOUFPartialFill()
        rb:Hide()
        return
    end

    -- Map ClassPower's string type to our numeric key
    local numericType = CLASSPOWER_TYPE_MAP[powerType]
    local pipCap = numericType and PIP_RESOURCES[numericType]
    if not pipCap then
        self:_StopOUFPartialFill()
        rb:Hide()
        return
    end

    local pipMax = math.min(pipCap, max)

    if pipMax ~= rb._lastPipCount or numericType ~= rb._lastPowerType then
        rb._lastPipCount  = pipMax
        rb._lastPowerType = numericType
        self:_OUFResourceBarRebuildGeometry()
    end

    local rc
    if p.oufResourceBarUseTypeColor ~= false then
        rc = RESOURCE_COLORS[numericType] or { r=1.0, g=0.61, b=0.04 }
    else
        rc = p.oufResourceBarColor or { r=1.0, g=0.61, b=0.04 }
    end
    local showEmpty = p.oufResourceBarShowEmpty ~= false
    local dimFactor = p.oufResourceBarEmptyDim or 0.2

    -- Fractional resources hand the bright fill to the per-pip StatusBars, so
    -- _fill drops to the dim backing for every pip; everything else keeps the
    -- plain two-state texture it has always used.
    local fractional = p.oufResourceBarPartialFill ~= false
                       and PartialCapable(numericType)
    if fractional then
        self:_EnsurePartialPipBars(numericType)
        fractional = rb._partial ~= nil
    end

    -- SetVertexColor, NOT SetColorTexture: the fill carries the power
    -- bar texture (layout-time), which SetColorTexture would stomp.
    for i = 1, pipMax do
        local pipFrame = rb._pips[i]
        local fill = pipFrame._fill
        if not fractional and i <= cur then
            fill:SetVertexColor(rc.r, rc.g, rc.b, 1)
        elseif showEmpty then
            fill:SetVertexColor(rc.r * dimFactor, rc.g * dimFactor, rc.b * dimFactor, 0.8)
        else
            fill:SetVertexColor(0, 0, 0, 0)
        end
    end

    if rb._partial then
        if fractional then
            -- Essence needs its fraction fetched; Destruction's already rode in
            -- on `cur`. A total below max means it is still filling, which is
            -- the only thing that warrants a per-frame pass.
            local total, live = cur, false
            if numericType == ESSENCE_TYPE then
                local t, m = EssenceTotal()
                if t then total, live = t, t < m end
            end

            for i = 1, #rb._partial do
                rb._partial[i]:SetStatusBarColor(rc.r, rc.g, rc.b, 1)
            end
            rb._partialCount = pipMax
            rb._partialLive  = live
            ApplyPartialFill(rb, total, pipMax)

            self:_EnsurePartialTicker():SetScript("OnUpdate", live and PartialOnUpdate or nil)
        else
            -- Bars exist but this resource has no fraction (spec swap, or the
            -- option was turned off): stand them down and let _fill render.
            self:_StopOUFPartialFill()
            for i = 1, #rb._partial do rb._partial[i]:Hide() end
        end
    end

    rb:Show()
end
