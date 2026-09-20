--[[
BuzzardFrames: Auras/AuraGroupHelpers.lua
Shared helpers + group config schema for the addon-drawn buff/container
icon pools. Replaces parallel code in (deleted) BuffIcons.lua and
CustomContainers.lua + AuraCustomizations.lua's UpdateCustomBuffContainers.

v67 REACHABILITY NOTE. On 12.1 the engine renders live auras (AuraContainer
slot buttons styled by DeriveSpellButtonSpec), so nothing here runs per
combat tick. Two tiers survive:
  * BF:GetActiveAuraGroups / GetDefaultBuffGroupConfig / GetContainerGroupConfig
    are still called at LAYOUT time (BuffsAndContainers:Layout, for the dummy
    icon pools used by preview frames and by test/setup mode on real frames).
  * BF:BuildAuraGroupCtx, BF:HideUnusedBuffSlots, BF:HideBuffPool and
    BF:ResolveAnchorFrame are reached only through Auras/RenderAuraGroup.lua,
    which is preview-only.
Remaining "hot path" wording below is historical: these structures are kept
because previews need them, not for combat throughput.

Schema for a groupConfig (see plan section "Step 2"):

    groupConfig = {
        id                  : string,      -- "default_<groupTypeKey>" or "container_<ci>"
        kind                : string,      -- "buff" or "container"
        containerIndex      : number,      -- 0 for default; ci for containers
        configSource        : table|nil,   -- container struct ref (containers only)

        reverseOrder        : bool,
        canLiftAboveBar     : bool,
        previewDummies      : bool,
        sotFEligible        : bool,

        perSpellOverrides   : "spec"|"always"|false,
        geometrySource      : "ac"|"container",

        pool                : function(frame) -> table,
        hideHelper          : function(frame),
        hideUnusedSlots     : function(frame, lastUsed),
        dataKey             : number|string,

        _ctxPool            : table,
    }
]]

local BF  = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local pairs, ipairs, type, next = pairs, ipairs, type, next

local MAX_BUFFS = BF.MAX_BUFFS

-- ============================================================
-- SHARED HELPERS
-- ============================================================

local function isBottomAnchor(a)
    return a == "BOTTOM" or a == "BOTTOMLEFT" or a == "BOTTOMRIGHT"
end
BF._isBottomAuraAnchor = isBottomAnchor

-- ============================================================
-- ClearSotFGlow: stop SotF glow on a buff icon. Moved here from
-- the deleted Indicators/BuffIcons.lua so the unified pipeline
-- can call it without depending on a deleted file.
-- ============================================================
local function ClearSotFGlow(icon)
    if not icon._sotfGlow then return end
    local gt = icon._sotfGlowType or "button"
    if gt == "border" then
        icon._sotfBorderActive = nil
        local orig = icon._sotfOrigBorderColor
        if orig then
            BF.SetIconBorderColor(icon, orig[1], orig[2], orig[3], orig[4])
        else
            BF.SetIconBorderColor(icon, BF.GetDefaultBorderColorFor("buff"))
        end
        icon._sotfOrigBorderColor = nil
    end
    -- (Non-border styles were LibCustomGlow effects; the library was
    -- removed along with the SotF glow module, so only the border
    -- restore remains -- nothing can set a non-border _sotfGlowType.)
    icon._sotfGlow = false
    icon._sotfGlowType = nil
    icon._sotfGlowColor = nil
end
BF.ClearSotFGlow = ClearSotFGlow

-- ============================================================
-- HideUnusedBuffSlots: hide buffFrames slots past lastUsed,
-- clearing SotF glow + per-icon caches. Moved here from the
-- deleted Indicators/BuffIcons.lua.
-- ============================================================
function BF:HideUnusedBuffSlots(frame, lastUsed)
    if not frame.buffFrames then return end
    -- v67: UnregisterIconForBounce dropped (Bounce.lua deleted).
    for idx = lastUsed + 1, MAX_BUFFS do
        local icon = frame.buffFrames[idx]
        if icon then
            ClearSotFGlow(icon)
            if icon:IsShown() then icon:Hide() end
            icon.SF_LastIndex   = nil
            icon.auraInstanceID = nil
        end
    end
end

-- ============================================================
-- HideBuffPool: hide every buff icon on a frame (used by the
-- default group's hideHelper closure).
-- ============================================================
function BF:HideBuffPool(frame)
    if not frame.buffFrames then return end
    -- v67: UnregisterIconForBounce dropped (Bounce.lua deleted).
    for i = 1, #frame.buffFrames do
        local icon = frame.buffFrames[i]
        if icon then
            ClearSotFGlow(icon)
            if icon:IsShown() then icon:Hide() end
            icon.SF_LastIndex   = nil
            icon.auraInstanceID = nil
        end
    end
end

-- ============================================================
-- ResolveGroupTypeKey: returns the cached group-type key for the
-- frame, computing it on first call. Wraps the logic that used
-- to live in BuffIcons:Update / UpdateCustomBuffContainers.
-- ============================================================
function BF:ResolveGroupTypeKey(frame)
    local key = frame._bf_containerGroupTypeKey
    if key then return key end
    local parentHeader = frame._bf_parentHeader or frame:GetParent()
    if parentHeader and not frame._bf_parentHeader then
        frame._bf_parentHeader = parentHeader
    end
    local isCustom = parentHeader and parentHeader.isCustomFrame
    if isCustom then
        -- v61: key by the CFG flat's stable cfgFlatID, not by array position.
        -- Custom Frame Groups ARE flats, so there is one key space for
        -- per-scope container data: flat identity. The old positional key
        -- ("cfGroup_" .. customGroupIndex) was a live bug -- CFG deletion is a
        -- table.remove, so every later group's index shifted down by one and
        -- inherited its neighbor's per-group container settings.
        -- BFLayout.lua already stamps header._cfgFlat = grp.flat, so the ID is
        -- in hand; GetCFGFlatID is the backfill path for groups created before
        -- cfgFlatID existed whose ID the options UI has not minted yet.
        local cfgFlat = parentHeader._cfgFlat
        key = cfgFlat and cfgFlat.cfgFlatID
        if not key and BF.GetCFGFlatID then
            key = BF:GetCFGFlatID(parentHeader.customGroupIndex or 1)
        end
    else
        local flatID = BF:ResolveActiveFlat(BF:GetActiveSlot())
        key = (flatID and flatID ~= "none") and flatID or "flat_party"
    end
    -- v61: key can now be nil for a CFG header whose group has gone away
    -- mid-refresh. Every consumer already tolerates a nil groupTypeKey (it
    -- collapses the two-tier read to the shared container top level -- see
    -- ResolveGroupSource in AuraCustomizations.lua), and leaving the memo
    -- unset means the next render re-derives instead of caching the miss.
    frame._bf_containerGroupTypeKey = key
    local _isC = isCustom and true or false
    frame._bf_isCustomFlag = _isC
    -- The raid/party flags are gated on `not _isC`, so they were already false
    -- for CFG frames regardless of what the key string looked like; swapping
    -- the CFG key to an opaque cfgFlatID does not change them. The find()
    -- calls only ever see an RP flat ID.
    frame._bf_isRaidFlag   = (not _isC) and (key:find("raid") and true or false) or false
    frame._bf_isPartyFlag  = (not _isC) and (not frame._bf_isRaidFlag) and (key:find("party") and true or false) or false
    return key
end

-- ============================================================
-- ResolveAuraAnchorFrame: legacy helper retained for callers that
-- still want the live-resolved anchor frame. The unified renderer
-- uses the pre-resolved _bf_auraAnchorTarget + _bf_powerBarShown
-- pair instead; this is here for any non-refactored consumer.
-- ============================================================
function BF:ResolveAuraAnchorFrame(frame, ac)
    if ac.aurasAbovePowerBar and frame.powerBar and frame.powerBar:IsShown() and frame.healthBar then
        -- frame.container, not healthBar.clipFrame: the clip narrows while
        -- a reduced-max-health effect is active (AbsorbBars
        -- _UpdateReducedMaxHealth), which dragged lifted auras left with
        -- the health fill. See BF.AuraLiftAnchorFrame (ContainerFactory).
        return frame.container or frame.healthBar.clipFrame or frame.healthBar
    end
    return nil
end

-- ============================================================
-- ClearFrameHeaderDerivedCaches: wipe every per-frame cache that
-- depends on header identity. Called from BFLayout.lua's
-- header Reset() and from InvalidateContainerIconCaches.
--
-- Excluded:
--   _bf_auraAnchorTarget  (frame-constant)
--   _bf_powerBarShown     (maintained by PowerBar:Update)
-- ============================================================
function BF:ClearFrameHeaderDerivedCaches(frame)
    if not frame then return end
    -- Preview frames stamp their own _bf_containerGroupTypeKey and must
    -- not have it cleared here (mirrors the original guard in
    -- InvalidateContainerIconCaches).
    if not frame._isPreviewFrame then
        frame._bf_containerGroupTypeKey = nil
        frame._bf_isCustomFlag          = nil
        frame._bf_isRaidFlag            = nil
        frame._bf_isPartyFlag           = nil
    end
    frame._bf_containerHidden = nil
    frame._bf_activeGroups    = nil
    -- Aura icon POSITION caches are anchor-target-blind (SF_LastIndex /
    -- SF_LastOffset key on index+offset only — that's why PowerBar:Update
    -- must invalidate them on visibility flips). A header-identity change
    -- can flip the frame's groupTypeKey and with it canLiftAboveBar
    -- (aurasAbovePowerBar differing per layout), so a reused frame would
    -- keep rendering icons at the stale un-lifted offsets until reload
    -- (field report: lift dead after raid/party flips, /reload healed).
    -- Invalidate here so the first render on the new identity re-anchors.
    if BF.InvalidateAuraPositionCache then
        BF:InvalidateAuraPositionCache(frame)
    end
end

-- ============================================================
-- GROUP CONFIG CONSTRUCTORS
-- ============================================================

-- Default-buff group config pool, keyed by groupTypeKey. Two frames
-- on the same layout share the same config table; different layouts
-- get different tables (because aurasAbovePowerBar / buffAnchor can
-- differ per layout).
local _defaultGroupConfigPool = {}

-- Container group config pool, keyed by [ci][groupTypeKey].
local _containerGroupConfigPool = {}

-- Reusable hideHelper / hideUnusedSlots / pool closures for the default
-- group (one allocation per file load, not per groupConfig).
local function _defPool(frame) return frame.buffFrames end
local function _defHide(frame) BF:HideBuffPool(frame) end
local function _defHideUnused(frame, n) BF:HideUnusedBuffSlots(frame, n) end

-- Helper invalidator: GetActiveCustomBuffContainers + EnsureFetchBuffSettings
-- callers must invalidate the pools when settings change.
function BF:InvalidateAuraGroupConfigPools()
    for k in pairs(_defaultGroupConfigPool) do _defaultGroupConfigPool[k] = nil end
    for ci, inner in pairs(_containerGroupConfigPool) do
        for k in pairs(inner) do inner[k] = nil end
    end
end

-- ============================================================
-- BF:GetDefaultBuffGroupConfig(ac, groupTypeKey)
-- Returns a pooled groupConfig table for the default buffs group.
-- ============================================================
function BF:GetDefaultBuffGroupConfig(ac, groupTypeKey)
    local cached = _defaultGroupConfigPool[groupTypeKey]
    if cached and cached._ac == ac then return cached end

    -- v93: was `(ac and ac.db) or (BF.db and BF.db.profile) or {}`. The
    -- ac.db branch is gone with the field itself (see the BF.AuraCache
    -- declaration in Auras/AuraConfig.lua) — it only ever held
    -- BF.db.profile, which is exactly what the fallback already resolved
    -- to, so this reads the same table it always did.
    local db = (BF.db and BF.db.profile) or {}
    local buffAnchor = ac and ac.buffAnchor or "BOTTOMRIGHT"

    -- reverseOrder: Path B only (non-whitelisted spec). Resolve trackList
    -- via BF.GetTrackListForSpec.
    -- v67: comment no longer names FetchBuffData (function deleted).
    local trackList = BF.playerSpecID and BF.GetTrackListForSpec
                      and BF.GetTrackListForSpec(BF.playerSpecID)
    local reverseOrder = (not trackList) and (db.reverseBuffs == true) or false

    -- Per-spell overrides: "spec" if any cooldown-text overrides exist
    -- for the current spec, else false (render loop skips the lookup).
    local acP = BF.acDB and BF.acDB.profile
    local specCT = acP and acP.specSpellCooldownText
    local specTable = specCT and specCT[BF.playerSpecID]
    local hasOverrides = specTable and next(specTable) ~= nil and true or false

    local cfg = cached or {}
    cfg.id               = "default_" .. tostring(groupTypeKey)
    cfg.kind             = "buff"
    cfg.containerIndex   = 0
    cfg.configSource     = nil
    cfg.reverseOrder     = reverseOrder
    cfg.canLiftAboveBar  = (ac and ac.aurasAbovePowerBar == true) and isBottomAnchor(buffAnchor) or false
    cfg.previewDummies   = false
    cfg.sotFEligible     = (BF._sotfGlowActive and not BF._sotfSkipRegularBuffs) and true or false
    cfg.perSpellOverrides = hasOverrides and "spec" or false
    cfg.geometrySource   = "ac"
    cfg.pool             = _defPool
    cfg.hideHelper       = _defHide
    cfg.hideUnusedSlots  = _defHideUnused
    cfg.dataKey          = 0
    cfg._ctxPool         = cfg._ctxPool or {}
    cfg._ac              = ac
    _defaultGroupConfigPool[groupTypeKey] = cfg
    return cfg
end

-- ============================================================
-- BF:GetContainerGroupConfig(c, ci, ac, groupTypeKey)
-- Returns a pooled groupConfig for a custom container.
-- ============================================================
function BF:GetContainerGroupConfig(c, ci, ac, groupTypeKey)
    local inner = _containerGroupConfigPool[ci]
    if not inner then
        inner = {}
        _containerGroupConfigPool[ci] = inner
    end
    local cached = inner[groupTypeKey]
    if cached and cached._ac == ac and cached.configSource == c then return cached end

    -- Effective anchor: taken from the one shared geometry resolver's anchor
    -- return, not re-derived here.
    --
    -- v61: this site had its own copy of the per-Layout groupSettings lookup,
    -- used only to decide canLiftAboveBar. It was a fifth reader of the tier
    -- that BF:ResolveContainerGeometry already owns, and it would have drifted
    -- the moment the per-Layout gate moved off the per-container toggle onto
    -- the Buffs aura section. The resolver also adds the Buffs baseline tier
    -- (ac.buffAnchor) that the old local fallback chain skipped.
    local _, _, _, _, _, effectiveAnchor = BF:ResolveContainerGeometry(c, groupTypeKey, ac)
    -- v92: the resolver returns anchorPoint RAW, and a flow anchor
    -- ("BUFFS" / "BIGDEF" / "C:<key>") is not a frame point at all -- it means
    -- "flow inside that host's icons", where there is no bar to lift above and
    -- no bottom edge to test. isBottomAnchor already answers false for every
    -- one of those strings, so this is belt over braces; it is stated because
    -- the alternative is a reader inferring that a sentinel was considered and
    -- rejected as an anchor, which is the class of bug the v65 SetPoint crash
    -- came from.
    local flowAnchored = BF.IsFlowAnchorValue
        and BF.IsFlowAnchorValue(effectiveAnchor) or false

    local hasSpecOverrides = BF.ContainerHasSpecOverrides and BF:ContainerHasSpecOverrides(ci) or false

    local cfg = cached or {}
    cfg.id               = "container_" .. ci
    cfg.kind             = "container"
    cfg.containerIndex   = ci
    cfg.configSource     = c
    cfg.reverseOrder     = false
    cfg.canLiftAboveBar  = (ac and ac.aurasAbovePowerBar == true)
        and not flowAnchored and isBottomAnchor(effectiveAnchor) or false
    cfg.previewDummies   = true
    cfg.sotFEligible     = (BF._sotfGlowActive and BF._containerHasSotF
        and BF._containerHasSotF[c] == true) and true or false
    cfg.perSpellOverrides = hasSpecOverrides and "spec" or false
    cfg.geometrySource   = "container"
    -- Per-ci pool / hide closures. Pooled per-ci to avoid per-call closure
    -- allocation; cfg.containerIndex carries the index for the closure body.
    cfg.pool             = cfg.pool or function(frame)
        local p = frame.SF_CustomContainerIcons
        return p and p[ci]
    end
    cfg.hideHelper       = cfg.hideHelper or function(frame)
        if BF._HideContainerPool then BF._HideContainerPool(frame, ci, true) end
    end
    cfg.hideUnusedSlots  = cfg.hideUnusedSlots or function(frame, n)
        if BF._HideContainerPool then BF._HideContainerPool(frame, ci, true, n + 1) end
    end
    cfg.dataKey          = ci
    cfg._ctxPool         = cfg._ctxPool or {}
    cfg._ac              = ac
    inner[groupTypeKey]  = cfg
    return cfg
end

-- ============================================================
-- BF:GetActiveAuraGroups(frame)
-- Returns the per-frame array of groupConfig tables that need
-- rendering. Cached on frame._bf_activeGroups; cleared by
-- ClearFrameHeaderDerivedCaches.
-- ============================================================
function BF:GetActiveAuraGroups(frame)
    local list = frame._bf_activeGroups
    if list then return list end

    list = {}
    local ac = BF:GetAuraCacheForFrame(frame)
    local groupTypeKey = BF:ResolveGroupTypeKey(frame)
    local parentHeader = frame._bf_parentHeader or frame:GetParent()
    if parentHeader and not frame._bf_parentHeader then
        frame._bf_parentHeader = parentHeader
    end

    -- Default-buffs visibility: NOT gated by anything container-related.
    -- The invariant: showBuffs only ever hides default buffs.
    local defaultVisible = true
    if parentHeader and parentHeader.isCustomFrame and parentHeader.moduleShowBuffs == false then
        defaultVisible = false
    end
    if ac and ac.showBuffs == false then
        defaultVisible = false
    end
    if defaultVisible then
        list[#list + 1] = BF:GetDefaultBuffGroupConfig(ac, groupTypeKey)
    end

    -- Container groups: only if the top-tier spec gate passes.
    if BF.HasActiveContainerSpellsForCurrentSpec
       and BF:HasActiveContainerSpellsForCurrentSpec() then
        local containers = BF:GetActiveCustomBuffContainers()
        local isCustomFlag = frame._bf_isCustomFlag
        local isRaidFlag   = frame._bf_isRaidFlag
        local isPartyFlag  = frame._bf_isPartyFlag
        for ci, c in ipairs(containers) do
            -- Per-container spec gate: skip if no current-spec spells.
            if BF.ContainerHasSpecSpells and BF:ContainerHasSpecSpells(ci) then
                -- Per-container per-frame-type visibility (same logic as the
                -- legacy UpdateCustomBuffContainers visibility check).
                -- v65: the per-Layout branch is gated by the two-gate
                -- predicate (BF:IsContainerPerLayoutActive) -- THIS container's
                -- own perLayoutConfig flag, or the group's Buffs override flag
                -- on a CFG scope.
                -- v69: global Enabled gate first (never set on single buffs),
                -- mirroring the resolution in BuffsAndContainers.
                local hidden = not c.singleBuff and c.enabled == false
                if c.groupSettings and BF:IsContainerPerLayoutActive(groupTypeKey, c) then
                    local gs = c.groupSettings[groupTypeKey]
                    if gs and gs.showForGroupType == false then
                        hidden = true
                    end
                end
                -- v73 (owner): the shared-tier per-frame-type gate
                -- (showOnParty / showOnRaid / showOnCustomFrames) is removed
                -- with its UI -- a shared container shows on every frame
                -- kind. Stale stored flags are deliberately IGNORED.
                -- v62: single buffs gate on their own Spec condition (plan
                -- 3.67). Resolved here, at active-groups build time, so
                -- consumers see a shorter list and never evaluate the
                -- predicate themselves. (v67: the "Update hot path" this
                -- originally shortened is gone -- BuffsAndContainers:Update
                -- no longer walks the group list at all; the remaining
                -- consumer is Layout's dummy-pool pass.)
                -- (BF:ContainerHasSpecSpells above is already
                -- spec-gated for single buffs by EnsureFetchBuffSettings; this
                -- keeps the decision visible at the same site as every other
                -- container visibility rule.)
                if not hidden and not BF:IsSingleBuffVisibleForSpec(c) then
                    hidden = true
                end
                -- v65/v92: a FLOW-ANCHORED single buff renders inside its
                -- host's icons -- the regular buff row, Big Defensive, or
                -- another container -- not in a container group of its own, so
                -- it contributes no group here. Belt over
                -- EnsureFetchBuffSettings, which already withholds
                -- _fbsContainersWithSpecSpells[ci] for these (so
                -- ContainerHasSpecSpells above is false and the group would not
                -- have been built anyway) -- stated at the same site as every
                -- other container visibility rule rather than left to be
                -- inferred two files away.
                --
                -- v92: ANY host, not just Buffs. This list feeds the legacy /
                -- preview render pass, which hands the group's anchor straight
                -- to SetPoint -- so an entry whose anchorPoint is a sentinel
                -- must never reach it. EnsureFetchBuffSettings resolves the
                -- same way (v92 converted it to the host resolver too), so the
                -- two gates agree for every sentinel and this stays a belt.
                if not hidden and BF:GetSingleBuffAnchorHost(c, groupTypeKey) then
                    hidden = true
                end
                if not hidden then
                    list[#list + 1] = BF:GetContainerGroupConfig(c, ci, ac, groupTypeKey)
                end
            end
        end
    end

    frame._bf_activeGroups = list
    return list
end

-- ============================================================
-- BF:BuildAuraGroupCtx(groupConfig, ac, gen)
-- Builds (or reuses) the per-group ctx table consumed by
-- RenderContainerIcons. Generation-guarded: only rebuilds when
-- AuraCache._cacheGen changes for this groupConfig.
-- ============================================================
function BF:BuildAuraGroupCtx(groupConfig, ac, gen)
    local pool = groupConfig._ctxPool
    local ctx = pool.ctx
    if ctx and pool._gen == gen and pool._ac == ac then return ctx end
    ctx = ctx or {}
    pool.ctx  = ctx
    pool._gen = gen
    pool._ac  = ac

    -- Default-buff groups use this builder. Container groups pull their
    -- ctx directly from EnsureContainerSettings (cs.ctx) in RenderAuraGroup,
    -- so this builder is never invoked for them.
    local autoScale  = ac.buffAutoScale
    local timerScale = ac.buffTimerScale or 1.0
    local bSize      = ac._roundedBuffSize or 12
    ctx.showDur          = ac.showBuffDuration
    ctx.durationFont     = ac.buffDurationFont
    ctx.durationBorder   = ac.buffDurationBorder or "OUTLINE"
    ctx.computedFontSize = autoScale and 11 or (ac.buffFontSize or 11)
    ctx.computedFontScale= autoScale and (bSize / 12 * timerScale) or 1.0
    ctx.autoScale        = autoScale
    ctx.timerScale       = timerScale
    ctx.swipeDis         = ac.disableBuffSwipe
    ctx.sparkDis         = ac.disableBuffSpark
    ctx.revSwipe         = ac.reverseBuffSwipe
    ctx.expiringCurve    = ac.expiringCurveBuff
    ctx.colorBorder      = ac.buffColorAuraBorder == true
    ctx.fontColor        = ac.buffFontColor
    ctx.showStacks       = ac.showStackText ~= false
    ctx.stackAutoScale   = ac.stackAutoScale
    ctx.stackTimerScale  = ac.stackTimerScale or 1.0
    ctx.defaultBorderR   = ac._defBorder_buff_r or 0
    ctx.defaultBorderG   = ac._defBorder_buff_g or 0
    ctx.defaultBorderB   = ac._defBorder_buff_b or 0
    ctx.defaultBorderA   = ac._defBorder_buff_a or 0.8

    ctx.hasPerSpellOverrides = (groupConfig.perSpellOverrides ~= false) and true or false
    ctx.sotfCheck = groupConfig.sotFEligible == true
    -- v67: ctx.bounceCheck removed (Bounce.lua deleted; nothing reads it).
    -- Stamp the aura cache reference on the ctx so per-spell override
    -- resolvers (ResolveSpellCooldownText) can pick the right baseline
    -- per frame. CFG frames get a per-CFG ac; main RP frames get
    -- BF.AuraCache. This is a new ctx field, distinct from pool._ac
    -- (set above as the cache-validity check key).
    ctx._ac = ac
    return ctx
end

-- ============================================================
-- BF:LayoutAuraGroup(frame, groupConfig)
-- Single entry point for laying out a group's icons.
--   kind == "buff"      → font/cooldown stamping on frame.buffFrames
--   kind == "container" → ensure pool + cache settings (EnsureContainerSettings)
-- ============================================================
function BF:LayoutAuraGroup(frame, groupConfig)
    if groupConfig.kind == "buff" then
        if BF._LayoutDefaultBuffGroup then
            BF._LayoutDefaultBuffGroup(frame)
        end
    else
        -- Container: triggers EnsureContainerSettings + pool pre-allocation
        -- so the runtime path never has to lazy-build.
        if BF._LayoutContainerGroup then
            BF._LayoutContainerGroup(frame, groupConfig)
        end
    end
end

-- ============================================================
-- BF:ResolveAuraGroupAnchorTarget(frame, groupConfig)
-- Pre-resolved-per-frame, pre-resolved-per-group anchor target.
-- Helper for RenderAuraGroup (v67: preview-only, not a hot path).
-- ============================================================
function BF:ResolveAuraGroupAnchorTarget(frame, groupConfig)
    if groupConfig.canLiftAboveBar and frame._bf_powerBarShown then
        return frame._bf_auraAnchorTarget
    end
    return nil
end
