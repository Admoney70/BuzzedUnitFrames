-- ============================================================
-- BuzzardFrames: AuraCustomizations/ExpirationGlow.lua
--
-- Per-spell "Expiration Glow" feature. When the remaining duration
-- of a buff icon drops below a user-configured threshold, this
-- module starts a LibCustomGlow glow on the icon (or recolors its
-- border for "border" glow type). The glow stops when:
--   * the aura is refreshed back above the threshold,
--   * the aura is removed (icon released / replaced), or
--   * the user disables the feature.
--
-- Architecture (CPU-optimized, mirrors SoulOfTheForest.lua pattern):
--
--   * Global gate flag BF._expirationGlowActive: true iff at least
--     one enabled config exists for any spec/spell. The render loop
--     and threshold poll both fast-bail when false, so non-users
--     pay zero cost. Recomputed only when configs change.
--
--   * Per-icon resolver cache. When the render loop sees a new
--     spellId in a slot, it calls Register(icon, sid, unit, exp).
--     Register caches the resolved config on the icon. While the
--     same spellId stays in the slot, no resolver call happens.
--     A generation counter (BF._expirationGlowConfigGen) busts the
--     cache when the user edits any setting.
--
--   * Threshold poll: integrated with the existing 0.2s-tick
--     animation-group loop in AuraConfig.lua (_ThresholdPollOnTick).
--     This module exposes BF._ExpirationGlowPollOnTick, which is
--     called from that loop. We register icons into a separate
--     map (_pollIcons) so the existing threshold-color path is
--     untouched.
--
--   * Per-icon state fields (do not collide with SotF):
--       icon._bf_expGlow        boolean: glow currently active
--       icon._bf_expGlowType    string:  active glow type
--       icon._bf_expGlowColor   {r,g,b,a}: active glow color
--       icon._bf_expGlowSpell   number:  cached spellId
--       icon._bf_expGlowCfg     table:   cached resolved config (or false=none)
--       icon._bf_expGlowGen     number:  config generation when cached
--       icon._bf_expGlowExp     number:  cached expirationTime
--       icon._bf_expGlowUnit    string:  unit token (for sweep on disable)
--       icon._bf_expGlowOrigBorderColor {r,g,b,a}: saved for "border" mode
--
-- Notes:
--   * Border-mode glow shares the existing icon._sotfBorderActive
--     gate read by RenderContainerIcons (so the per-render border
--     repaint doesn't clobber our color). Because SotF's "border"
--     mode and Expiration's "border" mode write to the same border,
--     they would conflict if both fired at once on the same icon.
--     SotF wins the slot it touches; Expiration only paints the
--     border if SotF is not currently using it.
-- ============================================================

local BF  = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")
local LCG = LibStub("LibCustomGlow-1.0", true)

local GetTime = GetTime
local canaccessvalue = canaccessvalue or function() return true end

-- ============================================================
-- STATE
-- ============================================================

-- Active flag — render loop and poll both bail when false.
-- Recomputed by RecomputeActive() whenever configs change.
BF._expirationGlowActive   = false

-- Bumped by option setters when any expiration-glow field changes.
-- Bump on RecomputeActive() too so the resolver cache invalidates
-- on profile load and option edits in a single mechanism.
BF._expirationGlowConfigGen = 0

-- Polled icons: icon -> true. Walked by _ExpirationGlowPollOnTick.
local _pollIcons = {}

-- Forward decl for helper used by Register/Unregister.
local StopGlow

-- ============================================================
-- GLOW START / STOP
-- ============================================================

StopGlow = function(icon)
    if not icon._bf_expGlow then return end
    local gt = icon._bf_expGlowType or "pixel"
    if gt == "border" then
        -- Only restore if we actually painted the border (SotF may
        -- have stolen the slot mid-flight).
        if icon._bf_expGlowOwnsBorder then
            local orig = icon._bf_expGlowOrigBorderColor
            if orig and BF.SetIconBorderColor then
                BF.SetIconBorderColor(icon, orig[1], orig[2], orig[3], orig[4])
            elseif BF.SetIconBorderColor then
                BF.SetIconBorderColor(icon, 0, 0, 0, 0.8)
            end
            icon._bf_expGlowOwnsBorder = nil
        end
        icon._bf_expGlowOrigBorderColor = nil
    elseif LCG then
        if gt == "pixel" then
            LCG.PixelGlow_Stop(icon, "bfExp")
        elseif gt == "autocast" then
            LCG.AutoCastGlow_Stop(icon, "bfExp")
        elseif gt == "proc" then
            LCG.ProcGlow_Stop(icon, "bfExp")
        else
            LCG.ButtonGlow_Stop(icon)
        end
    end
    icon._bf_expGlow      = false
    icon._bf_expGlowType  = nil
    icon._bf_expGlowColor = nil
end

local function StartGlow(icon, color, glowType)
    if glowType == "border" then
        -- SotF border mode owns the icon's border whenever active.
        -- Don't fight it, BUT still mark the glow as logically active
        -- so the poll-tick comparator doesn't keep allocating a new
        -- color table every 200ms trying to restart this glow. When
        -- SotF stops, ClearSotFGlow restores its saved border color;
        -- our next render pass will then re-resolve and (if the aura
        -- is still expiring) genuinely paint the border on the next
        -- poll tick because _bf_expGlowOwnsBorder is still false here.
        if icon._sotfBorderActive then
            icon._bf_expGlow      = true
            icon._bf_expGlowType  = glowType
            icon._bf_expGlowColor = color
            -- intentionally do NOT set _bf_expGlowOwnsBorder
            return
        end
        if not icon._bf_expGlowOrigBorderColor and icon.GetBackdropBorderColor then
            local r, g, b, a = icon:GetBackdropBorderColor()
            if r then icon._bf_expGlowOrigBorderColor = { r, g, b, a } end
        end
        if BF.SetIconBorderColor then
            BF.SetIconBorderColor(icon, color[1], color[2], color[3], color[4] or 1)
        end
        icon._bf_expGlowOwnsBorder = true
        icon._bf_expGlow      = true
        icon._bf_expGlowType  = glowType
        icon._bf_expGlowColor = color
        return
    end
    if not LCG then return end
    local w, h = icon:GetSize()
    if not w or not h or w <= 0 or h <= 0 then return end
    local ok
    if glowType == "pixel" then
        -- Pixel-snapped parameters keyed on the icon's current size
        -- (cached by BF.GetPixelGlowParamsForSize — O(1) on hits, math
        -- only runs once per distinct size for the whole session).
        local N, lenArg, thArg
        if BF.GetPixelGlowParamsForSize then
            N, lenArg, thArg = BF.GetPixelGlowParamsForSize(icon.cachedSize or w)
        else
            N, lenArg, thArg = 8, 6, 1
        end
        ok = pcall(LCG.PixelGlow_Start, icon, color, N, 0.4, lenArg, thArg, 0, 0, false, "bfExp")
    elseif glowType == "autocast" then
        ok = pcall(LCG.AutoCastGlow_Start, icon, color, nil, 0.25, nil, nil, nil, "bfExp")
    elseif glowType == "proc" then
        ok = pcall(LCG.ProcGlow_Start, icon, { color = color, key = "bfExp", duration = 0.8 })
    else
        ok = pcall(LCG.ButtonGlow_Start, icon, color, 0.25, nil)
    end
    if ok then
        icon._bf_expGlow      = true
        icon._bf_expGlowType  = glowType
        icon._bf_expGlowColor = color
    end
end

BF.StopExpirationGlow = StopGlow

-- ============================================================
-- CONFIG RESOLUTION
-- Cached on the icon. Re-resolves only when the spellId in the
-- slot changes OR the global config generation bumps.
-- ============================================================
local function ResolveConfigFor(icon, sid)
    if icon._bf_expGlowSpell == sid and icon._bf_expGlowGen == BF._expirationGlowConfigGen then
        local cfg = icon._bf_expGlowCfg
        if cfg == false then return nil end
        return cfg
    end
    local cfg = BF.ResolveSpellExpirationGlow and BF.ResolveSpellExpirationGlow(sid) or nil
    icon._bf_expGlowSpell = sid
    icon._bf_expGlowGen   = BF._expirationGlowConfigGen
    icon._bf_expGlowCfg   = cfg or false
    return cfg
end

-- ============================================================
-- REGISTER / UNREGISTER (render-loop facing API)
-- ============================================================

-- Register the icon for per-tick checking. Cheap: hash insert +
-- resolver cache check. Called once per icon per render frame.
-- The cached expirationTime is refreshed every call so the poll
-- loop can compute remaining = exp - GetTime() without going back
-- to C_UnitAuras.
local function Register(icon, sid, unit, exp)
    if not BF._expirationGlowActive then
        if icon._bf_expGlow then StopGlow(icon) end
        if _pollIcons[icon] then _pollIcons[icon] = nil end
        return
    end
    local cfg = ResolveConfigFor(icon, sid)
    if not cfg then
        if icon._bf_expGlow then StopGlow(icon) end
        if _pollIcons[icon] then _pollIcons[icon] = nil end
        return
    end
    icon._bf_expGlowExp  = exp
    icon._bf_expGlowUnit = unit

    -- "Always" mode: start the glow immediately on registration and
    -- skip the threshold poll entirely. PollOnTick is never visited
    -- for these icons, so toggling color/type/showMode bumps the gen
    -- and the next Register call (next render pass) restarts the
    -- glow with the new params. Teardown is handled by Unregister
    -- (icon release / hide path) via StopGlow.
    if cfg.showMode == "always" then
        if _pollIcons[icon] then _pollIcons[icon] = nil end
        local c        = cfg.color
        local glowType = cfg.glowType or "pixel"
        local cR = c and c.r or 1
        local cG = c and c.g or 0.2
        local cB = c and c.b or 0.2
        local cA = c and (c.a or 1) or 1
        local needsRestart = false
        if not icon._bf_expGlow then
            needsRestart = true
        elseif icon._bf_expGlowType ~= glowType then
            needsRestart = true
        else
            local oc = icon._bf_expGlowColor
            if not oc or oc[1] ~= cR or oc[2] ~= cG
                or oc[3] ~= cB or oc[4] ~= cA then
                needsRestart = true
            elseif glowType == "border"
                and not icon._bf_expGlowOwnsBorder
                and not icon._sotfBorderActive then
                needsRestart = true
            end
        end
        if needsRestart then
            if icon._bf_expGlow then StopGlow(icon) end
            StartGlow(icon, { cR, cG, cB, cA }, glowType)
        end
        return
    end

    -- "Threshold" mode (default): poll-driven start/stop.
    local wasEmpty = (next(_pollIcons) == nil)
    _pollIcons[icon] = true
    -- Ensure the shared 0.2s threshold timer is running so we get
    -- polled. Cheap: only the first registration after empty calls
    -- through; subsequent calls hit the no-op IsPlaying check.
    if wasEmpty and BF.StartExpirationGlowTimer then
        BF.StartExpirationGlowTimer()
    end
end
BF.RegisterIconForExpirationGlow = Register

-- Called from icon release / hide paths. O(1) cleanup.
-- Fast-bails when the icon has no expiration-glow state at all
-- (the common case for icons that never entered the threshold
-- window, and the universal case for every icon when the feature
-- is unused). Detection key is _bf_expGlowSpell because Register
-- always sets it before adding to _pollIcons.
local function Unregister(icon)
    if icon._bf_expGlowSpell == nil and not icon._bf_expGlow then return end
    if _pollIcons[icon] then _pollIcons[icon] = nil end
    if icon._bf_expGlow then StopGlow(icon) end
    icon._bf_expGlowSpell = nil
    icon._bf_expGlowCfg   = nil
    icon._bf_expGlowGen   = nil
    icon._bf_expGlowExp   = nil
    icon._bf_expGlowUnit  = nil
end
BF.UnregisterIconForExpirationGlow = Unregister

-- ============================================================
-- POLL TICK
-- Driven by the existing 0.2s animation-group loop in
-- AuraConfig.lua. One numeric compare + branch per registered
-- icon per tick; glow starts/stops happen only on threshold
-- crossings.
-- ============================================================
local function PollOnTick()
    if not next(_pollIcons) then return end
    local now = GetTime()
    for icon in pairs(_pollIcons) do
        if not icon:IsVisible() then
            -- Icon hidden (slot recycled / aura removed). Drop and
            -- ensure no glow lingers.
            _pollIcons[icon] = nil
            if icon._bf_expGlow then StopGlow(icon) end
        else
            local cfg = icon._bf_expGlowCfg
            if not cfg or cfg == false then
                _pollIcons[icon] = nil
                if icon._bf_expGlow then StopGlow(icon) end
            else
                local exp = icon._bf_expGlowExp
                if not exp or exp <= 0 then
                    -- Permanent aura or unknown duration: never expires.
                    if icon._bf_expGlow then StopGlow(icon) end
                elseif not canaccessvalue(exp) then
                    -- Secret expirationTime (private aura): can't compare.
                    if icon._bf_expGlow then StopGlow(icon) end
                else
                    local remaining = exp - now
                    local threshold = cfg.threshold or 3
                    if remaining > 0 and remaining <= threshold then
                        -- Should be glowing. Compare cfg color/type to the
                        -- live glow's saved values WITHOUT allocating; only
                        -- build the {r,g,b,a} table if we actually need to
                        -- (re)start the glow.
                        local c        = cfg.color
                        local glowType = cfg.glowType or "pixel"
                        local cR = c and c.r or 1
                        local cG = c and c.g or 0.2
                        local cB = c and c.b or 0.2
                        local cA = c and (c.a or 1) or 1
                        local needsRestart = false
                        if not icon._bf_expGlow then
                            needsRestart = true
                        elseif icon._bf_expGlowType ~= glowType then
                            needsRestart = true
                        else
                            local oc = icon._bf_expGlowColor
                            if not oc or oc[1] ~= cR or oc[2] ~= cG
                                or oc[3] ~= cB or oc[4] ~= cA then
                                needsRestart = true
                            elseif glowType == "border"
                                and not icon._bf_expGlowOwnsBorder
                                and not icon._sotfBorderActive then
                                -- Was deferred to SotF previously; SotF has
                                -- since released the border, so claim it now.
                                needsRestart = true
                            end
                        end
                        if needsRestart then
                            if icon._bf_expGlow then StopGlow(icon) end
                            StartGlow(icon, { cR, cG, cB, cA }, glowType)
                        end
                    else
                        -- Above threshold (or expired) -> ensure stopped.
                        if icon._bf_expGlow then StopGlow(icon) end
                    end
                end
            end
        end
    end
end
BF._ExpirationGlowPollOnTick = PollOnTick

-- ============================================================
-- GLOBAL GATE: recompute BF._expirationGlowActive
-- True iff ANY enabled per-spell entry exists in ANY spec.
-- O(specs * spells-with-entries). Called only when configs change.
-- ============================================================
local function RecomputeActive()
    local p = BF.acDB and BF.acDB.profile
    local active = false
    if p and p.specSpellExpirationGlow then
        for _, specMap in pairs(p.specSpellExpirationGlow) do
            for _, entry in pairs(specMap) do
                if entry and entry.enabled ~= false then
                    active = true
                    break
                end
            end
            if active then break end
        end
    end
    BF._expirationGlowActive = active
    BF._expirationGlowConfigGen = (BF._expirationGlowConfigGen or 0) + 1
end

-- Public sync entry point: call after any config change OR profile load.
function BF:ExpirationGlow_Sync()
    RecomputeActive()
    -- If the feature was turned off, sweep all active glows.
    if not BF._expirationGlowActive then
        if BF.activeFrames then
            for frame in pairs(BF.activeFrames) do
                if frame.buffFrames then
                    for i = 1, #frame.buffFrames do
                        local icon = frame.buffFrames[i]
                        if icon and icon._bf_expGlow then StopGlow(icon) end
                    end
                end
                local pools = frame.SF_CustomContainerIcons
                if pools then
                    for _, pool in pairs(pools) do
                        for i = 1, #pool do
                            local icon = pool[i]
                            if icon and icon._bf_expGlow then StopGlow(icon) end
                        end
                    end
                end
            end
        end
        -- Clear the poll set.
        for icon in pairs(_pollIcons) do _pollIcons[icon] = nil end
    end
end

-- ============================================================
-- LIFECYCLE
-- ============================================================
-- ExpirationGlow_Sync is invoked from:
--   * BF:InvalidateClaimedSpellCache (AuraCustomizations.lua) — runs
--     on spec change, talent change, profile load, settings edits.
--   * BF:OnACProfileChanged (Core_ProfileLifecycle.lua) — profile
--     swap on the AC database.
-- That gives us coverage of every event that can flip the active
-- gate without ExpirationGlow.lua needing its own event listeners.

-- Expose the poll-set for diagnostics / cleanup by other modules
-- (e.g. icon release hooks in AuraGroupHelpers).
BF._expirationGlowPollIcons = _pollIcons
