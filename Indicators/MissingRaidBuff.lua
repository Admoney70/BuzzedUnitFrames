--[[
BuzzardFrames: Indicators/MissingRaidBuff.lua
Missing raid buff icon indicator — shows a single icon when the unit
is missing an expected raid buff (Fortitude, Mark of the Wild, etc.).

Reads tracker state from BF._missingRaidBuffTracker and
BF._missingSymbioticTracker (see AuraCustomizations.lua tracker
registration + Statuses/SingleAuraTrackers.lua framework). The trackers
maintain s.idx[unit] from the shared HELPFUL scan in Buffs:UNIT_AURA;
this indicator just renders the missing texture when the tracker reports
absent. Priority: main raid-buff missing > symbiotic missing.

Icon slot pre-allocated by ApplyAuraGeometry (AuraConfig.lua) as
frame.missingRaidBuffIcon.
]]

local BF  = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local UnitIsConnected  = UnitIsConnected
local UnitIsDeadOrGhost = UnitIsDeadOrGhost
local UnitIsVisible    = UnitIsVisible

local SetIconBorderColor = BF.SetIconBorderColor

local MissingRaidBuff = BF.indicatorPrototype:new("missingRaidBuff")

-- Per-indicator Create: build the single missing-raid-buff icon.
-- No tooltip wiring (preserves pre-refactor behavior — missing-raid-buff
-- icons never had tooltips). Applies OVERLAY draw layer and the
-- desaturate that gives the "buff missing" visual cue (preserves
-- pre-refactor AuraConfig.lua:409-410).
function MissingRaidBuff:CanCreate(parent) return not parent._isPreviewFrame end
function MissingRaidBuff:Layout() end

function MissingRaidBuff:Create(parent)
    if parent.missingRaidBuffIcon then return end
    local level = parent:GetFrameLevel() + 223
    local icon = BF.BuildAuraIconFrame(parent, level + 1)
    if icon.Icon then
        icon.Icon:SetDrawLayer("OVERLAY", 1)
        icon.Icon:SetDesaturated(true)
    end
    parent.missingRaidBuffIcon = icon
end

-- ============================================================
-- MISSING-BUFF GLOW (red marching ants).
-- Same declarative machinery as the container Icon Effects
-- (ContainerFactory ApplyIconEffectCore / PreviewIconEffects): one
-- texture over Blizzard's IconAlertAnts sheet stepped by a FlipBook
-- animation group. The icon is a BF-built frame (BuildAuraIconFrame),
-- not an engine-owned aura button, so there is no forbidden-partition
-- restriction here -- the group is created once and merely Play()ed.
-- Geometry parity with ApplyGlowGeometry: ants span icon width x1.19.
-- ============================================================
local function EnsureMissingGlow(icon)
    if icon._bf_mrbAnts then return icon._bf_mrbAnts end
    local ants = BF.Texture(icon, nil, "OVERLAY", nil, 2)
    ants:SetTexture("Interface\\SpellActivationOverlay\\IconAlertAnts")
    ants:SetVertexColor(1, 0, 0, 1)
    ants:Hide()
    local ag = ants:CreateAnimationGroup()
    ag:SetLooping("REPEAT")
    local fb = ag:CreateAnimation("FlipBook")
    fb:SetDuration(0.7)
    fb:SetFlipBookRows(5); fb:SetFlipBookColumns(5); fb:SetFlipBookFrames(22)
    -- 48px frames on a 256px sheet: without explicit frame dimensions the
    -- flipbook divides the FULL sheet into 5ths and every frame samples
    -- off-grid (the ants visibly jump).
    if fb.SetFlipBookFrameWidth then
        fb:SetFlipBookFrameWidth(48)
        fb:SetFlipBookFrameHeight(48)
    end
    icon._bf_mrbAnts   = ants
    icon._bf_mrbAntsAG = ag
    return ants
end

local function StartMissingGlow(icon)
    local ants = EnsureMissingGlow(icon)
    local w = icon.cachedSize or icon:GetWidth() or 12
    if not w or w <= 0 then w = 12 end
    local aw = w * 1.19
    if icon._bf_mrbAntsSize ~= aw then
        ants:ClearAllPoints()
        ants:SetPoint("CENTER", icon, "CENTER", 0, 0)
        ants:SetSize(aw, aw)
        icon._bf_mrbAntsSize = aw
    end
    ants:Show()
    local ag = icon._bf_mrbAntsAG
    if ag and not ag:IsPlaying() then ag:Play() end
end

local function StopMissingGlow(icon)
    local ag = icon._bf_mrbAntsAG
    if ag and ag:IsPlaying() then ag:Stop() end
    if icon._bf_mrbAnts then icon._bf_mrbAnts:Hide() end
end

-- Per-scope cache write. Fields live in the `icons` section, not `auras`.
-- show*/glow toggles stay off-cache (read live via GetCachedSection in
-- :Update) — only geometry fields are pre-resolved here.
function MissingRaidBuff:UpdateDB(cache, flat, grp)
    local ipp = BF.ResolveCFGSection(BF, flat, grp, "icons") or {}
    cache.missingRaidBuffSize    = ipp.missingRaidBuffSize    or 12
    cache.missingRaidBuffAnchor  = ipp.missingRaidBuffAnchor  or "CENTER"
    cache.missingRaidBuffOffsetX = ipp.missingRaidBuffOffsetX or 0
    cache.missingRaidBuffOffsetY = ipp.missingRaidBuffOffsetY or 0
    cache._roundedMissingRaidBuffSize = BF:PixelRound(cache.missingRaidBuffSize)
end

-- ============================================================
-- HideAll
-- ============================================================
function MissingRaidBuff:HideAll(frame)
    local mIcon = frame.missingRaidBuffIcon
    if not mIcon then return end
    if mIcon:IsShown() then
        if mIcon._hasGlow then
            StopMissingGlow(mIcon)
            mIcon._hasGlow = false
        end
        mIcon:Hide()
    end
end

-- ============================================================
-- Update
-- Source: ScanAndDisplay.lua "MISSING RAID BUFF ICON" section
-- (lines 678-747).
-- ============================================================
function MissingRaidBuff:Update(frame, unit)
    -- Pet frames: pets don't need missing raid buff indicators
    local parentHeader = frame._bf_parentHeader or frame:GetParent()
    if parentHeader and parentHeader.isPetFrame then
        if frame.missingRaidBuffIcon then frame.missingRaidBuffIcon:Hide() end
        return
    end

    -- FAST-PATH FEATURE GATE: resolve the feature-enabled check BEFORE any
    -- other work. This function fires on every buff UNIT_AURA event (bound
    -- to the buffs status), so if the feature is off, we must return with
    -- essentially zero cost -- no frame lookups, no reachability check, no
    -- parent traversal, nothing. Previously the feature-enabled check was
    -- the 5th guard, which meant disabled users still paid ~7us per event
    -- (~0.94 ms/s at 135/s in raid combat) for a feature doing nothing.
    --
    -- The guard reads section config via the cached section profile (Perf 1A)
    -- so the cost of this check itself is a single table hash lookup.
    local p_mb = BF:GetCachedSection("icons", frame)
    if not p_mb then
        return
    end
    if not (p_mb.showMissingRaidBuff or p_mb.showMissingSymbiotic) then
        -- Feature fully off. Must sweep any lingering icon from a previous
        -- enabled state: ApplyAuraGeometry (AuraConfig.lua) only sizes the
        -- icon widget; it never hides it, and the option setter's refresh
        -- routes through here, so without this HideAll the icon stays
        -- visible after the user toggles both flags off.
        --
        -- Steady-state cost: HideAll bails on `not mIcon:IsShown()` before
        -- doing any work, so the per-UNIT_AURA hot path when the feature is
        -- off stays at one table index + one IsShown() check -- matching
        -- the fast-path guarantee the FEATURE GATE comment above describes.
        self:HideAll(frame)
        return
    end

    -- Symbiotic-only non-player short-circuit: when missing-raid-buff is off
    -- and only missing-symbiotic is on, the indicator has nothing to show on
    -- any unit other than the player. Symbiotic is a personal buff probed
    -- only on the player; no other frame can ever produce a visible icon on
    -- this path. Without this gate, every party/raid frame's buff UNIT_AURA
    -- would run the reachability check, frame lookups, and GetMissingRaidBuff-
    -- Icon call just to fall through to nil.
    if not p_mb.showMissingRaidBuff and not UnitIsUnit(unit, "player") then
        self:HideAll(frame)
        return
    end

    local mIcon = frame.missingRaidBuffIcon
    if not mIcon then return end

    -- Skip preview/dummy frames — DummyAuras.lua handles their rendering.
    if frame._isPreviewFrame then return end

    -- v93: hostile/charmed suppression (Auras/ContainerFactory.lua). This
    -- indicator reads real aura data through SingleAuraTrackers, which keeps
    -- working on a charmed member -- so without this gate the frame would go
    -- on advertising the raid buffs a hostile unit is "missing", the one
    -- aura visual left on an otherwise blank frame.
    if BF:IsUnitAuraSuppressed(unit) then
        self:HideAll(frame)
        return
    end

    local ac = BF:GetAuraCacheForFrame(frame)

    -- Gate: global showBuffs off suppresses everything including missing buff
    if ac.showBuffs == false then
        self:HideAll(frame)
        return
    end

    -- Gate: unit not visible (phased, cross-shard)
    -- Kept here because MissingRaidBuff doesn't go through GetIcons.
    if not UnitIsVisible(unit) then
        self:HideAll(frame)
        return
    end

    -- Check if the unit is missing a raid buff (feature confirmed enabled
    -- above). Reads tracker state from the SingleAuraTracker framework.
    -- Priority: main raid-buff missing wins over symbiotic missing.
    --
    -- When no tracker is registered (texture deferred, or player's class
    -- has no raid buff), `missing` stays nil -- the icon hides. Symbiotic
    -- tracker only exists for talented Druids.
    local missing = nil
    local inCombat = BF._inCombat
    -- OUT OF COMBAT ONLY, unconditionally. 12.1 makes the in-combat case
    -- impossible, so the old `or p_mb.showMissingRaidBuffInCombat` opt-in
    -- is gone and its option was removed (Options/Options_Icons.lua). The
    -- stored key survives in existing profiles and is deliberately NOT
    -- read here — a leftover `true` must not resurrect the behavior.
    local wantMissingCheck = not inCombat
    if wantMissingCheck
       and UnitIsConnected(unit)
       and not UnitIsDeadOrGhost(unit) then
        local rbTracker  = BF._missingRaidBuffTracker
        local symTracker = BF._missingSymbioticTracker

        -- Raid-buff branch (any unit, when feature on and tracker registered).
        if p_mb.showMissingRaidBuff and rbTracker and rbTracker:IsAbsent(unit) then
            missing = rbTracker.missingTexture
        end

        -- Symbiotic branch (player only, when feature on, tracker registered,
        -- in a group, and raid-buff didn't already claim the slot).
        if not missing
           and p_mb.showMissingSymbiotic
           and symTracker
           and UnitIsUnit(unit, "player")
           and GetNumGroupMembers and GetNumGroupMembers() > 0 then
            -- Look up by literal "player" token: the framework's dedicated
            -- UNIT_AURA("player") subscription writes s.idx["player"], not
            -- s.idx[frame.unit] (which would be raid7/party3 for the
            -- player's raid/party slot).
            if symTracker:IsAbsent("player") then
                missing = symTracker.missingTexture
            end
        end
    end

    if missing then
        local mSize   = ac._roundedMissingRaidBuffSize or 12
        local mAnchor = ac.missingRaidBuffAnchor  or "CENTER"
        local mOffX   = ac.missingRaidBuffOffsetX or 0
        local mOffY   = ac.missingRaidBuffOffsetY or 0
        mIcon.Icon:SetTexture(missing)
        mIcon.Icon:Show()
        SetIconBorderColor(mIcon, 0, 0, 0, 0.8)
        mIcon.count:Hide()
        if mIcon.cooldown then mIcon.cooldown:SetCooldown(0, 0); mIcon.cooldown:Hide() end
        if mIcon.cachedSize ~= mSize then
            mIcon:SetSize(mSize, mSize)
            mIcon.cachedSize = mSize
        end
        if mIcon.SF_MissingAnchor ~= mAnchor or mIcon.SF_MissingOffX ~= mOffX or mIcon.SF_MissingOffY ~= mOffY then
            mIcon:ClearAllPoints()
            mIcon:SetPoint(mAnchor, frame, mAnchor, mOffX, mOffY)
            mIcon.SF_MissingAnchor = mAnchor
            mIcon.SF_MissingOffX   = mOffX
            mIcon.SF_MissingOffY   = mOffY
        end
        mIcon:Show()
        do
            local wantGlow = p_mb and p_mb.missingRaidBuffShowGlow
            if wantGlow then
                -- StartMissingGlow re-anchors on size change, so calling it
                -- while already glowing is a cheap no-op re-check.
                StartMissingGlow(mIcon)
                mIcon._hasGlow = true
            elseif mIcon._hasGlow then
                StopMissingGlow(mIcon)
                mIcon._hasGlow = false
            end
        end
    else
        self:HideAll(frame)
    end
end

BF:RegisterIndicator(MissingRaidBuff)
MissingRaidBuff:EnableDeferredUpdates()

-- ============================================================
-- Combat-state hide/re-evaluate (plan §6.1 user decision).
--
-- The indicator is out-of-combat only (12.1), so it must hide
-- immediately on combat enter (not freeze the last-rendered state until
-- the next per-unit UA) and re-evaluate on combat exit. This used to be
-- conditional on the showMissingRaidBuffInCombat opt-in; now it always
-- applies.
--
-- Implementation: subscribe to PLAYER_REGEN_DISABLED / PLAYER_REGEN_ENABLED
-- via a dedicated event frame. On either event, call UpdateAllFrames so
-- every visible frame runs through MissingRaidBuff:_DoUpdate, which already
-- contains the correct in-combat gates (wantMissingCheck at the top of the
-- missing-detection block). On combat enter, every frame's gate will
-- evaluate to "don't check" and HideAll will fire. On combat exit, the
-- gate evaluates to "check" and the icon re-renders based on live tracker
-- state.
--
-- UpdateAllFrames goes through the deferred dispatcher's Update stub
-- (because the prototype's UpdateAllFrames calls self:Update, which was
-- replaced by EnableDeferredUpdates). That just marks every visible frame
-- dirty -- the actual _DoUpdate runs on the next OnUpdate flush. For an
-- immediate effect (HideAll on combat enter feels "instant"), we could
-- call _DoUpdate directly, but the one-frame deferral is imperceptible
-- and uses the existing batching infrastructure.
--
-- Combat-safe: PLAYER_REGEN_DISABLED fires entering combat, but the
-- dispatch path (mark dirty -> next OnUpdate -> _DoUpdate -> HideAll ->
-- mIcon:Hide + ants animation Stop) touches no protected APIs.
do
    -- v86 (event refactor stage 4): was a private CreateFrame. Both events
    -- are unitless, so this is a straight lift onto the shared layer.
    local combatEvents = BF:EventOwner("missingRaidBuffCombat")
    local function OnCombatChanged()
        if MissingRaidBuff.UpdateAllFrames then
            MissingRaidBuff:UpdateAllFrames()
        end
    end
    combatEvents:Sub("PLAYER_REGEN_DISABLED", OnCombatChanged, "unitless")
    combatEvents:Sub("PLAYER_REGEN_ENABLED",  OnCombatChanged, "unitless")
end
