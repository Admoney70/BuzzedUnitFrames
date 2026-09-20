--[[
BuzzardFrames: PingMirror.lua

THE SHARED PING-PIN ENGINE. Owned by NEITHER the unit-frames module nor the
raid/party module -- both are customers of it.

v96 (owner-approved plan 2026-08-25). This code used to live at the tail of
UnitFrames/oUF_Shared.lua, and its only production entry point was
BF:ApplyOUFPingIndicators <- BF:ApplyOUFPlayerLayout. That made the RAID/PARTY
ping pins silently dependent on the UNIT FRAMES module: with ptfEnabled off
(or merely showPlayerFrame off) the player frame is never built, that layout
never runs, `pingMirror` is never created, and SetPingTicker's `not pingMirror`
guard meant even the raid Ping Indicator toggle could not start the ticker.
The pins existed and nothing ever drove them.

The mirror now lives here, is started from the PLAYER_ENTERING_WORLD path in
Initialization.lua regardless of either module's enable flags, and collects
pins from two INDEPENDENT collectors:

  * CollectUnitFramePins -- the oUF target/focus/player pins
                            (_bfPingIndicator, built by BF.CreateOUFPingWidget)
  * CollectRaidPins      -- the raid/party pins (pingIndicatorTex, built by
                            Indicators/PingIndicator.lua)

Neither collector reads the other module's storage, and either returning
nothing is a normal, fully supported state.

WHY A MIRROR AT ALL: the ping-pin events (UNIT_PING_PIN_ADDED/REMOVED) are
SecureOnly and UnitPingIconFrameTemplate is a forbidden frame, so an addon can
neither receive a ping nor build a real receiver. The only route is watching
Blizzard's OWN receivers -- IsShown() and GetAtlas() are engine state and read
fine from here -- and pushing show/hide + texture kit onto our textures.
]]

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local IsInGroup = IsInGroup
local UnitGUID  = UnitGUID

-- 12.1 SECRET GUIDS.
-- UnitGUID returns a SECRET value while the unit is under combat secrecy, and
-- a secret cannot be used as a table key -- `t[secret]` hard-errors with
-- "attempted to index a table that cannot be indexed with secret keys".
-- The pin mirror is entirely GUID-keyed, so every UnitGUID result must be
-- sanitized at the CAPTURE site, exactly like BFStatus.lua's NotSecretOr.
--
-- Guarding the UNIT TOKEN instead does nothing: a token like "raid8target" is
-- a plain string and is never secret. That was the original defect -- the
-- guards tested the token while the GUID went straight into the index.
-- Owner-reported: 4x error on /reload in a raid, thrown from the compact
-- target-of-raid frames (unit="raid8target"), which are the likeliest to
-- carry a secret GUID mid-combat.
--
-- Returns nil when unreadable. Callers treat nil as "cannot be matched to a
-- receiver" and hide/skip, which is the same arm an absent unit already takes.
local function SafeGUID(unit)
    if not unit then return nil end
    local guid = UnitGUID(unit)
    if guid == nil then return nil end
    if issecretvalue and issecretvalue(guid) then return nil end
    if canaccessvalue and not canaccessvalue(guid) then return nil end
    if type(guid) ~= "string" then return nil end
    return guid
end
BF.SafePingGUID = SafeGUID

-- Set by ResolvePingEntries whenever it dropped a unit for an unreadable
-- GUID; read by the PLAYER_REGEN_ENABLED handler so leaving combat re-runs
-- the resolve. Deliberately NOT a timed retry: units do not leave combat on
-- a schedule, so polling would burn resolves for nothing. When the secrecy
-- was driven by SOMEONE ELSE's combat, this stays unresolved until the next
-- roster event or the next time the player leaves combat -- accepted.
local pingSecretSkipped = false
local wipe      = wipe
local pairs     = pairs

-- ============================================================
-- Blizzard's receivers
-- ============================================================
-- Is the ping-pin feature usable on this build? Both the events
-- (SecureOnly) and UnitPingIconFrameTemplate ("Cannot create a forbidden
-- frame from a tainted context") are closed to addons. The only route is
-- mirroring Blizzard's OWN receivers, which exist on exactly two solo
-- frames: TargetFrame and FocusFrame (boss frames reject pings in their
-- GUID callback; player/pet/ToT have no receiver at all). Those keep
-- their own event registration even after BlizzardFrames.lua hides and
-- UnregisterAllEvents() the parent, because the receiver is a separate
-- child frame.
local function GetBlizzardPingIconFrame(unit)
    local root = (unit == "target" and TargetFrame)
        or (unit == "focus" and FocusFrame) or nil
    local c = root and root.TargetFrameContent
    c = c and c.TargetFrameContentContextual
    local recv = c and c.PingIconFrame
    return recv and recv.IconFrame or nil, recv
end
BF.GetBlizzardPingIconFrame = GetBlizzardPingIconFrame

function BF.HasPingPinEvents()
    return GetBlizzardPingIconFrame("target") ~= nil
end

-- ------------------------------------------------------------
-- Real-ping mirror. Blizzard_PingUI runs in a secure environment, so
-- script hooks / method overrides on its frames can't be relied on;
-- IsShown() and GetAtlas() are engine state and read fine from here.
-- One light ticker polls the receivers' IconFrame and mirrors
-- show/hide + kit onto our widgets.
-- ------------------------------------------------------------
-- v96: each entry carries the oUF frame key AND that frame's own enable
-- flag, so the per-frame gate in CollectUnitFramePins costs one table read
-- (see GATE 2 there).
local PING_MIRROR_UNITS = {
    target = { key = "oufTarget", show = "showTargetFrame" },
    focus  = { key = "oufFocus",  show = "showFocusFrame"  },
}
local PING_PLAYER = { key = "oufPlayer", show = "showPlayerFrame" }
local pingMirror

-- iconFrame: a Blizzard receiver's IconFrame (or nil = treat as hidden)
-- el       : our _bfPingIndicator texture
local function MirrorIconFrame(iconFrame, el)
    if not el then return end
    local shown = iconFrame and iconFrame:IsShown() or false
    local atlas = shown and iconFrame.Icon and iconFrame.Icon:GetAtlas() or nil
    -- Key on (shown, atlas): a re-ping while a pin is already up only
    -- swaps the atlas, with no show/hide transition.
    local key = shown and (atlas or "?") or false
    if key == el._mirrorKey then return end
    el._mirrorKey = key
    if shown then
        if not el.isRaidPin then
            local p = BF.ufDB and BF.ufDB.profile
            if p and p.oufShowPingIndicator == false then return end
        end
        local kit = atlas and atlas:match("^Ping_Frame_(.+)$")
        BF._pingEventsSeen = (BF._pingEventsSeen or 0) + 1
        BF._lastPingKit = kit or atlas
        if kit then
            el:SetAtlas("Ping_Frame_" .. kit, el.useAtlasSize)
            el.Background:SetAtlas("Ping_Frame_BG_" .. kit, el.useAtlasSize)
        elseif atlas then
            el:SetAtlas(atlas, el.useAtlasSize)
            local bgAtlas = iconFrame.BackgroundMarker
                and iconFrame.BackgroundMarker:GetAtlas()
            if bgAtlas then el.Background:SetAtlas(bgAtlas, el.useAtlasSize) end
        else
            return -- nothing readable; leave ours hidden
        end
        el:Show()
        el:PostUpdate(kit)
    else
        el:Hide()
        el:PostUpdate(nil)
    end
end

-- Sources. The default UI has no receiver on PlayerFrame, but every
-- compact party/raid frame carries one (pingIconFrame, GUID-matched to
-- frame.unit, gated by the showPingsOnRaidFrames CVar); TargetFrame and
-- FocusFrame carry their own. Rather than resolving anything per tick,
-- receiver -> pin mappings are PRE-RESOLVED (on roster changes and on
-- toggle changes) into one flat list of { iconFrame, pin, pin, ... }
-- entries. The ticker is one loop of IsShown() compares over that list,
-- and it only exists while the list is non-empty: with the feature off
-- (or solo with every toggle off) nothing runs at all.
local COMPACT_FRAME_NAMES
local function GetCompactFrameNames()
    if COMPACT_FRAME_NAMES then return COMPACT_FRAME_NAMES end
    local t = {}
    for i = 1, 5 do t[#t + 1] = "CompactPartyFrameMember" .. i end
    for i = 1, 40 do t[#t + 1] = "CompactRaidFrame" .. i end
    for g = 1, 8 do
        for m = 1, 5 do t[#t + 1] = "CompactRaidGroup" .. g .. "Member" .. m end
    end
    COMPACT_FRAME_NAMES = t
    return t
end

local pingEntries = {}      -- { iconFrame = f, [1..n] = pin textures }
local pingRebuildPending
local pingTickerOn = false

-- Profiler hooks: the ticker and resolver are exposed on this table and
-- always invoked THROUGH it, so Profiler.lua can wrap them by name
-- (PingMirror:Tick / PingMirror:Resolve).
BF.pingMirror = {}

local function PingTick()
    for i = 1, #pingEntries do
        local e = pingEntries[i]
        local icf = e.iconFrame
        for j = 1, #e do MirrorIconFrame(icf, e[j]) end
    end
end

BF.pingMirror.Tick = PingTick
local function RunPingTick() return BF.pingMirror.Tick() end

-- C_Timer ticker rather than OnUpdate: no per-render-frame call just to
-- count down an accumulator, and nothing at all scheduled while off.
local pingTickerHandle
local function SetPingTicker(on)
    if on == pingTickerOn or not pingMirror then return end
    pingTickerOn = on
    if on then
        pingTickerHandle = C_Timer.NewTicker(0.2, RunPingTick)
    elseif pingTickerHandle then
        pingTickerHandle:Cancel()
        pingTickerHandle = nil
    end
end

local function HidePin(el)
    if el then el:Hide(); el:PostUpdate(nil); el._mirrorKey = false end
end

-- The raw pin texture for an oUF descriptor, or nil when that frame was
-- never built (ptfEnabled off from login is exactly this case).
local function UFPin(d)
    local f = BF[d.key]
    return f and f._bfPingIndicator
end

-- ============================================================
-- Collector 1: the oUF unit frames
-- ============================================================
-- TWO GATES, owner ruling 2026-08-25.
--
--   GATE 1 (module) -- ptfEnabled / oufShowPingIndicator. The cheap steady
--   state: off means one profile read, three idempotent HidePin calls on
--   pins that mostly do not exist, and return. No receiver lookups, no
--   entries, no per-frame work.
--
--   GATE 2 (frame)  -- each frame's own showXFrame flag, so somebody running
--   only the player frame does no target/focus work.
--
-- Both gates HIDE unconditionally rather than tracking edges. That was
-- considered and rejected: oUF's Disable() is UnregisterUnitWatch + Hide()
-- (Libs/oUF/ouf.lua), so a disabled frame's retained pin renders nothing
-- anyway, and a one-shot sweep would strand a pin that something OUTSIDE the
-- mirror had shown -- /bf pingtest calls el:Show() directly. HidePin is
-- idempotent and keyed (_mirrorKey), so the repeat cost is a nil test.
local function CollectUnitFramePins(add)
    -- ── GATE 1: the module ──────────────────────────────────────────────
    local p = BF.ufDB and BF.ufDB.profile
    if not (p and p.ptfEnabled and p.oufShowPingIndicator ~= false) then
        for _, d in pairs(PING_MIRROR_UNITS) do HidePin(UFPin(d)) end
        HidePin(UFPin(PING_PLAYER))
        return
    end

    -- ── GATE 2: each frame ──────────────────────────────────────────────
    -- Raid-style twins (UnitFrames/Twins.lua) deliberately do NOT gate the
    -- target/focus pins. Their twin only replaces the oUF frame while the unit
    -- is friendly-assistable; for a hostile target the oUF frame is back on
    -- screen and needs its pin. While the twin IS up the oUF frame is
    -- driver-hidden, so its retained pin renders nothing -- the same
    -- already-accepted no-op the header comment describes for Disable() -- and
    -- the twin carries the pin itself: through CollectRaidPins in a group, and
    -- through this collector's own receivers when solo (see soloTwinPin).
    -- The player twin is the one exception; see below.
    --
    -- Target / focus: static receivers, static pins.
    --
    -- Solo, the twin's own raid pin has nowhere to go: CollectRaidPins matches
    -- pins to Blizzard compact frames by GUID and there are none outside a
    -- group, so without this the driver-hidden oUF pin and the unmatched twin
    -- pin would leave the unit with no ping at all. These receivers are static
    -- and need no group, so out of a group the twin's pin rides them too. In a
    -- group the raid path owns that pin -- the two are mutually exclusive on
    -- IsInGroup(), so one texture is never driven by two receivers.
    local soloTwinPin = not IsInGroup()
    for unit, d in pairs(PING_MIRROR_UNITS) do
        local pin = UFPin(d)
        local twinPin
        if soloTwinPin and BF.IsTwinActive and BF:IsTwinActive(unit)
            and BF.GetTwinFrame then
            local twin = BF:GetTwinFrame(unit)
            twinPin = twin and twin.pingIndicatorTex or nil
        end
        if pin or twinPin then
            local icf = p[d.show] ~= false and GetBlizzardPingIconFrame(unit) or nil
            if icf then
                local e = { iconFrame = icf }
                if pin     then e[#e + 1] = pin     end
                if twinPin then e[#e + 1] = twinPin end
                pingEntries[#pingEntries + 1] = e
            else
                HidePin(pin)
                HidePin(twinPin)
            end
        end
    end

    -- The player pin has no receiver of its own; it rides the compact frame
    -- carrying the player's GUID, so it only exists in a group.
    -- The player twin has no friendly/hostile driver -- the player is always
    -- assistable -- so with it on the oUF player frame is Disabled outright and
    -- its pin can never render. Suppress it rather than key a dead pin to the
    -- player's GUID: the twin is in BF.activeFrames and CollectRaidPins claims
    -- that GUID with the twin's own raid pin.
    local playerPin = UFPin(PING_PLAYER)
    if playerPin then
        local playerTwin = BF.IsTwinActive and BF:IsTwinActive("player")
        local pguid = IsInGroup() and p[PING_PLAYER.show] ~= false and not playerTwin
            and SafeGUID("player") or nil
        if pguid then
            add(pguid, playerPin)
        else
            HidePin(playerPin)
        end
    end
end

-- ============================================================
-- Collector 2: the raid/party frames
-- ============================================================
-- Reads NOTHING from BF.ufDB -- that independence is the whole point of the
-- v96 split. Each frame's own icons.showPingIndicator (routed through
-- GetSectionProfileForFrame, so preview frames answer for themselves) is the
-- only gate, and a frame that is not collected is HIDDEN, so a pin cannot
-- survive leaving the group or switching the toggle off.
--
-- Raid-style twins are in BF.activeFrames like any raid frame, so in a group
-- they get their pin from here. Out of a group there is no compact frame to
-- match a GUID against, so the twins are left to CollectUnitFramePins' static
-- target/focus receivers instead of being blanket-hidden below.
local function CollectRaidPins(add)
    local frames = BF.activeFrames
    if not frames then return end
    if not IsInGroup() then
        for f in pairs(frames) do
            if not f._bf_twinKey then HidePin(f.pingIndicatorTex) end
        end
        return
    end
    for f in pairs(frames) do
        local pin = f.pingIndicatorTex
        if pin then
            local unit = f.unit
            local sip = BF.GetSectionProfileForFrame
                and BF:GetSectionProfileForFrame("icons", f)
            -- v93: the gate is the GUID's readability, not the unit token's.
            local guid = (not sip or sip.showPingIndicator ~= false)
                and SafeGUID(unit) or nil
            if guid then
                add(guid, pin)
            else
                if unit and (not sip or sip.showPingIndicator ~= false) then
                    -- Wanted a pin but the GUID is unreadable: retry on regen.
                    pingSecretSkipped = true
                end
                HidePin(pin)
            end
        end
    end
end

-- ============================================================
-- Resolve: build the flat receiver -> pins list
-- ============================================================
local function ResolvePingEntries()
    pingRebuildPending = nil
    pingSecretSkipped = false
    wipe(pingEntries)

    -- GUID -> { pin, ... } for everything that has no receiver of its own
    -- and must be matched to a compact frame instead.
    local pinsByGUID
    -- v97 (2026-08-27): every GUID-keyed pin collected this pass. A pin that
    -- ends up matched to no receiver (its player just left, or the receiver
    -- was reassigned during the debounce) used to be neither entered nor
    -- hidden -- a pin showing at that moment stayed up forever, with no
    -- ticker entry to ever clear it. Same "always overwrite on missing"
    -- rule Grid2's indicators follow: unmatched => hidden.
    local collected, matched
    local function addPin(guid, pin)
        -- Sink guard: a non-string guid can never be a safe table key here.
        if type(guid) ~= "string" or not pin then return end
        pinsByGUID = pinsByGUID or {}
        local l = pinsByGUID[guid]
        if not l then l = {}; pinsByGUID[guid] = l end
        l[#l + 1] = pin
        collected = collected or {}
        collected[pin] = true
    end

    CollectUnitFramePins(addPin)
    CollectRaidPins(addPin)

    if pinsByGUID then
        for _, name in ipairs(GetCompactFrameNames()) do
            local f = _G[name]
            local recv = f and f.pingIconFrame
            local icf = recv and recv.IconFrame
            local unit = f and f.unit
            -- v93: this line threw. Guard the GUID, not the unit token.
            local guid = icf and SafeGUID(unit) or nil
            if icf and unit and not guid then pingSecretSkipped = true end
            if guid then
                local pins = pinsByGUID[guid]
                if pins then
                    local e = { iconFrame = icf }
                    matched = matched or {}
                    for i = 1, #pins do
                        e[i] = pins[i]
                        matched[pins[i]] = true
                    end
                    pingEntries[#pingEntries + 1] = e
                end
            end
        end
    end
    if collected then
        for pin in pairs(collected) do
            if not (matched and matched[pin]) then HidePin(pin) end
        end
    end

    BF._pingEntryCount = #pingEntries
    SetPingTicker(#pingEntries > 0)
end
BF.pingMirror.Resolve = ResolvePingEntries
-- Exposed for the PLAYER_REGEN_ENABLED handler below, which lives in a
-- different closure and cannot see the upvalue.
function BF.pingMirror.SecretSkipped() return pingSecretSkipped end
local function RunPingResolve() return BF.pingMirror.Resolve() end

-- Debounced: roster events arrive in bursts, and header children pick up
-- their units during the same burst. Also the entry point for every
-- toggle (starts/stops the ticker as needed).
function BF:RebuildPingMirror()
    if pingRebuildPending then return end
    pingRebuildPending = true
    C_Timer.After(0.5, RunPingResolve)
end

function BF:EnsurePingMirror()
    if pingMirror or not BF.HasPingPinEvents() then return end
    pingMirror = CreateFrame("Frame")
    -- A hidden TargetFrame no longer gets PLAYER_TARGET_CHANGED (which is
    -- what clears its pin on retarget), so clear ours on unit change.
    -- Hide Blizzard's IconFrame too (plain frame method, not protected)
    -- so both sides reset together and the next ping is a clean
    -- transition; otherwise Blizzard's stays shown and we'd miss it.
    pingMirror:RegisterEvent("PLAYER_TARGET_CHANGED")
    pingMirror:RegisterEvent("PLAYER_FOCUS_CHANGED")
    pingMirror:RegisterEvent("GROUP_ROSTER_UPDATE")
    pingMirror:RegisterEvent("PLAYER_ENTERING_WORLD")
    -- v93: combat catch-up for secret GUIDs. A resolve that ran while a unit
    -- was under combat secrecy could not key that unit's pin (see SafeGUID)
    -- and set pingSecretSkipped; leaving combat is the cheapest moment the
    -- module can know a re-resolve might now succeed. Gated on the flag, so a
    -- clean resolve costs nothing on every combat exit -- and there is no
    -- timed retry on purpose: units do not leave combat on a schedule.
    -- Registered here rather than in BF:PLAYER_REGEN_ENABLED to keep this
    -- module self-contained (the v96 split's whole point).
    pingMirror:RegisterEvent("PLAYER_REGEN_ENABLED")
    -- v98: re-resolve after every Blizzard compact-frame layout. TryUpdate is
    -- the one funnel -- CompactPartyFrame:RefreshMembers + LayoutFrames --
    -- for every path that assigns a unit to a receiver: the roster handler
    -- BlizzardFrames.lua now leaves registered on the hidden container, the
    -- login-time layout Edit Mode triggers, and the manager's filter buttons.
    -- Our own GROUP_ROSTER_UPDATE below lands in the same burst, but the
    -- order between the two frames' handlers is not guaranteed and a resolve
    -- that ran BEFORE the layout would match nothing; the 0.5s debounce in
    -- RebuildPingMirror coalesces both into one resolve after the layout.
    if CompactRaidFrameContainer and CompactRaidFrameContainer.TryUpdate then
        hooksecurefunc(CompactRaidFrameContainer, "TryUpdate", function()
            BF:RebuildPingMirror()
        end)
    end
    pingMirror:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_REGEN_ENABLED" then
            if BF.pingMirror and BF.pingMirror.SecretSkipped() then
                BF:RebuildPingMirror()
            end
            return
        end
        if event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
            BF:RebuildPingMirror()
            return
        end
        local unit = event == "PLAYER_FOCUS_CHANGED" and "focus" or "target"
        local d    = PING_MIRROR_UNITS[unit]
        -- v96: touch Blizzard's receiver ONLY while we actually replace that
        -- frame. The Hide() below exists to keep OUR pin and Blizzard's in
        -- step; with the unit-frames module off, Blizzard's TargetFrame is
        -- live and unreplaced, and hiding its ping icon would be vandalism
        -- of a frame we do not own.
        local p   = BF.ufDB and BF.ufDB.profile
        if not (d and p and p.ptfEnabled and p[d.show] ~= false) then return end
        local pin = UFPin(d)
        if not pin then return end
        HidePin(pin)
        local iconFrame = GetBlizzardPingIconFrame(unit)
        if iconFrame and iconFrame:IsShown() then pcall(iconFrame.Hide, iconFrame) end
    end)
    BF:RebuildPingMirror()
end

-- "ticking" / "idle" / "off" -- for /bf pingtest status (BF:DebugFakePing in
-- UnitFrames/oUF_Shared.lua), which can no longer see these upvalues.
function BF:GetPingMirrorStatus()
    if pingTickerOn then return "ticking" end
    return pingMirror and "idle" or "off"
end
