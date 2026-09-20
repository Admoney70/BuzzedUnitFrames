-- ============================================================
-- BuzzardFrames: oUF_BossFrames.lua
-- Spawns 5 oUF-based boss frames (boss1-boss5) as a single
-- movable group with shared settings from p.boss.
-- Requires oUF_Shared.lua to be loaded first.
-- ============================================================
local BF  = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")
local oUF = BF.oUF  -- set by oUF_Shared.lua which is loaded first

local NUM_BOSS_FRAMES = 5

-- ── Icon block overhang ─────────────────────────────────────────────────────
-- How far the class icon / portrait block sticks out PAST the frame's left
-- and right edges, from settings alone (no frame needed, so the slot maths
-- can ask before the first layout). Mirrors _AnchorOUFIconFrame's anchoring
-- (oUF_Shared.lua) case for case: `outer` hangs off the icon's own side,
-- `inner` off the opposite side, `center` off neither; the circular shape
-- tucks 20px under the bar (outer) or sits 42px in from the far edge
-- (inner). Returns left, right in the frame's own (pre-scale) units.
function BF:_OUFIconOverhang(unitKey, p)
    p = p or self.ufDB.profile
    if p.playerShowClassIcon == false then return 0, 0 end
    local pf = p[unitKey] or {}
    local iconSz    = p.iconSize or 51
    local ringThick = p.classIconBorderThickness or 4
    local iconScale = pf.iconScale or 1.0
    if iconScale ~= 1.0 then
        iconSz    = math.floor(iconSz    * iconScale + 0.5)
        ringThick = math.floor(ringThick * iconScale + 0.5)
    end
    local sz = (p.classIconBorderEnabled ~= false) and (iconSz + ringThick * 2) or iconSz
    local side = self.bluzzardIconSide and self.bluzzardIconSide[unitKey] or "RIGHT"
    local loc  = p.iconLocation or "outer"
    local ox   = p.iconOffsetX or 0
    local circ = (p.iconShape or "circular") == "circular"
    local left, right = 0, 0
    if loc == "center" then
        return 0, 0
    elseif side == "LEFT" then
        if loc == "inner" then
            right = circ and (42 + ox) or (sz + ox)
        else
            left  = circ and (sz - 20 - ox) or (sz - ox)
        end
    else
        if loc == "inner" then
            left  = circ and (42 + ox) or (sz + ox)
        else
            right = circ and (sz - 20 - ox) or (sz - ox)
        end
    end
    if left  < 0 then left  = 0 end
    if right < 0 then right = 0 end
    return left, right
end

-- ── Slot overhead ─────────────────────────────────────────────────────────────
-- What one boss slot reserves BEYOND the oUF frame itself, in the frames' own
-- pre-scale space: `vert` along the vertical axis (buff row, debuff row and a
-- Below/Above/Bottom cast bar), `horiz` along the horizontal axis (a Left /
-- Right cast bar, which is frame-wide and sits beside the frame). The column
-- stacker, the Setup Mode overlay and the boss preview all read this ONE
-- function, so the three can never disagree about the slot pitch.
-- Also returns the vertical reserve split by side -- `above` (debuff row,
-- an Above cast bar) and `below` (buff row, a Below/Bottom cast bar) -- and
-- for a side cast bar which side it takes (`horizSide`, "left"/"right").
-- The twin slot needs the split: the twin hangs DOWN from its oUF frame's
-- TOPLEFT and is usually taller than the frame, so the neighbor under it
-- (or beside it) keeps its own aura rows only if the twin's span leaves
-- room for the reserve on the side the twin grows into.
function BF:GetBossSlotOverhead(p, pf)
    p  = p  or self.ufDB.profile
    pf = pf or p.boss or {}
    local above, below, horiz, horizSide = 0, 0, 0, nil
    if pf.bossShowBuffs   ~= false then below = below + (pf.bossBuffSize   or 18) + 2 end
    if pf.bossShowDebuffs ~= false then above = above + (pf.bossDebuffSize or 18) + 2 end
    if p.bossShowCastBar ~= false then
        local pos = p.bossCastBarPosition or "below"
        if pos == "left" or pos == "right" then
            -- The bar sits past the icon block on that side, so the block's
            -- overhang is part of what the slot reserves.
            local ovL, ovR = self:_OUFIconOverhang("boss", p)
            horiz = horiz + (p.bossCastBarWidth or 150) + (p.bossCastBarGap or 0) + 2
                  + (pos == "left" and ovL or ovR)
            horizSide = pos
        elseif pos == "above" then
            above = above + (p.bossCastBarHeight or 14) + 2
        else
            below = below + (p.bossCastBarHeight or 14) + 2
        end
    end
    return above + below, horiz, above, below, horizSide
end

-- The slot pitch along the grow axis, in the boss frames' pre-scale space.
-- Each slot has a "near" extent (frame plus what hangs off its far side in
-- the grow direction) and a "far" extent (what sticks out on the other
-- side); with one pitch for all five, the pitch must fit the largest near
-- extent of any slot against the largest far extent of any slot:
--   oUF slot, vertical : near = frame + below reserve (buff row, a
--                        Below/Bottom cast bar); far = above reserve
--                        (debuff row, an Above cast bar)
--   twin slot, vertical: near = twin height + its attached Below/Bottom
--                        cast bar; far = its attached Above cast bar
--   horizontal         : the same with the twin's width and a Left/Right
--                        cast bar (the oUF frame's is one-sided: horizSide)
-- The twin's cast bar is the twin's child, so it is scaled by twinScale;
-- twinSpan / twinScale are on-screen (GetTwinFrameSize), scale is the boss
-- frames' own, hence the divisions. twinSpan nil = twin off.
function BF:GetBossSlotSpan(p, pf, horizGrow, twinSpan, scale, twinScale)
    local slotBase = horizGrow and (pf.frameWidth or 150)
        or ((pf.nameBarHeight or 12) + (pf.healthBarHeight or 22) + (pf.powerBarHeight or 12))
    local _, horiz, above, below, horizSide = self:GetBossSlotOverhead(p, pf)
    local near, far
    if horizGrow then
        near = slotBase + ((horizSide == "right") and horiz or 0)
        far  = (horizSide == "left") and horiz or 0
    else
        near = slotBase + below
        far  = above
    end
    if twinSpan and scale and scale > 0 then
        local t = twinSpan / scale
        local castNear, castFar = 0, 0
        if p.bossShowCastBar ~= false then
            local pos = p.bossCastBarPosition or "below"
            local cs  = (twinScale or 1) / scale
            if horizGrow then
                local w = ((p.bossCastBarWidth or 150) + (p.bossCastBarGap or 0) + 2) * cs
                if     pos == "right" then castNear = w
                elseif pos == "left"  then castFar  = w end
            else
                local h = ((p.bossCastBarHeight or 14) + (p.bossCastBarGap or 0) + 2) * cs
                if     pos == "below" or pos == "bottom" then castNear = h
                elseif pos == "above"                   then castFar  = h end
            end
        end
        if t + castNear > near then near = t + castNear end
        if castFar > far then far = castFar end
    end
    return near + far, slotBase
end

-- ── Spawn ─────────────────────────────────────────────────────────────────────

-- v86 (event refactor stage 3): deferred-build listener owner. One owner
-- per feature; the subscription is taken only if the build has to wait for
-- oUF's PLAYER_LOGIN factory queue.
local buildEvents = BF:EventOwner("oufBossBuild")

function BF:BuildOUFBossFrames()
    if self.oufBoss then return end
    if not self._oufReady then
        -- v86 (event refactor stage 3): was a private CreateFrame per call.
        -- Every call while _oufReady is false built ANOTHER listener, so a
        -- second build attempt before PLAYER_LOGIN left two frames both
        -- waiting to fire. SubOnce unsubscribes itself on the first fire, and
        -- the IsSubscribed guard makes re-entry a no-op instead of a leak.
        if not buildEvents:IsSubscribed("PLAYER_LOGIN") then
            buildEvents:SubOnce("PLAYER_LOGIN", function() BF:BuildOUFBossFrames() end)
        end
        return
    end

    oUF:SetActiveStyle("BuzzardBluzzard")

    self.oufBoss = {}

    for i = 1, NUM_BOSS_FRAMES do
        local unitId = "boss" .. i
        local f = oUF:Spawn(unitId, "BuzzardFrames_oUFBoss" .. i)
        -- Grid2 pattern: register all mouse buttons so right-click menu works.
        f:RegisterForClicks("AnyUp")
        f:SetMovable(true)
        f:SetClampedToScreen(true)
        f._bossIndex = i
        self.oufBoss[i] = f
    end

    -- Single drag handle on boss1 that moves the entire group.
    BF:_BuildDragHandle(self.oufBoss[1], "boss", "Boss Frames")

    self:ApplyOUFBossFrameLayout()

    -- Delayed initial update so unit data is populated.
    C_Timer.After(0.5, function()
        for i = 1, NUM_BOSS_FRAMES do
            local f = self.oufBoss[i]
            if f then
                if f.UpdateAllElements then f:UpdateAllElements("Manual") end
                if f.UpdateTags        then f:UpdateTags() end
            end
        end
    end)
end

-- ── Anchor migration ──────────────────────────────────────────────────────────
-- Until 2026-09-12 the Up and Left grow directions offset boss1 by the
-- column's whole extent, so the saved anchor marked the far corner of the
-- bounding box (its top-left for Up, its left end for Left) and boss1 sat
-- at the other end. The anchor is boss1's own TOPLEFT for every direction
-- now. This one-shot moves every saved boss anchor of the ACTIVE profile
-- by exactly the offset the old layout applied -- computed by the same
-- slot maths, at the moment the first layout under the new rule runs, so
-- the twin and the aura / cast bar reserve enter as they did -- and the
-- frames stay where they were on screen. Guarded by the profile's
-- bossAnchorIsBoss1 sentinel (Defaults_UnitFrames.lua): a profile that
-- was never Up / Left is stamped and left alone; another profile migrates
-- on its own first layout; an exported profile carries the stamp.
function BF:MigrateBossAnchorToBoss1()
    local p = self.ufDB and self.ufDB.profile
    if not p or p.bossAnchorIsBoss1 then return end
    p.bossAnchorIsBoss1 = true
    local dir = p.bossGrowDirection or "DOWN"
    if dir ~= "UP" and dir ~= "LEFT" then return end

    local pf    = p.boss or {}
    local scale = pf.frameScale or 1.0
    local horiz = (dir == "LEFT")
    local twinSpan, twinScale
    if self.IsTwinActive and self:IsTwinActive("boss") and self.GetTwinFrameSize then
        local twinW, twinH, ts = self:GetTwinFrameSize("boss")
        twinSpan, twinScale = (horiz and twinW or twinH), ts
    end
    local slotSpan, slotBase = self:GetBossSlotSpan(p, pf, horiz, twinSpan, scale, twinScale)
    local dynSpacing = (p.bossFrameSpacing or 4) + (slotSpan - slotBase)
    -- The old offset: -(totalH - frameH) on Y for Up, +(totalW - barW) on X
    -- for Left, applied in boss1's own scaled space -- hence * scale to
    -- land in the anchor's (UIParent) space.
    local extent = (slotBase * 5 + dynSpacing * 4 - slotBase) * scale

    local function Shift(t)
        if type(t) ~= "table" or t.anchorX == nil or t.anchorY == nil then return end
        if horiz then t.anchorX = t.anchorX + extent
        else          t.anchorY = t.anchorY - extent end
    end
    -- The global fallback bucket and every UF layout's bucket
    -- (Core_UFLayout.lua GetUFAnchor: the "party" bucket is the one live
    -- path), whichever of them hold a saved position.
    Shift(rawget(p, "boss"))
    local layouts = rawget(p, "ufLayouts")
    if type(layouts) == "table" then
        for _, layout in pairs(layouts) do
            local party = type(layout) == "table" and rawget(layout, "party")
            if type(party) == "table" then Shift(rawget(party, "boss")) end
        end
    end
end

-- ── Layout ────────────────────────────────────────────────────────────────────
-- Boss1 is positioned via _ApplyOUFRightFrameLayout (anchor system).
-- Boss2-5 are stacked below boss1 with configurable spacing.

function BF:ApplyOUFBossFrameLayout()
    if not self.oufBoss then return end
    local boss1 = self.oufBoss[1]
    if not boss1 then return end

    -- One-shot per profile (sentinel-guarded, a boolean read afterwards).
    self:MigrateBossAnchorToBoss1()

    local p  = self.ufDB.profile
    local pf = p.boss or {}

    -- Frame dimensions, shared by the slot maths and the boss2..5 stacker.
    local nameH   = pf.nameBarHeight   or 12
    local healthH = pf.healthBarHeight or 22
    local powerH  = pf.powerBarHeight  or 12
    local frameH  = nameH + healthH + powerH
    local spacing = p.bossFrameSpacing or 4
    local barW    = pf.frameWidth      or 150
    local scale   = pf.frameScale      or 1.0
    local alpha   = pf.frameAlpha      or 1.0
    local enabled = p.showBossFrames
    local growDir = p.bossGrowDirection or "DOWN"

    -- Slot pitch. A slot normally reserves the oUF boss frame plus its aura /
    -- cast bar overhead. With the boss raid-style twin on, the twin sits at the
    -- same TOPLEFT as its oUF bossN frame and is usually the taller of the two,
    -- so every slot reserves max(oUF slot, twin) in the grow direction instead
    -- and boss1's twin can never overlap boss2 (plan 7.2). GetTwinFrameSize
    -- answers in on-screen UI units while these offsets live in the boss
    -- frame's own scaled space, hence the divide by scale.
    -- With the option off slotSpan is exactly slotBase + auraOverhead, so
    -- dynSpacing -- and every number derived from it -- is unchanged.
    -- Guarded: UnitFrames/Twins.lua loads after this file.
    -- Also gates the Enable branch in the boss2..5 stacker below.
    -- The per-slot reserve (aura rows, cast bar) and the twin's span both
    -- live in BF:GetBossSlotSpan, shared with the Setup Mode overlay.
    local twinOwnsBoss = self.IsTwinActive and self:IsTwinActive("boss")
    local horiz    = (growDir == "LEFT" or growDir == "RIGHT")
    local twinSpan, twinScale
    if twinOwnsBoss and self.GetTwinFrameSize then
        local twinW, twinH, ts = self:GetTwinFrameSize("boss")
        twinSpan, twinScale = (horiz and twinW or twinH), ts
    end
    local slotSpan, slotBase = self:GetBossSlotSpan(p, pf, horiz, twinSpan, scale, twinScale)

    -- Five frames with four gaps, where each gap = bossFrameSpacing + the
    -- slot's reserve beyond the frame itself (the boss2..5 stacker below
    -- uses this same upvalue).
    local dynSpacing = spacing + (slotSpan - slotBase)

    -- boss1 sits at the anchor for EVERY grow direction; boss2..5 stack
    -- away from it. So the saved position is the fixed end of the column:
    -- the bottom frame for Up, the right-hand frame for Left, the top /
    -- left-hand frame for Down / Right -- and the column grows and shrinks
    -- (aura rows, cast bar, twin) away from that end, never moving it.
    -- (Up and Left used to offset boss1 by the column's total extent so the
    -- anchor marked the far corner of the bounding box; a settings change
    -- then moved the whole column.)
    --
    -- Apply layout to boss1 using the shared right-frame helper.
    -- This handles size, position, anchor, health/power bars, icon, text,
    -- auras, border, raid target, phase indicator, enable/disable, and
    -- deferred reposition.
    self:_ApplyOUFRightFrameLayout(
        "boss", boss1, 1475, 500, "showBossFrames", "boss",
        function(f, p2, pf2)
            -- Cast bar layout for boss1
            BF:_ApplyOUFBossCastbarLayout(f, p2, pf2)
        end
    )

    -- Stack boss2-5 relative to boss1 in the chosen grow direction.
    for i = 2, NUM_BOSS_FRAMES do
        local f    = self.oufBoss[i]
        local prev = self.oufBoss[i - 1]
        if not f or not prev then return end

        f:SetSize(barW, frameH)
        f:SetScale(scale)
        f:SetAlpha(alpha)

        -- Health bar
        if f.Health then
            f.Health:ClearAllPoints()
            f.Health:SetHeight(healthH)
        end

        -- Power bar
        if f.Power then
            f.Power:ClearAllPoints()
            f.Power:SetHeight(powerH)
        end

        -- Icon block + insets (must come before health/power anchoring)
        BF:_ApplyOUFIconBlock(f, "boss" .. i)
        local inL_name, inR_name, inL_health, inR_health, inL_power, inR_power = BF:_ComputeOUFIconInsets(f, nameH, healthH, powerH)

        -- Apply insets to health/power bars. Anchor only to the non-icon
        -- side with offset 0 and use SetSize to shrink the bar — preserves
        -- offset-0 inheritance and avoids the divergent re-snap that a
        -- non-zero SetPoint offset introduces. See ApplyOUFPlayerLayout.
        if f.Health then
            f.Health:ClearAllPoints()
            -- v90.4: anchor side by ICON side (see GetOUFBarAnchorSide).
            local hAnchor = BF:GetOUFBarAnchorSide(f, inL_health)
            f.Health:SetPoint(hAnchor, f, hAnchor, 0, -nameH)
            f.Health:SetSize(BF:PixelRound(barW - inL_health - inR_health), healthH)
        end
        if f.Power then
            f.Power:ClearAllPoints()
            local pAnchor = BF:GetOUFBarAnchorSide(f, inL_power)
            f.Power:SetPoint(pAnchor, f, pAnchor, 0, -nameH - healthH)
            f.Power:SetSize(BF:PixelRound(barW - inL_power - inR_power), powerH)
        end

        -- Colors
        if f.Health and f.__unit then
            local r, g, b, isGradient, gradAlpha = BF:_GetOUFHealthColor(f.__unit, pf.useClassColor, "boss")
            local fillAlpha = BF:_GetOUFHealthBarFillAlpha("boss", isGradient, gradAlpha)
            f.Health:SetStatusBarColor(r, g, b, fillAlpha)
            f._bf_healthR, f._bf_healthG, f._bf_healthB = r, g, b
            f._bf_healthA = fillAlpha
            f._bf_healthGradient = isGradient
        end
        if f.Health then
            local hTex = (p.oufUseCustomHealthBarTexture and BF:ResolveBarTexture(p.oufHealthBarTexture)) or "Interface\\Buttons\\WHITE8X8"
            f.Health:SetStatusBarTexture(hTex)
        end
        BF:_ApplyOUFHealthBgColor(f)
        if f.Power and f.__unit then
            local r, g, b = BF:_GetOUFPowerColor(f.__unit, "boss")
            f.Power:SetStatusBarColor(r, g, b)
        end
        if f.Power then
            local pTex = (p.oufUseCustomPowerBarTexture and BF:ResolveBarTexture(p.oufPowerBarTexture)) or "Interface\\Buttons\\WHITE8X8"
            f.Power:SetStatusBarTexture(pTex)
        end
        BF:_ApplyOUFPowerBgColor(f)

        -- Name bar text
        BF:_ApplyOUFNameBarTextPositions(f, "boss")

        -- Bar text font sizes
        local hFontSz = pf.healthFontSize or 8
        local pFontSz = pf.powerFontSize  or 7
        if f.HealthPctText then f.HealthPctText:SetFont(GameFontNormalSmall:GetFont(), hFontSz, "") end
        if f.HealthValText then f.HealthValText:SetFont(GameFontNormalSmall:GetFont(), hFontSz, "") end
        if f.PowerPctText  then f.PowerPctText:SetFont(GameFontNormalSmall:GetFont(),  pFontSz, "") end
        if f.PowerValText  then f.PowerValText:SetFont(GameFontNormalSmall:GetFont(),  pFontSz, "") end
        BF:_ApplyOUFBarTextPositions(f, "boss")

        -- oUF aura layout (12.1 AuraContainer: size/spacing/max baked at spawn).
        -- Auras (same settings as boss1, keyed with "boss" prefix).
        -- v67: size/spacing/max apply LIVE via _ApplyOUFAuraLiveGeometry;
        -- anchoring, wrap width and user show/hide follow here.
        if f.Buffs then
            local show   = pf["bossShowBuffs"] ~= false
            local perRow = pf["bossBuffsPerRow"] or 8
            local offX   = pf["bossBuffOffsetX"] or 0
            local offY   = (pf["bossBuffOffsetY"] or 0) - BF:GetOUFBuffRowPush("boss", p)
            local sz, spacing = BF:_ApplyOUFAuraLiveGeometry(f.Buffs, pf, "boss", "Buff")
            f.Buffs:SetFlowLayoutMaximumLineSize(perRow * (sz + spacing))
            f.Buffs:ClearAllPoints()
            f.Buffs:SetPoint("TOPLEFT", f, "BOTTOMLEFT", offX, offY)
            f.Buffs._bf_userShown = show
        end

        if f.Debuffs then
            local show   = pf["bossShowDebuffs"] ~= false
            local perRow = pf["bossDebuffsPerRow"] or 8
            local offX   = pf["bossDebuffOffsetX"] or 0
            local offY   = pf["bossDebuffOffsetY"] or 0
            local sz, spacing = BF:_ApplyOUFAuraLiveGeometry(f.Debuffs, pf, "boss", "Debuff")
            f.Debuffs:SetFlowLayoutMaximumLineSize(perRow * (sz + spacing))
            f.Debuffs:ClearAllPoints()
            f.Debuffs:SetPoint("BOTTOMLEFT", f, "TOPLEFT", offX, offY)
            f.Debuffs._bf_userShown = show
        end

        if f.Buffs or f.Debuffs then
            BF.UpdateOUFAuraFilters(f)  -- applies show/hide (+ filters)
            if f.Buffs and f.Buffs.ForceUpdate then f.Buffs:ForceUpdate() end
            if f.Debuffs and f.Debuffs.ForceUpdate then f.Debuffs:ForceUpdate() end
        end

        BF:_ApplyOUFFrameBorder(f)
        -- Enable/disable oUF Power element + hide bar/border per toggle.
        -- Runs AFTER _ApplyOUFFrameBorder so the Hide() on fb.power wins
        -- over ApplyBox's re-show inside _ApplyOUFFrameBorder.
        BF:_ApplyOUFPowerElementState(f, "boss" .. i)
        BF:_ApplyOUFNameBarState(f, "boss" .. i)
        BF:_ApplyOUFRaidTargetIndicator(f, "boss" .. i)
        BF:_ApplyOUFPhaseIndicator(f, "boss" .. i)

        -- Cast bar layout for boss2-5
        BF:_ApplyOUFBossCastbarLayout(f, p, pf)

        -- Position: stack in the chosen grow direction relative to the previous
        -- frame. dynSpacing (above) accounts for auras, the cast bar and, when
        -- the boss twin is on, the taller twin's slot.
        f:ClearAllPoints()
        if growDir == "UP" then
            f:SetPoint("BOTTOMLEFT", prev, "TOPLEFT", 0, dynSpacing)
        elseif growDir == "LEFT" then
            f:SetPoint("TOPRIGHT", prev, "TOPLEFT", -dynSpacing, 0)
        elseif growDir == "RIGHT" then
            f:SetPoint("TOPLEFT", prev, "TOPRIGHT", dynSpacing, 0)
        else -- DOWN (default)
            f:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -dynSpacing)
        end

        -- See _ApplyOUFRightFrameLayout: with the boss twin on, the secure
        -- visibility driver owns this frame and Enable (RegisterUnitWatch)
        -- would clobber it. boss1 takes the same branch inside the helper,
        -- which also re-runs ApplyTwins if the watch is still installed.
        if not twinOwnsBoss then
            if enabled then f:Enable() else f:Disable() end
        end
    end

    -- Handle visibility (only boss1 has the group handle).
    if boss1._handle then
        if boss1._anchor and boss1._anchor.SnapHandle then
            boss1._anchor.SnapHandle()
        end
        local locked = self.db.global.locked
        if locked == nil then locked = true end
        boss1._handle:SetShown(not locked)
        boss1:SetMovable(not locked)
    end

    -- Refresh setup-mode test frame.
    if self._ufTestFrames and self._ufTestFrames["boss"] then
        local g = self.db.global
        if g.setupModeActive then
            self:ShowUFTestFrames()
        end
    end
end

-- ── Boss cast bar placement (baked values) ─────────────────────────────────
-- Anchors the bar to its oUF boss frame from the values
-- _ApplyOUFBossCastbarLayout bakes onto it. Also the path the twin swap
-- takes to hand the bar back (BF:_RestoreAttachedCastbar, oUF_Castbar.lua),
-- so it must not depend on the layout pass's locals. Five positions:
--   below  -- under the frame, past one row of buff icons (the default)
--   above  -- over the frame, past the debuff row
--   bottom -- directly under the power bar; the buff row is pushed below
--             the cast bar instead (BF:GetOUFBuffRowPush)
--   left / right -- beside the frame, centered on the health bar, past the
--             icon block, at its own Bar Width; the gap slider is the
--             horizontal distance
function BF:_AnchorOUFBossCastbar(f)
    local cb = f and f.Castbar
    if not cb then return end
    local pos        = cb._castBarPos or "below"
    local gap        = cb._castBarGap or 0
    local leftInset  = cb._cbInsetL or 0
    local rightInset = cb._cbInsetR or 0
    local belowAnchor = f.Power or f.Health or f
    local yOff = gap + 2 + (cb._cbAuraSpace or 0)
    cb:ClearAllPoints()
    if pos == "above" then
        -- Anchored to the FRAME, not f.Name: the name FontString's width is
        -- its text's width once _ApplyOUFNameBarTextPositions has re-anchored
        -- it by one point, so a bar hung off it shrank to the name's length.
        cb:SetPoint("BOTTOMLEFT",  f, "TOPLEFT",  leftInset,  yOff)
        cb:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", rightInset,  yOff)
    elseif pos == "bottom" then
        local bOff = gap + 2
        cb:SetPoint("TOPLEFT",  belowAnchor, "BOTTOMLEFT",  leftInset, -bOff)
        cb:SetPoint("TOPRIGHT", belowAnchor, "BOTTOMRIGHT", rightInset, -bOff)
    elseif pos == "left" or pos == "right" then
        -- Beside the frame: vertically centered on the health bar, and
        -- starting past the icon block when that hangs off this side.
        -- The health bar is inset from the frame edge by the circular
        -- icon's chord (_ComputeOUFIconInsets, cached on the frame), so the
        -- run from the bar's edge is: chord inset + icon overhang + gap.
        local xOff = gap + 2
        local ovL, ovR = self:_OUFIconOverhang("boss")
        local vAnchor = f.Health or f
        if pos == "left" then
            local run = (f._iconBarInsetLeft_health or 0) + ovL + xOff
            cb:SetPoint("RIGHT", vAnchor, "LEFT", -run + rightInset, 0)
        else
            local run = (f._iconBarInsetRight_health or 0) + ovR + xOff
            cb:SetPoint("LEFT", vAnchor, "RIGHT", run + leftInset, 0)
        end
        cb:SetWidth((cb._cbSideW or 150) - leftInset + rightInset)
    else
        cb:SetPoint("TOPLEFT",  belowAnchor, "BOTTOMLEFT",  leftInset, -yOff)
        cb:SetPoint("TOPRIGHT", belowAnchor, "BOTTOMRIGHT", rightInset, -yOff)
    end
    cb:SetHeight(cb._cbHeight or 14)
end

-- ── Boss Cast Bar Layout ────────────────────────────────────────────────────────
-- Positions each boss frame's cast bar. Always attached (never detachable).
-- Reads settings from the "boss" prefix keys in the profile.
function BF:_ApplyOUFBossCastbarLayout(f, p, pf)
    if not f or not f.Castbar then return end

    local uk   = "boss"  -- profile key prefix
    local show = p[uk .. "ShowCastBar"] ~= false
    local castH = p[uk .. "CastBarHeight"] or 14
    local gap   = p[uk .. "CastBarGap"]    or 0

    f.Castbar:ClearAllPoints()

    if not show then
        -- Disable the oUF Castbar element so cast events stop re-showing the
        -- bar (and its text/time children) after the user has turned it off.
        if f.IsElementEnabled and f:IsElementEnabled("Castbar") then
            f:DisableElement("Castbar")
        end
        if f.Castbar:GetParent() ~= f then
            f.Castbar:SetParent(f)
            f.Castbar:SetFrameLevel(f:GetFrameLevel() + 5)
        end
        f.Castbar:SetPoint("TOPLEFT",  f, "BOTTOMLEFT",  0, 0)
        f.Castbar:SetPoint("TOPRIGHT", f, "BOTTOMRIGHT", 0, 0)
        f.Castbar:SetHeight(0.001)
        f.Castbar:Hide()
        f.Castbar._bf_twinAttached = nil
        if f.Castbar._handle then f.Castbar._handle:Hide() end
        if f.Castbar._icon  then f.Castbar._icon:Hide()  end
        return
    end

    -- Re-enable the oUF Castbar element if it was previously disabled.
    if f.IsElementEnabled and not f:IsElementEnabled("Castbar") then
        f:EnableElement("Castbar", f.__unit)
    end

    -- Always attached, never detached.
    if f.Castbar:GetParent() ~= f then
        f.Castbar:SetParent(f)
        f.Castbar:SetFrameLevel(f:GetFrameLevel() + 5)
        f.Castbar:SetMovable(false)
    end
    if f.Castbar._handle then f.Castbar._handle:Hide() end

    -- Icon inset so the icon's edge aligns with the frame edge.
    local iconSz   = p[uk .. "CastBarIconSize"] or 16
    local iconSide = p[uk .. "CastBarIconSide"] or "left"
    local iconGap  = p[uk .. "CastBarIconGap"]  or 2
    local showIcon = p[uk .. "CastBarShowIcon"] ~= false
    local leftInset  = (showIcon and iconSide == "left")  and (iconSz + iconGap) or 0
    local rightInset = (showIcon and iconSide == "right") and -(iconSz + iconGap) or 0

    -- Bake the placement onto the bar (the anchoring below and the
    -- twin-attached swap in oUF_Castbar.lua both read these, never the
    -- profile), then anchor.
    local pos = p[uk .. "CastBarPosition"] or "below"
    f.Castbar._castBarPos = pos
    f.Castbar._castBarGap = gap
    f.Castbar._cbInsetL   = leftInset
    f.Castbar._cbInsetR   = rightInset
    f.Castbar._cbHeight   = castH
    -- Left / Right bars take their own width; the others span the frame.
    f.Castbar._cbSideW    = p[uk .. "CastBarWidth"] or 150
    -- One row of buff icons is skipped Below (the row sits between the
    -- frame and the bar); Bottom pushes the row under the bar instead.
    local buffSz    = pf and pf.bossBuffSize or 18
    local showBuffs = not pf or pf.bossShowBuffs ~= false
    f.Castbar._cbAuraSpace = showBuffs and (buffSz + 2) or 0
    BF:_AnchorOUFBossCastbar(f)

    -- A twin owning this slot takes the attached bar as its own child
    -- (placed on the twin while it is shown, back here while it is not).
    BF:_SyncTwinAttachedCastbar(f)

    -- Font.
    local castFontSz = p[uk .. "CastBarFontSize"] or 10
    local fontFace   = GameFontNormalSmall:GetFont()
    if f.Castbar.Text then f.Castbar.Text:SetFont(fontFace, castFontSz, "") end
    if f.Castbar.Time then f.Castbar.Time:SetFont(fontFace, castFontSz, "") end
    -- v67: pushback delay is its own FontString now (see oUF_Castbar.lua).
    if f.Castbar.Delay then f.Castbar.Delay:SetFont(fontFace, castFontSz, "") end

    -- Colors / border / icon.
    BF:_ApplyOUFCastbarBgColor(f)
    BF:_ApplyOUFCastbarBorder(f)
    BF:_ApplyOUFCastbarIcon(f)
end

-- Perf plan §L5.1 load-time mark: closes the UnitFrames runtime block (.toc 170-184).
if BuzzardFrames then BuzzardFrames:LoadMark("chunk:postUF") end
