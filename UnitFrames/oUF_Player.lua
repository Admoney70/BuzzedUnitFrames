-- ============================================================
-- BuzzardFrames: oUF_Player.lua
-- Spawns the oUF-based bluzzard player frame and wires it into
-- the existing BF profile / option system.
-- Requires oUF_Shared.lua to be loaded first.
-- ============================================================
local BF  = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")
local oUF = BF.oUF  -- set by oUF_Shared.lua which is loaded first

-- ── Spawn ─────────────────────────────────────────────────────────────────────

-- v86 (event refactor stage 3): deferred-build listener owner. One owner
-- per feature; the subscription is taken only if the build has to wait for
-- oUF's PLAYER_LOGIN factory queue.
local buildEvents = BF:EventOwner("oufPlayerBuild")

function BF:BuildOUFPlayerFrame()
    if self.oufPlayer then return end
    -- Guard: oUF must have completed its PLAYER_LOGIN factory queue before Spawn.
    if not self._oufReady then
        -- Queue the build for after PLAYER_LOGIN fires.
        -- v86 (event refactor stage 3): was a private CreateFrame per call.
        -- Every call while _oufReady is false built ANOTHER listener, so a
        -- second build attempt before PLAYER_LOGIN left two frames both
        -- waiting to fire. SubOnce unsubscribes itself on the first fire, and
        -- the IsSubscribed guard makes re-entry a no-op instead of a leak.
        if not buildEvents:IsSubscribed("PLAYER_LOGIN") then
            buildEvents:SubOnce("PLAYER_LOGIN", function() BF:BuildOUFPlayerFrame() end)
        end
        return
    end

    local p = self.ufDB.profile

    oUF:SetActiveStyle("BuzzardBluzzard")

    local f = oUF:Spawn("player", "BuzzardFrames_oUFPlayer")
    -- Grid2 pattern: oUF:Spawn() only registers LeftButtonUp via
    -- SecureUnitButtonTemplate. Register all buttons so *type2
    -- (togglemenu / right-click menu) actually fires.
    f:RegisterForClicks("AnyUp")
    f:SetFrameStrata("MEDIUM")
    f:SetFrameLevel(50)
    f:SetMovable(true)
    f:SetClampedToScreen(true)

    -- ── Drag handle ───────────────────────────────────────────────────────────
    BF:_BuildDragHandle(f, "player", "Player")

    -- ── Rested "zzz" indicator ───────────────────────────────────────────────
    -- Mirrors Blizzard's PlayerRestLoop: a looping texture animation shown over
    -- the portrait icon whenever IsResting() is true.
    -- We use the same atlas Blizzard uses so the look is identical.
    local restFrame = CreateFrame("Frame", nil, UIParent)
    restFrame:SetFrameStrata("MEDIUM")
    restFrame:SetFrameLevel(f:GetFrameLevel() + 12)
    restFrame:SetSize(40, 40)
    restFrame:EnableMouse(false)
    restFrame:Hide()

    -- Probe for the correct atlas name at runtime -- Blizzard has used several
    -- names across patches; try each in order and fall back to a Lua zzz anim.
    local restTex = BF.Texture(restFrame, nil, "OVERLAY", nil, 1)
    restTex:SetAllPoints(restFrame)

    -- Probe the flipbook atlas to get the spritesheet file and dimensions,
    -- then manually step through frames via OnUpdate.
    local atlasFound = false
    local restFile, restW, restH, restL, restR, restT, restB
    do
        local info = C_Texture.GetAtlasInfo("UI-HUD-UnitFrame-Player-Rest-Flipbook")
        if info and info.file then
            restFile = info.file
            -- The flipbook sheet is 10 columns x 5 rows = 50 frames
            -- Each frame is 1/10 of the sheet width, 1/5 of the sheet height
            -- info gives us the region inside the larger texture atlas file
            restL = info.leftTexCoord   or 0
            restR = info.rightTexCoord  or 1
            restT = info.topTexCoord    or 0
            restB = info.bottomTexCoord or 1
            restTex:SetTexture(restFile)
            atlasFound = true

        end
    end

    -- Alpha pulse via OnUpdate
    local restElapsed = 0
    local REST_PERIOD  = 2.2

    if atlasFound then
        -- Sheet is 360x420 px, frames are 60x60 → 6 cols × 7 rows = 42 frames
        local COLS        = 6
        local ROWS        = 7
        local TOTAL       = COLS * ROWS  -- 42
        local FPS         = 20  -- zzz animates slowly
        local frameW      = (restR - restL) / COLS
        local frameH_uv   = (restB - restT) / ROWS
        local curFrame    = 0
        restFrame:SetScript("OnUpdate", function(_, dt)
            restElapsed = restElapsed + dt
            local newFrame = math.floor(restElapsed * FPS) % TOTAL
            if newFrame ~= curFrame then
                curFrame = newFrame
                local col = curFrame % COLS
                local row = math.floor(curFrame / COLS)
                restTex:SetTexCoord(
                    restL + col       * frameW,
                    restL + (col + 1) * frameW,
                    restT + row       * frameH_uv,
                    restT + (row + 1) * frameH_uv
                )
            end
        end)
    else
        -- Fallback: cascading "zzz" FontStrings
        restTex:Hide()
        local zFont   = BF.font or STANDARD_TEXT_FONT
        local zLabels = {}
        local zPhase  = { 0, 0.33, 0.66 }
        for i = 1, 3 do
            local fs = restFrame:CreateFontString(nil, "OVERLAY")
            fs:SetFont(zFont, 8 + i * 2, "OUTLINE")
            fs:SetText("z")
            fs:SetTextColor(0.5, 0.8, 1, 1)
            fs:SetAlpha(0)
            zLabels[i] = fs
        end
        restFrame:SetScript("OnUpdate", function(_, dt)
            restElapsed = restElapsed + dt
            local frameH = restFrame:GetHeight() or 32
            for i = 1, 3 do
                local t = ((restElapsed / REST_PERIOD) + zPhase[i]) % 1.0
                local alpha
                if t < 0.3 then alpha = t / 0.3
                elseif t < 0.6 then alpha = 1.0
                else alpha = 1.0 - (t - 0.6) / 0.4 end
                local yOff = math.sin(t * math.pi) * (frameH * 0.4)
                zLabels[i]:SetAlpha(alpha)
                zLabels[i]:ClearAllPoints()
                zLabels[i]:SetPoint("BOTTOMLEFT", restFrame, "BOTTOMLEFT",
                    (i - 1) * 7, yOff)
            end
        end)
    end

    -- Update visibility on resting state changes.
    -- ClearAllPoints/SetPoint are protected during combat lockdown, so defer
    -- the repositioning until PLAYER_REGEN_ENABLED if we're in combat.
    local restPending = false
    local function UpdateRestIndicator()
        if not f.Health then return end
        if InCombatLockdown() then
            restPending = true
            return
        end
        restPending = false
        local resting = IsResting and IsResting()
        if resting then
            restFrame:ClearAllPoints()
            local pp = BF.ufDB and BF.ufDB.profile
            local iconShown = pp and pp.playerShowClassIcon ~= false and f._iconFrame and f._iconFrame:IsShown()
            if iconShown then
                -- Icon enabled: above and to the left of the health bar, near the icon
                restFrame:SetPoint("BOTTOMRIGHT", f.Health, "TOPLEFT", 20, 4)
            else
                -- Icon disabled: top center of the frame
                restFrame:SetPoint("BOTTOM", f, "TOP", 0, 2)
            end
            restFrame:Show()
        else
            restFrame:Hide()
        end
    end

    -- v86 (event refactor stage 4): was a private CreateFrame. All three
    -- events are unitless. Note this needs its OWN owner rather than sharing
    -- one with the raid-group listener below: both want PLAYER_ENTERING_WORLD,
    -- and AceEvent allows one callback per (object, event).
    local restEvents = BF:EventOwner("oufPlayerRest")
    local function OnRestEvent(_, event)
        if event == "PLAYER_REGEN_ENABLED" then
            if restPending then UpdateRestIndicator() end
        else
            UpdateRestIndicator()
        end
    end
    restEvents:Sub("PLAYER_UPDATE_RESTING", OnRestEvent, "unitless")
    restEvents:Sub("PLAYER_ENTERING_WORLD", OnRestEvent, "unitless")
    restEvents:Sub("PLAYER_REGEN_ENABLED",  OnRestEvent, "unitless")
    f._restFrame    = restFrame
    f._UpdateRestIndicator = UpdateRestIndicator

    self.oufPlayer = f

    -- Raid group text listener: update on group changes so the
    -- "[Group X]" text reflects the player's current subgroup.
    -- v86 (event refactor stage 4): own owner, for the reason noted on
    -- restEvents above -- these two subscriptions overlap on
    -- PLAYER_ENTERING_WORLD. Both events are unitless.
    local raidGroupEvents = BF:EventOwner("oufPlayerRaidGroup")
    local function OnRaidGroupChanged()
        if BF.oufPlayer and BF._UpdateRaidGroupText then
            BF:_UpdateRaidGroupText(BF.oufPlayer)
        end
    end
    raidGroupEvents:Sub("GROUP_ROSTER_UPDATE",  OnRaidGroupChanged, "unitless")
    raidGroupEvents:Sub("PLAYER_ENTERING_WORLD", OnRaidGroupChanged, "unitless")

    self:BuildOUFResourceBar()
    self:BuildOUFPowerBar()

    -- Alt power bar (detachable)
    self:BuildOUFAltPowerBar()

    self:ApplyOUFPlayerLayout()
    -- Force an initial update so health/power text and bar colors are populated.
    -- C_Timer.After(0) is too early at login -- unit data (name, health, power)
    -- isn't available yet on the first tick after Spawn.  Use a short delay so
    -- the engine has finished populating unit data before we read it.
    -- A second pass at 1.0 s catches the rare case where the first pass still
    -- lands before PLAYER_LOGIN data is fully flushed (e.g. slow realm).
    C_Timer.After(0.5, function()
        if f.UpdateAllElements then f:UpdateAllElements("Manual") end
        if f.UpdateTags        then f:UpdateTags() end
    end)
    C_Timer.After(1.0, function()
        if f.UpdateAllElements then f:UpdateAllElements("Manual") end
        if f.UpdateTags        then f:UpdateTags() end
    end)
end

-- Layout
-- Called on build and whenever the profile changes a layout-affecting value.

-- ============================================================
-- v91: THE UNPROTECTED HALF OF THE PLAYER LAYOUT.
--
-- ApplyOUFPlayerLayout opens with RunSecure and is therefore swallowed for
-- the whole of a fight, because it touches `f` -- a secure unit button whose
-- SetSize/SetPoint are protected. Everything in HERE is a plain
-- StatusBar/Frame/Texture, so it is legal in combat, and since v91 fixed the
-- frame's height it is also the complete set of work a shapeshift needs.
--
-- That is what closes the owner-reported bug: the alt power bar resizes
-- itself on a form change with no combat guard (UNIT_DISPLAYPOWER), and the
-- layout that had to agree with it could not run until combat ended -- so the
-- power bar hung outside its border, or left a gap, for the rest of the
-- fight. Now nothing protected has to agree with anything.
--
-- withTail: false from ApplyOUFPlayerLayout, which runs the text/border/
-- absorb passes itself further down and must not pay for them twice; true (or
-- omitted) from a standalone form change, which needs them.
-- ============================================================
function BF:ApplyOUFPlayerBarGeometry(withTail)
    local f = self.oufPlayer
    if not f then return end
    -- Re-entrancy: ApplyOUFAltPowerBarLayout below ends in
    -- UpdateOUFAltPowerBar, and an active/inactive edge there calls back in
    -- here. One pass is enough -- the second would recompute identical
    -- numbers from the same profile.
    if self._oufBarGeomBusy then return end
    self._oufBarGeomBusy = true

    local pf      = self.ufDB.profile.player or {}
    local nameH   = pf.nameBarHeight or 13
    local healthH = self:GetOUFPlayerHealthBandHeight()   -- band, incl. reserve
    local powerH  = self:GetPowerBarEffectiveHeight()
    local barW    = pf.frameWidth or 156
    local altH    = self:GetAltPowerBarEffectiveHeight()  -- active, not reserved

    -- Chord insets move with the band split, and nothing here is protected --
    -- the icon frame itself is, but v91 removed the altH/2 nudge that was the
    -- only reason a form change had to touch it.
    local _, _, inL_health, inR_health =
        BF:_ComputeOUFIconInsets(f, nameH, healthH, powerH, altH)

    if f.Health then
        local barH_w      = BF:PixelRound(barW - inL_health - inR_health)
        local healthDrawn = self:GetOUFPlayerHealthDrawnHeight()
        -- v90.4: anchor side by ICON side (see GetOUFBarAnchorSide) so
        -- every bar's far edge lands on the same snapped pixel.
        local anchorPt  = BF:GetOUFBarAnchorSide(f, inL_health)
        local container = f._oufHealthContainer
        local clip      = f._oufHealthClipFrame
        -- Explicit single-point anchor + SetSize on all three, rather than a
        -- SetAllPoints chain: see the long note in ApplyOUFPlayerLayout's
        -- history about the post-Spawn stale-width fill spill.
        if container then
            container:ClearAllPoints()
            container:SetPoint(anchorPt, f, anchorPt, 0, -nameH)
            container:SetSize(barH_w, healthDrawn)
            if clip then
                clip:ClearAllPoints()
                clip:SetPoint(anchorPt, f, anchorPt, 0, -nameH)
                clip:SetSize(barH_w, healthDrawn)
            end
        end
        f.Health:ClearAllPoints()
        f.Health:SetPoint(anchorPt, f, anchorPt, 0, -nameH)
        f.Health:SetSize(barH_w, healthDrawn)
    end

    -- Alt power bar before the power bar: the power bar no longer anchors to
    -- it, but the border de-duplication reads the state this pass resolves.
    if self.ApplyOUFAltPowerBarLayout then self:ApplyOUFAltPowerBarLayout() end
    self:ApplyOUFPowerBarLayout()

    if withTail ~= false then
        -- Health text rides the health bar, so it moves when the bar does.
        BF:_ApplyOUFBarTextPositions(f, "player")
        -- Border boxes, per-bar round kits and separator lines all describe
        -- the rects that just changed.
        BF:_ApplyOUFFrameBorder(f)
        -- Absorb/heal-prediction overlays are anchored into the health clip
        -- chain and inherit its height.
        if self.ApplyOUFAbsorbLayout then self:ApplyOUFAbsorbLayout(f) end
    end

    self._oufBarGeomBusy = nil
end

function BF:ApplyOUFPlayerLayout()
    local f = self.oufPlayer
    if not f then return end
    -- Grid2 parity (UpdateSize tier): queue at priority 7 in combat. The
    -- §3.6 superset tail at function end calls UpdateVisibility so this
    -- pri-7 method remains a superset of pri-8 UpdateVisibility under
    -- RunSecure's strict-priority displacement.
    if self:RunSecure(7, self, "ApplyOUFPlayerLayout") then return end
    local p = self.ufDB.profile

    local pf    = p.player or {}
    local nameH = pf.nameBarHeight       or 13
    -- v91: the health BAND, not the raw setting -- it already includes the
    -- alt power bar's reserved strip when that bar is eligible. See
    -- BF:GetOUFPlayerHealthBandHeight (oUF_AltPowerBar.lua).
    local healthH   = self:GetOUFPlayerHealthBandHeight()
    local powerH    = self:GetPowerBarEffectiveHeight()
    local barW      = pf.frameWidth          or 156
    local scale     = pf.frameScale          or 1.0
    local alpha     = pf.frameAlpha          or 1.0

    -- Alt power bar height: only included when the bar is actually active
    -- (enabled, attached, druid in a shapeshift form with spec toggled on).
    local altH = self:GetAltPowerBarEffectiveHeight()

    -- v91: THE PLAYER FRAME'S HEIGHT NO LONGER DEPENDS ON THE ALT POWER BAR.
    --
    -- It used to be nameH + healthH + altH + powerH, so a druid shifting form
    -- changed the frame's height. `f` is an oUF secure unit button, which
    -- makes SetSize PROTECTED -- which is why this whole function opens with
    -- RunSecure and is swallowed for the duration of a fight. The alt bar's
    -- own resize (UpdateOUFAltPowerBar) has no such guard, so mid-combat the
    -- two halves disagreed: the spacer grew, the frame did not, and the power
    -- bar rendered outside its border until combat ended and the queued
    -- layout replayed. Owner-reported, in both directions (overhang when
    -- shifting in, gap when shifting out).
    --
    -- The alt bar now takes its height out of the BOTTOM of the HEALTH bar
    -- instead. The total is invariant, so nothing protected has to run on a
    -- form change and the swap is legal in combat -- see
    -- BF:ApplyOUFPlayerBarGeometry below, the unprotected half of this
    -- function and the only part a form change needs.
    --
    -- Health rather than power, on the owner's call: the power bar can be
    -- detached, and reserving from a bar that may not be there would put the
    -- behavior back under a conditional. The health bar is always attached.
    --
    -- healthH here is the BAND, so this total already carries the reserved
    -- strip. It changes only on things that cannot happen mid-combat anyway
    -- (spec change, or the user editing a height), never on a form change.
    f:SetSize(barW, nameH + healthH + powerH)
    f:SetAlpha(alpha)
    f:SetScale(scale)
    local ufAncX, ufAncY = BF:GetUFAnchor("player")
    local ancX = ufAncX or pf.anchorX or 660
    local ancY = ufAncY or pf.anchorY or 420
    -- ancX/ancY are the frame/anchor TOPLEFT in UIParent virtual coords.
    -- Clamp to screen so a stale/corrupted saved value can't hide the frame.
    local visualW = barW * scale
    local visualH = (nameH + healthH + powerH) * scale
    ancX, ancY = BF:_ClampTopleftToScreen(ancX, ancY, visualW, visualH)
    -- Position the invisible anchor at the saved TOPLEFT, then pin the frame
    -- to the anchor's TOPLEFT (same pattern as raid/party anchor system).
    if f._anchor then
        f._anchor:ClearAllPoints()
        f._anchor:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", ancX, ancY)
    end
    f:ClearAllPoints()
    if f._anchor then
        f:SetPoint("TOPLEFT", f._anchor, "TOPLEFT", 0, 0)
    else
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", ancX, ancY)
    end

    -- Icon frame
    BF:_ApplyOUFIconBlock(f, "player")

    -- v91: the altH/2 icon nudge is GONE. It existed because the frame grew
    -- downward by altH and the icon had to follow the bar block; with a fixed
    -- frame height the block does not move, so there is nothing to correct.
    -- Removing it also removes the only protected call a form change used to
    -- need -- _iconFrame is a SecureUnitButtonTemplate button and cannot be
    -- re-anchored in combat. The matching term in _ComputeOUFIconInsets
    -- (oUF_Shared.lua, "KEEP IN SYNC" note) is removed with it.

    -- v91: the unprotected half, extracted so a shapeshift can run it on its
    -- own. Passing false because this function does the text/border/absorb
    -- tail itself, further down.
    self:ApplyOUFPlayerBarGeometry(false)

    -- Force an immediate health color update in case the option changed
    if f.Health and f.__unit then
        local r, g, b, isGradient, gradAlpha = BF:_GetOUFHealthColor(f.__unit, pf.useClassColor, "player")
        local fillAlpha = BF:_GetOUFHealthBarFillAlpha("player", isGradient, gradAlpha)
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
    BF:_ApplyOUFPowerBgColor(f)

    -- Bar text font sizes and positions (health only; power is handled by ApplyOUFPowerBarLayout)
    local hFontSz = pf.healthFontSize or 8
    local hFont = BF:GetOUFFont(nil, GameFontNormalSmall:GetFont())
    if f.HealthPctText then f.HealthPctText:SetFont(hFont, hFontSz, "") end
    if f.HealthValText then f.HealthValText:SetFont(hFont, hFontSz, "") end
    BF:_ApplyOUFBarTextPositions(f, "player")

    BF:_ApplyOUFNameBarTextPositions(f, "player")

    if f._handle then
        if f._anchor and f._anchor.SnapHandle then f._anchor.SnapHandle() end
        local locked = self.db.global.locked
        if locked == nil then locked = true end
        f._handle:SetShown(not locked)
        f:SetMovable(not locked)
    end

    -- oUF aura layout (12.1 AuraContainer: size/spacing/max baked at spawn).
    -- Buffs (below the frame, mirroring target layout but driven by player
    -- profile keys). v67: size/spacing/max apply LIVE via
    -- _ApplyOUFAuraLiveGeometry; anchoring and wrap width follow here.
    if f.Buffs then
        local show   = pf.playerShowBuffs == true
        local perRow = pf.playerBuffsPerRow   or 8
        local offX   = pf.playerBuffOffsetX   or 0
        local offY   = pf.playerBuffOffsetY   or 0
        local sz, spacing = BF:_ApplyOUFAuraLiveGeometry(f.Buffs, pf, "player", "Buff")
        f.Buffs:SetFlowLayoutMaximumLineSize(perRow * (sz + spacing))
        f.Buffs:ClearAllPoints()
        f.Buffs:SetPoint("TOPLEFT", f, "BOTTOMLEFT", offX, offY)
        f.Buffs._bf_userShown = show
    end

    -- Debuffs (above the frame, mirroring target layout)
    if f.Debuffs then
        local show   = pf.playerShowDebuffs == true
        local perRow = pf.playerDebuffsPerRow  or 8
        local offX   = pf.playerDebuffOffsetX  or 0
        local offY   = pf.playerDebuffOffsetY  or 0
        local sz, spacing = BF:_ApplyOUFAuraLiveGeometry(f.Debuffs, pf, "player", "Debuff")
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
    -- Name bar gating (strip background + text master switch). Runs
    -- AFTER _ApplyOUFFrameBorder so the Hide() on fb.name wins over
    -- ApplyBox's re-show.
    BF:_ApplyOUFNameBarState(f, "player")
    BF:_ApplyOUFRaidTargetIndicator(f, "player")
    BF:_ApplyOUFPhaseIndicator(f, "player")

    -- Combat Indicator
    if f.CombatIndicator then
        if p.oufShowCombatIndicator then
            local sz = p.oufCombatIndicatorSize or 18
            f.CombatIndicator:SetSize(sz, sz)
            f.CombatIndicator:ClearAllPoints()
            f.CombatIndicator:SetPoint("CENTER", f.Health, "CENTER", 0, 0)
            if f._combatFrame then f._combatFrame:Show() end
            -- oUF manages show/hide via UNIT_FLAGS; force an update
            if f.CombatIndicator.ForceUpdate then f.CombatIndicator:ForceUpdate() end
        else
            f.CombatIndicator:Hide()
            if f._combatFrame then f._combatFrame:Hide() end
        end
    end
    -- oUF drops element events on a frame that is not visible
    -- (Libs/oUF/events.lua), so ClassPower and Runes have to follow whichever
    -- of the player frame / hidden host is actually shown. Covers both the
    -- player raid-style twin and the plain showPlayerFrame toggle. Runs before
    -- ApplyOUFResourceBarLayout, which reads the owner's ClassPower state.
    if self.SyncClassPowerHost then self:SyncClassPowerHost() end
    BF:ApplyOUFResourceBarLayout()
    -- Global Ping Indicator settings (all frames — cheap; re-applied
    -- here so relayoutAll/login always covers icon-visibility changes
    -- affecting the Class Icon anchor fallback).
    BF:ApplyOUFPingIndicators()

    -- Rested indicator: refresh position after any layout change
    if f._restFrame and f._UpdateRestIndicator then
        f._UpdateRestIndicator()
    end

    -- RegisterUnitWatch (called by Enable) installs a secure state driver that
    -- can reposition the frame. Re-apply position (anchor then frame) after the
    -- current execution context yields so our SetPoint always wins.
    --
    -- The player raid-style twin replaces this frame outright: unlike
    -- target/focus/boss it needs no [@player,help] driver (the player is
    -- always assistable), so the twin case is exactly the showPlayerFrame=false
    -- case -- Disable, with ClassPower/Runes already moved to the hidden host
    -- by SyncClassPowerHost above.
    -- Guarded: UnitFrames/Twins.lua loads after this file.
    local twinOwnsPlayer = self.IsTwinActive and self:IsTwinActive("player")
    if p.showPlayerFrame and not twinOwnsPlayer then f:Enable() else f:Disable() end
    if f._anchor then
        f._anchor:ClearAllPoints()
        f._anchor:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", ancX, ancY)
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", f._anchor, "TOPLEFT", 0, 0)
    else
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", ancX, ancY)
    end
    C_Timer.After(0, function()
        if not f:GetParent() then return end
        if InCombatLockdown() then return end
        if f._anchor then
            f._anchor:ClearAllPoints()
            f._anchor:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", ancX, ancY)
            f:ClearAllPoints()
            f:SetPoint("TOPLEFT", f._anchor, "TOPLEFT", 0, 0)
        else
            f:ClearAllPoints()
            f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", ancX, ancY)
        end
        if f._anchor and f._anchor.SnapHandle and f._handle then
            f._anchor.SnapHandle()
        end
    end)

    -- Re-anchor absorb/overshield/heal prediction overlays after bar resize.
    if self.ApplyOUFAbsorbLayout then self:ApplyOUFAbsorbLayout(f) end

    -- Refresh the setup-mode test frame so it stays in sync with any
    -- size/scale/position changes applied above.
    if self._ufTestFrames and self._ufTestFrames["player"] then
        local g = self.db.global
        if g.setupModeActive then
            self:ShowUFTestFrames()
        end
    end

    -- Superset tail (§3.6): keep pri 7 a superset of pri 8 so a queued
    -- pri-8 UpdateVisibility isn't silently dropped when this method
    -- displaces it under RunSecure's strict-priority ordering.
    if self.UpdateVisibility then self:UpdateVisibility() end
end
