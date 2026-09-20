-- ============================================================
-- BuzzardFrames: UnitFrames/Twins.lua
-- Raid-style "twins" for the Player / Target / Focus / Boss frames.
--
-- A twin is a standalone secure button built by the RAID engine
-- (BF:RegisterFrame -> BuzzardFrame_Init) whose unit attribute is a
-- non-group token. It is NOT a header child: it hangs off an insecure
-- holder Frame that carries frameWidth/frameHeight the way a header does,
-- so BuzzardFrame_GetInitialSize / BuzzardFramePrototype:Layout resolve
-- exactly as they do for a raid frame. The holder deliberately carries no
-- _cfgFlat and no isCustomFrame/isPetFrame: every header-derived read in
-- Auras/ and Indicators/ tests those, so their absence puts the twin on the
-- main raid/party flat path.
--
-- Friendly gate: the twin is shown by a secure state driver on [@<token>,help]
-- and the oUF frame takes the complementary [@<token>,exists,nohelp] driver
-- in place of its unit watch. The unit attribute is set ONCE and never
-- changes; occupant changes are re-seeded through the roster sweep's own
-- per-unit step (BF._RosterUpdateUnit).
--
-- Everything secure here is out-of-combat only and self-defers to
-- PLAYER_REGEN_ENABLED.
-- ============================================================

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local CreateFrame, UIParent = CreateFrame, UIParent
local InCombatLockdown = InCombatLockdown
local UnitExists = UnitExists
local RegisterStateDriver, UnregisterStateDriver = RegisterStateDriver, UnregisterStateDriver
local UnregisterUnitWatch, UnitWatchRegistered = UnregisterUnitWatch, UnitWatchRegistered
local SecureButton_GetModifiedUnit = SecureButton_GetModifiedUnit
local ipairs, next, rawget, type = ipairs, next, rawget, type
local mabs = math.abs

-- Shared contract (see the twins brief): unit-frame profile key -> tokens.
local TWIN_TOKENS = {
    player = { "player" },
    target = { "target" },
    focus  = { "focus"  },
    boss   = { "boss1", "boss2", "boss3", "boss4", "boss5" },
}
local UF_ORDER  = { "player", "target", "focus", "boss" }
local SHOW_KEY  = { player = "showPlayerFrame", target = "showTargetFrame",
                    focus  = "showFocusFrame",  boss   = "showBossFrames" }
local STYLE_KEY = { player = "playerRaidStyle", target = "targetRaidStyle",
                    focus  = "focusRaidStyle",  boss   = "bossRaidStyle" }
local SCALE_KEY = { player = "twinScalePlayer", target = "twinScaleTarget",
                    focus  = "twinScaleFocus",  boss   = "twinScaleBoss" }

-- Same epsilon UpdateFramesSizeForHeader compares scales with.
local SCALE_EPSILON = 0.001

BF.twinFrames = BF.twinFrames or {}
local twinFrames = BF.twinFrames
local twinByKey  = {}    -- token -> twin frame

-- Header-shaped scratch table for BF:_ResolveHeaderSizeAndScale. That
-- function reads only .isCustomFrame / .isPetFrame off its argument before
-- taking the main raid/party arm, so an empty table answers for "a twin".
local sizeProbe = {}

local pendingApply, pendingRefresh, pendingRefreshForce
local twinEvents = BF:EventOwner("twins")

-- ============================================================
-- SETTINGS READS
-- ============================================================

-- The oUF frame for a twin token, or nil when it has not been built yet.
local function OUFFrameFor(token)
    if token == "player" then return BF.oufPlayer end
    if token == "target" then return BF.oufTarget end
    if token == "focus"  then return BF.oufFocus  end
    local idx = token:match("^boss(%d)$")
    if idx then
        return BF.oufBoss and BF.oufBoss[tonumber(idx)]
    end
    return nil
end

-- True when the oUF frame for this profile key is meant to be visible.
-- Mirrors _ApplyOUFRightFrameLayout's `if p[enableKey] then Enable else Disable`.
local function OUFWanted(ufKey)
    local p = BF.ufDB and BF.ufDB.profile
    if not p then return false end
    return (p.ptfEnabled and p[SHOW_KEY[ufKey]]) and true or false
end

-- Pure settings read; no frame needed.
--
-- ptfEnabled is included deliberately: it is the master switch every
-- `want<Frame>` in BF:ApplyOUFVisibility carries, and with it off there is no
-- oUF frame to twin, to anchor to, or to swap a driver on.
function BF:IsTwinActive(ufKey)
    local p = self.ufDB and self.ufDB.profile
    if not p then return false end
    if not SHOW_KEY[ufKey] then return false end
    return (p.ptfEnabled and p[SHOW_KEY[ufKey]] and p[STYLE_KEY[ufKey]]) and true or false
end

function BF:GetTwinFrame(twinKey)
    return twinByKey[twinKey]
end

-- Per-flat, per-twin scale override (§7.4). Default 1; the flat may not
-- carry the key at all yet (Package D owns the defaults).
function BF:GetTwinScale(ufKey)
    local key = SCALE_KEY[ufKey]
    if not key then return 1 end
    local ap = self._resolvedProfile
    if not ap then
        if self._contextIsRaid == nil then self:ResolveContext() end
        self:InvalidateRaidProfileCache()
        ap = self._contextIsRaid and self:GetRaidProfile() or self:GetActivePartyProfile()
    end
    local s = ap and ap[key]
    if type(s) ~= "number" or s <= 0 then return 1 end
    return s
end

-- ============================================================
-- GEOMETRY
-- ============================================================
-- Unscaled frame dimensions + the total scale to hang on the holder. The
-- dimensions and the header scale come from the SAME resolver the raid
-- headers use, so a twin at twinScale 1 is pixel-identical to a raid frame;
-- the twin scale multiplies the header scale on top.
local function ResolveTwinGeometry(ufKey)
    local w, h, scale = BF:_ResolveHeaderSizeAndScale(sizeProbe)
    return w, h, scale * BF:GetTwinScale(ufKey)
end

-- Width/height in UI units the twin occupies on screen. Package C uses this
-- for the boss column pitch.
-- Third return: the twin's total scale, for callers that size the twin's
-- attached children (the oUF cast bar) into the boss frames' space.
function BF:GetTwinFrameSize(ufKey)
    local w, h, scale = ResolveTwinGeometry(ufKey)
    return w * scale, h * scale, scale
end

-- Pin the twin's TOPLEFT to the oUF frame's TOPLEFT (which is its _anchor's
-- TOPLEFT). The two never fight: the twin is a child of its own holder, and
-- the oUF layout paths only ever re-point the oUF frame itself.
local function AnchorTwin(twin)
    local ouf = OUFFrameFor(twin._bf_twinKey)
    twin:ClearAllPoints()
    if ouf then
        twin:SetPoint("TOPLEFT", ouf, "TOPLEFT", 0, 0)
        return
    end
    -- Defensive only: a twin is active only when its frame's show flag is on,
    -- and that flag is what builds the oUF frame, so this is unreachable
    -- today. It reads the same saved anchor the oUF layout would have used.
    -- SetPoint offsets are in the twin's own (scaled) coordinate space, hence
    -- the divide.
    local x, y = BF:GetUFAnchor(twin._bf_twinUF)
    local s = twin._bf_twinHolder:GetScale() or 1
    if s <= 0 then s = 1 end
    twin:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", (x or 400) / s, (y or 300) / s)
end

-- Re-read the flat's frame size / scale and relayout every twin. Change
-- guarded on size exactly like BF:UpdateFramesSizeForHeader.
--
-- force = true relayouts every twin whether or not its dimensions moved, for
-- settings that change what frame:Layout() PRODUCES rather than how big it is
-- -- the oUF showPowerBar toggles, which the twin's Container height now
-- follows (BF:TwinForcesPowerBar, LayoutFrame.lua). A deferred refresh keeps
-- the strongest force asked for while it waits.
function BF:RefreshTwinLayout(force)
    if not twinFrames[1] then return end
    if InCombatLockdown() then
        pendingRefresh = true
        pendingRefreshForce = pendingRefreshForce or (force and true or false)
        return
    end
    for _, twin in ipairs(twinFrames) do
        local holder = twin._bf_twinHolder
        local w, h, scale = ResolveTwinGeometry(twin._bf_twinUF)
        local changed = w ~= holder.frameWidth
            or h ~= holder.frameHeight
            or mabs(scale - (holder:GetScale() or 1)) > SCALE_EPSILON
        if changed or force or self._forceReload then
            holder.frameWidth  = w
            holder.frameHeight = h
            holder:SetSize(w, h)
            holder:SetScale(scale)
            twin:Layout()
        end
        AnchorTwin(twin)
    end
end

-- ============================================================
-- BUILD
-- ============================================================
-- Everything SECURE_INIT (BFLayout.lua) applies to a header child, applied
-- insecurely here. The clickcast_header frame-ref half has no analogue
-- without a header, so the twin registers with ClickCastFrames directly --
-- the same route the oUF portrait icon button takes (oUF_Shared.lua).
local function ApplyTwinAttributes(twin)
    twin:SetAttribute("*type1", "target")
    twin:SetAttribute("*type2", "togglemenu")
    -- useparent-*: the holder carries none of these, so a twin never takes a
    -- vehicle/unitsuffix swap. That is required, not incidental -- the twin's
    -- token must stay exactly what it was set to.
    twin:SetAttribute("useparent-toggleForVehicle", true)
    twin:SetAttribute("useparent-allowVehicleTarget", true)
    twin:SetAttribute("useparent-unitsuffix", true)
    twin:SetAttribute("*toggleForVehicle2", "")
    if ClickCastFrames then ClickCastFrames[twin] = true end
end

local function BuildTwin(token, ufKey)
    local w, h, scale = ResolveTwinGeometry(ufKey)

    local holder = CreateFrame("Frame", "BuzzardFrames_TwinHolder_" .. token, UIParent)
    -- BuzzardFrame_GetInitialSize + BuzzardFramePrototype:Layout read these
    -- off the parent. No _cfgFlat / isCustomFrame / isPetFrame: see the file
    -- header.
    holder.frameWidth  = w
    holder.frameHeight = h
    holder:SetSize(w, h)
    holder:SetScale(scale)

    local template = BF:GetRaidFrameTemplate()
    local twin = CreateFrame("Button", "BuzzardFrames_Twin_" .. token, holder, template)
    twin._bf_twinKey    = token
    twin._bf_twinUF     = ufKey
    twin._bf_twinHolder = holder
    ApplyTwinAttributes(twin)

    -- Does everything BuzzardFrame_Init does for a header child: prototype,
    -- script hooks (so ActivateTwin's unit attribute fires
    -- OnAttributeChanged), indicators, aura containers, one-shot Layout.
    BF:RegisterFrame(twin)

    twinFrames[#twinFrames + 1] = twin
    twinByKey[token] = twin
    return twin
end

-- ============================================================
-- OCCUPANT CHANGES
-- ============================================================
-- The token never changes, so a retarget is the same-token/new-occupant case
-- the roster sweep handles on GROUP_ROSTER_UPDATE. This is that sweep's body
-- for one token: BF._RosterUpdateUnit does the GUID/name diff, re-seeds the
-- dead cache and broadcasts BF_UnitUpdated (which is what resets
-- auraSuppressed and the single-aura trackers); the per-frame repaint is the
-- caller's half, so it is replicated here verbatim.
local function UpdateTwinOccupant(token)
    local twin = twinByKey[token]
    if not (twin and twin._bf_twinActive) then return end
    -- A vanished occupant is skipped, exactly as the sweep skips one: nothing
    -- is evicted from roster_guids (that was BF's old permanent-eviction bug),
    -- and the twin is driver-hidden meanwhile. The next real occupant is
    -- caught by the GUID diff below.
    if not UnitExists(token) then return end

    local guids = BF.roster_guids
    local bucket = BF.frames_of_unit and rawget(BF.frames_of_unit, token)
    if guids and not guids[token] then
        -- First occupant this token has ever had. SetFrameUnit only calls
        -- RegisterRosterUnit for the FIRST frame on a token, and that call
        -- bails on `not UnitExists` -- which is the normal state for target /
        -- focus / bossN when the twin is built. Register now: it seeds
        -- roster_guids/names + the dead cache and broadcasts
        -- BF_UnitUpdated(joined), which arms the token's per-unit event frame.
        BF:RegisterRosterUnit(token)
        if bucket then
            for frame in next, bucket do
                BF.OnUnitOccupantChanged(frame, token)
            end
        end
        return
    end

    if BF._RosterUpdateUnit and BF._RosterUpdateUnit(token) and bucket then
        for frame in next, bucket do
            local old, new = frame.unit, SecureButton_GetModifiedUnit(frame)
            if old ~= new then
                BF.SetFrameUnit(frame, new)
                BF.OnUnitChanged(frame, new)
            else
                BF.OnUnitOccupantChanged(frame, token)
            end
        end
    end
end

local occupantEventsArmed
local function ArmOccupantEvents()
    if occupantEventsArmed then return end
    occupantEventsArmed = true
    -- All four are subscribed unitless: BFEvents' UNIT_EVENTS allowlist (which
    -- scope "any"/"roster" requires) does not carry UNIT_TARGETABLE_CHANGED,
    -- and that file is not ours to extend. The unit filter is one table read
    -- in the handler instead.
    twinEvents:Sub("PLAYER_TARGET_CHANGED", function()
        UpdateTwinOccupant("target")
    end, "unitless")
    twinEvents:Sub("PLAYER_FOCUS_CHANGED", function()
        UpdateTwinOccupant("focus")
    end, "unitless")
    twinEvents:Sub("INSTANCE_ENCOUNTER_ENGAGE_UNIT", function()
        for i = 1, 5 do UpdateTwinOccupant("boss" .. i) end
    end, "unitless")
    twinEvents:Sub("UNIT_TARGETABLE_CHANGED", function(_, _, unit)
        if unit and twinByKey[unit] then UpdateTwinOccupant(unit) end
    end, "unitless")
end

-- ============================================================
-- VISIBILITY
-- ============================================================
-- oUF skips element updates on a hidden frame (Libs/oUF/units.lua), so a
-- frame re-shown by our state driver has to repaint itself. Hooked once.
local function HookOUFShowOnce(f)
    if not f or f._bf_twinShowHooked then return end
    f._bf_twinShowHooked = true
    f:HookScript("OnShow", function(self)
        if self.UpdateAllElements then self:UpdateAllElements("OnShow") end
    end)
end

-- Hand the oUF frame back its unit watch (or leave it Disabled when its own
-- show flag is off -- Enable is literally RegisterUnitWatch, so restoring it
-- unconditionally would un-hide a frame the user turned off).
local function ReleaseOUFFrame(twin)
    local f = twin._bf_twinDrivenOUF
    if not f then return end
    twin._bf_twinDrivenOUF = nil
    UnregisterStateDriver(f, "visibility")
    if OUFWanted(twin._bf_twinUF) then
        if f.Enable then f:Enable() else f:Show() end
    else
        if f.Disable then f:Disable() else f:Hide() end
    end
end

local function ActivateTwin(twin)
    local token  = twin._bf_twinKey
    local holder = twin._bf_twinHolder
    holder:Show()
    AnchorTwin(twin)
    if not twin._bf_twinActive then
        twin._bf_twinActive = true
        -- Fires OnAttributeChanged -> SetFrameUnit -> OnUnitChanged: roster
        -- registration, caches, aura containers, first indicator pass.
        twin:SetAttribute("unit", token)
    end
    if token == "player" then
        -- Always assistable: no conditional needed.
        UnregisterStateDriver(twin, "visibility")
        twin:Show()
    else
        UnregisterStateDriver(twin, "visibility")
        RegisterStateDriver(twin, "visibility", "[@" .. token .. ",help] show; hide")
    end

    local ouf = OUFFrameFor(token)
    if ouf then
        HookOUFShowOnce(ouf)
        -- The player's oUF frame is Package C's: with the player twin on it
        -- takes the showPlayerFrame = false path so ClassPower moves to the
        -- hidden host. Never touch its watch here.
        --
        -- The UnitWatchRegistered term is the repair path: Enable is literally
        -- RegisterUnitWatch (Libs/oUF/ouf.lua), so anything that re-Enables
        -- this frame leaves it carrying a unit watch AND our driver -- two
        -- writers on one visibility. _ApplyOUFRightFrameLayout calls
        -- BF:ApplyTwins() exactly when it sees that, and this is the arm that
        -- answers it. Without the term the frame-identity guard alone would
        -- skip the re-swap on every repeat pass.
        if token ~= "player"
            and (twin._bf_twinDrivenOUF ~= ouf or UnitWatchRegistered(ouf)) then
            twin._bf_twinDrivenOUF = ouf
            UnregisterUnitWatch(ouf)
            UnregisterStateDriver(ouf, "visibility")
            RegisterStateDriver(ouf, "visibility",
                "[@" .. token .. ",exists,nohelp] show; hide")
        end
        -- An attached oUF cast bar becomes the twin's child while the twin
        -- is shown (oUF_Castbar.lua, twin-attached cast bars). The layout
        -- paths call this too, but on the FIRST activation they ran before
        -- the twin existed (ApplyOUFVisibility lays out, then ApplyTwins
        -- builds), so the twin asks for it here.
        if ouf.Castbar and BF._SyncTwinAttachedCastbar then
            BF:_SyncTwinAttachedCastbar(ouf)
        end
    end
end

local function DeactivateTwin(twin)
    -- Hand a twin-attached cast bar back to its oUF frame before the twin
    -- hides (the OnHide hook would do the same; this makes it explicit and
    -- drops the attachment so the hooks go quiet).
    local ouf = OUFFrameFor(twin._bf_twinKey)
    if ouf and ouf.Castbar and ouf.Castbar._bf_twinAttached then
        ouf.Castbar._bf_twinAttached = nil
        if BF._RestoreAttachedCastbar then BF:_RestoreAttachedCastbar(ouf) end
    end
    ReleaseOUFFrame(twin)
    if twin._bf_twinActive then
        twin._bf_twinActive = nil
        -- The engine's own teardown path: dropping the unit unregisters the
        -- roster token (when no other frame holds it) and parks the aura
        -- containers, so a twin that is off costs nothing per event.
        twin:SetAttribute("unit", nil)
    end
    UnregisterStateDriver(twin, "visibility")
    twin:Hide()
    twin._bf_twinHolder:Hide()
end

-- ============================================================
-- ENTRY POINT
-- ============================================================
-- Idempotent. Builds/shows/hides every twin from the current settings and
-- swaps the drivers on both sides. MUST be called last in
-- BF:ApplyOUFVisibility, after every f:Enable()/f:Disable().
function BF:ApplyTwins()
    -- The oUF frames are built on PLAYER_LOGIN; before that there is nothing
    -- to anchor to or swap a driver on, and ApplyOUFVisibility will call us
    -- again once they exist.
    if not self._oufReady then return end
    if InCombatLockdown() then
        pendingApply = true
        return
    end

    local anyActive = false
    for _, ufKey in ipairs(UF_ORDER) do
        local active = self:IsTwinActive(ufKey)
        for _, token in ipairs(TWIN_TOKENS[ufKey]) do
            local twin = twinByKey[token]
            if active then
                if not twin then twin = BuildTwin(token, ufKey) end
                ActivateTwin(twin)
                anyActive = true
            elseif twin then
                DeactivateTwin(twin)
            end
        end
    end

    if anyActive then ArmOccupantEvents() end
    -- Twin tokens are not group tokens, so UNIT_IN_RANGE_UPDATE is never
    -- delivered for them: the 1 s ticker is their only range source.
    if self.SyncRangeChecker then self:SyncRangeChecker() end
    self:RefreshTwinLayout()
end

local function OnRegenEnabled()
    if pendingApply then
        pendingApply = nil
        BF:ApplyTwins()
    end
    if pendingRefresh then
        local force = pendingRefreshForce
        pendingRefresh, pendingRefreshForce = nil, nil
        BF:RefreshTwinLayout(force)
    end
end
twinEvents:Sub("PLAYER_REGEN_ENABLED", OnRegenEnabled, "unitless")
