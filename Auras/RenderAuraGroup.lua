--[[
BuzzardFrames: Auras/RenderAuraGroup.lua
Per-group render dispatcher. Reads a single groupConfig (default
buffs OR a custom container) and pushes its pre-resolved arrays
through the shared RenderContainerIcons leaf.

v67: this whole file is PREVIEW-ONLY. On 12.1 the engine owns live
aura rendering (AuraContainer slot buttons styled via
DeriveSpellButtonSpec), so nothing on a live frame reaches here.
The only caller of BF:RenderAuraGroup is BF:RenderContainerGroupWithAuras
below, whose only callers are the options-preview sites in
AuraCustomizations.lua (:4244, :4417, :4444). Treat every "hot path"
/ "per-tick" claim in this file and in RenderContainerIcons.lua /
AuraGroupHelpers.lua as historical -- the code is kept because
previews need it, not because it runs in combat.

Public surface:
  BF:RenderAuraGroup(frame, unit, groupConfig, buffData)
  BF:RenderContainerGroupWithAuras(frame, groupConfig, auraList, previewSpecId)
  BF:HideAuraGroup(frame, groupConfig)
]]

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local ipairs = ipairs
local GetTime = GetTime

local MAX_BUFFS = BF.MAX_BUFFS

-- ============================================================
-- BF:RenderAuraGroup(frame, unit, groupConfig, buffData)
-- Per-group render entry. Settings have all been pre-resolved at
-- layout / cache-build time and live on the groupConfig + on the
-- frame; this function does only the minimal per-call work.
-- v67: preview-only (see the file header) -- reached solely via
-- BF:RenderContainerGroupWithAuras. The pre-resolution structure is
-- kept as-is, but it is no longer buying anything in combat.
-- ============================================================
function BF:RenderAuraGroup(frame, unit, groupConfig, buffData)
    if not buffData then return end
    local groupData = buffData._groupData and buffData._groupData[groupConfig.dataKey]
    if not groupData then
        -- No data for this group this pass: hide whatever was last shown.
        groupConfig.hideHelper(frame)
        return
    end

    local ac = BF:GetAuraCacheForFrame(frame)
    local gen = ac and ac._cacheGen or 0

    local n = groupData.n or 0
    if n == 0 then
        groupConfig.hideHelper(frame)
        return
    end

    -- Geometry + ctx + pool: ac for default group, EnsureContainerSettings-cached for containers.
    local size, offsets, anchor, offX, offY, maxIcons, groupTypeKey
    local ctx
    local pool
    if groupConfig.geometrySource == "ac" then
        size       = ac._roundedBuffSize or 12
        offsets    = ac._buffOffsets
        anchor     = ac.buffAnchor or "BOTTOMRIGHT"
        offX       = ac.buffOffsetX or 0
        offY       = ac.buffOffsetY or 0
        maxIcons   = ac.maxBuffs or MAX_BUFFS
        groupTypeKey = BF:ResolveGroupTypeKey(frame)
        ctx = BF:BuildAuraGroupCtx(groupConfig, ac, gen)
        -- Default-buff pool exists at frame creation (frame.buffFrames).
        pool = groupConfig.pool(frame)
        if not pool then return end
    else
        -- Container: pull settings + ctx from the EnsureContainerSettings cache.
        -- Its ctx already contains every container-specific field
        -- (showDur, durationFont, expiringCurve, defaultBorder, etc.). We
        -- overwrite hasPerSpellOverrides + sotfCheck so the per-group-config
        -- flags drive the render loop (instead of always-true for overrides
        -- and the cached container's SotF gate).
        local cs = BF._GetCachedContainerSettings and BF._GetCachedContainerSettings(
            groupConfig.containerIndex, groupConfig.configSource, ac,
            BF:ResolveGroupTypeKey(frame))
        if not cs then
            groupConfig.hideHelper(frame)
            return
        end
        size     = cs.size
        offsets  = cs.offsets
        anchor   = cs.anchor
        offX     = cs.offX
        offY     = cs.offY
        maxIcons = cs.maxIcons
        groupTypeKey = BF:ResolveGroupTypeKey(frame)
        ctx = cs.ctx
        -- Apply group-config-derived gates without mutating cs.ctx
        -- semantics across other frames (every frame consuming this
        -- container's settings agrees on these values for now).
        ctx.hasPerSpellOverrides = (groupConfig.perSpellOverrides ~= false) and true or false
        ctx.sotfCheck            = groupConfig.sotFEligible == true
        -- v67: ctx.bounceCheck removed (Bounce.lua deleted; nothing reads it).
        -- Per-spell override resolver picks its baseline from ctx._ac.
        -- The container ctx is shared across frames whose (ci, groupTypeKey)
        -- map to the same _auraCache, so a single stamp here is safe.
        ctx._ac                  = ac
        -- v62: single-buff container in hand for the PREVIEW (dummy) branch's
        -- cooldown-text resolve only -- the real-aura branches deliberately do
        -- not consult it (the 12.0.7 legacy live path renders single buffs
        -- with container-level visuals by owner decision; on 12.1 the live
        -- styling goes through DeriveSpellButtonSpec instead). Stamped
        -- unconditionally so a pooled ctx can never carry a stale container.
        local cSrc               = groupConfig.configSource
        ctx._sbC                 = (cSrc and cSrc.singleBuff) and cSrc or nil
        -- Ensure the pool exists and is large enough. This is the SOLE
        -- pool-resolution path for containers — we deliberately don't call
        -- groupConfig.pool(frame) earlier, because preview frames don't have
        -- frame.SF_CustomContainerIcons until _EnsureContainerIconPool
        -- lazily creates it. Reading the pool BEFORE ensure would early-exit
        -- for any preview frame that has never rendered this container before.
        if BF._EnsureContainerIconPool then
            pool = BF._EnsureContainerIconPool(frame, groupConfig.containerIndex,
                                               (n > maxIcons) and n or maxIcons)
        end
        if not pool then return end
    end

    -- Pre-resolved anchor target (per-group canLiftAboveBar AND per-frame
    -- _bf_powerBarShown). No IsShown call.
    local anchorFrame = nil
    if groupConfig.canLiftAboveBar and frame._bf_powerBarShown then
        anchorFrame = frame._bf_auraAnchorTarget
    end

    local rendered = BF.RenderContainerIcons(
        frame, unit, pool, n, maxIcons,
        groupData.textures, groupData.instanceIDs, groupData.expirations,
        groupData.durations, groupData.spellIDs,
        groupData.borderColors, groupData.stackCounts, groupData.isDummy,
        groupData.solidColors, groupData.iconTypes,
        size, offsets, anchor, offX, offY, anchorFrame,
        groupConfig.reverseOrder, groupTypeKey, ctx)

    groupConfig.hideUnusedSlots(frame, rendered or 0)
end

-- ============================================================
-- Preview scratch table. Kept separate from the production
-- _buffResult to avoid collisions with the live buff-collection
-- pass (which wipes _buffResult).
-- v67: comment no longer names FetchBuffData (function deleted).
-- ============================================================
local _previewBuffResult = {
    _groupData = {},
}
BF._previewBuffResult = _previewBuffResult

local function EnsurePreviewSlot(ci)
    local gd = _previewBuffResult._groupData[ci]
    if not gd then
        gd = {
            textures = {}, instanceIDs = {}, expirations = {},
            durations = {}, spellIDs = {}, borderColors = {},
            stackCounts = {}, solidColors = {}, iconTypes = {},
            isDummy = {}, n = 0,
        }
        _previewBuffResult._groupData[ci] = gd
    end
    return gd
end

-- ============================================================
-- BF:RenderContainerGroupWithAuras(frame, groupConfig, auraList, previewSpecId)
-- Renders a caller-provided aura list through the same primitive
-- as production. Used by the preview / setup-mode subsystem.
-- ============================================================
function BF:RenderContainerGroupWithAuras(frame, groupConfig, auraList, previewSpecId)
    if not frame or not groupConfig or not auraList then return end
    local gd = EnsurePreviewSlot(groupConfig.dataKey)

    local n = 0
    local GetSpellBorderColor = BF.GetSpellBorderColor
    -- v67: BF.GetBuffsBorderColor upvalue removed (12.0.7-only blanket
    -- "any buff" border color; the getter no longer exists).
    local GetSolidIconColor   = BF.GetSolidIconColor
    local GetSpellIconType    = BF.GetSpellIconType
    -- v62 (plan 3.67 slice 2): a single buff's visuals live on the CONTAINER
    -- (c.sbVisuals), not in the spec-keyed families, so the per-spell getters
    -- need the container passed as their sbC argument or the preview renders
    -- the plain icon while the 12.1 live path (DeriveSpellButtonSpec) shows
    -- the entry's own Icon Type / colors. configSource is the container for
    -- container groupConfigs and nil for the default group; only single-buff
    -- containers pass it through (a curated spell must keep the spec path).
    local cSrc = groupConfig.configSource
    local sbC  = (cSrc and cSrc.singleBuff) and cSrc or nil
    local specId = previewSpecId or BF.playerSpecID
    -- Spec-aware per-spell lookups: when previewing a non-current spec,
    -- temporarily swap BF.playerSpecID so the existing helpers consult
    -- the right spec's settings. Restored after the pre-resolve loop.
    -- v74: explicit `swapped` sentinel, not truthiness of savedSpec. When the
    -- real playerSpecID was NIL (specless character / pre-prime window), the
    -- old `if savedSpec then` restore never ran and BF.playerSpecID stayed
    -- stranded on the PREVIEW spec for the rest of the session -- and the
    -- container creation-relevance vector (BuildContainerRelevance) now
    -- decides which engine containers real frames even get from that field,
    -- so a stranded spec would build the wrong container set.
    local savedSpec, swapped
    if previewSpecId and previewSpecId ~= BF.playerSpecID then
        savedSpec = BF.playerSpecID
        swapped = true
        BF.playerSpecID = previewSpecId
    end

    for i = 1, #auraList do
        local a = auraList[i]
        if a then
            local sid = a.spellId
            gd.textures[i]   = a.icon
            gd.instanceIDs[i]= a.auraInstanceID
            gd.expirations[i]= a.expirationTime
            gd.durations[i]  = a.duration
            gd.spellIDs[i]   = sid
            gd.isDummy[i]    = a._isDummy
            gd.stackCounts[i]= a.applications
            local bc = sid and GetSpellBorderColor and GetSpellBorderColor(sid, sbC)
            gd.borderColors[i] = bc or false
            local sc = sid and GetSolidIconColor and GetSolidIconColor(sid, sbC)
            gd.solidColors[i] = sc or false
            -- v69: the gd.iconTypes ARRAY vocabulary is "Square" /
            -- "BorderedSquare" ("square with a border") — the stored type
            -- plus the entry's Show Border flag map INTO it here, so the
            -- Lua-drawn preview path renders the border without learning
            -- the flag. Legacy stored "SquareDuration" collapses to
            -- Square (this path draws a static solid stand-in either
            -- way); legacy "BorderedSquare" passes through unchanged.
            local ity = (sid and GetSpellIconType and GetSpellIconType(sid, sbC)) or false
            if ity == "SquareDuration" then ity = "Square" end
            if ity == "Square" and sc and sc.showBorder then
                ity = "BorderedSquare"
            end
            gd.iconTypes[i]  = ity
            n = i
        end
    end
    gd.n = n

    if swapped then
        BF.playerSpecID = savedSpec
    end

    BF:RenderAuraGroup(frame, frame.unit or "player", groupConfig, _previewBuffResult)
end

-- ============================================================
-- BF:HideAuraGroup(frame, groupConfig)
-- Thin wrapper over the group's pre-bound hide closure. Public
-- surface for callers that should not reach into the config.
-- ============================================================
function BF:HideAuraGroup(frame, groupConfig)
    if not frame or not groupConfig then return end
    groupConfig.hideHelper(frame)
end
