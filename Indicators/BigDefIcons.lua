--[[
BuzzardFrames: Indicators/BigDefIcons.lua
Big Defensive icon indicator — renders big defensive buff icons.

Grid2 pattern: indicator bound to the bigdef status. When bigdef's
UNIT_AURA handler calls self:UpdateIndicators(unit), this indicator's
Update method runs.

v67 (12.1-only): :Update no longer scans auras in Lua. BigDef:GetIcons was
deleted from Statuses/Auras.lua; :Update now resolves the show gate,
ensures the feature AuraContainer exists, and hands off to
BF:SyncAuraGridContainer(frame, "bigDef", unit, show) — the engine
container tracks, filters and renders natively.

Icon pool is pre-allocated by ApplyAuraGeometry (AuraConfig.lua).
]]

local BF  = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local ipairs           = ipairs
local pairs            = pairs
local issecretvalue    = issecretvalue  or function() return false end
local canaccessvalue   = canaccessvalue or function() return true  end
local UnitIsVisible    = UnitIsVisible
-- v92: the assist gate for anchored single-buff groups (:Update, §A5).
local UnitCanAssist    = UnitCanAssist

local SetIconBorderColor   = BF.SetIconBorderColor

-- v67: file-local _bigdefStatus upvalue removed (12.1-only). Its only
-- reader was the deleted BigDef:GetIcons render pass; grepped to zero
-- references in this file.

local BigDefIcons = BF.indicatorPrototype:new("bigDefIcons")

-- Per-indicator Create: build the big-defensive icon pool.
function BigDefIcons:CanCreate(parent) return not parent._isPreviewFrame end
-- Container path: the container is the indicator's widget (Layout
-- dispatch loops gate on GetFrame — see BuffsAndContainers:GetFrame).
function BigDefIcons:GetFrame(parent)
    return parent.bigDefIcons
        or (parent._bf_auraContainers and parent._bf_auraContainers.bigDef)
end

-- ============================================================
-- 12.1 CONTAINER PATH
-- Two mutually exclusive groups via 12.1 filter negation — the old
-- two-filter fetch + instanceID dedup collapses into filter construction.
-- The bigDefShowGlow LCG glow is CUT on this path (no container affordance).
-- ============================================================
local function BigDefContainerSpecs(parent)
    local ac = BF:GetAuraCacheForFrame(parent)
    local db = BF:GetSectionProfileForFrame("tooltips", parent)
    local size = ac._roundedBigDefSize or 24
    local autoScale = ac.bigDefAutoScale
    local buttonSpec = {
        size             = size,
        showDuration     = ac.showBigDefDuration and true or false,
        durationFont     = ac.bigDefDurationFont,
        durationFontSize = autoScale and 11 or (ac.bigDefFontSize or 11),
        durationBorder   = ac.bigDefDurationBorder or "OUTLINE",
        durationScale    = autoScale and (size / 12 * (ac.bigDefTimerScale or 1.0)) or nil,
        fontColor        = ac.bigDefFontColor,
        durationCurve    = ac.expiringCurveBigDef,
        hideDurationAbove1Min = ac.hideDurAbove1MinBigDef,
        disableSwipe     = ac.disableBigDefSwipe,
        disableSpark     = ac.disableBigDefSpark,
        reverseSwipe     = ac.reverseBigDefSwipe,
        dispelBorder     = false,  -- helpful auras; keep the base border
        borderColor      = ac.bigDefBorderColor,
        blizzardBorders  = ac.bigDefBlizzardBorders,
        borderStyle      = ac.bigDefBorderStyle,
        showGlow         = ac.bigDefShowGlow,  -- v34: presence glow (glows while an aura is displayed)
        -- Glow Color / Glow Style (owner): straight into the fields ApplyGlow
        -- (Auras/ContainerFactory.lua) already renders for the per-spell Icon
        -- Effects glow -- array {r,g,b,a} color, boolean pulse.
        glowColor        = ac._bigDefGlowRGBA,
        glowPulse        = ac.bigDefGlowStyle == "pulse",
        -- Owner: slightly larger ring than the shared default -- at Big
        -- Defensive sizes the shared pad reads as inset from the icon border.
        -- v93b/c: 0.26 -> 0.32 -> 0.42, tracking the shared default's
        -- 0.2 -> 0.26 -> 0.34 bumps (owner: the Big Defensive ring kept
        -- reading small), so this stays proportionally larger than the
        -- shared ring as intended. The value itself now lives with the
        -- other glow geometry at the top of Auras/ContainerFactory.lua --
        -- change ring sizes there, not here.
        glowPad          = BF.AURA_GLOW_PAD_BIGDEF,
        borderThickness  = ac.bigDefBorderThickness,
        tooltipEnabled   = ac.showBigDefTooltip or false,
        tooltipInCombat  = ac.showBigDefTooltipInCombat or false,
        tooltipPos       = db and db.bigDefTooltipPosition or "default",
        tooltipFrameY    = BF.TooltipBelowFrameY(parent, ac.bigDefAnchor, ac.bigDefOffsetY, size),
    }
    -- Stack text (Aura Text > Stack Text). Folded onto the button spec so
    -- ContainerFactory's ApplyStackCountStyle can stamp it at creation and
    -- on every restyle walk -- see BF:ApplyStackTextSpec.
    BF:ApplyStackTextSpec(buttonSpec, ac, size)
    local geo = {
        size          = size,
        anchor        = ac.bigDefAnchor,
        offsetX       = ac.bigDefOffsetX,
        offsetY       = ac.bigDefOffsetY,
        growDirection = ac.bigDefGrowDirection,
        perRow        = ac.bigDefIconsPerRow,
        spacing       = ac.bigDefSpacing,
        rowSpacing    = ac.bigDefRowSpacing,
        maxIcons      = ac.bigDefMaxCount or 1,
        canLift       = true,  -- aurasAbovePowerBar (resolved in ApplyAuraGridGeometry)
    }
    -- v92 §A4: the wrap budget for single buffs anchored to Big Defensive.
    -- The twin of BuffGeneralGeo's slack, and NOT optional: the wrap boundary
    -- is perRow*size in PIXELS, so one over-sized sb group eats the budget and
    -- wraps the line an icon early -- PTR-observed on the debuff path as big
    -- icons overlapping the neighboring group. bigDef carried no slack at all
    -- before this feature because every icon in it was the same size.
    local m = BF.MaxSingleBuffSizeFor and BF.MaxSingleBuffSizeFor(ac,
        BF.ResolveGroupTypeKey and BF:ResolveGroupTypeKey(parent), "bigDef")
    if m and size > 0 and m > size then geo.lineSizeSlack = m - size end
    return buttonSpec, geo
end

function BigDefIcons:Create(parent)
    -- Preview frames: plain icon pools only (dummy pipeline; no containers).
    if not parent._isPreviewFrame then
        if parent._bf_auraContainers and parent._bf_auraContainers.bigDef then return end
        -- v72 PERF: and no container for a frame that is not in service yet
        -- (never assigned a unit). Costs nothing to defer: :Update below
        -- already calls BF:EnsureFeatureAuraContainer on the first pass that
        -- sees the feature enabled, and that pass can only happen once the
        -- frame HAS a unit. See Auras/ContainerFactory.lua for the numbers.
        if BF:ShouldDeferFrameAuraContainers(parent) then return end
        -- v53 PERF: no container for a feature that is OFF in this frame's
        -- profile. Container creation is legal at any unrestricted moment,
        -- so :Update creates it on the first pass that sees the feature
        -- enabled (BF:EnsureFeatureAuraContainer).
        -- 2026-09-11 (field report 2026-09-10): the old NOTE here said CFG
        -- frames read the GLOBAL cache at this point and "simply create it on
        -- first Update". While restricted (a reload inside a keystone) that
        -- Update only queues into pendingCreates, which drains unrestricted, so
        -- a CFG that enables the feature had no Big Defensive for the whole
        -- key. CFG children are now created after their header carries its CFG
        -- identity (v86, ConfigureCustomFrameHeader), and GetAuraCacheForFrame
        -- builds a missing CFG flat cache on demand, so this reads the CFG's
        -- own value.
        if BF:GetAuraCacheForFrame(parent).showBigDef ~= true then return end
        local buttonSpec, geo = BigDefContainerSpecs(parent)
        BF:EnsureAuraGridContainer(parent, "bigDef", {
            frameLevelOffset = 224,  -- legacy: BuildAuraIconFrame(parent, level + 1)
            buttonSpec    = buttonSpec,
            maxFrameCount = geo.maxIcons,
            sortMethod    = AuraContainerSortMethod.BigDefensive,
            spacing       = geo.spacing,
            rowSpacing    = geo.rowSpacing,
            -- v79: ONE group carrying BOTH categories, not two.
            --
            -- maxFrameCount is a PER-GROUP cap and the engine has no
            -- container-level total, so the old bd + ext split gave Max
            -- Defensives to EACH group: "2" displayed up to FOUR icons. Owner-
            -- observed as four icons on a frame with the setting at 2.
            --
            -- One group means one cap, honored exactly. No duplicates: within a
            -- group an aura is a single candidate and is assigned once, so an
            -- aura flagged BOTH categories takes one slot. That is also what the
            -- old `!BIG_DEFENSIVE` on `ext` was for -- it existed solely to keep
            -- the two groups disjoint (cross-group overlap is deduped but the
            -- WINNER is engine-unspecified), and it is unnecessary here.
            --
            -- Ordering now comes from AuraContainerSortMethod.BigDefensive
            -- above, rather than from big-defensives being registered first.
            --
            -- v85 (2026-08-15): the v79 PTR-VERIFY resolved AGAINST the OR
            -- assumption. Owner-observed: with
            -- "HELPFUL|BIG_DEFENSIVE|EXTERNAL_DEFENSIVE" only EXTERNALS
            -- rendered -- same-family positive tokens AND (intersect), and
            -- externals carry BOTH flags while personal CDs carry only
            -- BIG_DEFENSIVE. That same observation implies EXTERNAL_DEFENSIVE
            -- is a SUBSET of BIG_DEFENSIVE, so the whole union is expressible
            -- as BIG_DEFENSIVE alone -- one group, one exact Max Defensives
            -- cap (the entire point of the v79 merge), no curated list, no
            -- candidate-filter carve-out exposure. candidateFilters cannot
            -- express a category union (no category booleans exist and
            -- candidates only narrow WITHIN the filter's matches), so this
            -- subset filter is the only single-group form.
            -- PTR-VERIFY: an external defensive NOT flagged BIG_DEFENSIVE
            -- would no longer render -- if one is ever observed missing, the
            -- fallback is the two disjoint groups (per-category caps).
            groups = {
                { key = "bd", filter = "HELPFUL|BIG_DEFENSIVE" },
            },
        })
        BF:ApplyAuraGridGeometry(parent, "bigDef", geo)
        return
    end
    parent.bigDefIcons = parent.bigDefIcons or {}
    local level = parent:GetFrameLevel() + 223
    local ac = BF:GetAuraCacheForFrame(parent)
    local db = BF:GetSectionProfileForFrame("tooltips", parent)
    local enabled = ac and ac.showBigDefTooltip or false
    local combat  = ac and ac.showBigDefTooltipInCombat or false
    local pos     = db and db.bigDefTooltipPosition or "default"
    -- BigDef icons render on OVERLAY draw layer so they cover the timer
    -- text of any underlying aura (preserves pre-refactor AuraConfig.lua:377).
    for i = 1, BF.MAX_BIG_DEF do
        if not parent.bigDefIcons[i] then
            local icon = BF.BuildAuraIconFrame(parent, level + 1)
            if icon.Icon then icon.Icon:SetDrawLayer("OVERLAY", 1) end
            parent.bigDefIcons[i] = icon
            self:EnableFrameTooltips(icon, enabled, combat, pos)
        end
    end
end

-- v67: BigDefIcons:UpdateFrameSettings removed (12.1-only). Tooltip bindings
-- are baked per container button, so this returned before touching the icon
-- pool on every 12.1 call. Its only dispatcher, BF:DispatchTooltipSettings,
-- was deleted along with the other three empty UpdateFrameSettings methods.

-- Per-scope cache write. Owns big-def geometry + bigDefColorAuraBorder
-- (lives in auraText behind useGlobal switch).
function BigDefIcons:UpdateDB(cache, flat, grp)
    -- v60: resolved per aura sub-category. The Buffs and Debuffs
    -- per-layout toggles are independent, so a flat's auras table can
    -- carry stale rawkeys for whichever group is currently OFF --
    -- ResolveCFGSection(..., "auras") plus an index would read them.
    local bdP    = BF.ResolveCFGAurasSubcat(BF, flat, grp, "bigDef") or {}
    cache.showBigDef          = bdP.showBigDef == true
    cache.bigDefSize          = bdP.bigDefSize or 24
    cache.bigDefAnchor        = bdP.bigDefAnchor or "CENTER"
    cache.bigDefOffsetX       = bdP.bigDefOffsetX or 0
    cache.bigDefOffsetY       = bdP.bigDefOffsetY or 0
    cache.bigDefIconsPerRow   = bdP.bigDefIconsPerRow or 5
    cache.bigDefSpacing       = bdP.bigDefSpacing or 1
    cache.bigDefRowSpacing    = bdP.bigDefRowSpacing or 1
    cache.bigDefGrowDirection = BF.NormalizeGrowDirection(
        bdP.bigDefGrowDirection or "RIGHT", cache.bigDefAnchor)
    cache.bigDefShowGlow      = bdP.bigDefShowGlow == true
    -- Glow Color / Glow Style (owner). The color is pre-converted to the
    -- array shape ApplyGlow's spec.glowColor consumes ({r,g,b,a} table ->
    -- {c[1..4]}), once per cache rebuild rather than per Layout.
    local gc = bdP.bigDefGlowColor
    cache._bigDefGlowRGBA     = gc and { gc.r or 1, gc.g or 1, gc.b or 1, gc.a or 1 } or nil
    cache.bigDefGlowStyle     = bdP.bigDefGlowStyle or "steady"
    cache.bigDefMaxCount      = bdP.bigDefMaxCount or 1
    cache._roundedBigDefSize  = BF:PixelRound(cache.bigDefSize)
    cache.bigDefBorderColor     = bdP.bigDefBorderColor
    cache.bigDefBorderThickness = bdP.bigDefBorderThickness or 1
    cache.bigDefBlizzardBorders = bdP.bigDefBlizzardBorders == true
    cache.bigDefBorderStyle     = bdP.bigDefBorderStyle

    -- bigDefColorAuraBorder: setting REMOVED (12.1 cut) — forced false.
    cache.bigDefColorAuraBorder = false

    local ttp = BF.ResolveCFGSection(BF, flat, grp, "tooltips") or {}
    cache.showBigDefTooltip         = ttp.showBigDefTooltip or false
    cache.showBigDefTooltipInCombat = ttp.showBigDefTooltipInCombat or false
end

-- Grid2 pattern: stamp cooldown config + color curve targets onto icon
-- frames at Layout time. Update loop then only calls
-- SetCooldownFromExpirationTime + UpdateIconColorCurve (2 args each).
-- v67: 12.0.7 branch removed (addon is 12.1-only).
function BigDefIcons:Layout(parent)
    if not parent._isPreviewFrame then
        if not (parent._bf_auraContainers and parent._bf_auraContainers.bigDef) then
            self:Create(parent)
        end
        local buttonSpec, geo = BigDefContainerSpecs(parent)
        BF:ApplyAuraGridGeometry(parent, "bigDef", geo)
        BF:ApplyAuraGridButtonSpec(parent, "bigDef", buttonSpec)
        -- ── v92 §A5: single buffs anchored to Big Defensive ────────────────
        -- Their sb<key> groups live in THIS container, but all single-buff
        -- maintenance lives in BuffsAndContainers (ApplySingleBuffGroups), so
        -- the emit is exported there and called from both sides: from
        -- ApplyBuffFilters, and from here -- because big-defensive creation and
        -- the scoped BF:RefreshBigDefOnly path never go through that function.
        --
        -- AFTER ApplyAuraGridGeometry: the emit re-points `bd`'s layoutIndex
        -- and pushes per-group layout tables, both of which are rebuilt from
        -- the container's retained _bf_lastGeo. A no-op (one field read) until
        -- the container exists, and cheap when nothing is anchored here.
        --
        -- The container-level restyle above never touches the sb groups: they
        -- carry their own _bf_groupSpecs entry, which is exactly what
        -- ApplyAuraGridButtonSpec's walk skips.
        if BF.ApplyBigDefAnchoredGroups then
            BF.ApplyBigDefAnchoredGroups(parent, BF:GetAuraCacheForFrame(parent))
        end
    end
    -- Fall through for the dummy icon pools (preview/test mode): they
    -- still need the font/scale stamping below.
    if not parent.bigDefIcons then return end
    local ac = BF:GetAuraCacheForFrame(parent)
    for i = 1, #parent.bigDefIcons do
        local icon = parent.bigDefIcons[i]
        -- Clear cached index so Update repositions with the new offset table.
        icon.SF_LastIndex = nil
        if icon.cooldown then
            local cd = icon.cooldown
            cd:SetDrawSwipe(not ac.disableBigDefSwipe)
            cd:SetDrawEdge(not ac.disableBigDefSpark)
            cd:SetReverse(ac.reverseBigDefSwipe or false)
            cd:SetHideCountdownNumbers(not ac.showBigDefDuration)
            -- Grid2 pattern: re-fetch if not yet available
            if ac.showBigDefDuration and not cd.timerText then
                cd.timerText = cd:GetCountdownFontString()
            end
            local tt = cd.timerText
            if tt then
                local fontPath = ac.bigDefDurationFont or "Interface\\AddOns\\BuzzardFrames\\Media\\Fonts\\RobotoCondensed-Bold.ttf"
                local autoScale = ac.bigDefAutoScale
                local fontSize = autoScale and 11 or (ac.bigDefFontSize or 11)
                local fontBorder = ac.bigDefDurationBorder or "OUTLINE"
                local timerScale = autoScale and ((ac._roundedBigDefSize or 24) / 12 * (ac.bigDefTimerScale or 1.0)) or 1.0
                cd._bf_font   = fontPath
                cd._bf_size   = fontSize
                cd._bf_border = fontBorder
                cd._bf_scale  = timerScale
                tt:SetFont(fontPath, fontSize, fontBorder)
                tt:SetScale(timerScale)
                tt:ClearAllPoints()
                tt:SetPoint("CENTER", cd, "CENTER", 0, 0)
                local fc = ac.bigDefFontColor
                if fc then
                    cd._bf_textR = fc.r or 1
                    cd._bf_textG = fc.g or 1
                    cd._bf_textB = fc.b or 1
                    cd._bf_textA = fc.a or 1
                    tt:SetTextColor(fc.r or 1, fc.g or 1, fc.b or 1, fc.a or 1)
                else
                    cd._bf_textR = 1
                    cd._bf_textG = 1
                    cd._bf_textB = 1
                    cd._bf_textA = 1
                    tt:SetTextColor(1, 1, 1, 1)
                end
            end
            -- Color curve config (Grid2 pattern: stamp on icon)
            icon.colorCurveObject = ac.expiringCurveBigDef
            icon.colorCurveText = tt
            icon.colorCurveBorder = (ac.bigDefColorAuraBorder == true) and true or nil
        end
    end
end

-- ============================================================
-- HideAll: hide all BigDef icons + stop glows.
-- Called when the feature is disabled or unit is unreachable.
-- ============================================================
function BigDefIcons:HideAll(frame)
    if not frame.bigDefIcons then return end
    for i = 1, #frame.bigDefIcons do
        local icon = frame.bigDefIcons[i]
        if icon:IsShown() then
            icon:Hide()
        end
        -- Clear change-guard state so repositioning works when icons reappear.
        icon.SF_LastSlot = nil
        icon.SF_LastOffX = nil
        icon.SF_LastOffY = nil
    end
end

-- ============================================================
-- Update: unit-sync + feature-gate for the bigDef AuraContainer.
-- v67 (12.1-only): no Lua aura scan and no status:GetIcons call — the
-- container tracks, filters and renders natively. This resolves the show
-- gate, creates the container on first enable, and calls
-- BF:SyncAuraGridContainer.
-- ============================================================
function BigDefIcons:Update(frame, unit)
    if frame._isPreviewFrame then return end
    local ac2 = BF:GetAuraCacheForFrame(frame)
    local ph = frame._bf_parentHeader or frame:GetParent()
    local moduleOff = ph and ph.isCustomFrame and ph.moduleShowBigDef == false
    -- v93: hostile/charmed suppression (Auras/ContainerFactory.lua). The owner
    -- ruling is "nothing at all on a hostile unit", so the whole container
    -- follows.
    --
    -- v94 (owner ruling 2026-08-23): `canAssist` joins it, in the SAME term,
    -- for the same reason -- Big Defensive shows NOTHING on a unit we cannot
    -- assist. This is exactly what the buffs row has always done
    -- (BuffsAndContainers:Update, `wantBuffs`), and it is what the per-group
    -- assist gate below used to work around. `bd` being token-driven is not a
    -- license to keep it on screen there: the ruling is about the DISPLAY, not
    -- about which groups happen to survive the engine's identity carve-out.
    --
    -- Both terms are RENDER gates and neither is ever a park trigger: a unit
    -- that is hostile, charmed or unassistable reverts in seconds, and all a
    -- transient state may do is take the container to shown = false. Parking
    -- is for durable config only -- see "NEVER PARK A TRANSIENT STATE" in
    -- Auras/ContainerFactory.lua.
    --
    -- Plain boolean; UnitCanAssist is not a secret value. One call per Update.
    local canAssist  = (not BF.GateOn("assist")) or BF.PlayerCanAssistUnit(unit)  -- v99
    local suppressed = BF:IsUnitAuraSuppressed(unit)
    local show = (ac2.showBigDef == true) and not moduleOff
        and canAssist and not suppressed
    -- v53 PERF: create-on-first-enable (see :Create). Two table
    -- indexes once the container exists.
    if ac2.showBigDef == true then
        BF:EnsureFeatureAuraContainer(frame, "bigDef", self)
    end
    BF:SyncAuraGridContainer(frame, "bigDef", unit, show)
    -- ── v92 §A5 / v94: BIG-DEFENSIVE-ANCHORED SINGLE BUFFS ───────────────
    -- The per-group ASSIST GATE that lived here is GONE (owner ruling
    -- 2026-08-23). It parked the sb groups with SetAuraGridGroupDormant on a
    -- TRANSIENT unit state and re-stamped their includeSpellIDs on every
    -- unpark -- and unparking clears the candidate set to {}, so a re-stamp
    -- refused in a restricted or secret-aura window left the group live on its
    -- bare caster-scope filter ("HELPFUL|PLAYER" and friends), rendering every
    -- buff on the unit into the Big Defensive display. The dormancy flag had
    -- already been committed by then, so the `~= want` guard never fired again
    -- and the junk stayed for the session. Owner-observed on a dungeon zone-in.
    --
    -- The replacement is not a safer park: `canAssist` is now part of the
    -- container's `show` term above, so the WHOLE container hides on a unit we
    -- cannot assist -- the buffs row's long-standing shape. Transient unit
    -- state takes a container to shown = false; parking is for durable config
    -- (a display turned off, a layout change, a preset removed, a host moved).
    -- See "NEVER PARK A TRANSIENT STATE" in Auras/ContainerFactory.lua.
    --
    -- What remains is NOT a gate: the container can be born HERE by
    -- create-on-first-enable with no :Layout following it, so its anchored
    -- entries have to be emitted once. Every later change arrives as a Layout.
    -- Cost when nothing is anchored here: one field read and one nil test.
    local cc = frame._bf_auraContainers and frame._bf_auraContainers.bigDef
    if cc and not cc._bf_sbInit and not BF:IsAuraCreationRestricted() then
        -- Restriction-gated like every other creation site -- while auras are
        -- restricted the flag stays down and a later pass retries.
        --
        -- v94: the flag is set AFTER the emit, not before. Setting it first
        -- meant an emit that threw, or that ran before its buckets were
        -- collected, latched the flag on a container that never got its groups
        -- -- and nothing retried.
        if BF.ApplyBigDefAnchoredGroups then
            BF.ApplyBigDefAnchoredGroups(frame, ac2)
        end
        cc._bf_sbInit = true
    end
end

BF:RegisterIndicator(BigDefIcons)
BigDefIcons:EnableDeferredUpdates()
