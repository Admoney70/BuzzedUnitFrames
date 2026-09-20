-- ============================================================
-- BuzzardFrames: UnitFrames/oUF_BossPreview.lua
-- Boss frame preview for the options panel (Unit Frames > Boss Frames >
-- Preview). Out of combat it force-shows the five REAL oUF boss frames --
-- exact styling, exact position -- and paints dummy data onto them, each
-- slot as an enemy (NPC boss / hostile coloring, "??" level) or a friendly
-- boss (NPC friendly coloring) -- bosses 1-3 start enemy, 4-5 friendly,
-- and the Preview tab toggles each one.
-- plus a looping animated cast on every cast bar and a few dummy buff /
-- debuff icons where the engine-owned aura containers sit (the containers
-- themselves are C-side and cannot be fed fake auras, so the icons are
-- drawn on an insecure overlay per frame).
--
-- Raid-style twin (UnitFrames/Twins.lua): with bossRaidStyle on, a friendly
-- boss shows the twin instead of the oUF frame, so slots 4 and 5 preview
-- the twin: a frame built by the raid PREVIEW engine itself
-- (Preview/Options_PreviewSystem.lua, BF:MakeStandalonePreviewFrame /
-- BF:PaintStandalonePreviewFrame -- the very pipeline the Preview section
-- draws with), laid out from the active flat at the boss twin scale, pinned
-- to the oUF frame's TOPLEFT exactly where AnchorTwin pins the real twin.
-- The real twin and those two oUF frames stay driver-hidden. A boss cast bar
-- is a child of its oUF frame and never detaches, so a twin slot draws no
-- cast bar -- same as the live twin.
--
-- Secure rules: the unit watch / visibility driver swap and the Show() are
-- out-of-combat only. PLAYER_REGEN_DISABLED ends the preview immediately
-- for everything insecure (cast bar scripts, overlays, twin previews); the
-- forced-shown secure frames are handed back on PLAYER_REGEN_ENABLED.
-- Every relayout (ApplyOUFBossFrameLayout) re-Enables the frames, so the
-- preview re-asserts itself from a hook on it -- position, size, cast bar
-- position and aura edits all show live.
-- ============================================================
local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local CreateFrame, UIParent = CreateFrame, UIParent
local InCombatLockdown = InCombatLockdown
local RegisterUnitWatch, UnregisterUnitWatch = RegisterUnitWatch, UnregisterUnitWatch
local UnregisterStateDriver = UnregisterStateDriver
local UnitLevel, GetTime = UnitLevel, GetTime
local ipairs, pairs, format, floor = ipairs, pairs, string.format, math.floor

local NUM_BOSS_FRAMES = 5
-- Per-slot friendliness lives in db.global.bossPreviewFriendly (Defaults.lua:
-- bosses 1-3 enemy, 4-5 friendly) -- saved, but global, so it never
-- travels with a profile export; db.global.showBossPreview likewise.
local function G() return BF.db and BF.db.global end

local function SlotFriendly(i)
    local g = G()
    local t = g and g.bossPreviewFriendly
    if t and t[i] ~= nil then return t[i] and true or false end
    return i >= 4
end
local CAST_DURATION   = 2.5        -- seconds per looping preview cast
local REPAINT_PERIOD  = 0.5        -- text/bar re-assert cadence while on
local AURA_RESTART    = 30         -- dummy aura cooldown restart (matches DummyAuras)

local CAST_ICON = "Interface\\Icons\\Spell_Fire_Fireball02"
local ENEMY_PORTRAIT    = "Interface\\Icons\\Achievement_Boss_Lichking"
local FRIENDLY_PORTRAIT = "Interface\\Icons\\Achievement_Character_Human_Male"
local BUFF_ICONS = {
    "Interface\\Icons\\Spell_Holy_PowerWordShield",
    "Interface\\Icons\\Spell_Nature_Regeneration",
    "Interface\\Icons\\Ability_Warrior_BattleShout",
}
local DEBUFF_ICONS = {
    "Interface\\Icons\\Spell_Shadow_ShadowWordPain",
    "Interface\\Icons\\Ability_Rogue_Rupture",
}
-- Per-slot fake health / power percentages so the five bars read as five
-- different units rather than a row of identical fills.
local FAKE_HEALTH = { 0.82, 0.55, 0.31, 0.94, 0.67 }
local FAKE_POWER  = { 0.60, 0.25, 0.90, 0.45, 0.80 }

local previewOn      = false
local restorePending = false       -- secure hand-back deferred to regen
local repaintTicker, auraTicker
local twinPreviews   = {}          -- slot -> standalone preview frame
local twinHolder

local events = BF:EventOwner("oufBossPreview")

-- ============================================================
-- Settings reads
-- ============================================================
local function P()  return BF.ufDB and BF.ufDB.profile end
local function PF() local p = P(); return p and (p.boss or {}) or {} end

local function TwinOn()
    return BF.IsTwinActive and BF:IsTwinActive("boss") or false
end

-- Slot i previews the twin (friendly + twin on), else the oUF frame.
local function SlotIsTwin(i)
    return SlotFriendly(i) and TwinOn() or false
end

-- The flat the boss twin is built from: the same resolver
-- BF:_ResolveHeaderSizeAndScale takes for the main raid/party header, then
-- its ID by identity in flatLayouts (the preview engine is keyed by ID).
local function TwinFlatID()
    if BF._contextIsRaid == nil and BF.ResolveContext then BF:ResolveContext() end
    local ap = BF._resolvedProfile
    if not ap then
        if BF.InvalidateRaidProfileCache then BF:InvalidateRaidProfileCache() end
        ap = BF:ResolveActiveIsRaid() and BF:GetRaidProfile() or BF:GetActivePartyProfile()
    end
    if not ap then return nil end
    local lp = BF.rpDB and BF.rpDB.profile and BF.rpDB.profile.layouts
    local fl = lp and lp.flatLayouts or {}
    for id, flat in pairs(fl) do
        if flat == ap then return id end
    end
    return nil
end

-- NPC colors the way _GetOUFHealthColor / _GetOUFNameColor resolve them,
-- without a unit: an enemy boss is "boss" under classification and hostile
-- under hostility; a friendly boss is "friendly" under both.
local function NpcColor(p, mode, friendly, staticKey, dr, dg, db)
    local c
    if mode == "classification" then
        c = friendly and p.globalNpcFriendlyColor or p.globalNpcBossColor
    elseif mode == "hostility" then
        c = friendly and p.globalNpcFriendlyColor or p.globalNpcRegularColor
    end
    c = c or p[staticKey]
    if c then return c.r, c.g, c.b end
    if friendly then return 0.0, 0.65, 0.0 end
    return dr, dg, db
end

local function HealthColor(p, friendly)
    local mode = p.globalNpcHealthColorMode or "classification"
    -- Gradient mode has no unit to sample; the static color stands in.
    if mode == "gradient" then mode = "static" end
    return NpcColor(p, mode, friendly, "globalNpcHealthColor", 0.8, 0.1, 0.1)
end

local function NameColor(p, friendly)
    local mode = p.globalNpcNameColorMode or "classification"
    return NpcColor(p, mode, friendly, "globalNpcNameColor", 1, 1, 1)
end

-- ============================================================
-- Dummy aura overlay (oUF slots)
-- ============================================================
-- One insecure overlay per oUF boss frame carrying plain icon textures where
-- the Buffs / Debuffs containers sit. Geometry mirrors the container
-- anchoring in oUF_BossFrames.lua / _ApplyOUFRightFrameLayout: buffs hang
-- off the frame's BOTTOMLEFT (pushed by GetOUFBuffRowPush for a Bottom cast
-- bar), debuffs stand on its TOPLEFT. Border: the flat 1px box in the aura
-- border color; the rounded / Blizzard styles are not reproduced here.
local function EnsureAuraOverlay(f)
    local ov = f._bf_bossPreviewAuras
    if ov then return ov end
    ov = CreateFrame("Frame", nil, f)
    ov:SetAllPoints(f)
    ov:SetFrameLevel(f:GetFrameLevel() + 6)
    ov:EnableMouse(false)
    ov._icons = {}
    ov:Hide()
    f._bf_bossPreviewAuras = ov
    return ov
end

local function EnsureIcon(ov, idx)
    local ic = ov._icons[idx]
    if ic then return ic end
    ic = CreateFrame("Frame", nil, ov)
    ic:EnableMouse(false)
    local tex = ic:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints(ic)
    tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    ic._tex = tex
    local function Edge()
        local t = ic:CreateTexture(nil, "OVERLAY")
        t:SetColorTexture(0, 0, 0, 0.8)
        return t
    end
    ic._top, ic._bottom, ic._left, ic._right = Edge(), Edge(), Edge(), Edge()
    ic._top:SetPoint("TOPLEFT");       ic._top:SetPoint("TOPRIGHT")
    ic._bottom:SetPoint("BOTTOMLEFT"); ic._bottom:SetPoint("BOTTOMRIGHT")
    ic._left:SetPoint("TOPLEFT");      ic._left:SetPoint("BOTTOMLEFT")
    ic._right:SetPoint("TOPRIGHT");    ic._right:SetPoint("BOTTOMRIGHT")
    ov._icons[idx] = ic
    return ic
end

-- Lays one row of `n` icons from `startIdx`: the first icon's `iconPoint`
-- corner sits at (x0, y0) from the frame's `framePoint` corner -- the way
-- the container's initialAnchor corner is pinned to the frame -- growing
-- right, wrapping by `growY` (+1 up for debuffs, -1 down for buffs).
local function LayoutIconRow(ov, f, startIdx, n, textures, iconPoint, framePoint,
                             x0, y0, sz, spacing, perRow, growY, bc, thick)
    local idx = startIdx
    for k = 1, n do
        local ic  = EnsureIcon(ov, idx)
        local col = (k - 1) % perRow
        local row = floor((k - 1) / perRow)
        ic:SetSize(sz, sz)
        ic:ClearAllPoints()
        ic:SetPoint(iconPoint, f, framePoint,
            x0 + col * (sz + spacing),
            y0 + growY * row * (sz + spacing))
        ic._tex:SetTexture(textures[((k - 1) % #textures) + 1])
        local r, g, b, a = bc.r or 0, bc.g or 0, bc.b or 0, bc.a or 0.8
        for _, e in ipairs({ ic._top, ic._bottom, ic._left, ic._right }) do
            e:SetColorTexture(r, g, b, a)
            e:SetShown(thick > 0)
        end
        ic._top:SetHeight(thick); ic._bottom:SetHeight(thick)
        ic._left:SetWidth(thick); ic._right:SetWidth(thick)
        ic:Show()
        idx = idx + 1
    end
    return idx
end

local function PaintAuraOverlay(f)
    local p, pf = P(), PF()
    local ov = EnsureAuraOverlay(f)
    local idx = 1
    local bc = p.oufAuraBorderColor or { r = 0, g = 0, b = 0, a = 0.8 }
    local thick = BF:PixelsToUI(p.oufAuraBorderThickness or 1)

    if pf.bossShowBuffs ~= false then
        local sz      = pf.bossBuffSize    or 18
        local spacing = pf.bossBuffSpacing or 2
        local perRow  = pf.bossBuffsPerRow or 8
        local maxN    = pf.bossMaxBuffs    or 8
        local n       = math.min(#BUFF_ICONS, maxN)
        local offX    = pf.bossBuffOffsetX or 0
        local offY    = (pf.bossBuffOffsetY or 0) - BF:GetOUFBuffRowPush("boss", p)
        -- Container: its TOPLEFT on the frame's BOTTOMLEFT; icons grow
        -- right and wrap downward.
        idx = LayoutIconRow(ov, f, idx, n, BUFF_ICONS, "TOPLEFT", "BOTTOMLEFT",
            offX, offY, sz, spacing, perRow, -1, bc, thick)
    end
    if pf.bossShowDebuffs ~= false then
        local sz      = pf.bossDebuffSize    or 18
        local spacing = pf.bossDebuffSpacing or 2
        local perRow  = pf.bossDebuffsPerRow or 8
        local maxN    = pf.bossMaxDebuffs    or 8
        local n       = math.min(#DEBUFF_ICONS, maxN)
        local offX    = pf.bossDebuffOffsetX or 0
        local offY    = pf.bossDebuffOffsetY or 0
        -- Container: its BOTTOMLEFT on the frame's TOPLEFT; icons grow
        -- right and wrap upward.
        idx = LayoutIconRow(ov, f, idx, n, DEBUFF_ICONS, "BOTTOMLEFT", "TOPLEFT",
            offX, offY, sz, spacing, perRow, 1, bc, thick)
    end
    for k = idx, #ov._icons do ov._icons[k]:Hide() end
    ov:Show()
end

local function HideAuraOverlay(f)
    local ov = f._bf_bossPreviewAuras
    if ov then ov:Hide() end
end

-- ============================================================
-- Cast bar preview
-- ============================================================
-- oUF's own Castbar OnUpdate (Libs/oUF/elements/castbar.lua) hides the bar
-- on every frame while no cast is tracked, so it is swapped out for the
-- duration of the preview and put back on release.
local function PreviewCastOnUpdate(cb, elapsed)
    local t = (cb._bf_previewT or 0) + elapsed
    if t >= CAST_DURATION then t = t - CAST_DURATION end
    cb._bf_previewT = t
    cb:SetValue(t)
    if cb.Time then cb.Time:SetFormattedText("%.1f", CAST_DURATION - t) end
end

local function StopCastPreview(f)
    local cb = f.Castbar
    if not cb or not cb._bf_previewArmed then return end
    -- Only a live element gets its script back: oUF's Disable nils the
    -- script and its private STATE, and its Enable re-installs both.
    local live = f.IsElementEnabled and f:IsElementEnabled("Castbar")
    cb:SetScript("OnUpdate", live and cb._bf_previewOnUpdate or nil)
    if cb.Time and cb.Time.binding then cb.Time.binding:SetEnabled(live and true or false) end
    cb._bf_previewOnUpdate = nil
    cb._bf_previewArmed    = nil
    cb._bf_previewT        = nil
    if cb.Text  then cb.Text:SetText("") end
    if cb.Time  then cb.Time:SetText("") end
    if cb._icon then cb._icon:Hide() end
    cb:Hide()
end

local function StartCastPreview(f)
    local cb = f.Castbar
    local p  = P()
    if not cb then return end
    if p.bossShowCastBar == false then StopCastPreview(f); return end
    -- Re-checked every paint, not just once: a Show Cast Bar off/on cycle
    -- runs oUF's Disable/Enable on the element, which sets the script to
    -- nil and back to oUF's own onUpdate underneath the preview.
    local cur = cb:GetScript("OnUpdate")
    if cur ~= PreviewCastOnUpdate then
        cb._bf_previewOnUpdate = cur
        cb._bf_previewArmed    = true
        cb:SetScript("OnUpdate", PreviewCastOnUpdate)
        -- oUF 14 drives .Time through an engine duration binding; while it
        -- is enabled the text written here would be overwritten.
        if cb.Time and cb.Time.binding then cb.Time.binding:SetEnabled(false) end
        -- Likewise the bar value follows a StatusBar timer after a real
        -- cast; drop it if the client offers a way to.
        if cb.ClearTimerDuration then cb:ClearTimerDuration() end
    end
    local c = p.castBarColor
    if c then cb:SetStatusBarColor(c.r, c.g, c.b) else cb:SetStatusBarColor(1, 0.84, 0) end
    cb:SetMinMaxValues(0, CAST_DURATION)
    cb._bf_previewT = cb._bf_previewT or ((f._bossIndex or 1) - 1) * 0.5
    if cb.Text  then cb.Text:SetText("Preview Cast") end
    if cb.Delay then cb.Delay:SetText("") end
    if cb.Time  then cb.Time:Show() end
    if cb._niOverlay  then cb._niOverlay:SetAlpha(0) end
    if cb._iconShield then cb._iconShield:SetAlpha(0) end
    if cb.Shield      then cb.Shield:Hide() end
    if cb._icon then
        cb._icon:SetTexture(CAST_ICON)
        -- castStarting = true: sizes/anchors the icon and shows it when the
        -- boss cast bar icon is enabled (oUF_Castbar.lua).
        BF:_ApplyOUFCastbarIcon(f, true)
    end
    cb:Show()
end


-- ============================================================
-- oUF slot paint
-- ============================================================
local function ForceShow(f)
    UnregisterUnitWatch(f)
    UnregisterStateDriver(f, "visibility")
    f._bf_bossPreviewShown = true
    if not f:IsShown() then f:Show() end
end

-- Hand the frame back: a unit watch hides it at once (no unit), and
-- BF:ApplyTwins' repair arm swaps that watch for the twin driver when the
-- twin owns the slot (Twins.lua ActivateTwin, the UnitWatchRegistered term).
local function Release(f)
    if not f._bf_bossPreviewShown then return end
    f._bf_bossPreviewShown = nil
    UnregisterStateDriver(f, "visibility")
    RegisterUnitWatch(f)
end

local function PaintOUFSlot(f, i)
    local p, pf = P(), PF()
    local friendly = SlotFriendly(i)

    -- Name / level
    if f.Name then
        f.Name:SetText("Boss " .. i)
        local r, g, b = NameColor(p, friendly)
        f.Name:SetTextColor(r, g, b, 1)
    end
    if f.Level then
        local showLevel = (pf.showNameBarText ~= false) and (pf.showLevel ~= false)
        if friendly then
            f.Level:SetText(tostring(UnitLevel("player") or 80))
            if f._skullIcon then f._skullIcon:Hide() end
            f.Level:SetShown(showLevel)
        else
            f.Level:SetText("??")
            -- Boss-level units draw the skull in place of the level text
            -- (Health.PostUpdate, oUF_Shared.lua).
            if f._skullIcon then
                f._skullIcon:SetShown(showLevel)
                f.Level:Hide()
            else
                f.Level:SetShown(showLevel)
            end
        end
    end

    -- Health
    if f.Health then
        local r, g, b = HealthColor(p, friendly)
        local fillAlpha = BF:_GetOUFHealthBarFillAlpha("boss", false)
        f.Health:SetMinMaxValues(0, 100)
        f.Health:SetValue(FAKE_HEALTH[i] * 100)
        f.Health:SetStatusBarColor(r, g, b, fillAlpha)
        f._bf_healthR, f._bf_healthG, f._bf_healthB = r, g, b
        f._bf_healthA = fillAlpha
        local pctFmt = (pf.showHealthPctSymbol ~= false) and "%d%%" or "%d"
        if f.HealthPctText then
            f.HealthPctText:SetText(format(pctFmt, floor(FAKE_HEALTH[i] * 100 + 0.5)))
            f.HealthPctText:SetShown(pf.showHealthPct ~= false)
            f.HealthPctText:SetAlpha(1)
        end
        if f.HealthValText then
            f.HealthValText:SetText(AbbreviateNumbers(floor(FAKE_HEALTH[i] * 4200000)))
            f.HealthValText:SetShown(pf.showHealthVal ~= false)
            f.HealthValText:SetAlpha(1)
        end
        if f.DeadText then f.DeadText:SetAlpha(0) end
    end

    -- Power (mana blue from the shared table, as a boss with no unit would)
    if f.Power then
        local c = BF.PowerTypeColors and BF.PowerTypeColors.MANA or { r = 0, g = 0.5, b = 1 }
        f.Power:SetMinMaxValues(0, 100)
        f.Power:SetValue(FAKE_POWER[i] * 100)
        f.Power:SetStatusBarColor(c.r, c.g, c.b)
        local pPctFmt = (pf.showPowerPctSymbol ~= false) and "%d%%" or "%d"
        if f.PowerPctText then
            f.PowerPctText:SetText(format(pPctFmt, floor(FAKE_POWER[i] * 100 + 0.5)))
            f.PowerPctText:SetAlpha(1)
        end
        if f.PowerValText then
            f.PowerValText:SetText(AbbreviateNumbers(floor(FAKE_POWER[i] * 250000)))
            f.PowerValText:SetAlpha(1)
        end
    end

    -- Class icon / portrait block. With no unit behind the frame oUF never
    -- ran a single element update (UpdateAllElements bails on a unit that
    -- does not exist), so the block sat as a blank disc: run the real
    -- render once for its visibility pass, then put sample art on
    -- whichever region it chose.
    if f._iconFrame and f._iconFrame:IsShown() and BF._UpdateOUFIcon then
        BF:_UpdateOUFIcon(f, f.__unit or ("boss" .. i))
        local region = f._oufIconActive
        if region and region ~= f._squarePortraitModel then
            region:SetTexture(friendly and FRIENDLY_PORTRAIT or ENEMY_PORTRAIT)
            if (p.iconShape or "circular") == "circular" then
                region:SetTexCoord(0, 1, 0, 1)
            else
                region:SetTexCoord(0.15, 0.85, 0.15, 0.85)
            end
        elseif region and region.SetUnit then
            -- Model style: the only model there is to show.
            region:SetUnit("player")
            region:SetCamera(1)
            region:EnableMouse(false)
        end
    end

    -- Same cause for the indicator textures: never initialized, so the
    -- raid-target texture showed its whole marker sheet. Boss 1 gets the
    -- skull marker where the option puts it; the rest hide.
    if f.RaidTargetIndicator then
        if i == 1 and p.oufShowRaidTarget ~= false then
            SetRaidTargetIconTexture(f.RaidTargetIndicator, 8)
            f.RaidTargetIndicator:Show()
        else
            f.RaidTargetIndicator:Hide()
        end
    end
    if f.PhaseIndicator then f.PhaseIndicator:Hide() end

    -- The bar may still be parented to a twin stand-in from a slot that
    -- was friendly a moment ago; the oUF frame takes it back.
    if f.Castbar and f.Castbar:GetParent() ~= f and BF._RestoreAttachedCastbar then
        BF:_RestoreAttachedCastbar(f)
    end
    StartCastPreview(f)
    PaintAuraOverlay(f)
end

local function ReleaseOUFSlot(f)
    StopCastPreview(f)
    HideAuraOverlay(f)
    if f.Name then f.Name:SetText("") end
end

-- A twin slot's cast bar preview rides the stand-in; stop it and hand the
-- bar back to the oUF frame (the real layout re-syncs it on release).
local function ReleaseTwinSlotCastbar(f)
    StopCastPreview(f)
    if f.Castbar and f.Castbar:GetParent() ~= f and BF._RestoreAttachedCastbar then
        BF:_RestoreAttachedCastbar(f)
    end
end

-- ============================================================
-- Twin slot preview
-- ============================================================
local function EnsureTwinHolder()
    if twinHolder then return twinHolder end
    twinHolder = CreateFrame("Frame", "BuzzardFrames_BossPreviewTwinHolder", UIParent)
    twinHolder:SetSize(100, 68)
    twinHolder:SetFrameStrata("MEDIUM")
    twinHolder:SetFrameLevel(10)
    twinHolder:Hide()
    return twinHolder
end

local function PaintTwinSlot(f, i)
    if not (BF.MakeStandalonePreviewFrame and BF.PaintStandalonePreviewFrame) then return end
    local flatID = TwinFlatID()
    if not flatID then return end
    local holder = EnsureTwinHolder()
    -- Twin scale multiplies the flat's own scale, exactly as the twin holder
    -- carries header scale x twin scale (Twins.lua ResolveTwinGeometry).
    holder:SetScale(BF.GetTwinScale and BF:GetTwinScale("boss") or 1)
    holder:Show()
    local tp = twinPreviews[i]
    if not tp then
        tp = BF:MakeStandalonePreviewFrame("BuzzardFrames_BossPreviewTwin" .. i, holder)
        twinPreviews[i] = tp
    end
    tp:ClearAllPoints()
    tp:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    tp:Show()
    -- The slot's own unit: an NPC (no class, no role) named like the oUF
    -- slots, at the same fake health.
    local unit = tp._bf_previewUnit
    if not unit then
        unit = { name = "Boss " .. i, class = nil, role = "NONE" }
        tp._bf_previewUnit = unit
    end
    unit.hp = FAKE_HEALTH[i]
    -- The twin rule (BF:TwinForcesPowerBar, LayoutFrame.lua): the boss
    -- oUF frame's Show Power Bar switch alone decides the twin's power bar.
    unit.forcePower = (PF().showPowerBar ~= false)
    BF:PaintStandalonePreviewFrame(tp, flatID, true, unit)
    -- The attached oUF cast bar rides the twin (oUF_Castbar.lua); here it
    -- rides the stand-in, with the same looping preview cast.
    if f.Castbar and P().bossShowCastBar ~= false and BF._PlaceCastbarOnTwin then
        BF:_PlaceCastbarOnTwin(f, tp)
        StartCastPreview(f)
    end
end

local function HideTwinSlot(i)
    local tp = twinPreviews[i]
    if not tp then return end
    if BF.HideStandalonePreviewFrame then BF:HideStandalonePreviewFrame(tp) else tp:Hide() end
end

local function HideAllTwinSlots()
    for i in pairs(twinPreviews) do HideTwinSlot(i) end
    if twinHolder then twinHolder:Hide() end
end

-- ============================================================
-- Paint / release passes
-- ============================================================
local painting = false   -- re-entrancy guard for the ApplyTwins hook

local function Paint()
    local frames = BF.oufBoss
    if not frames then return end
    painting = true
    for i = 1, NUM_BOSS_FRAMES do
        local f = frames[i]
        if f then
            if SlotIsTwin(i) then
                Release(f)
                ReleaseOUFSlot(f)
                PaintTwinSlot(f, i)
            else
                HideTwinSlot(i)
                ForceShow(f)
                PaintOUFSlot(f, i)
            end
        end
    end
    if not TwinOn() and twinHolder then twinHolder:Hide() end
    -- A slot handed back while the twin owns it needs the twin driver put
    -- back on its oUF frame (ApplyTwins' repair arm); idempotent otherwise.
    if TwinOn() and BF.ApplyTwins then BF:ApplyTwins() end
    painting = false
end

-- Insecure half of the teardown: safe in combat.
local function ReleaseInsecure()
    local frames = BF.oufBoss
    if frames then
        for i = 1, NUM_BOSS_FRAMES do
            local f = frames[i]
            if f then
                ReleaseOUFSlot(f)
                ReleaseTwinSlotCastbar(f)
            end
        end
    end
    HideAllTwinSlots()
    if repaintTicker then repaintTicker:Cancel(); repaintTicker = nil end
    if auraTicker    then auraTicker:Cancel();    auraTicker    = nil end
end

-- Secure half: hand the frames back and re-run the real layout so every
-- element is repainted from the real (absent) units.
local function ReleaseSecure()
    local frames = BF.oufBoss
    if frames then
        for i = 1, NUM_BOSS_FRAMES do
            local f = frames[i]
            if f then Release(f) end
        end
    end
    if BF.ApplyOUFBossFrameLayout then BF:ApplyOUFBossFrameLayout() end
    if BF.ApplyTwins then BF:ApplyTwins() end
    if frames then
        for i = 1, NUM_BOSS_FRAMES do
            local f = frames[i]
            if f and f.UpdateAllElements then f:UpdateAllElements("ForceUpdate") end
        end
    end
end

-- ============================================================
-- Public API
-- ============================================================
function BF:IsBossPreviewActive()
    return previewOn
end

-- Per-slot friendliness (Boss Frames > Preview: "Boss N: Enemy / Friendly").
-- A change while previewing repaints at once, which is also what swaps a
-- slot between the oUF frame and the twin.
function BF:IsBossPreviewFriendly(i)
    return SlotFriendly(i)
end

function BF:SetBossPreviewFriendly(i, friendly)
    if type(i) ~= "number" or i < 1 or i > NUM_BOSS_FRAMES then return end
    local g = G()
    if not g then return end
    g.bossPreviewFriendly = g.bossPreviewFriendly or { false, false, false, true, true }
    g.bossPreviewFriendly[i] = friendly and true or false
    self:RepaintBossPreview()
end

-- The saved switch (db.global.showBossPreview): the preview runs whenever
-- the options panel is open, the way showPreview drives the raid previews.
function BF:IsBossPreviewEnabled()
    local g = G()
    return g and g.showBossPreview == true or false
end

-- Re-assert the preview after anything that re-laid-out or re-Enabled the
-- boss frames. No-op while off; deferred past combat.
function BF:RepaintBossPreview()
    if not previewOn then return end
    if InCombatLockdown() then return end
    if not self.oufBoss then return end
    -- Boss frames switched off underneath the preview (the layout just
    -- Disabled them): the preview goes with them rather than re-showing
    -- frames the user turned off.
    local p = P()
    if not (p and p.ptfEnabled and p.showBossFrames) then
        self:_RunBossPreview(false)
        return
    end
    Paint()
end

-- The user's switch: saves the flag, then starts or stops.
function BF:SetBossPreview(on)
    on = on and true or false
    local g = G()
    if g then g.showBossPreview = on end
    self:_RunBossPreview(on)
end

-- Panel open: pick the saved switch up. Panel close, combat, loading
-- screen: stop without touching it.
function BF:ResumeBossPreview()
    if self:IsBossPreviewEnabled() then self:_RunBossPreview(true) end
end

function BF:StopBossPreview()
    self:_RunBossPreview(false)
end

-- Runtime start/stop; the saved flag is the caller's business.
function BF:_RunBossPreview(on)
    on = on and true or false
    if on == previewOn then
        if on then self:RepaintBossPreview() end
        return
    end
    if on then
        if InCombatLockdown() then return end
        local p = P()
        if not (p and p.ptfEnabled and p.showBossFrames) then return end
        if not self.oufBoss then
            if self.BuildOUFBossFrames then self:BuildOUFBossFrames() end
            if not self.oufBoss then return end
        end
        previewOn = true
        restorePending = false
        Paint()
        repaintTicker = C_Timer.NewTicker(REPAINT_PERIOD, function()
            -- Text and bar values only; the cast bars animate on their own
            -- OnUpdate. Anything (a tag refresh, an element ForceUpdate)
            -- that wrote a real value back is overwritten here.
            if previewOn and not InCombatLockdown() and BF.oufBoss then
                for i = 1, NUM_BOSS_FRAMES do
                    local f = BF.oufBoss[i]
                    if f and f._bf_bossPreviewShown then
                        -- ForceShow, not a bare Show(): anything that
                        -- re-Enabled the frame put a unit watch back on
                        -- it, and a watched frame with no unit is hidden
                        -- again on the next evaluation -- a bare Show()
                        -- here made it flash twice a second.
                        if not f:IsShown() then ForceShow(f) end
                        PaintOUFSlot(f, i)
                    end
                end
            end
        end)
        auraTicker = C_Timer.NewTicker(AURA_RESTART, function()
            -- Dummy aura cooldowns on the twin previews run out after
            -- AURA_RESTART seconds (DummyAuras); repaint restarts them.
            if previewOn and not InCombatLockdown() then
                for i, tp in pairs(twinPreviews) do
                    if tp:IsShown() and BF.oufBoss and BF.oufBoss[i] then
                        PaintTwinSlot(BF.oufBoss[i], i)
                    end
                end
            end
        end)
    else
        previewOn = false
        ReleaseInsecure()
        if InCombatLockdown() then
            restorePending = true
        else
            ReleaseSecure()
        end
    end
end

-- ============================================================
-- Hooks and events
-- ============================================================
-- Every relayout re-Enables the frames (RegisterUnitWatch hides them); the
-- hook puts the preview back the moment the layout returns.
hooksecurefunc(BF, "ApplyOUFBossFrameLayout", function()
    if previewOn then BF:RepaintBossPreview() end
end)

-- ApplyTwins runs AFTER the boss layout inside ApplyOUFVisibility, and its
-- twin off-switch hands the oUF frames their unit watch back (ReleaseOUFFrame
-- -> Enable), hiding frames the layout hook had just force-shown. Repaint
-- once it is done -- unless Paint itself is the caller (it runs ApplyTwins
-- for the repair arm), which the guard skips.
hooksecurefunc(BF, "ApplyTwins", function()
    if previewOn and not painting then BF:RepaintBossPreview() end
end)

-- Raid/party page edits sweep the Preview section's frames through
-- RefreshPreviewFrames; the twin previews are not in that set, so they
-- follow here.
if BF.RefreshPreviewFrames then
    hooksecurefunc(BF, "RefreshPreviewFrames", function()
        if not previewOn or InCombatLockdown() or not TwinOn() then return end
        for i, tp in pairs(twinPreviews) do
            if tp:IsShown() and BF.oufBoss and BF.oufBoss[i] then
                PaintTwinSlot(BF.oufBoss[i], i)
            end
        end
    end)
end

events:Sub("PLAYER_REGEN_DISABLED", function()
    if previewOn then
        previewOn = false
        ReleaseInsecure()
        restorePending = true
    end
end, "unitless")

events:Sub("PLAYER_REGEN_ENABLED", function()
    if restorePending then
        restorePending = false
        ReleaseSecure()
        -- Combat only paused it: back on if the switch is still set and
        -- the options panel is still up (the host frame the preview
        -- engine anchors to).
        local host = BF._previewHostFrame
        if host and host:IsShown() then BF:ResumeBossPreview() end
    end
end, "unitless")

-- A real encounter or a loading screen stops the preview (the saved switch
-- stays; the next panel open resumes it).
events:Sub("INSTANCE_ENCOUNTER_ENGAGE_UNIT", function()
    if previewOn then BF:StopBossPreview() end
end, "unitless")
events:Sub("PLAYER_ENTERING_WORLD", function()
    if previewOn then BF:StopBossPreview() end
end, "unitless")
