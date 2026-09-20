--[[
BuzzardFrames: Auras/RenderContainerIcons.lua
Unified icon render loop for the addon-drawn buff/container icon pools.

v67: PREVIEW-ONLY. BF.RenderContainerIcons has exactly one caller,
Auras/RenderAuraGroup.lua:BF:RenderAuraGroup, which is itself reached
only from the options-preview entry BF:RenderContainerGroupWithAuras.
Live aura rendering on 12.1 is done by the engine's AuraContainer slot
buttons (styled via DeriveSpellButtonSpec in Indicators/), never here.
Comments below that talk about per-frame / per-icon cost are historical:
the code is retained because previews need it, not for combat throughput.

RenderIcons() uses inline cooldown application (Grid2 pattern: stamp
config at Layout, call SetCooldownFromExpirationTime +
UpdateIconColorCurve at update time). Per-spell overrides stamp cooldown
properties on the icon when the spell changes.

The caller is responsible for:
  - Pool management (frame.buffFrames vs SF_CustomContainerIcons[ci])
  - Hiding unused slots after RenderIcons returns
  - Building the ctx table with cooldown/stack/border/SotF settings
  - Resolving anchorFrame (e.g. for aurasAbovePowerBar)
]]

local BF  = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local canaccessvalue = canaccessvalue or function() return true end
local issecretvalue  = issecretvalue  or function() return false end

-- ============================================================
-- Lazy upvalue resolution (not available at load time)
-- ============================================================
local SetIconBorderColor
local ApplyIconTextureOrSolid
local ResolveSpellCooldownText
local GetSpellIconType
local GetSpellBorderColor
local ApplySotFGlow
local UpdateSolidIconColorCurve
-- v67: RegisterIconForBounce upvalue removed (Bounce.lua deleted).

local function ResolveUpvalues()
    SetIconBorderColor       = BF.SetIconBorderColor
    ApplyIconTextureOrSolid  = BF.ApplyIconTextureOrSolid
    ResolveSpellCooldownText = BF.ResolveSpellCooldownText
    GetSpellIconType         = BF.GetSpellIconType
    GetSpellBorderColor      = BF.GetSpellBorderColor
    ApplySotFGlow            = BF.ApplySotFGlow
    UpdateSolidIconColorCurve = BF.UpdateSolidIconColorCurve
end

-- ============================================================
-- RenderIcons: Unified per-icon render loop.
--
-- Arguments:
--   frame        - the unit frame
--   unit         - unit token (e.g. "party1")
--   pool         - icon array (frame.buffFrames or SF_CustomContainerIcons[ci])
--   nIcons       - number of source icons available
--   maxIcons     - max visible cap
--   srcTex       - parallel array: textures
--   srcIID       - parallel array: instance IDs
--   srcExp       - parallel array: expirations
--   srcDur       - parallel array: durations
--   srcSID       - parallel array: spell IDs
--   srcBorders   - parallel array: pre-resolved border colors (nil = resolve inline)
--   srcStacks    - parallel array: stack counts (pre-resolved)
--   srcDummy     - parallel array: isDummy flags (nil for default container)
--   srcSolid     - parallel array: pre-resolved solid icon colors (nil = inline fallback)
--   srcIconTypes - parallel array: pre-resolved icon types (nil = inline fallback)
--   size         - icon size in pixels
--   offsets      - position offset table (from CalcContainerOffsets or _buffOffsets)
--   anchor       - anchor point string ("BOTTOMRIGHT", etc.)
--   offX, offY   - base position offsets
--   anchorFrame  - frame to anchor icons to (nil = use `frame`)
--   reverseOrder - if true, iterate source arrays in reverse
--   groupTypeKey - for ResolveSpellCooldownText per-spell lookups
--   ctx          - settings table (see below)
--
-- ctx fields:
--   showDur, durationFont, durationBorder, computedFontSize, computedFontScale
--   autoScale, timerScale   (for live font scale recomputation from size)
--   swipeDis, sparkDis, revSwipe
--   expiringCurve, colorBorder
--   fontColor
--   showStacks, stackAutoScale, stackTimerScale
--   defaultBorderR, defaultBorderG, defaultBorderB, defaultBorderA
--   sotfCheck  (bool: should SotF glow be applied?)
--
-- Returns: number of icons rendered (caller uses this to hide unused slots)
-- ============================================================
local function RenderIcons(frame, unit, pool, nIcons, maxIcons,
    srcTex, srcIID, srcExp, srcDur, srcSID, srcBorders, srcStacks, srcDummy,
    srcSolid, srcIconTypes,
    size, offsets, anchor, offX, offY, anchorFrame,
    reverseOrder, groupTypeKey, ctx)

    if not SetIconBorderColor then ResolveUpvalues() end

    local rendered = 0
    local af = anchorFrame or frame
    local hasDummies = srcDummy ~= nil
    local hasSpellOverrides = ctx.hasPerSpellOverrides

    -- Pre-compute baseline font scale from live size (handles liveSize
    -- containers where ctx.computedFontScale was cached at a different size).
    local baseFontScale = ctx.autoScale and (size / 12 * (ctx.timerScale or 1.0)) or ctx.computedFontScale

    for rawIdx = 1, nIcons do
        if rendered >= maxIcons then break end
        local sourceIdx = reverseOrder and (nIcons - rawIdx + 1) or rawIdx
        local tex = srcTex and srcTex[sourceIdx]
        if not tex then
            -- Dense arrays: break on nil when not reversed.
            -- Reverse mode: gaps possible, skip.
            if not reverseOrder then break end
        else
            rendered = rendered + 1
            local idx = rendered
            local icon = pool[idx]
            if not icon then break end

            local sid = srcSID and srcSID[sourceIdx]
            local iid = srcIID and srcIID[sourceIdx]
            local isDummy = hasDummies and srcDummy[sourceIdx]

            -- ── Texture ──────────────────────────────────────────
            -- Pre-resolved solid color supplied by the caller (srcSolid array)
            -- eliminates 4-7 table chain lookups per icon.
            -- Falls back to inline resolution when srcSolid is nil.
            local solid = srcSolid and srcSolid[sourceIdx]
            if solid == false then solid = nil end  -- false sentinel = no solid
            if not solid and not srcSolid then
                -- No pre-resolved array: inline fallback (legacy path)
                -- v67: isBuffIcon argument dropped (blanket buff solid-icon
                -- override was a 12.0.7-only setting; getter is gone).
                if hasDummies then
                    local curveUnit = (not isDummy) and unit or nil
                    local curveIID  = (not isDummy) and iid or nil
                    ApplyIconTextureOrSolid(icon, tex, sid, curveUnit, curveIID)
                else
                    ApplyIconTextureOrSolid(icon, tex, sid, unit, iid)
                end
            elseif solid then
                -- Solid color: SetColorTexture paints the entire texture
                -- region uniformly, so the TexCoord crop is irrelevant.
                -- We intentionally do NOT touch SetTexCoord here so the
                -- creation-time crop (0.07, 0.93, 0.07, 0.93) persists
                -- and stays valid for the next regular-texture render
                -- on this slot.
                icon.Icon:SetColorTexture(solid.r, solid.g, solid.b, solid.a or 1)
                if not isDummy and UpdateSolidIconColorCurve then
                    UpdateSolidIconColorCurve(icon, sid, unit, iid)
                end
            else
                -- Regular texture: TexCoord crop was set at icon creation
                -- (AuraConfig.lua:137) and is never disturbed by the solid
                -- branch above, so no per-render SetTexCoord call is needed.
                icon.Icon:SetTexture(tex)
                icon._bf_solidColorCurve = nil
            end
            icon.Icon:SetDesaturated(false)
            -- v94: and restore its ALPHA, for the same "this pool is shared"
            -- reason SetDesaturated(false) is here. The Buff List preview's
            -- Square (Color by Duration) path alpha-0s the icon region so only
            -- its glyph shows, and frame.buffFrames is the default group's
            -- pool (AuraGroupHelpers.lua, cfg.pool = _defPool) -- so a slot it
            -- left behind would render here as a bordered empty box with
            -- duration text and no art. The single-spell preview reaches this
            -- painter WITHOUT going through ApplyDummyIcon, which is where the
            -- other reset lives, so it needs its own.
            icon.Icon:SetAlpha(1)
            if not icon.Icon:IsShown() then icon.Icon:Show() end

            icon.auraInstanceID = iid

            -- ── Border ───────────────────────────────────────────
            -- Skip the repaint if SotF is currently using the icon's
            -- border to display a glow.
            if not icon._sotfBorderActive then
                -- Pre-resolved icon type supplied by the caller (srcIconTypes
                -- array) eliminates 4 table chain lookups per icon.
                local iconType = srcIconTypes and srcIconTypes[sourceIdx]
                if iconType == false then iconType = nil end  -- false sentinel = default
                if not srcIconTypes then
                    iconType = sid and GetSpellIconType and GetSpellIconType(sid)
                end
                -- v48: Blizzard-style buff borders (12.1 preview parity):
                -- helpful icons render borderless + uncropped, matching
                -- the real container path's blizzard mode.
                -- v67: 12.0.7 branch removed (addon is 12.1-only).
                local blizzB = ctx._ac and ctx._ac.buffBlizzardBorders
                -- (v69: the srcIconTypes vocabulary is Square/BorderedSquare
                -- only — legacy stored values are collapsed at the array
                -- build sites, this path never sees them.)
                if iconType == "Square" or blizzB then
                    SetIconBorderColor(icon, 0, 0, 0, 0)
                    icon._bf_customBorderColor = nil
                    icon._bf_customBorderSpellId = nil
                    if not icon._bf_borderless then
                        icon.Icon:ClearAllPoints()
                        icon.Icon:SetPoint("TOPLEFT", 0, 0)
                        icon.Icon:SetPoint("BOTTOMRIGHT", 0, 0)
                        icon._bf_borderless = true
                    end
                    if blizzB and iconType ~= "Square" then
                        if not icon._bf_blizzCrop then
                            icon.Icon:SetTexCoord(0, 1, 0, 1)
                            icon._bf_blizzCrop = true
                        end
                        -- v49 swipe inset parity (see ApplyBorderInsets).
                        local cdKey = "b" .. size
                        if icon.cooldown and icon._bf_cdInset ~= cdKey then
                            icon._bf_cdInset = cdKey
                            local inset = size * 0.04
                            icon.cooldown:ClearAllPoints()
                            icon.cooldown:SetPoint("TOPLEFT", icon, "TOPLEFT", inset, -inset)
                            icon.cooldown:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", -inset, inset)
                        end
                    elseif icon._bf_blizzCrop then
                        icon.Icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
                        icon._bf_blizzCrop = nil
                        if icon.cooldown and icon._bf_cdInset then
                            icon._bf_cdInset = nil
                            -- Full-bleed: the backdrop border's outer edge
                            -- is the icon rect and both shapes are square,
                            -- so the swipe covers the band exactly with
                            -- nothing beyond (flat-branch parity with
                            -- ApplyBorderInsets).
                            icon.cooldown:ClearAllPoints()
                            icon.cooldown:SetAllPoints(icon)
                        end
                    end
                else
                    if icon._bf_borderless then
                        local bs = BF:PixelsToUI(1)
                        icon.Icon:ClearAllPoints()
                        icon.Icon:SetPoint("TOPLEFT", bs, -bs)
                        icon.Icon:SetPoint("BOTTOMRIGHT", -bs, bs)
                        icon._bf_borderless = nil
                    end
                    if icon._bf_blizzCrop then
                        icon.Icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
                        icon._bf_blizzCrop = nil
                    end
                    -- Border color: pre-resolved array (default container) or
                    -- inline resolution (custom container, srcBorders == nil).
                    local bc
                    if srcBorders then
                        bc = srcBorders[sourceIdx]
                    else
                        bc = sid and GetSpellBorderColor and GetSpellBorderColor(sid)
                    end
                    if bc and bc ~= false then
                        SetIconBorderColor(icon, bc.r, bc.g, bc.b, bc.a or 1)
                        icon._bf_customBorderColor = true
                        icon._bf_customBorderSpellId = sid
                    elseif hasSpellOverrides then
                        -- Per-spell colorAuraBorder: when enabled, use the
                        -- spell's font color as the default border color.
                        local sctBdr = sid and ResolveSpellCooldownText(sid, groupTypeKey, ctx._ac)
                        if sctBdr and sctBdr.colorAuraBorder and sctBdr.fontColor then
                            local fc = sctBdr.fontColor
                            SetIconBorderColor(icon, fc.r or 1, fc.g or 1, fc.b or 1, 0.8)
                        else
                            SetIconBorderColor(icon, ctx.defaultBorderR, ctx.defaultBorderG, ctx.defaultBorderB, ctx.defaultBorderA)
                        end
                        icon._bf_customBorderColor = nil
                        icon._bf_customBorderSpellId = nil
                    else
                        SetIconBorderColor(icon, ctx.defaultBorderR, ctx.defaultBorderG, ctx.defaultBorderB, ctx.defaultBorderA)
                        icon._bf_customBorderColor = nil
                        icon._bf_customBorderSpellId = nil
                    end
                end
            end

            -- ── Cooldown ─────────────────────────────────────────
            if icon.cooldown then
                local cd = icon.cooldown
                if hasDummies and isDummy then
                    -- Dummy/preview: no real unit/aura to query. Set cooldown directly.
                    -- Per-spell aura text overrides still apply to previews.
                    local _exp = srcExp and srcExp[sourceIdx]
                    local _dur = srcDur and srcDur[sourceIdx]
                    if _dur and _exp and canaccessvalue(_dur) then
                        cd:SetCooldown(_exp - _dur, _dur)
                    end
                    local _showDur  = ctx.showDur
                    local _swipeDis = ctx.swipeDis
                    local _sparkDis = ctx.sparkDis
                    local _revSwipe = ctx.revSwipe or false
                    local _font     = ctx.durationFont
                    local _fSize    = ctx.computedFontSize
                    local _fBorder  = ctx.durationBorder
                    local _fScale   = baseFontScale
                    local _fColor   = ctx.fontColor
                    -- v62: ctx._sbC (stamped by RenderAuraGroup's container
                    -- branch) routes a single buff's cooldown-text resolve to
                    -- the entry's own store. Dummy/preview branch ONLY -- the
                    -- real-aura branch below stays sbC-free by owner decision
                    -- (legacy live renders single buffs with container-level
                    -- visuals; 12.1 live styles via DeriveSpellButtonSpec).
                    local sct = ResolveSpellCooldownText and sid and ResolveSpellCooldownText(sid, groupTypeKey, ctx._ac, ctx._sbC)
                    if sct then
                        _showDur  = sct.showDur
                        _swipeDis = sct.swipeDis
                        _sparkDis = sct.sparkDis
                        _revSwipe = sct.revSwipe or false
                        _font     = sct.durationFont
                        _fSize    = (not sct.autoScale) and (sct.fontSize or 11) or 11
                        _fBorder  = sct.durationBorder
                        _fScale   = sct.autoScale and (size / 12 * (sct.timerScale or 1.0)) or 1.0
                        _fColor   = sct.fontColor or _fColor
                    end
                    cd:SetHideCountdownNumbers(not _showDur)
                    cd:SetDrawSwipe(not _swipeDis)
                    cd:SetDrawEdge(not _sparkDis)
                    cd:SetReverse(_revSwipe)
                    if _showDur then
                        cd._bf_font   = _font
                        cd._bf_size   = _fSize
                        cd._bf_border = _fBorder
                        cd._bf_scale  = _fScale
                        if _fColor then
                            cd._bf_textR = _fColor.r or 1
                            cd._bf_textG = _fColor.g or 1
                            cd._bf_textB = _fColor.b or 1
                            cd._bf_textA = _fColor.a or 1
                        end
                        -- Inline font apply (replaces removed ApplyBFFont)
                        local tt = cd.timerText
                        if tt then
                            tt:SetFont(cd._bf_font, cd._bf_size, cd._bf_border)
                            tt:SetScale(cd._bf_scale)
                            tt:ClearAllPoints()
                            tt:SetPoint("CENTER", cd, "CENTER", 0, 0)
                            if not cd._bf_dispelColorActive then
                                tt:SetTextColor(cd._bf_textR, cd._bf_textG, cd._bf_textB, cd._bf_textA or 1)
                            end
                        end
                    end
                    -- Threshold color curve (v48): stamp + register with a
                    -- persistent dummy duration object (mirrors DummyAuras'
                    -- MakeApplyDummyIcon — dummy icons never pass through
                    -- the live UpdateIconCooldown/curve path, so container
                    -- previews showed no threshold text colors). Per-spell
                    -- override curve wins; sct with "no curve" means NO
                    -- curve, not fall-back-to-container.
                    local _curve = sct and sct.expCurve or (not sct and ctx.expiringCurve) or nil
                    local _tt = cd.timerText
                    if _showDur and _curve and _tt
                       and _dur and _exp and canaccessvalue(_dur)
                       and C_DurationUtil and BF.UpdateIconColorCurve then
                        icon.colorCurveObject = _curve
                        icon.colorCurveText = _tt
                        icon.colorCurveBorder = nil
                        local durObj = icon._bf_dummyDurObj
                        if not durObj then
                            durObj = C_DurationUtil.CreateDuration()
                            icon._bf_dummyDurObj = durObj
                        end
                        durObj:SetTimeFromEnd(_exp, _dur)
                        BF.UpdateIconColorCurve(icon, durObj)
                    else
                        icon.colorCurveObject = nil
                        icon.colorCurveText = nil
                        if BF.RemoveIconColorCurve then BF.RemoveIconColorCurve(icon) end
                    end
                    cd:Show()
                else
                    -- Real aura: Grid2 inline pattern.
                    -- Per-spell override: stamp cooldown properties if spell changed.
                    local sct = hasSpellOverrides and sid and ResolveSpellCooldownText(sid, groupTypeKey, ctx._ac)
                    if sct then
                        -- Per-spell override: stamp override cooldown properties
                        if cd._bf_sctSpell ~= sid then
                            cd:SetHideCountdownNumbers(not sct.showDur)
                            cd:SetDrawSwipe(not sct.swipeDis)
                            cd:SetDrawEdge(not sct.sparkDis)
                            cd:SetReverse(sct.revSwipe or false)
                            local sc = sct.autoScale and (size / 12 * (sct.timerScale or 1.0)) or 1.0
                            local fs = (not sct.autoScale) and (sct.fontSize or 11) or 11
                            cd._bf_font   = sct.durationFont
                            cd._bf_size   = fs
                            cd._bf_border = sct.durationBorder
                            cd._bf_scale  = sc
                            local fc = sct.fontColor or ctx.fontColor
                            if fc then
                                cd._bf_textR = fc.r or 1
                                cd._bf_textG = fc.g or 1
                                cd._bf_textB = fc.b or 1
                                cd._bf_textA = fc.a or 1
                            end
                            local tt = cd.timerText
                            if tt then
                                tt:SetFont(cd._bf_font, cd._bf_size, cd._bf_border)
                                tt:SetScale(cd._bf_scale)
                                tt:ClearAllPoints()
                                tt:SetPoint("CENTER", cd, "CENTER", 0, 0)
                                if not cd._bf_dispelColorActive then
                                    tt:SetTextColor(cd._bf_textR, cd._bf_textG, cd._bf_textB, cd._bf_textA or 1)
                                end
                            end
                            -- Stamp override curve + border onto icon.
                            -- Use sct.expCurve directly (may be nil): a per-spell
                            -- override that disables threshold/hide-above-1-min
                            -- means "no curve", not "fall back to global curve".
                            icon.colorCurveObject = sct.expCurve
                            icon.colorCurveText = tt or cd.timerText
                            icon.colorCurveBorder = sct.colorBorder
                            cd._bf_sctSpell = sid
                        end
                    elseif cd._bf_sctSpell then
                        -- Spell changed away from override: restore layout defaults
                        cd:SetHideCountdownNumbers(not ctx.showDur)
                        cd:SetDrawSwipe(not ctx.swipeDis)
                        cd:SetDrawEdge(not ctx.sparkDis)
                        cd:SetReverse(ctx.revSwipe or false)
                        cd._bf_font   = ctx.durationFont
                        cd._bf_size   = ctx.computedFontSize
                        cd._bf_border = ctx.durationBorder
                        cd._bf_scale  = baseFontScale
                        local fc = ctx.fontColor
                        if fc then
                            cd._bf_textR = fc.r or 1
                            cd._bf_textG = fc.g or 1
                            cd._bf_textB = fc.b or 1
                            cd._bf_textA = fc.a or 1
                        else
                            cd._bf_textR = 1
                            cd._bf_textG = 1
                            cd._bf_textB = 1
                            cd._bf_textA = 1
                        end
                        local tt = cd.timerText
                        if tt then
                            tt:SetFont(cd._bf_font, cd._bf_size, cd._bf_border)
                            tt:SetScale(cd._bf_scale)
                            tt:ClearAllPoints()
                            tt:SetPoint("CENTER", cd, "CENTER", 0, 0)
                            if not cd._bf_dispelColorActive then
                                tt:SetTextColor(cd._bf_textR, cd._bf_textG, cd._bf_textB, cd._bf_textA or 1)
                            end
                        end
                        icon.colorCurveObject = ctx.expiringCurve
                        icon.colorCurveText = cd.timerText
                        icon.colorCurveBorder = ctx.colorBorder
                        cd._bf_sctSpell = nil
                    else
                        -- No per-spell override, no stale override to clear.
                        -- Grid2 pattern: ensure the icon always has the current
                        -- curve from Layout/ctx. Covers custom container icons
                        -- (never Layout-stamped) and post-settings-change updates
                        -- where the curve object was rebuilt.
                        icon.colorCurveObject = ctx.expiringCurve
                        icon.colorCurveText = cd.timerText
                        icon.colorCurveBorder = ctx.colorBorder
                    end
                    local dur = srcDur and srcDur[sourceIdx] or 0
                    local exp = srcExp and srcExp[sourceIdx] or 0
                    BF.UpdateIconCooldown(icon, unit, exp, dur, iid)
                end
            end

            -- ── Stack count ──────────────────────────────────────
            if hasDummies and isDummy then
                -- Dummy/preview: hide stack text (no real aura data).
                if icon.count:IsShown() then icon.count:Hide() end
            elseif ctx.showStacks then
                local apps = srcStacks and srcStacks[sourceIdx]
                icon.count:SetText(apps or "")
                if ctx.stackAutoScale then
                    icon.count:SetScale(size / 12 * ctx.stackTimerScale)
                end
                if not icon.count:IsShown() then icon.count:Show() end
            else
                if icon.count:IsShown() then icon.count:Hide() end
            end

            -- ── Size ─────────────────────────────────────────────
            if icon.cachedSize ~= size then
                icon:SetSize(size, size)
                icon.cachedSize = size
            end

            -- ── Position ─────────────────────────────────────────
            if icon.SF_LastIndex ~= idx then
                icon:ClearAllPoints()
                local off = offsets[idx]
                if off then
                    icon:SetPoint(anchor, af, anchor, off.x + offX, off.y + offY)
                end
                icon.SF_LastIndex = idx
            end

            -- ── SotF glow ────────────────────────────────────────
            if ctx.sotfCheck then
                icon._sotfUnit = unit
                if ApplySotFGlow then ApplySotFGlow(icon, iid) end
            end

            -- v67: the Bounce block was removed with AuraCustomizations/
            -- Bounce.lua (the engine owns icon position on 12.1, so the
            -- animation had nothing to move). ctx.bounceCheck is no longer
            -- read here.

            if not icon:IsShown() then icon:Show() end
        end
    end

    return rendered
end

BF.RenderContainerIcons = RenderIcons
