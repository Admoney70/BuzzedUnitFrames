-- ============================================================
-- BuzzardFrames: oUF_Castbar.lua
-- Shared helper for building an oUF-compatible Castbar element.
-- Call BF:_BuildOUFCastbar(f, unitKey) from inside the oUF style
-- function (BluzzardStyle) so f.Castbar is set before oUF calls
-- Enable(). unitKey defaults to "target" for backward compat.
--
-- Sub-widgets:
--   Castbar.Text      - spell name (left-aligned FontString)
--   Castbar.Time      - remaining time (right-aligned FontString)
--   Castbar.Spark     - leading-edge fill indicator (Texture)
--   Castbar.Shield    - non-interruptible shield icon (Texture)
--   Castbar._bg       - background texture
--   Castbar._borderFrame - 4-edge border box
--   Castbar._unitKey  - "target" or "focus" (stored for shared helpers)
--
-- Public helpers – all accept an optional frame argument that
-- defaults to self.oufTarget for backward compatibility.
-- Options callbacks for the *target* frame pass no argument;
-- options callbacks for the *focus* frame pass BF.oufFocus.
--   BF:_ApplyOUFCastbarColors(f)   - re-reads profile bar colors live
--   BF:_ApplyOUFCastbarBgColor(f)  - re-reads profile bg color live
--   BF:_ApplyOUFCastbarBorder(f)   - re-reads profile border settings live
-- ============================================================
local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

-- Border-code revision marker (read by /bfborders — see oUF_Shared.lua).
BF._bfBorderRevCastbar = "v63"

-- ── Per-unit color helpers ────────────────────────────────────────────────────
-- unitKey is "target" or "focus"; profile keys follow the pattern
-- <unitKey>CastBarColor / <unitKey>CastBarUninterruptibleColor.

local function GetCastColorFor(unitKey)
    local c = BF.ufDB and BF.ufDB.profile.castBarColor
    if c then return c.r, c.g, c.b end
    return 1, 0.84, 0
end

local function GetUninterruptibleColorFor(unitKey)
    local c = BF.ufDB and BF.ufDB.profile.castBarUninterruptibleColor
    if c then return c.r, c.g, c.b end
    return 0.565, 0.557, 0.545
end

-- ── _ApplyOUFCastbarColors ────────────────────────────────────────────────────
-- Updates cast bar + uninterruptible overlay colors on one or all cast bars.
-- Pass a specific frame to update just that one, or nil to update all.
function BF:_ApplyOUFCastbarColors(f)
    if f then
        -- Single frame update
        if not f.Castbar then return end
        local cb = f.Castbar
        local unitKey = cb._unitKey or "target"
        cb:SetStatusBarColor(GetCastColorFor(unitKey))
        if cb._niOverlay then
            local r, g, b = GetUninterruptibleColorFor(unitKey)
            cb._niOverlay:SetColorTexture(r, g, b, 1)
        end
    else
        -- Update all cast bars
        if self.oufTarget then self:_ApplyOUFCastbarColors(self.oufTarget) end
        if self.oufFocus  then self:_ApplyOUFCastbarColors(self.oufFocus)  end
        if self.oufBoss then
            for i = 1, 5 do
                if self.oufBoss[i] then self:_ApplyOUFCastbarColors(self.oufBoss[i]) end
            end
        end
    end
end

-- ── _ApplyOUFCastbarBgColor ───────────────────────────────────────────────────
function BF:_ApplyOUFCastbarBgColor(f)
    if f then
        if not (f.Castbar and f.Castbar._bg) then return end
        local c = BF.ufDB and BF.ufDB.profile.castBarBgColor
                  or { r=0, g=0, b=0, a=0.6 }
        f.Castbar._bg:SetColorTexture(c.r, c.g, c.b, c.a or 0.6)
    else
        -- Update all cast bars
        if self.oufTarget then self:_ApplyOUFCastbarBgColor(self.oufTarget) end
        if self.oufFocus  then self:_ApplyOUFCastbarBgColor(self.oufFocus)  end
        if self.oufBoss then
            for i = 1, 5 do
                if self.oufBoss[i] then self:_ApplyOUFCastbarBgColor(self.oufBoss[i]) end
            end
        end
    end
end

-- ── Castbar spell-icon border styling (v62) ──────────────────────────────────
-- The castbar's spell icon is an AURA-ICON-CLASS element (owner
-- decision): it follows the Unit Frames → Global → Auras Border Style +
-- Border Color/Thickness settings, NOT the frame Border Mode.
--   Blizzard-Style : borderless uncropped icon (Blizzard's own castbar
--                    icons carry no border; the aura blizzard border is
--                    dispel-driven, which a spell icon has none of).
--   Square         : the 4 edge textures at the configured thickness,
--                    tinted by the aura border color (0 = borderless).
--   Rounded (x2)   : stretched IconMask clip + IconBorder ring at the
--                    aura v59 outer offsets, tinted by the aura border
--                    color — identical treatment to the UF aura icons.
-- Applied from _ApplyOUFCastbarBorder (layout path) AND from
-- BF:RestyleOUFAuraButtons (live aura-settings changes).
local CB_ICON_RING_TEX       = "Interface\\AddOns\\BuzzardFrames\\Media\\IconBorder"
local CB_ICON_RING_THICK_TEX = "Interface\\AddOns\\BuzzardFrames\\Media\\IconBorderThick"

function BF:_ApplyOUFCastbarIconBorder(f)
    local cb = f and f.Castbar
    local icon = cb and cb._icon
    local edges = icon and icon._edges
    if not edges then return end
    local p = BF.ufDB and BF.ufDB.profile
    local style = BF:GetOUFAuraBorderStyle()
    local bc = (p and p.oufAuraBorderColor) or { r = 0, g = 0, b = 0, a = 0.8 }
    local inner = icon._inner

    if style == "rounded" or style == "rounded_thick" then
        edges.top:Hide(); edges.bottom:Hide(); edges.left:Hide(); edges.right:Hide()
        if inner then inner:SetTexCoord(0.07, 0.93, 0.07, 0.93) end
        local ring = icon._roundRing
        if ring then
            local thick = style == "rounded_thick"
            local path = thick and CB_ICON_RING_THICK_TEX or CB_ICON_RING_TEX
            if ring._bf_lastTex ~= path then
                ring:SetTexture(path)
                ring._bf_lastTex = path
            end
            -- Outer offset IS the visible side thickness (aura v59 rethin).
            local o = thick and 1 or 0.5
            ring:ClearAllPoints()
            ring:SetPoint("TOPLEFT", icon, "TOPLEFT", -o, o)
            ring:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", o, -o)
            ring:SetVertexColor(bc.r or 0, bc.g or 0, bc.b or 0, bc.a or 0.8)
            ring:Show()
        end
        if icon._roundMask then icon._roundMask:Show() end
    elseif style == "blizzard" then
        if icon._roundRing then icon._roundRing:Hide() end
        if icon._roundMask then icon._roundMask:Hide() end
        edges.top:Hide(); edges.bottom:Hide(); edges.left:Hide(); edges.right:Hide()
        if inner then inner:SetTexCoord(0, 1, 0, 1) end
    else -- flat
        if icon._roundRing then icon._roundRing:Hide() end
        if icon._roundMask then icon._roundMask:Hide() end
        if inner then inner:SetTexCoord(0.07, 0.93, 0.07, 0.93) end
        local thickN = (p and p.oufAuraBorderThickness) or 1
        if thickN <= 0 then
            edges.top:Hide(); edges.bottom:Hide(); edges.left:Hide(); edges.right:Hide()
        else
            local px = BF:PixelsToUI(thickN)
            edges.top:SetHeight(px)
            edges.bottom:SetHeight(px)
            edges.left:SetWidth(px)
            edges.right:SetWidth(px)
            local r, g, b, a = bc.r or 0, bc.g or 0, bc.b or 0, bc.a or 0.8
            edges.top:SetColorTexture(r, g, b, a)
            edges.bottom:SetColorTexture(r, g, b, a)
            edges.left:SetColorTexture(r, g, b, a)
            edges.right:SetColorTexture(r, g, b, a)
            edges.top:Show(); edges.bottom:Show(); edges.left:Show(); edges.right:Show()
        end
    end
end

-- ── _ApplyOUFCastbarBorder ────────────────────────────────────────────────────
function BF:_ApplyOUFCastbarBorder(f)
    f = f or self.oufTarget
    if not (f and f.Castbar and f.Castbar._borderFrame) then return end
    local unitKey = (f.Castbar._unitKey) or "target"
    local cb  = f.Castbar
    local bbf = cb._borderFrame
    local p   = BF.ufDB and BF.ufDB.profile
    if not p then return end

    -- Rounded border mode (v59): the castbar gets its own standalone
    -- ring+mask kit (same Frame* art as the unit frame ring, tinted by
    -- frameBorderColor) in place of the 4-edge box. The kit rides the
    -- Castbar frame, so attach/detach re-parenting carries it along;
    -- the host level is re-stamped here because the Castbar's frame
    -- level changes across those re-parents (+2 matches _borderFrame).
    -- The masked regions are the fill, the bg, and the uninterruptible
    -- overlay (anchored to the fill); the spark/shield/icon markers
    -- stay unmasked like the raid frames' small markers.
    -- Spell icon border (v62): follows the AURA border settings in every
    -- frame border mode — applied here so it tracks every castbar layout.
    BF:_ApplyOUFCastbarIconBorder(f)

    if BF:ApplyUFBarRoundBorder(cb,
        { cb:GetStatusBarTexture(), cb._bg, cb._niOverlay },
        cb:GetFrameLevel() + 2) then
        bbf:Hide()
        return
    end

    local show = p[unitKey .. "CastBarBorderEnabled"] == true
    if not show then
        bbf:Hide()
        return
    end

    local thick = p[unitKey .. "CastBarBorderThickness"] or 1
    local bc    = p[unitKey .. "CastBarBorderColor"] or { r=0, g=0, b=0, a=1 }
    local r, g, b, a = bc.r, bc.g, bc.b, bc.a or 1

    bbf.top:SetColorTexture(r, g, b, a)
    bbf.top:ClearAllPoints()
    bbf.top:SetPoint("TOPLEFT",  cb, "TOPLEFT",  0, 0)
    bbf.top:SetPoint("TOPRIGHT", cb, "TOPRIGHT", 0, 0)
    bbf.top:SetHeight(thick)

    bbf.bottom:SetColorTexture(r, g, b, a)
    bbf.bottom:ClearAllPoints()
    bbf.bottom:SetPoint("BOTTOMLEFT",  cb, "BOTTOMLEFT",  0, 0)
    bbf.bottom:SetPoint("BOTTOMRIGHT", cb, "BOTTOMRIGHT", 0, 0)
    bbf.bottom:SetHeight(thick)

    bbf.left:SetColorTexture(r, g, b, a)
    bbf.left:ClearAllPoints()
    bbf.left:SetPoint("TOPLEFT",    cb, "TOPLEFT",    0, 0)
    bbf.left:SetPoint("BOTTOMLEFT", cb, "BOTTOMLEFT", 0, 0)
    bbf.left:SetWidth(thick)

    bbf.right:SetColorTexture(r, g, b, a)
    bbf.right:ClearAllPoints()
    bbf.right:SetPoint("TOPRIGHT",    cb, "TOPRIGHT",    0, 0)
    bbf.right:SetPoint("BOTTOMRIGHT", cb, "BOTTOMRIGHT", 0, 0)
    bbf.right:SetWidth(thick)

    bbf:Show()
end

-- ── _ApplyOUFCastbarIcon ──────────────────────────────────────────────────────
-- Positions, sizes, and shows/hides the spell icon next to the cast bar.
-- castStarting: pass true when called from PostCastStart (castbar not yet shown).
function BF:_ApplyOUFCastbarIcon(f, castStarting)
    if not (f and f.Castbar and f.Castbar._icon) then return end
    local cb = f.Castbar
    local p  = BF.ufDB and BF.ufDB.profile
    if not p then return end

    local unitKey = cb._unitKey or "target"
    local uk      = unitKey

    local iconSz   = p[uk .. "CastBarIconSize"] or 20
    local iconSide = p[uk .. "CastBarIconSide"] or "left"
    local gap      = p[uk .. "CastBarIconGap"]  or 2

    cb._icon:SetSize(iconSz, iconSz)
    -- Size the shield proportionally to the icon, preserving the 29:33 aspect ratio.
    if cb._iconShield then
        local scale = iconSz / 20  -- 20px icon = reference size
        cb._iconShield:SetSize(29 * scale, 33 * scale)
    end
    cb._icon:ClearAllPoints()
    if iconSide == "right" then
        cb._icon:SetPoint("LEFT", cb, "RIGHT", gap, 0)
    else
        cb._icon:SetPoint("RIGHT", cb, "LEFT", -gap, 0)
    end
    local enabled = p[uk .. "ShowCastBar"] ~= false and p[uk .. "CastBarShowIcon"] ~= false
    cb._icon:SetShown(enabled and (castStarting or cb:IsShown()))
end

-- ── _BuildOUFCastbar ──────────────────────────────────────────────────────────
-- unitKey: "target" (default) or "focus".  Stored as Castbar._unitKey so all
-- shared helpers can derive the correct profile keys at runtime.
function BF:_BuildOUFCastbar(f, unitKey)
    unitKey = unitKey or "target"

    local Castbar = BF.StatusBar(nil, f)
    Castbar:SetFrameLevel(f:GetFrameLevel() + 5)
    Castbar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    Castbar:SetStatusBarColor(GetCastColorFor(unitKey))
    Castbar:SetSize(100, 14)
    Castbar:Hide()

    -- Store unitKey so all shared helpers know which profile keys to use.
    Castbar._unitKey = unitKey

    -- Background
    local castBg = BF.Texture(Castbar, nil, "BACKGROUND")
    castBg:SetAllPoints(Castbar)
    local bc = BF.ufDB and BF.ufDB.profile.castBarBgColor
               or { r=0, g=0, b=0, a=0.6 }
    castBg:SetColorTexture(bc.r, bc.g, bc.b, bc.a or 0.6)
    Castbar._bg = castBg

    -- Uninterruptible color overlay: a solid-color texture anchored to the
    -- status bar fill texture. Shown/hidden via SetAlphaFromBoolean on the
    -- secret notInterruptible boolean. When visible (non-interruptible), it
    -- covers the normal cast color with the uninterruptible color.
    local niOverlay = BF.Texture(Castbar, nil, "ARTWORK", nil, 2)
    niOverlay:SetAllPoints(Castbar:GetStatusBarTexture())
    local nir, nig, nib = GetUninterruptibleColorFor(unitKey)
    niOverlay:SetColorTexture(nir, nig, nib, 1)
    niOverlay:SetAlpha(0)
    Castbar._niOverlay = niOverlay

    -- Border frame
    local bbf = CreateFrame("Frame", nil, Castbar)
    bbf:SetAllPoints(Castbar)
    bbf:SetFrameLevel(Castbar:GetFrameLevel() + 2)
    bbf:EnableMouse(false)
    bbf:Hide()
    local function MakeEdge()
        local t = BF.Texture(bbf, nil, "OVERLAY", nil, 2)
        t:SetColorTexture(0, 0, 0, 1)
        return t
    end
    bbf.top    = MakeEdge()
    bbf.bottom = MakeEdge()
    bbf.left   = MakeEdge()
    bbf.right  = MakeEdge()
    Castbar._borderFrame = bbf

    -- Spell name text
    local castText = Castbar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    castText:SetPoint("LEFT", Castbar, "LEFT", 2, 0)
    castText:SetTextColor(1, 1, 1, 1)
    castText:SetJustifyH("LEFT")
    castText:SetWordWrap(false)
    Castbar.Text = castText

    -- Remaining time text
    local castTime = Castbar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    castTime:SetPoint("RIGHT", Castbar, "RIGHT", -2, 0)
    castTime:SetTextColor(1, 1, 1, 1)
    castTime:SetJustifyH("RIGHT")
    Castbar.Time = castTime

    -- Spell pushback delay (v67, oUF 14.0.0).
    --
    -- Pre-14.0.0 the delay was appended INLINE to .Time by oUF's own onUpdate
    -- ('%.1f|cffff0000%s%.2f|r'). 14.0.0 drives .Time from an engine duration
    -- binding and renders the delay into a SEPARATE optional `.Delay`
    -- FontString instead ('%s%.2f' with a +/- prefix, castbar.lua). Without
    -- this region the library simply has nowhere to draw it and pushback goes
    -- unannotated -- the bar still moves, but silently.
    --
    -- Anchored RIGHT-to-LEFT-of .Time so it grows leftward, inward from the
    -- bar's right edge: .Time is pinned to that edge, so anchoring the delay
    -- after it would push the text outside the bar. Reads "+0.35 2s" rather
    -- than the old inline "2.4+0.35"; same information, no overlap.
    local castDelay = Castbar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    castDelay:SetPoint("RIGHT", castTime, "LEFT", -3, 0)
    castDelay:SetTextColor(1, 0, 0, 1)   -- matches the old |cffff0000 inline color
    castDelay:SetJustifyH("RIGHT")
    castDelay:SetWordWrap(false)
    Castbar.Delay = castDelay

    -- Spark
    local castSpark = BF.Texture(Castbar, nil, "OVERLAY")
    castSpark:SetSize(8, 16)
    castSpark:SetBlendMode("ADD")
    castSpark:SetPoint("CENTER", Castbar:GetStatusBarTexture(), "RIGHT", 0, 0)
    Castbar.Spark = castSpark

    -- Shield icon — floats just outside the left edge of the cast bar
    -- so it never overlaps the spell name text.
    local castShield = BF.Texture(Castbar, nil, "OVERLAY")
    castShield:SetSize(12, 12)
    castShield:SetPoint("RIGHT", Castbar, "LEFT", -3, 0)
    castShield:SetAtlas("nameplates-InterruptShield")
    Castbar.Shield = castShield

    -- Spell icon (parented to the Castbar so it follows the bar's visibility
    -- and parent chain automatically — including when the bar is detached and
    -- reparented to UIParent for target/focus). Previously parented to
    -- UIParent, which meant the icon did not hide when the Castbar's ancestor
    -- hid without triggering the Castbar's own IsShown() transition — most
    -- visibly, boss-frame icons were orphaned on screen after an encounter
    -- ended (the boss frame hid, but the Castbar's OnHide never fired so the
    -- icon was never cleaned up).
    local iconTex = CreateFrame("Frame", nil, Castbar)
    iconTex:SetFrameLevel(Castbar:GetFrameLevel() + 3)
    iconTex:SetSize(20, 20)
    iconTex:Hide()
    local iconTexInner = BF.Texture(iconTex, nil, "ARTWORK")
    iconTexInner:SetAllPoints(iconTex)
    iconTexInner:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    local function MakeIconEdge()
        local t = BF.Texture(iconTex, nil, "OVERLAY", nil, 1)
        t:SetColorTexture(0, 0, 0, 1)
        return t
    end
    local ib = {}
    ib.top    = MakeIconEdge(); ib.top:SetPoint("TOPLEFT",     iconTex, "TOPLEFT",     0, 0); ib.top:SetPoint("TOPRIGHT",    iconTex, "TOPRIGHT",    0, 0); ib.top:SetHeight(1)
    ib.bottom = MakeIconEdge(); ib.bottom:SetPoint("BOTTOMLEFT", iconTex, "BOTTOMLEFT", 0, 0); ib.bottom:SetPoint("BOTTOMRIGHT", iconTex, "BOTTOMRIGHT", 0, 0); ib.bottom:SetHeight(1)
    ib.left   = MakeIconEdge(); ib.left:SetPoint("TOPLEFT",    iconTex, "TOPLEFT",    0, 0); ib.left:SetPoint("BOTTOMLEFT",  iconTex, "BOTTOMLEFT",  0, 0); ib.left:SetWidth(1)
    ib.right  = MakeIconEdge(); ib.right:SetPoint("TOPRIGHT",  iconTex, "TOPRIGHT",   0, 0); ib.right:SetPoint("BOTTOMRIGHT", iconTex, "BOTTOMRIGHT", 0, 0); ib.right:SetWidth(1)
    iconTex.SetTexture = function(self, tex) iconTexInner:SetTexture(tex) end
    -- Stored so _ApplyOUFCastbarBorder can restyle the icon (v61: the
    -- rounded border modes round the spell icon too — previously these
    -- were locals and the 1px edge box could never be hidden).
    iconTex._inner = iconTexInner
    iconTex._edges = ib

    -- Rounded spell-icon kit (v61): the aura-icon treatment — stretched
    -- IconMask clips the icon, stretched IconBorder ring just outside it
    -- (same art/geometry as the resource pips and UF aura icons). Created
    -- hidden; a rounded oufBorderMode selects them in
    -- _ApplyOUFCastbarBorder. BLOCKING LOAD on the mask: it is shown
    -- live on a mode switch, and an async CLAMPTOBLACKADDITIVE mask
    -- reads BLACK (erases the icon) until it finishes.
    local iMask = BF.MaskTexture(iconTex)
    if iMask.SetBlockingLoadsRequested then
        iMask:SetBlockingLoadsRequested(true)
    end
    iMask:SetTexture("Interface\\AddOns\\BuzzardFrames\\Media\\IconMask",
        "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    iMask:SetAllPoints(iconTex)
    iMask:Hide()
    iconTexInner:AddMaskTexture(iMask)
    iconTex._roundMask = iMask
    local iRing = BF.Texture(iconTex, nil, "OVERLAY", nil, 2)
    iRing:Hide()
    iconTex._roundRing = iRing

    Castbar.Icon  = iconTex
    Castbar._icon = iconTex

    -- Shield background behind the spell icon — shown when the cast is not
    -- interruptible, mirroring Blizzard's TargetFrameSpellBar.BorderShield.
    -- Atlas: UI-CastingBar-Shield (FileID 4505194), native size ~29x33.
    -- Parented to iconTex so it follows the icon automatically.
    local iconShield = BF.Texture(iconTex, nil, "ARTWORK", nil, -1)
    iconShield:SetAtlas("UI-CastingBar-Shield")
    iconShield:SetPoint("CENTER", iconTex, "CENTER", 0, -2)
    -- Size is set dynamically in _ApplyOUFCastbarIcon based on the icon size.
    iconShield:SetSize(29, 33)
    iconShield:SetAlpha(0)
    Castbar._iconShield = iconShield

    Castbar:HookScript("OnHide", function(element)
        iconTex:Hide()
        if element._iconShield then element._iconShield:SetAlpha(0) end
        if element._niOverlay then element._niOverlay:SetAlpha(0) end
        if element.Time then element.Time:Show() end
        -- v67: clear any pushback text so it can't reappear on the next cast
        -- before the library has had a chance to write it.
        if element.Delay then element.Delay:SetText("") end
    end)

    -- PostCast callbacks — capture unitKey so color lookups are always correct.
    --
    -- oUF 14.0.0: every castbar runtime field (notInterruptible, castID,
    -- casting, channeling, spellID, delay, startTime, endTime, holdTime, ...)
    -- moved OFF the element into a file-local STATE table inside
    -- Libs/oUF/elements/castbar.lua. `element.notInterruptible` is therefore
    -- permanently nil and must be read from the CALLBACK ARGUMENT instead —
    -- the library passes it as
    --   PostCastStart(unit, spellID, notInterruptible, name, texture, isTradeSkill)
    --   PostCastInterruptible(unit, spellID, notInterruptible)
    -- Reading the dead field made SetAlphaFromBoolean(nil, ...) run on every
    -- cast start, so the uninterruptible tint and icon shield never appeared.
    Castbar.PostCastStart = function(element, unit, spellID, notInterruptible)
        element:SetStatusBarColor(GetCastColorFor(unitKey))
        if element.Time then element.Time:Show() end
        -- Show/hide uninterruptible overlay and icon shield via secret-safe API
        if element._niOverlay then
            element._niOverlay:SetAlphaFromBoolean(notInterruptible, 1, 0)
        end
        if element._iconShield then
            element._iconShield:SetAlphaFromBoolean(notInterruptible, 1, 0)
        end
        BF:_ApplyOUFCastbarIcon(f, true)
        -- Live re-anchor: the container-edge anchoring already tracks aura
        -- rows natively (secret heights never enter Lua); this only handles
        -- the container shown/hidden flip (e.g. unit phased, user toggle)
        -- since layout last ran. HOT PATH: baked fields only, no allocations.
        if element._avoidAurasEnabled and element:GetParent() ~= UIParent then
            BF:_AnchorAttachedCastbar(f)
        end
    end
    -- 14.0.0 signature: (unit, spellID, notInterruptible) — see PostCastStart.
    Castbar.PostCastInterruptible = function(element, unit, spellID, notInterruptible)
        -- Show/hide uninterruptible overlay and icon shield
        if element._niOverlay then
            element._niOverlay:SetAlphaFromBoolean(notInterruptible, 1, 0)
        end
        if element._iconShield then
            element._iconShield:SetAlphaFromBoolean(notInterruptible, 1, 0)
        end
    end
    -- oUF 14.0.0: `element.holdTime` also moved into the private STATE table,
    -- so the old `element.holdTime = (element.holdTime or 0) + 0.5` here wrote
    -- a dead field. It cannot simply become a `timeToHold` write either: the
    -- library latches `STATE.holdTime = element.timeToHold` BEFORE it fires
    -- these callbacks (castbar.lua, the CastStop and CastFail paths), so any
    -- value set from inside a callback only takes effect on the NEXT failed
    -- cast. timeToHold must be static — see the assignment below.
    local function OnInterrupted(element)
        element:SetStatusBarColor(1, 0.1, 0.1)
        if element.Time then element.Time:Hide() end
        -- v67: the delay text hides with the timer it annotates, otherwise a
        -- stale "+0.35" sits on the bar through the whole hold period.
        if element.Delay then element.Delay:SetText("") end
    end
    Castbar.PostCastInterrupted = function(element)
        OnInterrupted(element)
    end
    Castbar.PostCastStop = function(element)
        -- Do NOT hide the icon here. OnHide fires once holdTime expires and
        -- hides the icon then, so it stays visible during the hold period
        -- (e.g. when a cast is interrupted the bar + icon linger together).
        element:SetStatusBarColor(GetCastColorFor(unitKey))
        if element._niOverlay  then element._niOverlay:SetAlpha(0) end
        if element._iconShield then element._iconShield:SetAlpha(0) end
    end
    Castbar.PostCastFail = function(element)
        -- PostCastInterrupted handles the interrupt case separately.
        -- PostCastFail only fires for non-interrupt failures (spell canceled,
        -- out of range, etc.) so no text comparison needed here.
        -- Icon is hidden by OnHide once the hold expires, not eagerly here.
        element:SetStatusBarColor(1, 0.1, 0.1)
    end

    -- Total linger after an interrupted/failed cast. Was 0.3 here plus 0.5
    -- added from the callbacks (= 0.8); oUF 14.0.0 made that addition
    -- impossible (see OnInterrupted above), so the same 0.8 is expressed
    -- statically. Safe to raise: the library only reads timeToHold on the
    -- FAILED / INTERRUPTED paths, so a normal successful cast never lingers.
    Castbar.timeToHold = 0.8

    -- Guard against nil stages in empowered casts (oUF library bug).
    -- oUF uses (element.UpdatePips or UpdatePips) so this override takes priority.
    Castbar.UpdatePips = function(element, stages)
        if not stages then return end
        local isHoriz = element:GetOrientation() == 'HORIZONTAL'
        local elementSize = isHoriz and element:GetWidth() or element:GetHeight()
        local lastOffset = 0
        for stage, stageSection in next, stages do
            local offset = lastOffset + (elementSize * stageSection)
            lastOffset = offset
            local pip = element.Pips[stage]
            if not pip then
                pip = (element.CreatePip or CreateFrame)('Frame', nil, element, 'CastingBarFrameStagePipTemplate')
                element.Pips[stage] = pip
            end
            pip:ClearAllPoints()
            if isHoriz then
                pip:SetPoint('CENTER', element, 'LEFT', offset, 0)
            else
                pip:SetPoint('CENTER', element, 'BOTTOM', 0, offset)
            end
            pip:Show()
        end
        if element.PostUpdatePips then
            element:PostUpdatePips(stages)
        end
    end

    -- Drag handle (label and saved-position keys are per-unit)
    local labelText = (unitKey == "focus") and "Focus Cast Bar" or "Target Cast Bar"
    local handle = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    handle:SetFrameStrata("MEDIUM")
    handle:SetFrameLevel(110)
    handle:SetBackdrop({ bgFile="Interface\\Buttons\\White8x8",
                         edgeFile="Interface\\Buttons\\White8x8", edgeSize=1 })
    handle:SetBackdropColor(0.1, 0.3, 0.6, 0.8)
    handle:SetBackdropBorderColor(0.2, 0.5, 0.9, 1)
    handle:EnableMouse(true)
    handle:SetMovable(true)
    handle:RegisterForDrag("LeftButton")
    local lbl = handle:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetPoint("CENTER")
    lbl:SetText(labelText)
    lbl:SetTextColor(1, 1, 1)
    handle:SetScript("OnDragStart", function()
        Castbar:SetUserPlaced(true)
        Castbar:StartMoving()
    end)
    handle:SetScript("OnDragStop", function()
        Castbar:StopMovingOrSizing()
        -- Detached castbar is parented to UIParent (scale=1), so GetLeft()/GetTop()
        -- are already in UIParent virtual coords. No scale division needed.
        local x = Castbar:GetLeft()
        local y = Castbar:GetTop()
        Castbar:ClearAllPoints()
        Castbar:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
        BF.ufDB.profile[unitKey .. "CastBarAnchorX"]     = x
        BF.ufDB.profile[unitKey .. "CastBarAnchorY"]     = y
        BF.ufDB.profile[unitKey .. "CastBarAnchorSaved"] = true
        BF:_SnapOUFCastbarHandle(f)
    end)
    handle:Hide()
    Castbar._handle = handle

    f.Castbar = Castbar
    return Castbar
end


-- ── _AnchorAttachedCastbar ──────────────────────────────────────────────────
-- (Re)anchors an attached cast bar, honoring "Avoid Auras".
--
-- 12.1 constraints: AuraContainer heights are SECRET numbers (comparing
-- them in Lua hard-errors) AND addon frames may not anchor to the
-- container (it carries the UntrustedLayoutScriptExecution forbidden
-- aspect, so SetPoint against it is disallowed). The castbar therefore
-- cannot track actual aura rows at all. Instead, "Avoid Auras" reserves
-- the FULL configured aura block: ceil(maxAuras / perRow) rows computed
-- from profile values at layout time and baked as _cbAvoidY. Static,
-- never overlaps, uses no secret data.
--
-- Fallback when Avoid Auras is off or the aura container is hidden:
-- classic 20+gap. IsShown() on the container is safe — its shown state
-- is set by BF.UpdateOUFAuraFilters, not derived from aura data.
--
-- HOT PATH (PostCastStart): reads only baked fields — no profile lookups,
-- no string concatenation, no allocations.
function BF:_AnchorAttachedCastbar(f)
    local element = f.Castbar
    if not element then return end
    local pos    = element._castBarPos or "below"
    local gap    = element._castBarGap or 0
    local lInset = element._cbInsetL or 0
    local rInset = element._cbInsetR or 0

    element:ClearAllPoints()

    if pos == "above" then
        -- Debuffs grow upward from the frame top.
        local auraC = element._avoidAurasEnabled and f.Debuffs or nil
        local yOff = (auraC and auraC:IsShown() and element._cbAvoidY)
            and (element._cbAvoidY + gap) or (20 + gap)
        local aboveAnchor = f.Name or f
        element:SetPoint("BOTTOMLEFT",  aboveAnchor, "TOPLEFT",  lInset,  yOff)
        element:SetPoint("BOTTOMRIGHT", aboveAnchor, "TOPRIGHT", rInset,  yOff)
    else
        -- Buffs grow downward from the frame bottom.
        local auraC = element._avoidAurasEnabled and f.Buffs or nil
        local yOff = (auraC and auraC:IsShown() and element._cbAvoidY)
            and (element._cbAvoidY + gap) or (20 + gap)
        local belowAnchor = f.Power or f.Health or f
        element:SetPoint("TOPLEFT",  belowAnchor, "BOTTOMLEFT",  lInset, -yOff)
        element:SetPoint("TOPRIGHT", belowAnchor, "BOTTOMRIGHT", rInset, -yOff)
    end
end

-- ── Detached cast bar event proxy ────────────────────────────────────────────
-- oUF drops every element event on a frame that is not visible
-- (Libs/oUF/events.lua onEvent gates on self:IsVisible()), so while a
-- raid-style twin holds the target/focus oUF frame driver-hidden its Castbar
-- element stops being driven. An ATTACHED bar is a child of that frame and
-- goes down with it, so it does not care. A DETACHED bar is parented to
-- UIParent (see the detach branch below) and stays on screen, so it needs an
-- event source of its own -- one that outlives the twin option, see
-- _SyncOUFCastbarProxy.
--
-- This proxy is a plain insecure frame that mirrors the exact list castbar.lua
-- registers on the owner (Libs/oUF/elements/castbar.lua eventMethods) plus the
-- retarget event oUF would otherwise service through UpdateAllElements, and
-- answers each one with Castbar:ForceUpdate().
--
-- ForceUpdate -> Update -> CastStart re-reads UnitCastingInfo /
-- UnitChannelInfo, so start / stop / delay / channel / empower and the
-- (not-)interruptible shield all repaint correctly from live state. The one
-- loss: CastFail and CastInterrupted set a timeToHold red linger that
-- ForceUpdate cannot reproduce -- it finds no cast and hides -- so an
-- interrupted cast snaps away instead of fading. Accepted (owner ruling).
local CASTBAR_PROXY_UNIT_EVENTS = {
    "UNIT_SPELLCAST_START",
    "UNIT_SPELLCAST_STOP",
    "UNIT_SPELLCAST_DELAYED",
    "UNIT_SPELLCAST_FAILED",
    "UNIT_SPELLCAST_INTERRUPTED",
    "UNIT_SPELLCAST_INTERRUPTIBLE",
    "UNIT_SPELLCAST_NOT_INTERRUPTIBLE",
    "UNIT_SPELLCAST_CHANNEL_START",
    "UNIT_SPELLCAST_CHANNEL_UPDATE",
    "UNIT_SPELLCAST_CHANNEL_STOP",
    "UNIT_SPELLCAST_EMPOWER_START",
    "UNIT_SPELLCAST_EMPOWER_UPDATE",
    "UNIT_SPELLCAST_EMPOWER_STOP",
}

local function CastbarProxyOnEvent(proxy)
    local f = proxy._bfOwner
    if not f then return end
    -- Only step in where oUF cannot: a visible owner still drives the element
    -- itself, and a second ForceUpdate would just repeat that work.
    if f:IsVisible() then return end
    local cb = f.Castbar
    if cb and cb.ForceUpdate then cb:ForceUpdate() end
end

-- Armed whenever the bar is detached, twin or no twin: CastbarProxyOnEvent
-- already no-ops on a visible owner, so an armed proxy on a normally-shown
-- frame costs one IsVisible test per cast event and nothing else. Keying it on
-- IsTwinActive instead would leave a window on a twin turned off IN COMBAT --
-- the layout pass disarms at once while ApplyTwins defers pulling the driver
-- to PLAYER_REGEN_ENABLED, so the still-hidden owner would feed nothing for
-- the rest of the fight. Disarmed on re-attach and on hide.
-- The proxy is insecure, so registering events is safe at any time; the single
-- caller (_ApplyOUFCastbarLayout) is an out-of-combat layout path regardless.
-- unitKey is "target" or "focus" -- both the profile key and the unit token.
function BF:_SyncOUFCastbarProxy(f, unitKey, detached)
    local proxy = f._bfCastProxy
    local want = detached and true or false

    if not want then
        if proxy and proxy._bfArmedFor then
            proxy:UnregisterAllEvents()
            proxy._bfArmedFor = nil
        end
        return
    end

    if not proxy then
        proxy = CreateFrame("Frame")
        proxy._bfOwner = f
        proxy:SetScript("OnEvent", CastbarProxyOnEvent)
        f._bfCastProxy = proxy
    end
    if proxy._bfArmedFor == unitKey then return end

    proxy:UnregisterAllEvents()
    for i = 1, #CASTBAR_PROXY_UNIT_EVENTS do
        proxy:RegisterUnitEvent(CASTBAR_PROXY_UNIT_EVENTS[i], unitKey)
    end
    -- The retarget event oUF would otherwise service through
    -- UpdateAllElements: target / focus changed, or -- for a bossN token
    -- (twin-attached boss cast bars) -- the encounter roster changing.
    local retarget = (unitKey == "focus"  and "PLAYER_FOCUS_CHANGED")
                  or (unitKey == "target" and "PLAYER_TARGET_CHANGED")
                  or "INSTANCE_ENCOUNTER_ENGAGE_UNIT"
    proxy:RegisterEvent(retarget)
    proxy._bfArmedFor = unitKey
end

-- ── Twin-attached cast bars ───────────────────────────────────────────────────
-- With a raid-style twin owning a unit (UnitFrames/Twins.lua), an ATTACHED
-- cast bar stays attached -- to the twin. A friendly occupant shows the
-- twin, a hostile one the oUF frame, and the two swap under a secure
-- driver, so the bar follows by re-parenting: a child of the twin while it
-- is shown, of the oUF frame while it is not. Both are insecure moves,
-- made from insecure OnShow / OnHide hooks on the twin, so an in-combat
-- occupant change keeps the bar on the visible frame. As a child of the
-- twin it takes the twin's scale, as any attached child would.
--
-- Placement on the twin follows the same Cast Bar Position rules against
-- the twin's bounds (its aura rows are inside the frame, so no row is
-- skipped): Below / Bottom under it, Above over it, Left / Right beside it
-- centered on it at the bar's own width (_cbSideW; twin width when the
-- bar carries none), the gap slider honored.
--
-- Events: oUF drops element events on a hidden owner, so the detached
-- bar's proxy (_SyncOUFCastbarProxy above) is armed for the token while
-- the twin owns it.
--
-- Everything below reads the values the layout paths bake onto the bar
-- (_castBarPos, _castBarGap, _cbInsetL / R, _cbHeight), never the profile,
-- so the hooks are cheap and safe at any time.

-- The twin token for this oUF frame's cast bar, or nil.
local function TwinTokenFor(f)
    local uk = f.Castbar and f.Castbar._unitKey
    if uk == "boss" then
        return f._bossIndex and ("boss" .. f._bossIndex) or nil
    elseif uk == "target" or uk == "focus" then
        return uk
    end
    return nil
end

-- The ACTIVE twin for this frame's unit and its token, or nil.
function BF:_GetCastbarTwin(f)
    local cb = f and f.Castbar
    if not cb then return nil end
    if not (self.IsTwinActive and self:IsTwinActive(cb._unitKey)) then return nil end
    local token = TwinTokenFor(f)
    local twin  = token and self.GetTwinFrame and self:GetTwinFrame(token)
    if not twin then return nil end
    return twin, token
end

function BF:_AnchorCastbarToTwin(f, twin)
    local cb = f.Castbar
    local pos    = cb._castBarPos or "below"
    local gap    = (cb._castBarGap or 0) + 2
    local lInset = cb._cbInsetL or 0
    local rInset = cb._cbInsetR or 0
    cb:ClearAllPoints()
    if pos == "above" then
        cb:SetPoint("BOTTOMLEFT",  twin, "TOPLEFT",  lInset, gap)
        cb:SetPoint("BOTTOMRIGHT", twin, "TOPRIGHT", rInset, gap)
    elseif pos == "left" then
        cb:SetPoint("RIGHT", twin, "LEFT", -gap + rInset, 0)
        cb:SetWidth((cb._cbSideW or twin:GetWidth()) - lInset + rInset)
    elseif pos == "right" then
        cb:SetPoint("LEFT", twin, "RIGHT", gap + lInset, 0)
        cb:SetWidth((cb._cbSideW or twin:GetWidth()) - lInset + rInset)
    else -- below / bottom
        cb:SetPoint("TOPLEFT",  twin, "BOTTOMLEFT",  lInset, -gap)
        cb:SetPoint("TOPRIGHT", twin, "BOTTOMRIGHT", rInset, -gap)
    end
    cb:SetHeight(cb._cbHeight or 14)
end

-- Make the bar a child of `host` (the twin, or a preview stand-in for it).
function BF:_PlaceCastbarOnTwin(f, host)
    local cb = f.Castbar
    if not cb then return end
    if cb:GetParent() ~= host then
        cb:SetParent(host)
        cb:SetFrameLevel(host:GetFrameLevel() + 5)
        cb:SetMovable(false)
    end
    self:_AnchorCastbarToTwin(f, host)
end

-- Back onto the oUF frame with the ordinary attached placement.
function BF:_RestoreAttachedCastbar(f)
    local cb = f.Castbar
    if not cb then return end
    if cb:GetParent() ~= f then
        cb:SetParent(f)
        cb:SetFrameLevel(f:GetFrameLevel() + 5)
        cb:SetMovable(false)
    end
    if cb._isBossCastbar then
        if self._AnchorOUFBossCastbar then self:_AnchorOUFBossCastbar(f) end
    else
        self:_AnchorAttachedCastbar(f)
    end
    cb:SetHeight(cb._cbHeight or 14)
end

local function TwinCastbarOnShow(twin)
    local f = twin._bf_cbOwner
    if f and f.Castbar and f.Castbar._bf_twinAttached then
        BF:_PlaceCastbarOnTwin(f, twin)
    end
end

local function TwinCastbarOnHide(twin)
    local f = twin._bf_cbOwner
    if f and f.Castbar and f.Castbar._bf_twinAttached then
        BF:_RestoreAttachedCastbar(f)
    end
end

-- Called by both attached layout paths once the placement values are
-- baked, and by Twins.lua when a twin activates. Returns true when the
-- twin owns the bar (and has placed it), false when the ordinary attached
-- placement stands.
function BF:_SyncTwinAttachedCastbar(f)
    local cb = f and f.Castbar
    if not cb then return false end
    local twin, token = self:_GetCastbarTwin(f)
    if not twin then
        cb._bf_twinAttached = nil
        return false
    end
    cb._bf_twinAttached = true
    if not twin._bf_cbHooked then
        twin._bf_cbHooked = true
        twin:HookScript("OnShow", TwinCastbarOnShow)
        twin:HookScript("OnHide", TwinCastbarOnHide)
    end
    twin._bf_cbOwner = f
    self:_SyncOUFCastbarProxy(f, token, true)
    if twin:IsShown() then
        self:_PlaceCastbarOnTwin(f, twin)
    else
        self:_RestoreAttachedCastbar(f)
    end
    return true
end

-- ── _ApplyOUFCastbarLayout ────────────────────────────────────────────────────
-- All profile key lookups are derived from f.Castbar._unitKey so the same
-- function works for both the target and focus cast bars without duplication.
function BF:_ApplyOUFCastbarLayout(f, p, pf)
    if not f.Castbar then return end

    local unitKey = (f.Castbar._unitKey) or "target"
    local uk      = unitKey  -- shorthand for repeated concatenation

    local show     = p[uk .. "ShowCastBar"] ~= false
    local detached = show and (p[uk .. "CastBarDetached"] == true)
    local castH    = p[uk .. "CastBarHeight"] or 14
    local gap      = p[uk .. "CastBarGap"]    or 0
    local pos      = p[uk .. "CastBarPosition"] or "below"
    local locked   = BF.db.global.locked; if locked == nil then locked = true end

    -- Arm/disarm the detached-bar event proxy. This is the one funnel every
    -- cast bar layout path reaches, and `detached` is already false whenever
    -- the bar is hidden, so all three outcomes are covered by one call.
    BF:_SyncOUFCastbarProxy(f, unitKey, detached)

    local wasShown = f.Castbar:IsShown()
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
        if f.Castbar._icon then f.Castbar._icon:Hide() end
        return
    end

    -- Re-enable the oUF Castbar element if it was previously disabled.
    if f.IsElementEnabled and not f:IsElementEnabled("Castbar") then
        f:EnableElement("Castbar", f.__unit)
    end

    if detached then
        f.Castbar._bf_twinAttached = nil
        local castW = p[uk .. "CastBarWidth"] or (pf.frameWidth or 156)

        -- Compute the attached position from profile values so we have a
        -- sensible first-detach default even after a reload (when
        -- _attachedX/_attachedY are nil because the attached branch hasn't run).
        local scale   = pf.frameScale or 1.0
        local nameH   = pf.nameBarHeight   or 13
        local healthH = pf.healthBarHeight or 22
        local powerH  = pf.powerBarHeight  or 10
        local frameH  = (nameH + healthH + powerH) * scale
        local ancX    = pf.anchorX or 0
        local ancY    = pf.anchorY or 0
        local computedAttachedX, computedAttachedY
        if pos == "above" then
            computedAttachedX = ancX
            computedAttachedY = ancY + (20 + gap) * scale
        else
            computedAttachedX = ancX
            computedAttachedY = ancY - frameH - (20 + gap) * scale
        end

        -- Only use the saved anchor when the user has explicitly dragged the bar.
        -- If no saved position exists, seed it from the computed attached position
        -- so the bar appears near the unit frame on first detach rather than 0,0.
        if not p[uk .. "CastBarAnchorSaved"] then
            p[uk .. "CastBarAnchorX"] = computedAttachedX
            p[uk .. "CastBarAnchorY"] = computedAttachedY
        end

        -- Reparenting off the oUF frame is load-bearing beyond scale: with a
        -- raid-style twin active the oUF frame is hidden by a secure
        -- visibility state driver (UnitFrames/Twins.lua) while the unit is
        -- friendly, and a detached bar that were still its child would go down
        -- with it. Strata/level/anchor are re-established here, and the drag
        -- handle and the icon already live on UIParent / the Castbar itself.
        if f.Castbar:GetParent() ~= UIParent then
            f.Castbar:SetParent(UIParent)
            f.Castbar:SetFrameStrata("MEDIUM")
            f.Castbar:SetFrameLevel(50)
            f.Castbar:SetMovable(true)
            f.Castbar:SetClampedToScreen(true)
        end
        f.Castbar:SetSize(castW, castH)
        f.Castbar:ClearAllPoints()
        f.Castbar:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT",
            p[uk .. "CastBarAnchorX"] or 0,
            p[uk .. "CastBarAnchorY"] or 0)
        if wasShown then f.Castbar:Show() end
        if f.Castbar._handle then
            f.Castbar._handle:SetShown(not locked)
            if not locked then BF:_SnapOUFCastbarHandle(f) end
        end
    else
        if f.Castbar:GetParent() ~= f then
            f.Castbar:SetParent(f)
            f.Castbar:SetFrameLevel(f:GetFrameLevel() + 5)
            f.Castbar:SetMovable(false)
            p[uk .. "CastBarAnchorX"]     = nil
            p[uk .. "CastBarAnchorY"]     = nil
            p[uk .. "CastBarAnchorSaved"] = nil
        end
        -- Bake everything the (re-)anchoring needs onto the Castbar so the
        -- live PostCastStart path never reads the profile.
        f.Castbar._avoidAurasEnabled = p[uk .. "CastBarAvoidAuras"] ~= false
        f.Castbar._castBarPos        = pos
        f.Castbar._castBarGap        = gap

        -- When the icon is on the left, offset the bar rightward so the
        -- icon's left edge aligns with the frame's left edge. Mirror for right.
        local iconSz  = p[uk .. "CastBarIconSize"] or 20
        local iconSide = p[uk .. "CastBarIconSide"] or "left"
        local iconGap2 = p[uk .. "CastBarIconGap"]  or 2
        local showIcon = p[uk .. "CastBarShowIcon"] ~= false
        local leftInset  = (showIcon and iconSide == "left")  and (iconSz + iconGap2) or 0
        local rightInset = (showIcon and iconSide == "right") and -(iconSz + iconGap2) or 0
        f.Castbar._cbInsetL = leftInset
        f.Castbar._cbInsetR = rightInset

        -- "Avoid Auras" reservation: the full configured aura block height,
        -- ceil(maxAuras / perRow) rows + 5px padding (12.1: actual rows
        -- cannot be measured — heights are secret — nor tracked by
        -- anchoring to the container — forbidden aspect). Size/spacing/max
        -- come from the spawn-baked container values (what is actually
        -- rendered); perRow is the live profile value (wrap width is live).
        do
            local auraC = (pos == "above") and f.Debuffs or f.Buffs
            if auraC then
                local sz      = auraC._bf_size or 18
                local spacing = auraC._bf_spacing or 2
                local maxN    = auraC._bf_maxN or 32
                local perRow
                if pos == "above" then
                    perRow = pf[uk .. "DebuffsPerRow"] or 8
                else
                    perRow = pf[uk .. "BuffsPerRow"] or 8
                end
                local rows = math.ceil(maxN / math.max(1, perRow))
                f.Castbar._cbAvoidY = rows * sz + (rows - 1) * spacing + 5
            else
                f.Castbar._cbAvoidY = nil
            end
        end

        -- Anchor now (classic frame-edge anchoring; Avoid Auras just uses
        -- the reserved offset instead of the 20px base gap).
        f.Castbar._cbHeight = castH
        BF:_AnchorAttachedCastbar(f)
        f.Castbar:SetHeight(castH)
        -- A twin owning this unit takes the attached bar as its own child
        -- (placed on the twin while it is shown).
        BF:_SyncTwinAttachedCastbar(f)
        -- Compute position from profile values alone -- same coordinate space
        -- as unit frame anchors (TOPLEFT relative to UIParent BOTTOMLEFT).
        -- ancX/ancY is the frame TOPLEFT. The frame has SetScale(scale) applied,
        -- so child positions in virtual coords are: ancX + localX*scale, ancY - localY*scale.
        local scale   = pf.frameScale or 1.0
        local nameH   = pf.nameBarHeight   or 13
        local healthH = pf.healthBarHeight or 22
        local powerH  = pf.powerBarHeight  or 10
        local frameH  = (nameH + healthH + powerH) * scale
        local ancX    = pf.anchorX or 0
        local ancY    = pf.anchorY or 0
        if pos == "above" then
            f.Castbar._attachedX = ancX
            f.Castbar._attachedY = ancY + (20 + gap) * scale
        else
            f.Castbar._attachedX = ancX
            f.Castbar._attachedY = ancY - frameH - (20 + gap) * scale
        end
        if f.Castbar._handle then f.Castbar._handle:Hide() end
        if wasShown then f.Castbar:Show() end
    end

    local castFontSz = pf.castBarFontSize or p[uk .. "CastBarFontSize"] or 10
    -- v61: castbars follow the Unit Frames global font (GetOUFFont
    -- returns the stock font when Adjust Fonts is off).
    local fontFace   = BF:GetOUFFont(nil, GameFontNormalSmall:GetFont())
    if f.Castbar.Text then f.Castbar.Text:SetFont(fontFace, castFontSz, "") end
    if f.Castbar.Time then f.Castbar.Time:SetFont(fontFace, castFontSz, "") end
    -- v67: the pushback delay is its own FontString now; keep it on the same
    -- font as .Time so the two read as one line.
    if f.Castbar.Delay then f.Castbar.Delay:SetFont(fontFace, castFontSz, "") end

    BF:_ApplyOUFCastbarBgColor(f)
    BF:_ApplyOUFCastbarBorder(f)

    if f.Castbar._icon then
        local iconSz  = p[uk .. "CastBarIconSize"] or 20
        local side    = p[uk .. "CastBarIconSide"]  or "left"
        local iconGap = p[uk .. "CastBarIconGap"]   or 2
        f.Castbar._icon:SetSize(iconSz, iconSz)
        f.Castbar._icon:ClearAllPoints()
        if side == "right" then
            f.Castbar._icon:SetPoint("LEFT",  f.Castbar, "RIGHT",  iconGap, 0)
        else
            f.Castbar._icon:SetPoint("RIGHT", f.Castbar, "LEFT",  -iconGap, 0)
        end
        f.Castbar._icon:Hide()
    end
end
