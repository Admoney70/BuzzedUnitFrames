-- ============================================================
-- BuzzardFrames: Auras/ContainerFactory.lua
-- 12.1 AuraContainer infrastructure for raid/party frame auras.
--
-- Architecture (see Docs/RaidParty_Auras_12.1_Container_Migration_Plan.md
-- and Docs/AuraContainer_API_Reference_12.1.md):
--   * One AuraContainer per migrated grid feature per frame, created
--     lazily by the feature's indicator Create/Layout, stored in
--     frame._bf_auraContainers[featureKey].
--   * Blizzard pool-creates AuraButtons for the container's aura group;
--     our initializeFrame styles each button ONCE at creation from the
--     frame's settings cache (BF:GetAuraCacheForFrame — global,
--     per-layout flat, or per-CFG flat).
--   * Live reconfiguration via the container/group setters (filter,
--     maxFrameCount, sort, layout, flow anchoring). Button VISUALS are
--     baked at creation — restyling requires new buttons (V3: post-PEW
--     out-of-combat mutability unverified) → options that change button
--     visuals prompt reload for now.
--
-- v67: 12.0.7 branch removed (addon is 12.1-only). This file used to bail
-- out early on pre-12.1 clients, where the legacy aura engine ran instead;
-- migrated features now always run on containers and the legacy scan/render
-- paths are permanently dormant (they would hard-error on secret aura data
-- in combat on 12.1).
-- ============================================================

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

-- ============================================================
-- SHARED AURA GLOW / ANTS GEOMETRY (single source of truth).
-- The ring and the marching-ants sheet are sized as a ratio of the icon
-- size. FOUR call sites render this art -- the live container path
-- (ApplyGlowGeometry, below), the Big Defensive override
-- (Indicators/BigDefIcons.lua spec.glowPad), the setup-mode dummies
-- (Auras/DummyAuras.lua ApplyDummyGlow) and the Icon Effects options
-- preview (AuraCustomizations/PreviewIconEffects.lua LayoutPreviewFx) --
-- and they had drifted apart (0.34 / 0.42 / 0.26 / 0.2), so the previews
-- lied about how large the live ring actually renders.
-- ContainerFactory.lua loads before all three consumers (see the .toc),
-- so they read these at runtime. CHANGE SIZES HERE, NOWHERE ELSE.
BF.AURA_GLOW_PAD        = 0.4    -- default ring pad, x icon size per side
BF.AURA_GLOW_PAD_BIGDEF = 0.45   -- Big Defensive ring (proportionally larger)
BF.AURA_ANTS_SCALE      = 1.19   -- marching-ants ring, x icon size
-- ============================================================

local UnitIsVisible = UnitIsVisible

-- Vehicle-tainted container gate (2026-08-13). Applying/re-evaluating
-- container config while the player is in a vehicle corrupts candidate-table
-- group/slot assignment (one matched aura duplicated across slots) — and the
-- corruption sticks until a re-scan OUTSIDE vehicle state. A container gets
-- TAINTED (hidden at alpha 0) when its contents can no longer be trusted and
-- no in-vehicle call can fix them:
--   * BORN in a vehicle (reload-in-vehicle: whole config applied in vehicle
--     state) — MarkVehicleTainted at the creation sites below;
--   * a CINEMATIC fires while in a vehicle — the UNIT_FACTION handler's
--     rescan (Auras.lua) would re-evaluate in vehicle state (= duplication
--     junk) while skipping it leaves the cinematic's stale junk, so
--     MarkAllContainersVehicleTainted hides everything instead.
-- The vehicle-exit flush (Auras.lua) clears the flags and re-runs the
-- visibility gate AFTER re-scanning. Both container alpha writers
-- (SyncAuraGridContainer / RefreshAuraContainerVisibilityForUnit) fold the
-- flag so the change-guarded gate can't re-raise the alpha early.
-- Steady-state containers in vehicles are untouched — they display fine.
local function MarkVehicleTainted(c)
    if BF.PlayerInVehicle and BF.PlayerInVehicle() then
        c._bf_vehicleTainted = true
        c._bf_visAlpha = 0
        c:SetAlpha(0)
        BF._bf_anyVehicleTainted = true
    end
end

-- ============================================================
-- CONTAINER VISIBILITY ALPHA — ONE WRITER, ONE UNION.
--
-- Every aura container BF owns is hidden by dropping its ALPHA, not by
-- hiding it: the engine keeps rendering stale, unfiltered aura data for a
-- bound-but-unreachable unit, and candidate-filter parking cannot clear
-- engine DISPLAY state. Five gates feed that decision — the container's own
-- shown state, vehicle taint, the cinematic gate, hostile/charmed
-- suppression, and unit reachability (visible + not offline).
--
-- WHY THIS IS A FUNCTION (owner-reported, 2026-08-19). The union used to be
-- written out longhand at each of three call sites, and the change-guard
-- field _bf_visAlpha was shared between them. The SHARED SLOT container lives
-- in the same frame._bf_auraContainers table as the grid containers, so all
-- three sweeps wrote ITS alpha too — but the slot path (SlotContainerShown)
-- had no alpha writer at all. So:
--
--   1. a layout transition momentarily takes the slot container's
--      _bf_activeSlots to 0, so _bf_shown goes false;
--   2. a sweep runs in that window, computes 0, writes alpha 0 and records
--      _bf_visAlpha = 0;
--   3. the slots come back, SlotContainerShown sets _bf_shown = true and
--      calls SetShown(true) -- and nothing ever raises the alpha again,
--      because the only code that writes it is change-guarded on a field
--      that already says 0.
--
-- The result was a container that is shown, correctly levelled, correctly
-- parented, bound to the right unit, with correct filters and candidate sets,
-- with the engine happily assigning auras to its slots -- and invisible.
-- Every per-slot diagnostic reported it healthy, because every field they
-- read WAS healthy. Confirmed on the owner's frames: the same slot on two
-- player frames, byte-identical in every other respect, visAlpha 1 on one and
-- 0 on the other.
--
-- A partial fix (add a SetAlpha to the slot path) would leave four call sites
-- each free to compute a different union, which is the shape that produced
-- the bug. One function, called by all of them, cannot drift.
-- ============================================================

-- Offline read for the visibility gate. Reads the Offline status's
-- event-maintained cache (a table index — NO UnitIsConnected API call on the
-- aura-tick hot path). Needed because UnitIsVisible alone misses the
-- disconnect edge: at the moment the offline event fires the unit can still
-- read visible, and for a CROSS-FACTION member the engine repaints the
-- containers with junk the instant the unit goes offline (assist relation
-- fully degraded) — with no UNIT_AURA ever firing again to re-run this gate.
--
-- Resolved per call rather than captured: this file loads before the statuses.
local function IsUnitOffline(unit)
    local s = BF.statuses and BF.statuses.offline
    return (s and s:IsActive(unit)) and true or false
end

-- The union. `shown` is the container's own visibility decision — the grid
-- path passes the value it is about to apply, the slot path passes the one
-- derived from its live slot count.
-- ============================================================
-- HOSTILE / CHARMED UNIT SUPPRESSION (v93, 2026-08-20, owner ruling).
--
-- A group member that gets mind-controlled -- or any unit that turns
-- unfriendly -- stops being a unit this addon can filter auras on:
--
--   * HELPFUL side: Blizzard's ValidateCandidateFilters permits
--     includeSpellIDs matching only on ASSISTABLE units, so every group
--     that narrows by spell id (sb<key>, sp<sid>, bfc<ci>/main) silently
--     loses its candidate set and falls back to its permissive filter
--     string -- "every helpful aura on the unit". That is the v79 assist
--     gate's reasoning (BuffsAndContainers:Update), unchanged.
--   * HARMFUL side, which had NO gate at all: the RAID scoping stops
--     narrowing on a unit we cannot assist, so the debuffs row degrades to
--     "every debuff on the unit" -- on a charmed raid member, the whole
--     raid's DoTs. The dispel visuals go with it: they are dispel-TYPE
--     driven, so every dispellable DoT lights them up.
--
-- Owner requirement (2026-08-20): show NOTHING on such a unit until it is
-- friendly again, rather than garbage.
--
-- ONE predicate, deliberately the widest net (owner choice, same date):
--   * UnitCanAttack     -- hostile: charmed member, turned NPC, PvP flip.
--   * not UnitCanAssist -- the engine's OWN carve-out predicate; also
--                          catches cross-faction party members.
--
-- There is deliberately NO UnitIsCharmed term: it returns a SECRET boolean on
-- 12.1 and testing it throws (see the note at the test itself). The two terms
-- above already cover every charm that matters.
--
-- CACHED per unit token and event-maintained (UNIT_FLAGS / UNIT_FACTION
-- plus the BF_UnitUpdated / BF_UnitLeft roster messages -- wiring lives in
-- Auras/Auras.lua), because ContainerVisAlpha below runs per container per
-- aura tick: the hot path has to be one table read, exactly like
-- IsUnitOffline above. nil means "not resolved yet", NOT "not suppressed":
-- the read fills it lazily, so a unit whose first paint precedes any event
-- is still gated. The API calls stay in the cold path.
-- ============================================================
local auraSuppressed = {}

-- pcall'd by ComputeAuraSuppressed below. Every test in here is a boolean
-- test on a unit API, which is the exact shape 12.1 can turn into a secret
-- value without warning -- and this one already did once (UnitIsCharmed).
local function ResolveAuraSuppressed(unit)
    if not UnitExists(unit) then return false end
    -- Never our own frame: self-filtering always works, and a player who is
    -- themselves mind-controlled still needs to read their own auras.
    if UnitIsUnit(unit, "player") then return false end
    -- Both plain booleans. NO UnitIsCharmed TERM -- do not add one back:
    -- on 12.1 UnitIsCharmed returns a SECRET boolean, and testing it throws
    -- "attempt to perform boolean test on a secret boolean value" (owner
    -- repro on raid22, 2026-08-20). It bought nothing anyway: a charmed unit
    -- is either attackable or non-assistable, which the two tests below
    -- already catch, and a charmed unit that is STILL friendly and assistable
    -- is one the group owns (an enslaved demon) -- whose auras filter fine
    -- and must not be blanked. UnitCanAttack and UnitCanAssist are not
    -- secret: the addon has always tested them directly (Health:GetColor,
    -- the v79 assist gate).
    if UnitCanAttack("player", unit) then return true end
    if not BF.PlayerCanAssistUnit(unit) then return true end
    return false
end

-- Fail OPEN. A secret value, or any other client refusal, degrades to "not
-- suppressed" -- i.e. exactly the pre-v93 behavior -- rather than throwing
-- from an event handler or blanking every frame in the group. The cost is one
-- pcall per cache miss or edge; the hot path never reaches here.
local function ComputeAuraSuppressed(unit)
    local ok, v = pcall(ResolveAuraSuppressed, unit)
    return (ok and v) and true or false
end

-- ============================================================
-- v99 (2026-08-27): AURA GATES.
-- Build 69465 changed AuraContainerUtil.CanApplyIdentityCandidateFilters:
-- helpful-aura include/exclude sets are now ALWAYS honored on group
-- members (UnitIsPlayerControlledOrGroupMember), and the remaining
-- UnitCanAssist tests ignore immune/uninteractable states. That was the
-- root cause behind three BF gates, which are now OFF by default (PTR
-- verified 2026-08-27 on build 69497, owner ruling):
--   assist    (v79)  buffs row / bfc / slot host / bigDef sb* blanked on a
--                    non-assistable unit -- OFF: include sets hold now.
--   vehicle   (v84)  vehicle-taint alpha hide                -- OFF.
--   cinematic        cinematic alpha gate                    -- OFF.
-- Still needed (different mechanisms, untouched by the engine change):
--   suppress  (v93)  hostile/charmed suppression -- the HARMFUL filter
--                    string stops narrowing on a hostile unit (an MC'd
--                    member shows the raid's DoTs), and it is the only
--                    thing left that blanks a hostile frame.        -- ON.
--   visibility       alpha 0 for not-visible / offline units (engine
--                    keeps stale display state for unreachable units;
--                    re-verified: junk returned with it off).       -- ON.
--   assist4          suppress's assist predicate uses the four-argument
--                    UnitCanAssist(unit, true, true), per Blizzard's
--                    guidance, so a vehicle / teleport moment is not
--                    "unassistable".                                -- ON.
-- The values are CONSTANTS -- nothing is persisted (owner ruling: no
-- per-user gate tables). `/bf gates` (debug-gated) flips them for the
-- current session only, for A/B testing; the hot path reads the upvalues.
-- ============================================================
local GATE_ASSIST, GATE_SUPPRESS, GATE_VEHICLE, GATE_CINEMATIC, GATE_VISIBILITY, GATE_ASSIST4
    = false, true, false, false, true, true
BF.AURA_GATE_NAMES = { "assist", "suppress", "vehicle", "cinematic", "visibility", "assist4" }
local function GateOn(name)
    if name == "assist"     then return GATE_ASSIST     end
    if name == "suppress"   then return GATE_SUPPRESS   end
    if name == "vehicle"    then return GATE_VEHICLE    end
    if name == "cinematic"  then return GATE_CINEMATIC  end
    if name == "visibility" then return GATE_VISIBILITY end
    if name == "assist4"    then return GATE_ASSIST4    end
    return false
end
BF.GateOn = GateOn
local function SetGate(name, on)
    on = on and true or false
    if     name == "assist"     then GATE_ASSIST     = on
    elseif name == "suppress"   then GATE_SUPPRESS   = on
    elseif name == "vehicle"    then GATE_VEHICLE    = on
    elseif name == "cinematic"  then GATE_CINEMATIC  = on
    elseif name == "visibility" then GATE_VISIBILITY = on
    elseif name == "assist4"    then GATE_ASSIST4    = on
    end
end
-- The assist predicate the suppression test shares (2-arg legacy or 4-arg
-- 69465 form).
function BF.PlayerCanAssistUnit(unit)
    if not UnitCanAssist then return true end
    if GATE_ASSIST4 then
        return UnitCanAssist("player", unit, true, true) and true or false
    end
    return UnitCanAssist("player", unit) and true or false
end

local function IsUnitAuraSuppressed(unit)
    if not unit then return false end
    if not GATE_SUPPRESS then return false end
    local v = auraSuppressed[unit]
    if v == nil then
        v = ComputeAuraSuppressed(unit)
        auraSuppressed[unit] = v
    end
    return v
end

-- Public read, for the feature indicators' own `shown` terms.
--
-- WHAT HIDES A SUPPRESSED UNIT: SetShown(false) + the alpha union below.
-- Both are plain frame ops, both work in combat, and together they are the
-- COMPLETE mechanism. Nothing else is needed and nothing else is wanted.
--
-- WHAT MUST NEVER BE USED FOR IT: SetEnabled(false) -- "parking". Suppression
-- is a state that lasts seconds and reverts, so the park arms explicitly
-- refuse it (see "NEVER PARK A TRANSIENT STATE" in SyncAuraGridContainer,
-- and its twin in SlotContainerShown). If you are here because you want to
-- reclaim the engine evaluation a suppressed unit still costs: don't. It is
-- one unit for a few seconds, and the disable/enable/UpdateAllAuras cycle on
-- the two edges costs more than it saves, on the frame least able to afford
-- it. Owner ruling, 2026-08-20.
function BF:IsUnitAuraSuppressed(unit)
    return IsUnitAuraSuppressed(unit)
end

-- Re-resolve one unit. Returns true only when the answer actually MOVED;
-- callers use that edge to re-run the aura indicators, which is what parks
-- (and later resumes) the containers.
function BF:RefreshUnitAuraSuppression(unit)
    if not unit then return false end
    local was = auraSuppressed[unit]
    local now = ComputeAuraSuppressed(unit)
    auraSuppressed[unit] = now
    return was ~= now
end

-- Unit tokens are recycled -- "raid5" is a different player after a join --
-- so the cached answer dies with the assignment and is re-resolved on the
-- next read. Same reason, same messages, as the Phased status's
-- ResetPhaseUnit (BFStatus.lua).
function BF:ClearUnitAuraSuppression(unit)
    if unit then
        auraSuppressed[unit] = nil
    else
        wipe(auraSuppressed)
    end
end

local function ContainerVisAlpha(c, unit, shown)
    -- v99: each term switchable via `/bf gates` (see the gate block above).
    return (shown and unit
        and (not GATE_VEHICLE or not c._bf_vehicleTainted)
        and (not GATE_CINEMATIC or not BF._cinematicGateActive)
        and not IsUnitAuraSuppressed(unit)
        and (not GATE_VISIBILITY or (UnitIsVisible(unit) and not IsUnitOffline(unit)))
    ) and 1 or 0
end

-- Apply it, change-guarded. Returns the alpha now in force.
local function ApplyContainerVisAlpha(c, unit, shown)
    local a = ContainerVisAlpha(c, unit, shown)
    if c._bf_visAlpha ~= a then
        c._bf_visAlpha = a
        c:SetAlpha(a)
    end
    return a
end
BF._ApplyContainerVisAlpha = ApplyContainerVisAlpha

-- v99c NOTE (2026-08-27): hooking the container's own OnUpdate (the exact
-- engine repaint moment -- ManagedAuraContainerPrivateMixin:OnDirtyChanged
-- arms RunWhenVisibleOnce) was tried and is REFUSED: CustomAuraContainerTemplate
-- is a forbidden-partition frame and HookScript throws. The gate therefore
-- stays event-driven, with UNIT_IN_RANGE_UPDATE (Range.lua) added as an
-- extra edge and the Phased ticker sampling UnitIsVisible at 0.25 s.

-- Cinematic-in-vehicle: taint every live container (see gate comment above).
-- pcall'd: in-encounter cinematics can fire in combat.
function BF:MarkAllContainersVehicleTainted()
    if not GATE_VEHICLE then return end  -- v99
    local frames = self.activatedFrames
    if not frames then return end
    for frame in pairs(frames) do
        local t = frame._bf_auraContainers
        if t then
            for _, c in pairs(t) do
                if not c._bf_vehicleTainted then
                    c._bf_vehicleTainted = true
                    c._bf_visAlpha = 0
                    pcall(c.SetAlpha, c, 0)
                    BF._bf_anyVehicleTainted = true
                end
            end
        end
    end
end

-- ============================================================
-- Shared constants
-- ============================================================

-- Dispel-type color map (string-keyed, per the 12.1 customDispelColorMap
-- contract). Sourced from Blizzard's DebuffTypeColor with fallbacks.
local DISPEL_COLOR_MAP
do
    local dtc = _G.DebuffTypeColor or {}
    local function col(key, r, g, b)
        local c = dtc[key]
        if c then return { r = c.r, g = c.g, b = c.b } end
        return { r = r, g = g, b = b }
    end
    DISPEL_COLOR_MAP = {
        Magic   = col("Magic",   0.2, 0.6, 1.0),
        Curse   = col("Curse",   0.6, 0.0, 1.0),
        Disease = col("Disease", 0.6, 0.4, 0.0),
        Poison  = col("Poison",  0.0, 0.6, 0.0),
        Bleed   = col("Bleed",   0.8, 0.0, 0.0),
        None    = { r = 0, g = 0, b = 0 },  -- keep the flat black border
    }
end

local FONT_ROBOTO = "Interface\\AddOns\\BuzzardFrames\\Media\\Fonts\\RobotoCondensed-Bold.ttf"
-- Square-glyph font for the "Square (Color by Duration)" icon type: EVERY
-- glyph (printable ASCII + U+2588 + .notdef) is an identical filled square
-- with zero advance, centered on the pen — any string the engine writes
-- renders as exactly ONE em-sized square. Duration text becomes the square
-- icon; the textColor curve becomes the threshold coloring (engine-side,
-- zero combat Lua). PTR-PASSED 2026-08-13 (BuzzardSquareSpike).
local FONT_SQUARE = "Interface\\AddOns\\BuzzardFrames\\Media\\Fonts\\SquareGlyph.ttf"
-- Rounded variant for the rounded Border Styles: same glyph, corners
-- rounded IN THE FONT OUTLINE (FontStrings cannot be masked, so the
-- rounded fill must come from the glyph itself). Corner radius is
-- 137/1000 em == 35/256 — measured by circle-fitting IconMask.tga's
-- contour — and both stretch proportionally, so the glyph nests inside
-- the ring art at EVERY size (corner profiles verified identical
-- row-for-row at render size). One font serves Rounded and Rounded
-- (Thick): they share the mask contour, only the ring art differs.
local FONT_SQUARE_ROUND = "Interface\\AddOns\\BuzzardFrames\\Media\\Fonts\\SquareGlyphRound.ttf"
-- Base point size the square font is bound at; the FontString is SetScale'd
-- to spec.size/this so the square tracks the button size (mirrors the
-- autoScale size/12 convention used for real duration text).
local SQUARE_FONT_BASE = 12
-- v94: exported for the Buff List PREVIEW (Auras/DummyAuras.lua). The preview
-- reproduces the durationSquare render rather than approximating it -- same
-- two fonts, same base size, same scale rule -- because a threshold color
-- curve binds to a FontString, so a tinted texture could never carry one. One
-- definition, so the preview cannot drift from the live glyph.
BF.SQUARE_GLYPH_FONT       = FONT_SQUARE
BF.SQUARE_GLYPH_FONT_ROUND = FONT_SQUARE_ROUND
BF.SQUARE_GLYPH_FONT_BASE  = SQUARE_FONT_BASE
-- v93: match the ICON's rasterization rule for anything that overlays the
-- icon rect. Textures snap to the pixel grid by default; _bf_icon explicitly
-- does NOT (see the note at its creation), and FontStrings cannot snap at
-- all -- so a snapped overlay of an unsnapped rect rasterizes up to a pixel
-- away from the thing it covers. Owner-reported symptom on a Square (Color
-- by Duration) icon once the flash was anchored to the icon rect: the flash
-- showed as a colored line along the TOP edge and the glyph hung past it as
-- a line along the BOTTOM -- one pixel of offset, split across both edges.
local function UnsnapIconOverlay(tex)
    if tex and tex.SetSnapToPixelGrid then
        tex:SetSnapToPixelGrid(false)
        tex:SetTexelSnappingBias(0)
    end
end


-- Presence glow (v34): the BigDef/Important "Show Glow" toggles
-- re-expressed for containers. The old conditional triggers are
-- unobservable under 12.1 secrecy, but a permanently-started LCG
-- ButtonGlow parented to the button glows exactly while the engine
-- displays an aura on it (children follow button visibility).
-- (LCG itself is no longer used on the container path — see the static
-- glow note below; the legacy/preview pipelines still use it.)
-- Presence glows (BigDef/Important/CC Show Glow + v47 per-spell Icon
-- Effects glows). spec fields: showGlow, glowType ("button" default /
-- "pixel" / "autocast" / "proc"), glowColor (array {r,g,b,a} or nil).
-- The glow runs the whole time the button is shown — the legacy
-- threshold trigger is not portable (remaining time is secret).
-- STATIC presence glow. The pooled buttons and their DESCENDANTS sit in
-- the Forbidden Partition where SetScript is denied — every LCG glow
-- style is OnUpdate-animated, so none of them can run there (the
-- pcalls swallowed the denials; the API reference is explicit: "NOT
-- available on buttons: glows, animations"). Texture DRAWING works
-- fine, so the presence glow is a static action-button glow ring
-- (LCG's own IconAlert ring asset), created at init and tinted by the
-- configured color. All glow styles render this same ring.
-- size comes from the SPEC (never button:GetWidth() — button
-- dimensions are SECRET post-PEW; comparing threw and silently aborted
-- every restyle walk. That was the "all live settings dead" bug.)
local function ApplyGlowGeometry(button, size, padRatio)
    local w = size or 24
    local tex = button._bf_glowTex
    if tex then
        -- v61: pad 0.2 = exact LCG ButtonGlow steady-state parity (the
        -- glow frame is button×1.4 and the outerGlow fills it — LCG
        -- ButtonGlow_Start / AnimIn_OnFinished). The previous 0.22
        -- (1.44×) rendered the ring visibly larger than the legacy glow.
        -- padRatio (owner): per-feature override -- the Big Defensive glow
        -- passes spec.glowPad (0.26, BigDefIcons.lua) because at its icon
        -- sizes the 0.2 ring read as inset from the border. Default stays 0.2
        -- for everything else (per-spell Icon Effects glow keeps LCG parity).
        -- v93b: NO snapping here, and the default ratio raised 0.2 -> 0.26.
        --
        -- A v93 revision briefly ran this through BF:PixelSnap. That was
        -- wrong: PixelSnap TRUNCATES toward zero (it exists so a 1px border
        -- can never render as 2px), so it could only ever shrink the ring --
        -- up to a full device pixel per side, straight toward the "ring sits
        -- inside the border" symptom it was meant to fix. The pad is soft
        -- ring art, not a hard edge that has to land on a pixel boundary, so
        -- it wants no snapping at all.
        --
        -- Ratio history (all owner-driven, ring reading too small / inset
        -- from the border rather than overlaying it): 0.2 (LCG ButtonGlow
        -- parity) -> 0.26 -> 0.34. The LCG parity the 0.2 encoded is
        -- deliberately abandoned; the note above is kept for provenance.
        local pad = w * (padRatio or BF.AURA_GLOW_PAD)
        tex:ClearAllPoints()
        tex:SetPoint("TOPLEFT", button, "TOPLEFT", -pad, pad)
        tex:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", pad, -pad)
    end
    -- Ants ring geometry (BF.AURA_ANTS_SCALE; LCG parity: button × 1.4 ×
    -- 0.85 ≈ 1.19, centered — the ants art is a border-ring pattern per frame).
    local ants = button._bf_antsTex
    if ants then
        local aw = w * BF.AURA_ANTS_SCALE
        ants:ClearAllPoints()
        ants:SetPoint("CENTER", button, "CENTER", 0, 0)
        ants:SetSize(aw, aw)
    end
end

-- v49 VISUAL ALERTS (Marching Ants / Flash, per the default raid
-- frames' buff alert styles). The C_UnitAuras registry entry alone does
-- NOT render on custom containers — Blizzard's frames draw the alerts
-- in SECURE frame code (secure code may script the partition; ours
-- can't). Replicated with ANIMATION GROUPS: declarative, engine-driven,
-- no scripts — created + configured at init, merely Play()ed later.
-- Ants = FlipBook over Blizzard's IconAlertAnts sheet (256×256, 48×48
-- frames, 22 frames — the same sheet LCG steps via OnUpdate); Flash =
-- looping alpha pulse on an additive overlay.
-- PTR-VERIFY (v49): AnimationGroup playback inside the forbidden
-- partition — if denied, alerts degrade to static (ants sheet frame 1 /
-- no flash), pcall-guarded.
-- v84 (Stage 5 §9.9): the per-spell "Blizzard Visual Alert" numeric list is
-- GONE, replaced by the Icon Effect model (None / Glow / Marching Ants /
-- Flash + Effect Color). The ANTS and FLASH art below is unchanged — what
-- changed is that its color now comes from one user-facing color picker
-- instead of five hardcoded variants per style, and that Glow joins it as a
-- third effect (driven through ApplyGlow, which already owns the ring).
--
-- Ported icon-effect machinery. Everything here is DECLARATIVE: engine-owned
-- aura buttons and their descendants live in the forbidden partition, where
-- SetScript is refused, so every OnUpdate-driven glow style (pixel / autocast /
-- proc) is unreachable by design — which is exactly why Glow Style offers only
-- Steady and Pulsing. Do not add options that cannot render.
local function ApplyIconEffectCore(button, spec)
    local kind = spec.iconEffect
    local c    = spec.iconEffectColor
    local cr = c and (c[1] or 1) or 1
    local cg = c and (c[2] or 1) or 1
    local cb = c and (c[3] or 1) or 1
    local ca = c and (c[4] or 1) or 1
    local ants, flash = button._bf_antsTex, button._bf_flashTex
    if kind == "ants" then
        -- ALPHA VIA SetAlpha, NOT the vertex color's 4th arg (owner-reported:
        -- the picker's alpha did nothing on the ring OR the ants, while
        -- Pulsing -- which drives OBJECT alpha through its animation -- always
        -- worked). Vertex-color alpha does not read on these overlay ring
        -- assets; object alpha does. Tint with three args, strength with
        -- SetAlpha. Same treatment in ApplyGlowCore below and in both preview
        -- painters (DummyAuras ApplyDummyGlow, PreviewIconEffects
        -- ApplyPreviewFx) -- all four must agree.
        ants:SetVertexColor(cr, cg, cb)
        ants:SetAlpha(ca)
        ants:Show()
        local ag = button._bf_antsAG
        if ag and not ag:IsPlaying() then ag:Play() end
    else
        ants:Hide()
        -- v53 PERF: the groups are not started at button init (see
        -- InitAuraButton) — a button whose spell has no ants effect never runs
        -- one, and one whose effect was turned off stops here. The engine steps
        -- EVERY playing animation group once per rendered frame, so a
        -- permanently-playing group on every pooled button is a per-frame cost
        -- proportional to the pool size.
        local ag = button._bf_antsAG
        if ag and ag:IsPlaying() then ag:Stop() end
    end
    if kind == "flash" then
        -- v93: anchor the flash to the rect the visible art actually occupies.
        -- It is created SetAllPoints(button) -- the OUTER rect, border band
        -- included -- but a Square (Color by Duration) icon's glyph is centered
        -- on _bf_icon, which ApplyBorderInsets insets by
        -- PixelsToUI(borderThickness). On a bordered square the flash was
        -- therefore a rectangle one border-width larger on every side than the
        -- square it flashes (owner-reported).
        --
        -- Change-guarded on a stored rect id so a repeat restyle walk with an
        -- unchanged border config does no anchor work at all, and it lives
        -- inside this branch so buttons with no flash effect never pay for it.
        -- NOTE: deliberately narrow -- only durationSquare specs move. Regular
        -- icons keep flashing the full button rect exactly as they always have.
        -- v93b: for a Square (Color by Duration) the target is the GLYPH's own
        -- FontString, not the icon rect. Anchoring to the icon left the flash
        -- rendering 1px high (owner-reported: a colored line along the top
        -- edge and the red glyph hanging past it at the bottom) -- the icon
        -- rect and the scaled FontString do not land on the same pixel. The
        -- font itself is exact (ink box 0..1000 of a 1000 em, lsb 0, ascent
        -- 1000 / descent 0), so the offset is in the FontString's placement,
        -- and anchoring to it cancels that by construction.
        -- v93c: plus a one-device-pixel LEFT and DOWN correction on the glyph
        -- rect (owner-measured). The residual is the glyph INK's position
        -- inside its own FontString rect: the font rasterizer places it and
        -- there is no API to read where the ink landed, nor can a FontString
        -- be pixel-snapped -- so this is a measured correction, not something
        -- derivable. Textures take exact coordinates; glyph ink does not.
        -- Applied via explicit corner points rather than SetAllPoints so the
        -- offset rides in the target's own space.
        local wantRect = (spec.durationSquare and button._bf_duration) and "glyph"
            or "button"
        if button._bf_flashRect ~= wantRect then
            local target = (wantRect == "glyph") and button._bf_duration or button
            if pcall(function()
                flash:ClearAllPoints()
                if wantRect == "glyph" then
                    local px = BF:PixelsToUI(1)
                    flash:SetPoint("TOPLEFT",     target, "TOPLEFT",     -px, -px)
                    flash:SetPoint("BOTTOMRIGHT", target, "BOTTOMRIGHT", -px, -px)
                else
                    flash:SetAllPoints(target)
                end
            end) then
                button._bf_flashRect = wantRect
            end
        end
        -- v93c: BLEND on a Square (Color by Duration), ADD everywhere else.
        -- ADD renders `underlying + flash x alpha`, which is right over dark
        -- icon ART but wrong over the square: the glyph is already a
        -- saturated duration-curve color, so adding a bright tint clips the
        -- channels toward white and the configured Effect Color barely reads
        -- (owner-reported: "the color I set isn't actually working"). BLEND
        -- shows the chosen color at the chosen alpha. Change-guarded like
        -- the rect above -- SetBlendMode is a plain property setter, but
        -- there is no reason to re-stamp it on every walk.
        local wantBlend = spec.durationSquare and "BLEND" or "ADD"
        if button._bf_flashBlend ~= wantBlend then
            if pcall(flash.SetBlendMode, flash, wantBlend) then
                button._bf_flashBlend = wantBlend
            end
        end
        flash:SetVertexColor(cr, cg, cb)
        -- The color picker's ALPHA is the pulse PEAK: re-stamped on the two
        -- animations rather than rebuilding the group (plain property setters,
        -- runtime-legal; creating animations is init-window-only).
        local fIn, fOut = button._bf_flashIn, button._bf_flashOut
        if fIn then fIn:SetToAlpha(ca) end
        if fOut then fOut:SetFromAlpha(ca) end
        flash:Show()
        local ag = button._bf_flashAG
        if ag and not ag:IsPlaying() then ag:Play() end
    else
        flash:Hide()
        -- Stop() restores the baked alpha (0), matching the hidden state.
        local ag = button._bf_flashAG
        if ag and ag:IsPlaying() then ag:Stop() end
    end

    -- Desaturate: a plain property setter on the BF-owned icon texture. The
    -- texture is engine-BOUND (SetIcon) but still ours, so property setters
    -- work at runtime.
    local icon = button._bf_icon
    if icon then icon:SetDesaturated(spec.iconDesaturate and true or false) end

    -- Recolor: a tinted overlay over the icon art (baked at init, hidden until
    -- configured).
    local rc = button._bf_recolorTex
    if rc then
        local rcc = spec.iconRecolorColor
        if spec.iconRecolor then
            rc:SetVertexColor(rcc and (rcc.r or 1) or 1,
                rcc and (rcc.g or 1) or 1,
                rcc and (rcc.b or 1) or 1,
                rcc and (rcc.a or 0.5) or 0.5)
            rc:Show()
        else
            rc:Hide()
        end
    end

    -- Pandemic: the ENGINE computes the refresh window against the secret
    -- remaining duration and renders the region only inside it. The region is
    -- bound ONCE at init (a binding — init-window-only) and gated here purely
    -- by ALPHA, never Show/Hide: AddPandemicRegion stamps the region's Shown
    -- aspect, so the engine owns visibility and a Hide would fight it. That
    -- also means no Clear/Add pair ever runs at runtime, which matters because
    -- ClearPandemicRegions drops EVERY region on the button.
    local pt = button._bf_pandemicTex
    if pt then
        local pc = spec.pandemicColor
        if spec.pandemic then
            pt:SetColorTexture(pc and (pc.r or 0.239216) or 0.239216,
                pc and (pc.g or 1) or 1,
                pc and (pc.b or 0.254902) or 0.254902,
                pc and (pc.a or 0.15) or 0.15)
            pt:SetAlpha(1)
        else
            pt:SetAlpha(0)
        end
    end
end
-- ============================================================
-- DIAGNOSTIC OUTPUT GATE
--
-- Every diagnostic in this file is one-shot and fires on a genuine engine
-- denial, so none of them can spam -- but a shipped build must print NOTHING
-- a user did not ask for, and several of these name internal state or point
-- at developer commands. They all route through here, and here is gated on
-- the same user-facing toggle the /bf debug commands use (Experimental
-- Options -> Show Debug Outputs in chat), so the default install is silent
-- and anyone diagnosing a real problem still gets them by flipping one
-- switch.
--
-- Resolved per call, never cached: this file loads before the DB, and the
-- toggle can be flipped mid-session.
-- ============================================================
-- Note the callers' one-shot flags latch whether or not the gate let the
-- message through, so turning the toggle ON mid-session will not retroactively
-- surface something that already happened -- /reload first. Deliberate: making
-- the latch conditional would re-test the gate on every denial for the life of
-- the session, on paths that run inside the restyle walls.
local function DevPrint(...)
    if not (BF.IsDebugOutputEnabled and BF:IsDebugOutputEnabled()) then return end
    print(...)
end
BF._AuraDevPrint = DevPrint

-- v53 PHASE 3 (report R6): guard kept -- this runs uncovered from
-- InitAuraButton (the engine's initializeFrame callback; no BF pcall wall wraps
-- it) and, unlike the restyle walls, it must NOT abort: a denied effect may not
-- cancel a walk's commit, or every other live setting on that container stays
-- baked. Surfaces the first error once, under the diagnostic gate above.
local function ApplyIconEffects(button, spec)
    local ants, flash = button._bf_antsTex, button._bf_flashTex
    if not (ants and flash) then return end
    local ok, err = pcall(ApplyIconEffectCore, button, spec)
    if not ok and not BF._vaErrPrinted then
        BF._vaErrPrinted = true
        DevPrint("|cffff0000BuzzardFrames IconEffect error:|r", tostring(err))
    end
end
-- v53 PHASE 3 (report R6): same treatment as ApplyIconEffects above --
-- guard kept (uncovered on the InitAuraButton path, and its result drives
-- button._bf_glowOn), closure allocation retired.
local function ApplyGlowCore(button, tex, spec)
    local c = spec.glowColor
    local ca = c and (c[4] or 1) or 1
    -- Tint on the vertex color, STRENGTH on object alpha -- see the note in
    -- ApplyIconEffectCore's ants branch. Passing ca as SetVertexColor's 4th
    -- arg rendered identically at every alpha (owner-reported), so the ring
    -- ignored the Glow Color picker's alpha entirely on the steady path while
    -- Pulsing, which animates object alpha, honored it.
    tex:SetVertexColor(
        c and (c[1] or 1) or 1,
        c and (c[2] or 1) or 1,
        c and (c[3] or 1) or 1)
    tex:SetAlpha(ca)
    -- v93 REVERTED (owner-reported: glows stopped rendering entirely): this
    -- briefly read button:GetWidth() to lay the ring from the button's ACTUAL
    -- size. On 12.1 an engine-owned aura button's dimensions are SECRET, so
    -- the `> 0` guard raised -- and ApplyGlowCore runs inside a pcall (~:612),
    -- so the error was swallowed, tex:Show() never ran, and no glow ever
    -- appeared. NEVER read button geometry here. The spec.size/gSize mismatch
    -- this was chasing is instead fixed at the source: spec.size is now
    -- PixelRound'd rather than floored to a whole UI unit
    -- (BuffsAndContainers ~:2128/:2131), so it lands on the same grid as the
    -- gSize the button is sized with.
    ApplyGlowGeometry(button, spec.size, spec.glowPad)
    tex:Show()
    -- v84 §9.9: Glow Style. "Steady" is the static ring (the only thing v47
    -- could render); "Pulsing" runs the looping alpha animation baked at init.
    -- Its floor and ceiling are re-scaled from the color picker's alpha here
    -- — plain property setters on the animation objects, so the picker tunes
    -- the pulse without rebuilding the group (creating animations is
    -- init-window-only). Every other glow style the old UI offered
    -- (pixel/autocast/proc) is OnUpdate-driven and therefore impossible on
    -- engine-owned buttons; there is deliberately no option for them.
    local ag = button._bf_glowAG
    if ag then
        if spec.glowPulse then
            local gi, go = button._bf_glowIn, button._bf_glowOut
            if gi then gi:SetFromAlpha(ca * 0.35); gi:SetToAlpha(ca) end
            if go then go:SetFromAlpha(ca); go:SetToAlpha(ca * 0.35) end
            if not ag:IsPlaying() then ag:Play() end
        elseif ag:IsPlaying() then
            -- Stop() restores the BAKED alpha (1), which would blow the steady
            -- ring back to full strength after a Pulsing -> Steady switch --
            -- now that object alpha carries the picker's alpha, re-stamp ca
            -- rather than 1.
            ag:Stop()
            tex:SetAlpha(ca)
        end
    end
end
local function ApplyGlow(button, spec)
    local tex = button._bf_glowTex
    if not tex then return end
    if spec.showGlow then
        if pcall(ApplyGlowCore, button, tex, spec) then
            button._bf_glowOn = true
        end
    elseif button._bf_glowOn then
        if pcall(function()
            local ag = button._bf_glowAG
            if ag and ag:IsPlaying() then ag:Stop() end
            tex:Hide()
        end) then
            button._bf_glowOn = nil
        end
    end
end

-- Duration text formatter. Without a textFormatter, SetDurationText's
-- default renders abbreviated units ("5s") — legacy BF showed the
-- Cooldown widget's native countdown numbers (AuraConfig.lua:
-- GetCountdownFontString), i.e. a bare integer under a minute, then
-- "2m"/"2h"/"2d". Replicated with a NumericRuleFormatter breakpoint
-- ruleset (C_StringUtil, 12.0.5+; evaluated engine-side — works with
-- secret durations, no per-tick Lua). Seconds band rounds UP (countdown
-- semantics: shows "1" until expiry, never "0").
-- PTR-VERIFY: rounding parity of the >=60s bands vs the legacy engine
-- countdown (user-visible only when duration text isn't hidden above 1m).
local DURATION_RULE_FORMATTER
local DURATION_RULE_FORMATTER_HIDE60
do
    local up      = Enum.NumericRuleFormatRounding and Enum.NumericRuleFormatRounding.Up or 1
    local nearest = Enum.NumericRuleFormatRounding and Enum.NumericRuleFormatRounding.Nearest or 0
    DURATION_RULE_FORMATTER = C_StringUtil.CreateNumericRuleFormatter()
    DURATION_RULE_FORMATTER:SetBreakpoints({
        { threshold = 0,     format = "%d",  step = 1, rounding = up },
        { threshold = 60,    format = "%dm", components = { { div = 60,    step = 1, rounding = nearest } } },
        { threshold = 3600,  format = "%dh", components = { { div = 3600,  step = 1, rounding = nearest } } },
        { threshold = 86400, format = "%dd", components = { { div = 86400, step = 1, rounding = nearest } } },
    })
    -- Hide-duration-above-1-minute variant: >=60s formats to an EMPTY
    -- string. PTR-CONFIRMED: the engine textColor curve binding does not
    -- honor the curve's alpha-0 point above 60s, so hiding must be
    -- expressed through the formatter instead.
    DURATION_RULE_FORMATTER_HIDE60 = C_StringUtil.CreateNumericRuleFormatter()
    DURATION_RULE_FORMATTER_HIDE60:SetBreakpoints({
        { threshold = 0,  format = "%d", step = 1, rounding = up },
        { threshold = 60, format = "" },
    })
end
-- showDuration-OFF variant: empty at EVERY duration. Same
-- engine behavior as the HIDE60 case — with a textColor curve bound the
-- text repaints regardless of FontString alpha, so ApplyDurationTextStyle's
-- SetAlpha(0) alone left the "Show Duration Text" toggle dead
-- (PTR-observed); the OFF state must go through the formatter too.
local DURATION_RULE_FORMATTER_HIDDEN
do
    DURATION_RULE_FORMATTER_HIDDEN = C_StringUtil.CreateNumericRuleFormatter()
    DURATION_RULE_FORMATTER_HIDDEN:SetBreakpoints({
        { threshold = 0, format = "" },
    })
end
-- Square (Color by Duration) variant: a CONSTANT one-character string at
-- EVERY duration. The character is irrelevant — every glyph in FONT_SQUARE
-- is the same square — but a constant string keeps the FontString from
-- re-measuring each tick. Constant non-empty formats are PTR-CONFIRMED
-- (2026-08-13, BuzzardSquareSpike), as is the textColor curve repainting
-- on an unchanging string.
local DURATION_RULE_FORMATTER_SQUARE
do
    DURATION_RULE_FORMATTER_SQUARE = C_StringUtil.CreateNumericRuleFormatter()
    DURATION_RULE_FORMATTER_SQUARE:SetBreakpoints({
        { threshold = 0, format = "#" },
    })
end

-- Shared exports for the dispel slot visuals (border/overlay/dot).
-- None = legacy red fallback used by the "all" modes.
BF.DispelVisualColorMap = {
    Magic   = DISPEL_COLOR_MAP.Magic,
    Curse   = DISPEL_COLOR_MAP.Curse,
    Disease = DISPEL_COLOR_MAP.Disease,
    Poison  = DISPEL_COLOR_MAP.Poison,
    Bleed   = DISPEL_COLOR_MAP.Bleed,
    None    = { r = 0.8, g = 0.0, b = 0.0 },
}

-- Legacy dispel visual mode → 12.1 container filter.
-- v74: the "dispellable" (Dispellable by Me) branch returns the SAME filter as
-- the debuff-container meDispellable preset, via its source of truth
-- BF:MeDispelFilterParts (DebuffIcons.lua).
-- v91 (owner ruling 2026-08-17): that resolver moved off the RAID token onto
-- the DISPEL-TYPE SET model, so this branch is now "HARMFUL|DISPELLABLE" plus
-- an includeDispelTypes map of the player's currently dispellable types for
-- EVERY class (the old warlock-only Magic special case dissolved into the
-- per-spec table). `ac` is the frame's aura cache and carries the two "By Me"
-- toggles; nil resolves them at their defaults. Callers that own a slot pass
-- the second return through SetAuraSlotCandidates as includeDispelTypes;
-- table-constructor callers truncate it harmlessly.
-- NOTE: `allDispellable` here is a DISPEL-VISUAL mode key (dispelIndicatorMode
-- and friends), unrelated to the retired container preset of the same name.
-- ── 2026-08-25 (owner request): the dispel VISUALS' own By-Me governors ──
-- BF:MyDispelTypes asks its `ac` exactly two questions -- debuffDispMeTalented
-- and debuffDispMeLongCd -- and those are the DEBUFF ICONS' answers, set on
-- the Debuff Preset/Filter subtab. The custom dispel visuals now answer them
-- separately (dispelVisualDispMeTalented / dispelVisualDispMeLongCd, on the
-- Dispel Indicators tab), so every visual-side call routes its aura cache
-- through this view first.
--
-- ONE reusable table, not a fresh one per call: MyDispelTypes and
-- MeDispelFilterParts read the two fields, build a cache key and return --
-- neither retains the table -- and EnsureDispelSlot / SyncDispelVisualSlots
-- are on the per-frame aura path, where a per-call allocation is exactly what
-- the rest of this file goes out of its way to avoid. Defaults match
-- MyDispelTypes' own (talented ON unless explicitly false, long-cd OFF unless
-- explicitly true), so a cache predating the keys resolves identically.
local _dvDispMeAC = {}
function BF.DispelVisualDispMeAC(ac)
    _dvDispMeAC.debuffDispMeTalented = not (ac and ac.dispelVisualDispMeTalented == false)
    _dvDispMeAC.debuffDispMeLongCd   = (ac and ac.dispelVisualDispMeLongCd) == true
    return _dvDispMeAC
end

function BF.DispelVisualFilterFor(mode, ac)
    if mode == "all" then
        return "HARMFUL"
    elseif mode == "allDispellable" then
        return "HARMFUL|DISPELLABLE"       -- 12.1 token: dispellable by anyone
    end
    if BF.MeDispelFilterParts then
        -- The visual-side governors, never the debuff-icon pair -- see
        -- BF.DispelVisualDispMeAC above.
        return BF:MeDispelFilterParts(BF.DispelVisualDispMeAC(ac))
    end
    return "HARMFUL|DISPELLABLE"
end

-- v34 two-axis growDirection → flow layout axis + growth directions.
-- "PRIMARY_SECONDARY": primary fills the line, secondary is the wrap
-- direction. Caches normalize legacy single-axis values before they
-- reach here (BF.NormalizeGrowDirection), but aliases are kept as a
-- belt-and-braces fallback for un-normalized callers (custom container
-- configs) — mapped to the pre-v34 hardcoded secondaries.
-- PTR-VERIFY: FlowDirection sign semantics (Left=-1, Right=1, Up=1, Down=-1).
local GROW_MAP = {
    RIGHT_DOWN = { axis = 0, h =  1, v = -1 },  -- fill right, wrap down
    RIGHT_UP   = { axis = 0, h =  1, v =  1 },  -- fill right, wrap up
    LEFT_DOWN  = { axis = 0, h = -1, v = -1 },  -- fill left,  wrap down
    LEFT_UP    = { axis = 0, h = -1, v =  1 },  -- fill left,  wrap up
    DOWN_RIGHT = { axis = 1, h =  1, v = -1 },  -- fill down, wrap right
    DOWN_LEFT  = { axis = 1, h = -1, v = -1 },  -- fill down, wrap left
    UP_RIGHT   = { axis = 1, h =  1, v =  1 },  -- fill up,   wrap right
    UP_LEFT    = { axis = 1, h = -1, v =  1 },  -- fill up,   wrap left
}
GROW_MAP.RIGHT = GROW_MAP.RIGHT_DOWN
GROW_MAP.LEFT  = GROW_MAP.LEFT_DOWN
GROW_MAP.DOWN  = GROW_MAP.DOWN_RIGHT
GROW_MAP.UP    = GROW_MAP.UP_RIGHT

-- Tooltip position mode → AuraButton tooltip anchor token.
-- "frame"/"default" have no button-relative expression (documented
-- divergence in the migration plan) — nearest ANCHOR_* used.
local TOOLTIP_ANCHOR_MAP = {
    icon    = "ANCHOR_BOTTOMRIGHT",
    iconTR  = "ANCHOR_CURSOR_RIGHT",
    frame   = "ANCHOR_BOTTOM",
    -- Token semantics (PTR-corrected): directional tokens are
    -- BUTTON-relative (classic GameTooltip owner anchoring); CURSOR_*
    -- follow the cursor. "default" (legacy stored value; the choice is
    -- removed from the 12.1 options) = Below Frame — the aura tooltip
    -- is a forbidden-partition frame with NO game-default-position
    -- expression (ANCHOR_NONE renders it nowhere, with or without
    -- offsets; it is unreachable for manual anchoring).
    default = "ANCHOR_BOTTOM",
}

-- ============================================================
-- Button styling (initializeFrame)
-- Style spec fields (resolved from the settings cache by each feature):
--   size, showDuration, durationFont, durationFontSize, durationBorder,
--   durationScale, fontColor {r,g,b,a}, durationCurve (LuaColorCurveObject),
--   disableSwipe, disableSpark, reverseSwipe,
--   showStacks (boolean), dispelBorder (boolean),
--   tooltipEnabled, tooltipInCombat, tooltipPos
-- ============================================================

-- ------------------------------------------------------------
-- Style helpers, shared by InitAuraButton (creation) and
-- BF:ApplyAuraGridButtonSpec (live restyle — V3-proven for native calls
-- on pooled buttons out of combat, same class as the SetSize live path).
-- ------------------------------------------------------------

-- Rounded border styles (v54): HET's PTR-proven icon pattern — the
-- STRETCHED (unsliced) 256px rounded-rect mask clips the engine-bound
-- icon, a stretched white ring is drawn 1px (2px for thick) outside the
-- button and tinted with the border color, and the SAME mask file is
-- the cooldown swipe texture so the swipe is the rounded shape
-- (the Blizzard Cooldown Manager trick).
-- Mask attach happens ONCE at init (AddMaskTexture in the init window);
-- rounded on/off is expressed as mask/ring Show-Hide + property setters
-- — the live-proven call class (oUF cutout-mask precedent for hidden
-- masks disabling masking).
local ROUND_RING_TEX = "Interface\\AddOns\\BuzzardFrames\\Media\\IconBorder"
local ROUND_RING_THICK_TEX = "Interface\\AddOns\\BuzzardFrames\\Media\\IconBorderThick"
local ROUND_ICON_MASK_TEX = "Interface\\AddOns\\BuzzardFrames\\Media\\IconMask"
-- v68: dedicated SWIPE asset. IconMask stayed the swipe texture until v68,
-- and its GEOMETRY is right (outer contour pixel-identical to the ring art,
-- swipe rect == ring rect) -- but its corner-arc alpha is the mask's own AA
-- ramp (partial alpha), and swipe darkening is maskAlpha x swipeAlpha. Under
-- mipmap minification the corner texels average well below 1, so the ring's
-- corner arc rendered only fractionally darkened while the straight band got
-- the full swipe -- user-visible as a few uncovered border pixels on every
-- rounded corner. IconSwipe is the same rounded-rect fill with the alpha
-- HARDENED to 255 across the full ring band and dilated ~2/256 px past the
-- outer contour (short falloff), so corner coverage survives filtering at any
-- icon size (owner-approved 2026-08-12; overreach is <= ~0.3 screen px).
-- IconMask itself is untouched -- it still clips the icon and must not grow.
local ROUND_SWIPE_TEX = "Interface\\AddOns\\BuzzardFrames\\Media\\IconSwipe"

-- spec.borderStyle: "blizzard" | "flat" | "rounded" | "rounded_thick".
-- Absent (older stored spec builders / per-spell solid specs): derived
-- from the legacy blizzardBorders flag — also the 12.0 fallback rule
-- (rounded renders flat on the legacy engine).
local function BorderStyleOf(spec)
    local s = spec.borderStyle
    if s == "rounded" or s == "rounded_thick" then return s end
    if s == "blizzard" or spec.blizzardBorders then return "blizzard" end
    return "flat"
end

local function IsRoundedStyle(s)
    return s == "rounded" or s == "rounded_thick"
end

-- Live border-MODE switch (flat ↔ Blizzard-style ↔ rounded). Runs FIRST
-- in the restyle walk. Textures can't be destroyed, so all sets coexist
-- with the inactive ones hidden; dispel bindings are re-bound to the
-- active border texture. The mode flag flips only after the branch
-- completes, so a pcall-aborted switch retries fully on the next walk.
-- Rounded is a flat-family mode (cropped ARTWORK icon, cd level +1);
-- ring/mask visibility + geometry are owned by ApplyBorderInsets, which
-- runs after this in both walks.
local function ApplyBorderMode(button, spec)
    local style = BorderStyleOf(spec)
    local cur = button._bf_borderStyleMode
        or (button._bf_blizzMode and "blizzard" or "flat")
    if cur == style then return end
    local icon, cd = button._bf_icon, button._bf_cd
    if style == "blizzard" then
        if button._bf_border then button._bf_border:Hide() end
        -- The dispel border set is flat-family only, and
        -- ApplyDispelBorderBinding early-returns in blizzMode — park it
        -- here on a live switch or the engine's last shown-state lingers.
        -- (The base ring is parked by ApplyBorderInsets' blizz branch;
        -- the base underlay by the _bf_border:Hide() above.)
        if button._bf_dispelEdges then
            for i = 1, 4 do button._bf_dispelEdges[i]:Hide() end
        end
        if button._bf_dispelRing then button._bf_dispelRing:Hide() end
        if icon then
            icon:SetTexCoord(0, 1, 0, 1)
            icon:SetDrawLayer("BACKGROUND", 1)  -- below the parent-level swipe
        end
        -- v88i: from the tracked seed, not a read -- see InitAuraButton.
        local bl = button._bf_btnLevel
        if cd and bl then
            cd:SetFrameLevel(bl)
            button._bf_cdLevel = bl
        end
        -- Keep the text holder (duration text, dispel-type corner icon, blizz
        -- border) ONE above the cooldown after re-leveling it, so those regions
        -- stay above the swipe. Set once at init when cd was at button level;
        -- cd moves here on a live style switch, so the holder must follow.
        if button._bf_textFrame and button._bf_cdLevel then
            button._bf_textFrame:SetFrameLevel(button._bf_cdLevel + 1)
            button._bf_tfLevel = button._bf_cdLevel + 1
        end
        if spec.dispelBorder then
            local b = button._bf_blizzBorderTex
            if not b then
                -- On the text holder, above the swipe (see InitAuraButton).
                b = BF.Texture((button._bf_textFrame or button), nil, "OVERLAY")
                b:SetAllPoints(button)
                button._bf_blizzBorderTex = b
            end
            b:Show()
            button:ClearDispelTypeTextures()
            button:AddDispelTypeTexture(b, {
                style = Enum.CustomAuraButtonDispelTypeTextureStyle
                    and Enum.CustomAuraButtonDispelTypeTextureStyle.Border or 0,
                showWhenHarmful = true,
                showWhenHelpful = false,
                showWithoutDispelType = true,
            })
        end
        button._bf_blizzMode = true
    else
        if button._bf_blizzBorderTex then
            button._bf_blizzBorderTex:Hide()
        end
        if not button._bf_border then
            local border = BF.Texture(button, nil, "BACKGROUND", nil, 0)
            border:SetAllPoints(button)
            border:SetTexture("Interface\\Buttons\\WHITE8x8")
            button._bf_border = border
        end
        -- Underlay only in flat mode; rounded hides it (the ring +
        -- masked icon replace it — the underlay would show through the
        -- masked-off corners). v71: dispel-border specs show it again —
        -- it is their STATIC base border (the engine-bound surface is
        -- the separate dispel set; see ApplyDispelBorderBinding).
        if IsRoundedStyle(style) then
            button._bf_border:Hide()
        else
            button._bf_border:Show()
        end
        if icon then
            icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
            icon:SetDrawLayer("ARTWORK", 0)
        end
        -- v88i: from the tracked seed, not a read -- see InitAuraButton.
        local bl = button._bf_btnLevel
        if cd and bl then
            cd:SetFrameLevel(bl + 1)
            button._bf_cdLevel = bl + 1
        end
        -- Text holder follows the cooldown up (see the blizzard branch): the
        -- dispel-type corner icon + duration text live here and must stay ABOVE
        -- the cooldown swipe (cd is now button+1; without this the holder — set
        -- to cd+1 at init when cd was button-level — would be EQUAL to cd and the
        -- swipe could cover the corner icon).
        if button._bf_textFrame and button._bf_cdLevel then
            button._bf_textFrame:SetFrameLevel(button._bf_cdLevel + 1)
            button._bf_tfLevel = button._bf_cdLevel + 1
        end
        if spec.dispelBorder then
            -- Release the Blizzard-border binding; ApplyDispelBorderBinding
            -- (later in the walk, now that the mode flag is flat-family)
            -- re-binds the separate dispel set.
            button:ClearDispelTypeTextures()
        end
        button._bf_blizzMode = nil
    end
    button._bf_borderStyleMode = style
    -- Geometry (insets vs full-bleed, ring/mask visibility) and colors
    -- are re-applied by ApplyBorderInsets / ApplyBorderStyle /
    -- ApplyDispelBorderBinding, which run after this in the restyle walk.
end

-- spec.borderColor: per-feature Border Color setting (default black).
-- No-ops in Blizzard-border mode (no flat border texture exists).
-- Tints BOTH the flat underlay and the rounded ring — only one is ever
-- shown, and tinting the hidden one keeps live style switches correct.
local function ApplyBorderStyle(button, spec)
    if button._bf_blizzMode then return end
    local bc = spec.borderColor
    local r = bc and bc.r or 0
    local g = bc and bc.g or 0
    local b = bc and bc.b or 0
    local a = bc and (bc.a or 0.8) or 0.8
    if button._bf_border then
        button._bf_border:SetVertexColor(r, g, b, a)
    end
    if button._bf_roundRing then
        button._bf_roundRing:SetVertexColor(r, g, b, a)
    end
end

-- spec.solidIcon (v43 per-spell customizations): render a plain color
-- texture in place of the aura icon ("Square" / "Bordered Square" icon
-- types). The icon texture is NOT engine-bound (SetIcon skipped/unbound)
-- so the engine never stomps the color with the aura's real texture.
-- Static color only — per-spell solid-color threshold curves are CUT
-- (no duration-driven texture color binding in the 12.1 API).
-- Live Icon↔Square switches unbind via ClearIcon() and rebind via
-- SetIcon(tex); PTR-VERIFY: re-callability post-PEW (pcall-guarded; on
-- denial the switch completes on reload).
local function ApplySolidIcon(button, spec)
    local icon = button._bf_icon
    if not icon then return end
    local si = spec.solidIcon
    if si then
        if not button._bf_solid then
            -- Unbind BEFORE painting, and bail if the button stays bound.
            -- Painting first left the engine owning the texture on a denied
            -- unbind: the engine kept repainting the real aura icon while
            -- our SetVertexColor persisted, rendering a color TINT over the
            -- spell texture instead of a flat square (PTR-observed on
            -- single-buff main groups, whose buttons are pool-created
            -- engine-bound). _bf_iconBound is stamped only by the two real
            -- bind sites (InitAuraButton, the revert branch below), so a
            -- born-solid button -- never bound -- passes even if its
            -- precautionary unbind is denied. On bail the button is
            -- left fully normal; the switch completes on reload, where
            -- InitAuraButton births it solid.
            --
            -- ClearIcon(), NOT SetIcon(nil). The 12.1
            -- CustomAuraButtonSharedMixin pairs every Set<Thing> binding
            -- setter with an explicit Clear<Thing>, and SetIcon is NOT
            -- nil-tolerant -- passing nil throws, the pcall swallows it,
            -- _bf_iconBound stays true and the function returns two lines
            -- below WITHOUT EVER PAINTING. That is the whole bug: the
            -- border restyle (which runs earlier, in
            -- RestyleButtonWithSolidIcon) landed while the solid fill and
            -- the Icon Color never did, so Square/Bordered Square kept
            -- showing the spell texture and color edits did nothing.
            -- Grid2 does the same thing the same way -- ClearIcon() then
            -- paint (modules/IndicatorIcons.lua:293, GridIndicatorAuras.lua:121).
            local unbind = button.ClearIcon
            if unbind and pcall(unbind, button) then
                button._bf_iconBound = nil
            end
            if button._bf_iconBound then return end
            button._bf_solid = true
        end
        icon:SetTexture("Interface\\Buttons\\WHITE8x8")
        icon:SetTexCoord(0, 1, 0, 1)
        icon:SetVertexColor(si.r or 0, si.g or 0.7, si.b or 1, si.a or 1)
        -- Hollow border (legacy backdrop parity: edge-only, no fill).
        -- The flat full-bleed underlay border sits UNDER the icon and
        -- shows through whenever the Icon Color has alpha < 1, so solid
        -- mode hides it and draws four edge textures instead. Square
        -- (borderThickness 0) draws no border at all.
        if button._bf_border then button._bf_border:Hide() end
        local edges = button._bf_solidEdges
        -- v69: rounded Border Styles on solid squares — the mask clips our
        -- WHITE8x8 fill and the ring IS the border (ApplyBorderMode /
        -- ApplyBorderInsets own them, they run earlier in the walk), so
        -- the flat edge textures must stand down or they double-border.
        if IsRoundedStyle(BorderStyleOf(spec)) then
            if edges then
                for i = 1, 4 do edges[i]:Hide() end
            end
        elseif (spec.borderThickness or 1) > 0 then
            if not edges then
                edges = {}
                for i = 1, 4 do
                    local t = BF.Texture(button, nil, "ARTWORK", nil, 1)
                    t:SetTexture("Interface\\Buttons\\WHITE8x8")
                    edges[i] = t
                end
                button._bf_solidEdges = edges
            end
            local px = BF:PixelsToUI(spec.borderThickness or 1)
            local top, bottom, left, right = edges[1], edges[2], edges[3], edges[4]
            top:ClearAllPoints()
            top:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
            top:SetPoint("TOPRIGHT", button, "TOPRIGHT", 0, 0)
            top:SetHeight(px)
            bottom:ClearAllPoints()
            bottom:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0)
            bottom:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, 0)
            bottom:SetHeight(px)
            left:ClearAllPoints()
            left:SetPoint("TOPLEFT", button, "TOPLEFT", 0, -px)
            left:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, px)
            left:SetWidth(px)
            right:ClearAllPoints()
            right:SetPoint("TOPRIGHT", button, "TOPRIGHT", 0, -px)
            right:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, px)
            right:SetWidth(px)
            local bc = spec.borderColor
            local r = bc and bc.r or 0
            local g = bc and bc.g or 0
            local b = bc and bc.b or 0
            local a = bc and (bc.a or 0.8) or 0.8
            for i = 1, 4 do
                edges[i]:SetVertexColor(r, g, b, a)
                edges[i]:Show()
            end
        elseif edges then
            for i = 1, 4 do edges[i]:Hide() end
        end
    elseif button._bf_solid then
        icon:SetVertexColor(1, 1, 1, 1)
        if pcall(button.SetIcon, button, icon) then
            button._bf_iconBound = true
        end
        button._bf_solid = nil
        -- Restore the normal flat underlay border; retire the edges.
        -- (ApplyBorderMode only re-shows the underlay on a MODE change,
        -- so an Icon-type revert within flat mode restores it here.)
        if button._bf_solidEdges then
            for i = 1, 4 do button._bf_solidEdges[i]:Hide() end
        end
        -- The flat underlay is a SQUARE full-bleed texture. It must only be
        -- restored when the border is actually flat: in Rounded styles the
        -- ring + masked icon replace it, and a re-shown square underlay pokes
        -- its corners out behind the rounded ring (ApplyBorderMode's mode
        -- guard early-returns while the mode is already rounded, so nothing
        -- re-hides it). Mirror the exact condition ApplyBorderMode hides it
        -- under: rounded style OR a dispel spec (hosted edges).
        if button._bf_border and not spec.blizzardBorders
            and not IsRoundedStyle(BorderStyleOf(spec)) then
            -- v71: dispel specs restore the underlay too — it is their
            -- static base border now (hosted edges are gone).
            button._bf_border:Show()
        end
    end
end

-- spec.borderThickness: inset the icon + cooldown by the configured border
-- width (pixel-perfect; 0 = borderless). Re-callable live — SetPoint on
-- our own sub-regions is the same V3 class as SetSize (the bound regions'
-- forbidden aspect is re-PARENTING, not re-anchoring). PTR-VERIFY.
local function ApplyBorderInsets(button, spec)
    local icon, cd = button._bf_icon, button._bf_cd
    if button._bf_blizzMode then
        -- Blizzard-style: uncropped full-size icon (mirrors the unit
        -- frames' oUF default CreateButton). The SQUARE swipe is inset
        -- proportionally (v49 fix): a full-size swipe both overhung the
        -- rounded border ring and showed square corners outside the
        -- rounded outline — no frame level fixes square geometry. A 10%
        -- inset keeps the swipe inside the atlas corner radius at any
        -- size (re-stamped by the live-size walk on resizes).
        if icon then icon:ClearAllPoints(); icon:SetAllPoints(button) end
        local s = spec.size or 24  -- button dims are SECRET — never read them
        if cd then
            -- 4%: just enough for the square corners to stay inside the
            -- rounded corner radius now that the ring hugs the edges
            -- (10% read as visibly undersized).
            -- DISPEL-RING buttons (debuffs) need a DEEPER inset: their
            -- border is the oversized dispel atlas ring (+12% pad below),
            -- whose corner curve cuts further inward than the buff icon
            -- art's radius — at 4% the square swipe corners poked
            -- outside the rounded outline (PTR-observed). 8%: eyeball
            -- starting point, owner-tunable.
            local inset = s * (button._bf_blizzBorderTex and 0.08 or 0.04)
            cd:ClearAllPoints()
            cd:SetPoint("TOPLEFT", button, "TOPLEFT", inset, -inset)
            cd:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -inset, inset)
        end
        -- Rounded dispel border ring (v49): the border atlases carry
        -- transparent padding around the ring art — anchored edge-to-edge
        -- the visible ring rendered INSIDE the button. Oversize the
        -- texture so the ring hugs the aura's edges (tunable overhang).
        local bb = button._bf_blizzBorderTex
        if bb then
            local pad = s * 0.12
            bb:ClearAllPoints()
            bb:SetPoint("TOPLEFT", button, "TOPLEFT", -pad, pad)
            bb:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", pad, -pad)
        end
        if button._bf_roundRing then button._bf_roundRing:Hide() end
        if button._bf_roundMask then button._bf_roundMask:Hide() end
        return
    end
    local style = BorderStyleOf(spec)
    if IsRoundedStyle(style) then
        -- Rounded: full-size cropped icon clipped by the mask; ring
        -- drawn OUTSIDE the button (the outer offset IS the visible
        -- side thickness — HET pattern); the cooldown takes the ring's
        -- rect and its swipe texture is the mask asset (set in
        -- ApplyCooldownStyle), so the swipe covers the border band in
        -- the ring's own shape and no square corners poke past it.
        -- v59 rethin: Rounded (Thick) := the OLD Rounded (band 4 design
        -- units, offset 1) — IconBorderThick.tga is a byte copy of the
        -- old IconBorder.tga; Rounded := new thinner art (band 2 design
        -- units, offset 0.5 — both halved, same step the frame borders
        -- took in v56).
        local o = style == "rounded_thick" and 1 or 0.5
        if icon then
            icon:ClearAllPoints()
            icon:SetAllPoints(button)
        end
        -- Ring FIRST, then the swipe anchored TO THE RING.
        --
        -- The swipe must cover the border band exactly and stop on its
        -- outer edge. Anchoring both to the button with the same numbers
        -- was not enough: the cooldown is a FRAME and the ring is a
        -- TEXTURE, and the two round their rects independently (`o` is a
        -- HALF unit for plain Rounded, so off-grid buttons land them on
        -- either side of a pixel boundary) — that was the intermittent
        -- 1px corner overshoot. SetAllPoints(ring) makes them the same
        -- rect by construction, so no rounding path can separate them.
        --
        -- The shapes then match too: IconBorder.tga / IconBorderThick.tga
        -- have a PIXEL-IDENTICAL outer contour to IconMask.tga (verified
        -- 256/256 rows, zero deviation — the mask is the solid fill of the
        -- same rounded rect the rings are drawn on), and that mask IS the
        -- swipe texture (ApplyCooldownStyle). Same rect + same contour =
        -- exact overlap, rounded corners included.
        local ring = button._bf_roundRing
        if ring then
            ring:SetTexture(style == "rounded_thick"
                and ROUND_RING_THICK_TEX or ROUND_RING_TEX)
            ring:ClearAllPoints()
            -- Raw `o`, NOT BF:PixelsToUI(o) — `o` is already in UI units.
            ring:SetPoint("TOPLEFT", button, "TOPLEFT", -o, o)
            ring:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", o, -o)
            ring:Show()
        end
        if cd then
            cd:ClearAllPoints()
            if ring then
                cd:SetAllPoints(ring)
            else
                cd:SetPoint("TOPLEFT", button, "TOPLEFT", -o, o)
                cd:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", o, -o)
            end
        end
        if button._bf_roundMask then button._bf_roundMask:Show() end
        return
    end
    if button._bf_roundRing then button._bf_roundRing:Hide() end
    if button._bf_roundMask then button._bf_roundMask:Hide() end
    local px = BF:PixelsToUI(spec.borderThickness or 1)
    if icon then
        icon:ClearAllPoints()
        icon:SetPoint("TOPLEFT", button, "TOPLEFT", px, -px)
        icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -px, px)
    end
    if cd then
        -- FULL-BLEED swipe: the flat border's OUTER edge is the button rect
        -- (_bf_border is SetAllPoints(button); _bf_solidEdges run inward
        -- from the button edges), and both border and swipe are square —
        -- so a button-sized swipe covers the band exactly with nothing
        -- beyond it. Same rule as the rounded branch, square geometry.
        -- Also matches Grid2 (IndicatorIcons.lua:250 SetAllPoints, icon
        -- inset by borderSize at :296-297) and avoids the v49 1px rounding
        -- slivers between swipe and icon on off-grid frames.
        cd:ClearAllPoints()
        cd:SetAllPoints(button)
    end
end

-- v71 SEPARATE DISPEL BORDER (replaces the v65 alpha-host + v70 two-set
-- designs). The BASE border is now fully STATIC — the ordinary underlay
-- (flat) or the vertex-colored ring (rounded), never engine-bound, so
-- the Border Color's RGBA applies as plain region color with no host
-- frame. The DISPEL border is a dedicated set (4 edges + a ring) bound
-- with showWithoutDispelType = false: the ENGINE shows it only while
-- the slot aura carries a dispel type (semantics proven by the debuff
-- overlay's "dispellable" mode) and renders it FULLY OPAQUE — the
-- engine's alpha stomp on bound textures (v63 PTR finding) now works
-- FOR us instead of needing a host to fight it. Typed debuffs: opaque
-- dispel color drawn over the static base. Typeless: static base only.
-- "None" is never rendered for the bound set, so the plain dispel map
-- suffices (DispelMapWithBase deleted with the old design).
--
-- CPU: everything here is bind-time (init/restyle walk); per-aura
-- updates are 100% engine-side, and the base border costs the engine
-- nothing at all. Re-callable on restyle (Clear + re-Add). PTR-VERIFY:
-- re-binding dispel textures post-PEW; engine hiding the
-- showWithoutDispelType=false set on typeless auras in the border
-- context.
--
-- v95 (2026-08-25): the two ways this function could leave a dispel border
-- INVISIBLE while the settings said it was on are both closed below —
--   (b) `spec.dispelBorderThickness or spec.borderThickness or 1` treated a
--       stored 0 as a value (0 is truthy in Lua), so "Border Thickness 0"
--       silently zero-sized the DISPEL edges too; and
--   (c) "Color Border by Dispel Type" OFF only skipped the WIDENING, so the
--       dispel color was still bound and still painted over the base.
-- Both are documented at their sites.
local function HideDispelSet(edges, ring)
    for i = 1, 4 do edges[i]:Hide() end
    if ring then ring:Hide() end
end
local function ApplyDispelBorderBinding(button, spec)
    if button._bf_blizzMode then return end  -- Blizzard border bound at init
    if not spec.dispelBorder then return end
    local edges = button._bf_dispelEdges
    if not edges then return end
    local opts = {
        style = Enum.CustomAuraButtonDispelTypeTextureStyle
            and Enum.CustomAuraButtonDispelTypeTextureStyle.PreserveAsset or 3,
        showWhenHarmful = true,
        showWhenHelpful = false,
        showWithoutDispelType = false,  -- typeless auras: static base only
        customDispelColorMap = DISPEL_COLOR_MAP,
    }
    local ring = button._bf_dispelRing
    button:ClearDispelTypeTextures()
    -- v95 (c) "COLOR BORDER BY DISPEL TYPE" = OFF NOW ACTUALLY TURNS IT OFF.
    -- This flag used to be read in exactly ONE place (the colorFull widening a
    -- few lines down), so switching it off left the dispel edges/ring BOUND and
    -- SHOWN — the engine kept painting a dispellable debuff's border in its
    -- dispel color, only no longer thick enough to cover the base border. The
    -- toggle therefore read as "make the dispel color thinner", not "off".
    -- The dispel set exists for no other purpose than that coloring, so OFF
    -- means: bind nothing (the ClearDispelTypeTextures above already released
    -- last pass's bindings) and park every region, leaving the STATIC base
    -- border — the configured Border Color — as the whole border.
    --
    -- Tested `== false`, never `not spec.colorBorderByDispel`: nil must keep
    -- today's behavior. The option's own default is `~= false` (nil == on,
    -- Options_Auras.lua debuffColorBorderByDispel), and both debuff spec
    -- builders resolve it to a real boolean, so nil here means "a spec that
    -- never had an opinion" — those keep binding, exactly as before.
    --
    -- Live: ButtonSpecSig already folds colorBorderByDispel (and
    -- dispelBorderThickness), so a toggle flip moves the container's/group's
    -- style signature and the restyle walk re-runs this function. No new
    -- change-guard wiring was needed.
    if spec.colorBorderByDispel == false then
        HideDispelSet(edges, ring)
        return
    end
    -- v71: "Color border by dispel type" (default on). Rather than bind the base
    -- border into the dispel set (which recolors typeless via
    -- DISPEL_COLOR_MAP.None = black, clobbering the configured Border Color),
    -- we keep the SEPARATE dispel edges/ring — they show ONLY on dispellable
    -- auras (showWithoutDispelType=false) and are HIDDEN on typeless, leaving the
    -- base border's configured color visible. To make the dispel color fully
    -- OVERRIDE the base for dispellable auras, the edges must be at least as
    -- thick as the base border, so nothing of the base peeks around them. That
    -- widening happens below (colorFull) where the edge thickness is stamped.
    local colorFull = spec.colorBorderByDispel and true or false
    if IsRoundedStyle(BorderStyleOf(spec)) then
        for i = 1, 4 do edges[i]:Hide() end
        if ring then
            -- Mirror the geometry/art ApplyBorderInsets stamped on the
            -- base ring earlier in this same walk (style-derived
            -- constants; anchors track the button rect, so resizes need
            -- no re-stamp here). Rounded thickness is art-driven
            -- (thin/thick assets), so Dispel Border Thickness is a
            -- flat-style setting only — matching the base thickness UI.
            local style = BorderStyleOf(spec)
            local o = style == "rounded_thick" and 1 or 0.5
            ring:SetTexture(style == "rounded_thick"
                and ROUND_RING_THICK_TEX or ROUND_RING_TEX)
            ring:ClearAllPoints()
            ring:SetPoint("TOPLEFT", button, "TOPLEFT", -o, o)
            ring:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", o, -o)
            ring:Show()
            button:AddDispelTypeTexture(ring, opts)
        end
    else
        if ring then ring:Hide() end
        -- Edge geometry stamped here: runs at init and on every restyle
        -- walk, so thickness changes apply live. Anchors reference the
        -- button's rect only (never its secret size). Independent
        -- thickness (falls back to the base border's when unset); a
        -- value larger than the base grows INWARD over the icon edge —
        -- the edges sit above the icon's ARTWORK layer by design.
        -- v71: when "Color border by dispel type" is on, the dispel edges must
        -- fully COVER the base border so the dispel color overrides it (no base
        -- color peeking around thinner dispel edges). Use at least the base
        -- border thickness in that case; otherwise the Dispel Border Width alone.
        -- v95 (b) NIL-AWARE FALLBACK, and an EXPLICIT 0 that really removes.
        -- This was `spec.dispelBorderThickness or spec.borderThickness or 1`,
        -- which is wrong in Lua for a numeric setting whose valid range starts
        -- at 0: only nil and false are falsy, so a stored 0 is a VALUE, not a
        -- miss. Two distinct bugs came out of that one expression, and they
        -- want OPPOSITE answers — which is why the two cases are now told
        -- apart instead of sharing a fallback chain:
        --
        --   dispelBorderThickness == nil (spec never carried one) and
        --   borderThickness == 0 ("Border Thickness 0 removes the border"):
        --       the old chain produced 0 and zero-sized the DISPEL edges too,
        --       so removing the BASE border silently removed the dispel
        --       coloring with it. The user asked for no base border, not for
        --       no dispel border. Floor the FALLBACK at 1px.
        --
        --   dispelBorderThickness == 0 (the user set THIS slider to 0):
        --       "0 removes the dispel border" — the Dispel Border Thickness
        --       tooltip says so in as many words (Options_Auras.lua), and the
        --       main Debuffs row passes ac.debuffDispelBorderThickness straight
        --       through, so that semantic MUST survive. It only half-survived:
        --       zero-size edges are invisible, but with colorFull on the
        --       math.max below widened them back up to the base thickness and
        --       the "removed" border reappeared in dispel colors. Now it
        --       returns with the set parked and nothing bound.
        --
        -- The 0-removes branch is deliberately INSIDE the flat branch. Rounded
        -- dispel thickness is art-driven (thin/thick ring assets) and the
        -- slider is hidden for non-flat styles, so a value left over from a
        -- flat session must not silently delete a rounded container's dispel
        -- ring.
        local dispelPx = spec.dispelBorderThickness
        if dispelPx == nil then
            dispelPx = spec.borderThickness
            if dispelPx == nil or dispelPx <= 0 then dispelPx = 1 end
        elseif dispelPx <= 0 then
            HideDispelSet(edges, ring)   -- ring already hidden above; explicit
            return
        end
        if colorFull then
            -- Clamped at 1: the base thickness can be 0 here (base border
            -- removed) and widening TO 0 would undo the floor above.
            dispelPx = math.max(dispelPx, math.max(spec.borderThickness or 1, 1))
        end
        local px = BF:PixelsToUI(dispelPx)
        local e1, e2, e3, e4 = edges[1], edges[2], edges[3], edges[4]
        e1:ClearAllPoints(); e1:SetPoint("TOPLEFT", button, "TOPLEFT"); e1:SetPoint("TOPRIGHT", button, "TOPRIGHT"); e1:SetHeight(px)
        e2:ClearAllPoints(); e2:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT"); e2:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT"); e2:SetHeight(px)
        e3:ClearAllPoints(); e3:SetPoint("TOPLEFT", button, "TOPLEFT", 0, -px); e3:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, px); e3:SetWidth(px)
        e4:ClearAllPoints(); e4:SetPoint("TOPRIGHT", button, "TOPRIGHT", 0, -px); e4:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, px); e4:SetWidth(px)
        for i = 1, 4 do
            edges[i]:Show()
            button:AddDispelTypeTexture(edges[i], opts)
        end
    end
end

-- Live show/hide/resize of the dispel-type corner icon (companion to the
-- init-time binding in InitAuraButton). Runs in the restyle walk so the
-- toggle and the size % update without a button rebuild. The texture is
-- created lazily here too, because a button built while the toggle was OFF
-- has no _bf_dispelTypeIcon yet. Binding is idempotent for the engine (we
-- re-bind on create). Zero per-frame cost — this only runs on a settings
-- change (sig-guarded restyle walk).
local function ApplyDispelTypeIcon(button, spec)
    local dti = button._bf_dispelTypeIcon
    if not spec.dispelTypeIcon then
        -- ApplyDispelBorderBinding (which runs BEFORE this in the restyle walk)
        -- already called ClearDispelTypeTextures, dropping every binding on the
        -- button INCLUDING this icon's, then re-added only the border. So when
        -- the icon is off we do nothing but hide the texture — its binding is
        -- already gone. (Non-dispel-border specs never Clear, but those never
        -- had the icon bound either, so hiding is enough.)
        if dti then dti:Hide() end
        return
    end
    if not dti then
        dti = BF.Texture((button._bf_textFrame or button), nil, "OVERLAY", nil, 2)
        button._bf_dispelTypeIcon = dti
    end
    -- Frame-level: the icon lives on _bf_textFrame, which must sit ABOVE the
    -- cooldown so the swipe doesn't cover it — but the duration text (also on
    -- _bf_textFrame, a FontString, which always draws above textures in the same
    -- layer) stays on top of the icon. cd is re-leveled by ApplyBorderMode only
    -- on a style change, so pin the holder above cd here whenever the icon is
    -- applied (guarded no-op when already correct).
    -- v88i BUGFIX. This used to be:
    --     local want = cd:GetFrameLevel() + 1
    --     if tf:GetFrameLevel() < want then tf:SetFrameLevel(want) end
    -- Both frames are descendants of an aura button, so both levels are SECRET
    -- once auras are secret -- and `<` on a secret THROWS rather than returning
    -- a wrong answer. Inside the pcall wall around the restyle walk that means
    -- a silent abort of everything after this line: exactly the failure mode
    -- the note at the top of this file records ("comparing threw and silently
    -- aborted every restyle walk -- the 'all live settings dead' bug").
    -- Buffs never reach here (gated on spec.dispelTypeIcon above), which is why
    -- it stayed hidden; the debuff path does.
    --
    -- Fixed the same way that note prescribes: compare BF's own tracked
    -- numbers, never a value read back off the button.
    local tf = button._bf_textFrame
    local cdl = button._bf_cdLevel
    if tf and cdl then
        local want = cdl + 1
        if (button._bf_tfLevel or 0) < want then
            tf:SetFrameLevel(want)
            button._bf_tfLevel = want
        end
    end
    local sc = (spec.dispelTypeIconScale or 40) / 100
    local sz = (spec.size or 24) * sc
    dti:SetSize(sz, sz)
    -- Overlap the icon's top-right corner rather than floating fully outside it:
    -- pull the badge inward (down-left) by ~35% of its own size, re-anchored per
    -- size change. A pure CENTER-on-TOPRIGHT put half the badge past the corner;
    -- this keeps it hugging the corner while overlaying the icon a bit.
    local nudge = sz * 0.35
    dti:ClearAllPoints()
    dti:SetPoint("CENTER", button, "TOPRIGHT", -nudge, -nudge)
    dti:Show()
    -- Always (re)bind: the ClearDispelTypeTextures in ApplyDispelBorderBinding
    -- earlier in this same walk wiped every binding on the button, so a bound
    -- icon needs re-adding each restyle. AddDispelTypeTexture on an unbound
    -- texture is the same call the border uses; harmless if the Clear didn't
    -- run (dispel-border specs always Clear, and only they reach here with the
    -- icon on).
    button:AddDispelTypeTexture(dti, {
        style = Enum.CustomAuraButtonDispelTypeTextureStyle
            and Enum.CustomAuraButtonDispelTypeTextureStyle.Icon or 1,
        showWhenHarmful = true,
        showWhenHelpful = false,
    })
end

local function ApplyCooldownStyle(button, spec)
    local cd = button._bf_cd
    if not cd then return end
    cd:SetDrawSwipe(not spec.disableSwipe)
    cd:SetDrawEdge(not spec.disableSpark)
    cd:SetReverse(spec.reverseSwipe or false)
    -- Rounded swipe: the dedicated swipe asset (v68 — was the mask asset;
    -- see ROUND_SWIPE_TEX for why the mask's soft corner alpha left the
    -- ring's corner arc under-darkened). Stretched by the engine — shape
    -- matches the icon mask at any size. Leaving rounded restores
    -- WHITE8X8, which under the default swipe color reads like the stock
    -- swipe; only ever touched on buttons that have been rounded, so
    -- never-rounded buttons keep the untouched template swipe.
    -- PTR-VERIFY: runtime SetSwipeTexture on bound cooldowns (same call
    -- flagged in HET), and WHITE8X8 ≈ template swipe appearance after a
    -- live rounded→flat/blizzard switch.
    if IsRoundedStyle(BorderStyleOf(spec)) then
        cd:SetSwipeTexture(ROUND_SWIPE_TEX)
        button._bf_swipeRounded = true
    elseif button._bf_swipeRounded then
        cd:SetSwipeTexture("Interface\\Buttons\\WHITE8x8")
        button._bf_swipeRounded = nil
    end
end

-- Square glyph scale for a durationSquare spec: fills the button, minus
-- the solid-edge border band when one is drawn (spec.borderThickness > 0
-- + a border color — same condition ApplySolidIcon draws edges under),
-- so the square sits INSIDE the border instead of underlapping it.
local function SquareGlyphScale(spec, size)
    local inset = 0
    -- Rounded styles never inset: the ring hangs OUTSIDE the button and
    -- the rounded glyph fills it edge-to-edge, exactly like the masked
    -- icon does for regular buttons. Only the flat edge-texture border
    -- eats into the button rect.
    if not IsRoundedStyle(BorderStyleOf(spec)) then
        local t = spec.borderThickness
        inset = (t and t > 0) and BF:PixelsToUI(t) or 0
    end
    -- v93: round the em box onto the device-pixel grid. The glyph is
    -- rasterized by the client at (box / pixelMult) physical pixels and
    -- FontStrings have no SetSnapToPixelGrid, so a fractional box rasterizes
    -- a fraction of a pixel larger or smaller than the rect around it -- the
    -- slack the Flash misalignment showed up in.
    local s = BF:PixelRound((size or 24) - 2 * inset)
    if s < 1 then s = 1 end
    return s / SQUARE_FONT_BASE
end

-- Font + scale + rect for the square glyph, in one place because they
-- are coupled: the border inset shrinks the glyph, the border style
-- picks the font, and SetPoint offsets are in the FontString's OWN
-- scaled space so every scale change must re-stamp the points. Called
-- from ApplyDurationTextStyle and both live-size walks.
--
-- Placement: CENTER-anchored to the (alpha-0) ICON TEXTURE region with
-- an auto-sized rect (the icon anchor follows ApplyBorderInsets for
-- free, so a flat-bordered square centers within its border band), plus
-- a constant 0.4 UI px rightward correction — the owner-measured mean
-- of a constant sub-pixel leftward bias (rounded font, six sizes
-- 10..50: 0.4/0.7/0/0.4/0.3/0.5). The residual ±0.35 px is pixel-grid
-- rasterization jitter: the button's own edges land at arbitrary
-- sub-pixel phases set by the engine's SECRET flow layout, which Lua
-- can neither read nor snap to, and FontStrings have no
-- SetSnapToPixelGrid. Do not chase it with formulas.
--
-- CAUTIONARY TALE (do not re-learn): a size-proportional "(size-1)/4"
-- bias was measured here across six calibration rounds and turned out
-- to be a STALE FONT CACHE — the client caches font FILES BY PATH for
-- the whole session (/reload does NOT re-read a changed TTF), and
-- SquareGlyph.ttf had been rewritten in place mid-calibration. A full
-- client restart showed the true bias is ~0. Never rewrite a shipped
-- font file in place; bump the filename.
-- (Direct-at-final-size rasterization was tested and made no visible
-- difference vs 12pt*SetScale — the client already rasterizes scaled
-- FontStrings at effective size — so the scale path stays: it has no
-- font-size-cap risk at large icon sizes.)
local function ApplySquareGlyphGeometry(button, spec, size)
    local dur = button._bf_duration
    if not dur then return end
    local s = SquareGlyphScale(spec, size)
    -- Rounded Border Styles swap the FONT: the roundness lives in the
    -- glyph outline (see FONT_SQUARE_ROUND).
    dur:SetFont(IsRoundedStyle(BorderStyleOf(spec))
        and FONT_SQUARE_ROUND or FONT_SQUARE, SQUARE_FONT_BASE, "")
    dur:SetScale(s)
    dur:SetJustifyH("CENTER")
    dur:SetJustifyV("MIDDLE")
    -- 0.4 px correction in UI px; SetPoint offsets resolve in the FS's
    -- scaled space, so divide by the scale.
    local cx = 0.4 / s
    local anchor = button._bf_icon or button
    local ok = pcall(function()
        dur:ClearAllPoints()
        dur:SetPoint("CENTER", anchor, "CENTER", cx, 0)
    end)
    if ok then button._bf_durSquareRect = true end
end

-- Font/scale/base color + the showDuration toggle (expressed as region
-- alpha: the FontString and its binding always exist — see InitAuraButton
-- — so the toggle never needs to create bindings post-PEW).
local function ApplyDurationTextStyle(button, spec)
    local dur = button._bf_duration
    if not dur then return end
    if spec.durationSquare then
        -- Square (Color by Duration): the duration text IS the icon.
        -- Font, justify, scale and anchoring live as a unit in
        -- ApplySquareGlyphGeometry (centered on the alpha-0 icon region
        -- + a 0.4 px sub-pixel correction — see the notes there;
        -- re-stamped every restyle because the border inset changes the
        -- scale). No font-flag border ever: WoW outlines are always
        -- black; colored borders come from the solid-edge textures
        -- (Border group).
        ApplySquareGlyphGeometry(button, spec, spec.size)
    else
        -- Revert the fixed rect if this button used to be a square
        -- (live icon-type switch): back to the creation-time auto-sized
        -- CENTER point.
        if button._bf_durSquareRect then
            local ok = pcall(function()
                dur:ClearAllPoints()
                dur:SetPoint("CENTER", button, "CENTER", 0, 0)
            end)
            if ok then button._bf_durSquareRect = nil end
        end
        dur:SetFont(spec.durationFont or FONT_ROBOTO,
            spec.durationFontSize or 11, spec.durationBorder or "OUTLINE")
        dur:SetScale(spec.durationScale or 1)
    end
    local fc = spec.fontColor
    if fc then
        dur:SetTextColor(fc.r or 1, fc.g or 1, fc.b or 1, fc.a or 1)
    else
        dur:SetTextColor(1, 1, 1, 1)
    end
    dur:SetAlpha(spec.showDuration and 1 or 0)
end

-- Stack count text. The container path previously baked Roboto 9
-- OUTLINE at BOTTOMRIGHT into the creation body below and never touched
-- the FontString again, so nothing in Aura Text > Stack Text reached a
-- 12.1 aura (BF:ApplyStackTextStyle in Auras.lua only walks the legacy
-- icon pools). The spec fields come from BF:ApplyStackTextSpec.
--
-- Like the duration text, the FontString is created UNCONDITIONALLY --
-- SetApplicationCount can only bind safely inside the configuration
-- window -- so the Show Stack Text toggle is expressed as alpha here and
-- stays live-flippable.
local function ApplyStackCountStyle(button, spec)
    local count = button._bf_count
    if not count then return end
    count:SetFont(spec.stackFont or FONT_ROBOTO, spec.stackSize or 9,
        spec.stackBorder or "OUTLINE")
    count:SetScale(spec.stackScale or 1)
    local anchor = spec.stackAnchor or "BOTTOMRIGHT"
    count:ClearAllPoints()
    count:SetPoint(anchor, button, anchor, spec.stackX or 4, spec.stackY or -3)
    -- Show Stack Text. The count has no textColor curve bound (which is
    -- what made SetAlpha(0) alone insufficient for the duration text --
    -- see DURATION_RULE_FORMATTER_HIDDEN), so alpha is the real kill and
    -- the engine never touches alpha. Hide() is belt-and-braces, but only
    -- ever un-hide a string THIS function hid: the string is bound to the
    -- engine's application count, which owns the shown state (bare
    -- binding = shown only above 1 application), and this runs on every
    -- restyle walk -- an unconditional Show() would fight it.
    local show = spec.showStacks ~= false
    count:SetAlpha(show and 1 or 0)
    if show then
        if count._bf_stackHidden then
            count._bf_stackHidden = nil
            count:Show()
        end
    else
        count._bf_stackHidden = true
        count:Hide()
    end
end

-- (Re)bind duration text: formatter + threshold color curve. Re-called
-- on restyle so curve changes (threshold settings, hide-above-1-min)
-- take effect live. PTR-VERIFY: rebinding an already-bound FontString
-- post-PEW (pcall-guarded in the restyle walk).
local function BindDurationText(button, spec)
    local dur = button._bf_duration
    if not dur then return end
    -- showDuration OFF: bind the always-empty formatter and no curve
    -- (see DURATION_RULE_FORMATTER_HIDDEN — alpha alone can't hide the
    -- text while a curve binding repaints it).
    if not spec.showDuration then
        button:SetDurationText(dur,
            { textFormatter = DURATION_RULE_FORMATTER_HIDDEN })
        return
    end
    -- Square icon type: constant one-glyph format at every duration
    -- (the square must never band into m/h/d or hide above 1 min — the
    -- derive path forces hideDurationAbove1Min off for it).
    local opts = { textFormatter = spec.durationSquare
        and DURATION_RULE_FORMATTER_SQUARE
        or (spec.hideDurationAbove1Min
            and DURATION_RULE_FORMATTER_HIDE60 or DURATION_RULE_FORMATTER) }
    if spec.durationCurve and Enum.DurationTextBindingProperty then
        opts.textColor = {
            curve = spec.durationCurve,
            property = Enum.DurationTextBindingProperty.RemainingDuration,
        }
    end
    button:SetDurationText(dur, opts)
end

-- "Below Frame" y-offset (v52): the engine anchors tooltips
-- BUTTON-relative only, but the vertical gap between a feature's icon
-- row and the unit frame's bottom edge is computable from our own
-- geometry (anchor corner + configured offset + frame height — all
-- readable; only the per-button cell is secret). ANCHOR_BOTTOM plus
-- this offset lands the tooltip below the FRAME, legacy-style.
-- Approximations: first-row plane (extra wrap rows shift it), and the
-- horizontal position follows the hovered icon (per-cell x is secret).
function BF.TooltipBelowFrameY(frame, anchor, offsetY, size)
    local h = (frame and frame.GetHeight and frame:GetHeight()) or 0
    -- 2026-09-11 (field report 2026-09-10, reload inside a keystone): at
    -- :Create the frame is not sized yet (frame:Layout sizes it later, and
    -- skips SetSize in combat), so GetHeight() is 0 and every TOP/side-anchored
    -- "Below Frame" offset was baked wrong. The correction is the tooltip-only
    -- walk, which is skipped while restricted -- i.e. for the whole key. Fall
    -- back to the size the frame WILL get: its header's frameHeight, exactly
    -- what BFLayout.lua's BuzzardFrame_GetInitialSize returns (that accessor is
    -- file-local there, so it is read directly). Preview frames / frames with
    -- no header carrying a height keep the old 0.
    if (not h or h <= 0) and frame and frame.GetParent then
        local header = frame:GetParent()
        local hh = header and header.frameHeight
        if type(hh) == "number" and hh > 0 then h = hh end
    end
    h = h or 0
    offsetY = offsetY or 0
    size = size or 0
    anchor = anchor or "BOTTOMRIGHT"
    -- Distance from the BUTTON's bottom edge to the frame's bottom edge.
    -- The tooltip anchor offset is button-relative, and the button hangs
    -- below its group anchor point: for BOTTOM anchors the button bottom
    -- sits at the anchor, for TOP anchors it hangs a full icon height
    -- below it, for side/center anchors half an icon height.
    local d
    if anchor:find("BOTTOM") then
        d = offsetY
    elseif anchor:find("TOP") then
        d = h + offsetY - size
    else
        d = h * 0.5 + offsetY - size * 0.5
    end
    if d < 0 then d = 0 end
    return -d
end

local function ApplyTooltipStyle(button, spec)
    if spec.tooltipEnabled then
        local pos = spec.tooltipPos or "default"
        local y = 0
        if (pos == "frame" or pos == "default") and spec.tooltipFrameY then
            y = spec.tooltipFrameY
        end
        button:SetTooltipAnchorPoint(
            TOOLTIP_ANCHOR_MAP[pos] or "ANCHOR_BOTTOMRIGHT", 0, y)
        button:SetHideTooltipInCombat(not spec.tooltipInCombat)
        button:EnableMouse(true)
        if button.SetMouseMotionEnabled then
            button:SetMouseMotionEnabled(true)
        end
    else
        -- No binding disables tooltips outright; suppress mouse input
        -- instead — motion input specifically drives the native tooltip
        -- hit-testing, so it is disabled alongside clicks.
        -- PTR-VERIFY: mouse-flag calls on a pooled AuraButton post-PEW.
        button:EnableMouse(false)
        if button.SetMouseMotionEnabled then
            button:SetMouseMotionEnabled(false)
        end
        -- Belt: even if some input path still reaches the button, at
        -- least never show the tooltip in combat.
        if button.SetHideTooltipInCombat then
            button:SetHideTooltipInCombat(true)
        end
    end
end

local function InitAuraButton(button, spec)
    -- v77 RE-ENTRY GUARD. This function is NOT idempotent: every region below
    -- is created unconditionally, so a second call on the same button leaks a
    -- whole second set of textures/frames, duplicates every engine binding
    -- (SetIcon, SetDurationCooldown, AddDispelTypeTexture, ...) and attaches a
    -- second MaskTexture that can NEVER be detached once auras are secret
    -- (RemoveMaskTexture is forbidden then -- Docs/AuraContainer_API_Reference
    -- _12.1.md). The v77 top-up path keys off _bf_icon for exactly this
    -- reason; this is the backstop so no later caller can corrupt a button by
    -- reaching it twice.
    if button._bf_icon then return end
    -- §L5.1 headersBuilt drill-down. This runs once per engine-pooled aura
    -- button, and the pool is created eagerly at AddAuraGroup -- so the count
    -- here is the decisive per-unit-frame widget number. nil unless the
    -- harness is collecting (see BF:LoadHBBegin).
    local hb  = BF._loadHB
    local hbT = hb and debugprofilestop() or nil
    local size = spec.size or 24
    button:SetSize(size, size)

    local initStyle = BorderStyleOf(spec)
    button._bf_borderStyleMode = initStyle

    if initStyle == "blizzard" then
        -- Blizzard-style borders (v34, default off): mirrors the unit
        -- frames' oUF default CreateButton — uncropped icon, and (for
        -- dispel-bordered features) the engine's rounded per-dispel-type
        -- border atlas drawn over it. Helpful features render borderless,
        -- matching Blizzard. Baked at creation and live-switchable by the
        -- restyle walk (ApplyBorderMode); Border Color/Thickness and
        -- the flat dispel recolor do not apply in this mode.
        button._bf_blizzMode = true
    else
        -- Flat border: solid square behind the inset icon (raid-frame
        -- look); color + thickness from the per-feature Border settings.
        -- Also created (hidden) for rounded styles — it's the live
        -- switch target back to flat.
        local border = BF.Texture(button, nil, "BACKGROUND", nil, 0)
        border:SetAllPoints(button)
        border:SetTexture("Interface\\Buttons\\WHITE8x8")
        -- v71: dispel specs DO show the underlay again — it is their
        -- static base border (the v65 hosted-edges design is gone; the
        -- engine-bound surface is now only the separate dispel set).
        if IsRoundedStyle(initStyle) then border:Hide() end
        button._bf_border = border
    end

    -- (Rounded ring is created AFTER the text holder below — it lives on
    -- that holder so it renders ABOVE the cooldown swipe; see the v57
    -- comment at its creation site.)

    -- Icon draw layer: ARTWORK in flat mode (above the BACKGROUND flat
    -- border; the child cooldown at level+1 draws the swipe above it).
    -- BACKGROUND(1) in Blizzard mode: with the cooldown at the BUTTON's
    -- level the swipe renders in a low tier, so the icon must sit below
    -- it — stack: icon → swipe → rounded border (OVERLAY). Mirrors
    -- Blizzard's own parent-level-cooldown aura buttons.
    local icon = BF.Texture(button, nil,
        spec.blizzardBorders and "BACKGROUND" or "ARTWORK",
        nil, spec.blizzardBorders and 1 or 0)
    if not spec.blizzardBorders then
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    end
    -- v49 pixel parity with the cooldown swipe: textures snap to the
    -- pixel grid by default, the swipe's radial shader does not — on
    -- buttons whose position lands off-grid (differs by frame ancestry,
    -- e.g. the aurasAbovePowerBar lift) the snapped icon rasterized 1px
    -- past the swipe on the misaligned axis ("swipe too short/narrow").
    -- Unsnapped, both rasterize the same rect identically.
    if icon.SetSnapToPixelGrid then
        icon:SetSnapToPixelGrid(false)
        icon:SetTexelSnappingBias(0)
    end
    button._bf_icon = icon
    if spec.solidIcon then
        -- Per-spell solid icon type: color texture, never engine-bound.
        ApplySolidIcon(button, spec)
    else
        button:SetIcon(icon)
        -- Bind marker consumed by ApplySolidIcon: a LIVE Icon->Square
        -- switch must not paint the solid color while the engine still
        -- owns the texture (see the unbind-first note there).
        button._bf_iconBound = true
    end

    -- Rounded icon mask: created + ATTACHED here in the init window
    -- (bindings/attachments are init-only-safe; HET proves masks on
    -- engine-bound icons render on 12.1). Hidden mask = masking off
    -- (oUF cutout precedent), so live style switches are pure Show/Hide.
    -- Stretched, never nine-sliced (radius must scale with the swipe
    -- texture, which always stretches — the rounded-icon rule).
    local rmask = BF.MaskTexture(button)
    if rmask.SetBlockingLoadsRequested then
        rmask:SetBlockingLoadsRequested(true)
    end
    rmask:SetTexture(ROUND_ICON_MASK_TEX,
        "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    rmask:SetAllPoints(button)
    rmask:Hide()
    icon:AddMaskTexture(rmask)
    button._bf_roundMask = rmask

    -- Cooldown (swipe/spark/reverse baked from settings; countdown numbers
    -- disabled — duration text is a dedicated bound FontString below).
    local cd = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
    cd:SetHideCountdownNumbers(true)
    -- v88i: TRACK THE LEVELS WE SET; NEVER READ THEM BACK.
    -- A frame level read off an aura button or any of its descendants is a
    -- SECRET once auras are secret, and comparing a secret THROWS -- the exact
    -- class recorded at the top of this file ("button dimensions are SECRET
    -- post-PEW; comparing threw and silently aborted every restyle walk"). The
    -- button's own level is the seed, so it is captured here, in the init
    -- window, where reading it is legal; every derived level is arithmetic on
    -- BF's own numbers from that point on.
    local btnLevel = button:GetFrameLevel()
    button._bf_btnLevel = btnLevel
    if spec.blizzardBorders then
        -- Blizzard technique (XML useParentLevel="true" on aura cooldowns):
        -- render the cooldown at the BUTTON's frame level, so the rounded
        -- border texture (OVERLAY layer) draws above the square swipe
        -- corners instead of the swipe covering the border art.
        cd:SetFrameLevel(btnLevel)
        button._bf_cdLevel = btnLevel
    else
        -- Engine default for a child frame is parent level + 1.
        button._bf_cdLevel = btnLevel + 1
    end
    button._bf_cd = cd
    ApplyCooldownStyle(button, spec)
    button:SetDurationCooldown(cd)

    -- Text holder above the cooldown swipe. Also hosts the Blizzard-style
    -- rounded border texture (v49 fix): the cooldown is a CHILD frame, and
    -- children render above the parent button's own textures even at the
    -- same frame level — a border on the button was covered by the square
    -- swipe corners on debuffs. On this holder (cd level + 1) the border
    -- draws above the swipe; FontStrings render above textures within the
    -- layer, so the duration text stays on top.
    local textFrame = CreateFrame("Frame", nil, button)
    textFrame:SetAllPoints(button)
    textFrame:SetFrameLevel(button._bf_cdLevel + 1)
    button._bf_tfLevel = button._bf_cdLevel + 1
    button._bf_textFrame = textFrame

    -- v71 SEPARATE DISPEL BORDER SET (dispel specs only — debuffs). The
    -- v65 alpha host and the v70 second host are GONE: the base border
    -- is the static underlay (flat) / vertex-colored ring (rounded),
    -- never engine-bound, so plain region RGBA carries the Border Color
    -- with no host frame; the dispel set below is the only engine-bound
    -- border surface, and the engine's alpha stomp on bound textures
    -- (v63 PTR finding) is exactly the always-opaque rendering we want.
    -- Textures live directly ON THE BUTTON at OVERLAY sublevel 1 —
    -- above the base ring (sublevel 0) and the icon's ARTWORK layer,
    -- below the cooldown swipe (child frame, draws above all button
    -- regions — the "swipe covers border" contract holds). Created
    -- unconditionally for dispel specs (post-config texture creation is
    -- unreliable — glow-region precedent). ApplyDispelBorderBinding
    -- owns binding, visibility and geometry.
    --
    -- v95 (2026-08-25): created for ANY dispel spec, Blizzard-style included.
    -- The gate used to be `and not spec.blizzardBorders`, which made the
    -- Blizzard style a ONE-WAY DOOR for an engine-pooled button: a debuff
    -- container whose buttons were first built while it inherited a
    -- Blizzard-Style border had no _bf_dispelEdges at all, and switching that
    -- container to Square/Rounded afterwards DID clear _bf_blizzMode
    -- (ApplyBorderMode's flat branch) but then died on
    -- ApplyDispelBorderBinding's `if not edges then return end` — a permanent,
    -- silent early-return. The container drew its base border and never a
    -- dispel color until a reload rebuilt the pool. Five textures are the
    -- cheap half of a button and creation is init-only-safe, so they are built
    -- unconditionally and simply stay parked while the button is in Blizzard
    -- mode.
    --
    -- NOTHING in the blizz path shows them, and nothing here has to: they are
    -- born Hidden, ApplyDispelBorderBinding still early-returns on
    -- _bf_blizzMode (the Blizzard border texture is bound at init and owns the
    -- dispel coloring in that mode), and ApplyBorderMode's blizzard branch
    -- re-parks them on a live switch INTO the mode. All of their geometry
    -- (anchors + thickness) is stamped by ApplyDispelBorderBinding, which runs
    -- AFTER ApplyBorderMode in the restyle walk — so the same walk that clears
    -- the flag on the way OUT of Blizzard mode also anchors, sizes, shows and
    -- binds them. No init-time sizing is needed, and adding any would be wrong
    -- anyway: it would have to read the button rect, which is SECRET post-PEW.
    if spec.dispelBorder then
        local dispelEdges = {}
        for i = 1, 4 do
            local t = BF.Texture(button, nil, "OVERLAY", nil, 1)
            t:SetTexture("Interface\\Buttons\\WHITE8x8")
            t:Hide()
            dispelEdges[i] = t
        end
        button._bf_dispelEdges = dispelEdges
        local dRing = BF.Texture(button, nil, "OVERLAY", nil, 1)
        dRing:SetTexture(ROUND_RING_TEX)
        dRing:Hide()
        button._bf_dispelRing = dRing
    end

    -- Rounded ring: ALWAYS created (post-config texture creation is
    -- unreliable — glow-region precedent), hidden until a rounded style
    -- shows it (ApplyBorderInsets owns visibility + anchors + art).
    -- v59: on the BUTTON itself, which puts it BELOW the cooldown — the
    -- cd is a CHILD frame and children always render above the parent's
    -- own regions, so the swipe darkens the border band as it passes.
    -- (v57 had it on the TEXT HOLDER, above the swipe, because back then
    -- the swipe overhung the button and the ring was hiding that
    -- overhang. The swipe now matches the ring rect exactly, so there is
    -- nothing to hide and the ring belongs underneath.)
    -- v71: the ring is STATIC for every spec (the alpha host is gone) —
    -- plain vertex color carries the Border Color RGBA, and dispel specs
    -- draw their bound dispel ring (OVERLAY sublevel 1) over it.
    local ring = BF.Texture(button, nil, "OVERLAY", nil, 0)
    ring:SetTexture(ROUND_RING_TEX)
    ring:Hide()
    button._bf_roundRing = ring
    ApplyBorderStyle(button, spec)  -- no-op in blizzard mode

    -- Inset icon + cooldown by the border thickness. (After the ring
    -- exists — the rounded branch anchors/shows it.)
    ApplyBorderInsets(button, spec)

    -- Duration text (native binding; threshold coloring via color curve —
    -- replaces the legacy 0.2s poll). Created UNCONDITIONALLY: bindings
    -- can only be established safely in the configuration window, so the
    -- showDuration toggle is expressed as FontString alpha (live-flippable
    -- in ApplyDurationTextStyle) rather than by skipping creation.
    local dur = textFrame:CreateFontString(nil, "OVERLAY")
    dur:SetPoint("CENTER", button, "CENTER", 0, 0)
    button._bf_duration = dur
    ApplyDurationTextStyle(button, spec)
    BindDurationText(button, spec)

    -- Stack count: bare binding = show only when applications > 1
    -- (matches the legacy >=2 rule; the legacy 99 cap is dropped for now).
    -- Created unconditionally; ApplyStackCountStyle owns font, size,
    -- border, scale, anchor and the Show Stack Text alpha gate.
    --
    -- ORDER MATTERS: style BEFORE SetApplicationCount, exactly like the
    -- duration text above styles before BindDurationText.
    -- SetApplicationCount writes the count into the FontString as part of
    -- establishing the binding, and SetText on a FontString that has no
    -- font yet raises "FontString:SetText(): Font not set" -- once per
    -- button in the engine's 10-button CreateFrameBatch.
    -- Created FROM A FONT OBJECT ("NumberFontNormal", the same thing the
    -- unit-frame path uses) rather than bare: that guarantees a valid font
    -- is present no matter what, so a bad custom font path in
    -- ApplyStackCountStyle degrades to a readable fallback instead of
    -- leaving the string fontless for SetApplicationCount to trip over.
    -- ApplyStackCountStyle overrides font/size/border immediately below.
    local count = textFrame:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    count:SetTextColor(1, 1, 1)
    button._bf_count = count
    ApplyStackCountStyle(button, spec)
    button:SetApplicationCount(count)

    -- Dispel-type coloring of the flat border (PreserveAsset recolors OUR
    -- texture; "None" base = the configured Border Color).
    ApplyDispelBorderBinding(button, spec)

    -- Blizzard-style dispel border: engine-set rounded atlas over the
    -- icon (pre-colored per dispel type; typeless debuffs get the default
    -- border). Same binding recipe as oUF's default CreateButton.
    if spec.blizzardBorders and spec.dispelBorder then
        local bborder = BF.Texture(textFrame, nil, "OVERLAY")
        -- Oversized so the ring hugs the aura edges (see ApplyBorderInsets,
        -- which owns re-stamps; this bakes the same anchors at init since
        -- the insets pass ran before this texture existed).
        local bpad = (spec.size or 24) * 0.12
        bborder:SetPoint("TOPLEFT", button, "TOPLEFT", -bpad, bpad)
        bborder:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", bpad, -bpad)
        button._bf_blizzBorderTex = bborder
        button:AddDispelTypeTexture(bborder, {
            style = Enum.CustomAuraButtonDispelTypeTextureStyle
                and Enum.CustomAuraButtonDispelTypeTextureStyle.Border or 0,
            showWhenHarmful = true,
            showWhenHelpful = false,
            showWithoutDispelType = true,
        })
    end

    -- Dispel-type CORNER ICON (v71): the engine's own dispel-type symbol drawn
    -- at the icon's top-right corner (Icon style), auto-hidden for auras with no
    -- dispel type — i.e. only ever visible on dispellable debuffs. Bound here
    -- through the SAME helper the restyle walk uses, so init and live toggling
    -- share one code path. Runs AFTER ApplyDispelBorderBinding above (whose
    -- ClearDispelTypeTextures would otherwise wipe this binding). Zero per-frame
    -- Lua — the engine fills the bound texture.
    ApplyDispelTypeIcon(button, spec)

    -- Tooltips (native AuraButtonTooltip).
    ApplyTooltipStyle(button, spec)

    -- Static presence-glow ring (see ApplyGlow): created unconditionally
    -- at init (post-config texture creation is not reliable), hidden
    -- until a glow spec enables it. Lives on its own child frame so it
    -- renders above the duration text tier.
    local glowFrame = CreateFrame("Frame", nil, button)
    glowFrame:SetAllPoints(button)
    glowFrame:SetFrameLevel(button._bf_tfLevel + 1)
    local glowTex = BF.Texture(glowFrame, nil, "OVERLAY")
    glowTex:SetTexture("Interface\\SpellActivationOverlay\\IconAlert")
    glowTex:SetTexCoord(0.00781250, 0.50781250, 0.27734375, 0.52734375)
    glowTex:Hide()
    button._bf_glowTex = glowTex
    -- v84 §9.9 Glow Style = Pulsing: a looping alpha animation on the ring.
    -- Declarative and engine-stepped — SetScript is refused on engine-owned
    -- aura buttons and their descendants, so an OnUpdate pulse is impossible.
    -- Created here because AnimationGroup creation AND Play() are
    -- init-window-only; ApplyGlow merely starts/stops it and re-scales its
    -- floor/ceiling from the color picker's alpha.
    local glowAG = glowTex:CreateAnimationGroup()
    glowAG:SetLooping("REPEAT")
    local gIn = glowAG:CreateAnimation("Alpha")
    gIn:SetOrder(1); gIn:SetDuration(0.6)
    gIn:SetFromAlpha(0.35); gIn:SetToAlpha(1)
    local gOut = glowAG:CreateAnimation("Alpha")
    gOut:SetOrder(2); gOut:SetDuration(0.6)
    gOut:SetFromAlpha(1); gOut:SetToAlpha(0.35)
    button._bf_glowAG = glowAG
    button._bf_glowIn, button._bf_glowOut = gIn, gOut

    -- v49/v84 icon-effect regions + animation groups (see ApplyIconEffects).
    -- Ants: FlipBook over the 22-frame IconAlertAnts sheet (5×5 grid).
    local antsTex = BF.Texture(glowFrame, nil, "OVERLAY", nil, 2)
    antsTex:SetTexture("Interface\\SpellActivationOverlay\\IconAlertAnts")
    antsTex:Hide()
    button._bf_antsTex = antsTex
    local antsAG = antsTex:CreateAnimationGroup()
    antsAG:SetLooping("REPEAT")
    local fb = antsAG:CreateAnimation("FlipBook")
    fb:SetDuration(0.7)
    fb:SetFlipBookRows(5)
    fb:SetFlipBookColumns(5)
    fb:SetFlipBookFrames(22)
    -- 48px frames on a 256px sheet: without explicit frame dimensions
    -- the flipbook divides the FULL sheet into 5ths (51.2px cells) and
    -- every frame samples off-grid — the ants "jumped around".
    if fb.SetFlipBookFrameWidth then
        fb:SetFlipBookFrameWidth(48)
        fb:SetFlipBookFrameHeight(48)
    end
    -- v53 PERF: NOT started here. ApplyIconEffects (called at the tail of
    -- this function, and from both restyle walks) plays it only while an
    -- ants alert is actually configured, and stops it when it is not.
    button._bf_antsAG = antsAG
    -- Flash: additive overlay with a looping in/out alpha pulse.
    local flashTex = BF.Texture(glowFrame, nil, "OVERLAY", nil, 3)
    flashTex:SetTexture("Interface\\Buttons\\WHITE8x8")
    flashTex:SetBlendMode("ADD")
    flashTex:SetAllPoints(button)
    UnsnapIconOverlay(flashTex)   -- v93: rasterize like the icon it overlays
    flashTex:SetAlpha(0)
    flashTex:Hide()
    button._bf_flashTex = flashTex
    local flashAG = flashTex:CreateAnimationGroup()
    flashAG:SetLooping("REPEAT")
    local aIn = flashAG:CreateAnimation("Alpha")
    aIn:SetOrder(1)
    aIn:SetDuration(0.4)
    aIn:SetFromAlpha(0)
    aIn:SetToAlpha(0.5)
    local aOut = flashAG:CreateAnimation("Alpha")
    aOut:SetOrder(2)
    aOut:SetDuration(0.4)
    aOut:SetFromAlpha(0.5)
    aOut:SetToAlpha(0)
    -- v53 PERF: NOT started here (see the ants group above).
    button._bf_flashAG = flashAG
    -- v84 §9.9: retained so the Effect Color's ALPHA can re-scale the pulse
    -- PEAK at style time (plain property setters; the group is never rebuilt).
    button._bf_flashIn, button._bf_flashOut = aIn, aOut
    -- v84 §9.9: FLASH takes the rounded mask; the ring and the ants must NOT.
    -- The flash is an overlay of the ICON rect, so on a rounded icon style it
    -- has to be clipped to the same rounded shape as the icon or it renders as
    -- a square patch over a round icon. The ring and the ants are deliberately
    -- OVERSIZED outside that rect (pad 0.2 / x1.19 — see ApplyGlowGeometry) and
    -- masking them would cut off exactly the part that makes them readable.
    -- Attach-once at init (mask ATTACHMENT is init-window-only); a hidden mask
    -- is inert, so live rounded/square switches stay pure Show/Hide.
    if button._bf_roundMask then
        flashTex:AddMaskTexture(button._bf_roundMask)
    end

    -- v84 §9.9 Recolor: a tinted overlay over the icon ART (not the border),
    -- so it reads as a recolor of the icon rather than of the whole button.
    -- Same mask rule as the flash. Baked here, hidden until configured.
    local recolorTex = BF.Texture(button, nil, "ARTWORK", nil, 2)
    recolorTex:SetTexture("Interface\\Buttons\\WHITE8x8")
    recolorTex:SetAllPoints(icon)
    UnsnapIconOverlay(recolorTex)  -- v93: same latent 1px error as the flash
    recolorTex:Hide()
    if button._bf_roundMask then
        recolorTex:AddMaskTexture(button._bf_roundMask)
    end
    button._bf_recolorTex = recolorTex

    -- v84 §9.9 Pandemic Effect. The ENGINE computes the pandemic (refresh)
    -- window against the aura's SECRET remaining duration and renders this
    -- region only inside it — which is why it replaces the old
    -- threshold-driven "glow when expiring": a seconds threshold can never be
    -- evaluated in Lua on 12.1, and v47 could only ever render a static ring.
    --
    -- Bound ONCE, here, because AddPandemicRegion is a BINDING and bindings are
    -- init-window-only. Runtime gating is ALPHA only (ApplyIconEffectCore):
    -- the bind stamps the region's Shown aspect so the engine owns visibility,
    -- and it means ClearPandemicRegions — which drops EVERY region on the
    -- button — never has to run.
    --
    -- Feature-detected AND pcall'd: AddPandemicRegion is absent from the
    -- generated API documentation extract, so its presence is treated as
    -- optional. On a client without it the effect is simply inert.
    local pandemicTex = BF.Texture(glowFrame, nil, "OVERLAY", nil, 1)
    pandemicTex:SetColorTexture(0.239216, 1, 0.254902, 0.15)
    pandemicTex:SetAllPoints(icon)
    UnsnapIconOverlay(pandemicTex) -- v93: same latent 1px error as the flash
    pandemicTex:SetAlpha(0)
    button._bf_pandemicTex = pandemicTex
    if button.AddPandemicRegion then
        pcall(button.AddPandemicRegion, button, pandemicTex)
    end

    -- Geometry for the glow ring + ants (after both exist).
    ApplyGlowGeometry(button, spec.size)

    -- Presence glow (BigDef/Important Show Glow + per-spell glows) +
    -- visual alert.
    ApplyGlow(button, spec)
    ApplyIconEffects(button, spec)
    -- v88 COMPLETION MARKER. `_bf_icon` is the RE-ENTRY guard and it is stamped
    -- MID-WALK (above), so it answers "has anything been built on this button",
    -- NOT "did the styling walk finish". Those two diverge exactly when the walk
    -- is interrupted -- a denied setter on a tainted stack once auras are secret
    -- (DenyTaintedAccessWhenAurasAreSecret is armed on every aura button at
    -- PLAYER_ENTERING_WORLD; Docs/AuraContainer_API_Reference_12.1.md) -- and a
    -- half-built button then reads as fully styled to every "is it styled" test
    -- in this file. Stamped LAST, so it is true only for a completed walk.
    -- Both markers are load-bearing and they answer different questions:
    -- `_bf_icon` gates RE-ENTRY (this function is not idempotent),
    -- `_bf_initDone` gates REPAIR.
    button._bf_initDone = true
    if hb then
        hb.buttons  = hb.buttons + 1
        hb.buttonMs = hb.buttonMs + (debugprofilestop() - hbT)
    end
end

-- v88: one-shot diagnostic for a button whose styling walk started and did not
-- finish. Unrecoverable on a GROUP pool button (the regions already built can
-- never be removed and InitAuraButton can never safely re-run over them),
-- recoverable on a SLOT (BF:DiscardAuraSlotVisual retires it and the next
-- creation pass acquires a fresh slot key). Printed once per session so a
-- denial storm cannot spam the chat frame.
local function ReportHalfBuiltButton(where)
    if BF._halfBuiltPrinted then return end
    BF._halfBuiltPrinted = true
    DevPrint("|cffff0000BuzzardFrames:|r an aura button's styling was interrupted ("
        .. tostring(where) .. ") -- most likely a denied call on a tainted stack "
        .. "while auras were secret. Slot displays repair themselves out of "
        .. "combat; group buttons need a /reload.")
end
BF.ReportHalfBuiltButton = ReportHalfBuiltButton

-- ============================================================
-- v77 PERF: DON'T STYLE THE BUTTONS THAT CAN NEVER BE SHOWN
--
-- AddAuraGroup pre-creates a pool of buttons per group and calls
-- initializeFrame for every one of them. The pool is NOT sized by
-- maxFrameCount -- maxFrameCount only caps how many of them the engine may
-- DISPLAY. Pool size CONFIRMED (v77 measurement): exactly 10 buttons are
-- pre-created per aura group, regardless of maxFrameCount, so POOL_BATCH = 10
-- is a verified constant, no longer just a working assumption. (Matches
-- Docs/AuraContainer_API_Reference_12.1.md's "Frames are pooled in batches of
-- 10"; maxFrameCount never exceeds 8 inside BF anyway -- Max Buffs / Max
-- Debuffs / container Max Icons are all min 1 max 8.)
--
-- Measured: 11,500 InitAuraButton calls at login on the owner's profile
-- (50 frames x ~23 groups x 10), 2887 ms. A per-spell group has
-- maxFrameCount 1 and pays for 10 buttons; nine of them can never render.
--
-- GRID2'S PATTERN, ported directly (Grid2/modules/IndicatorIcons.lua,
-- Icon_LayoutB): let the engine create the pool, but skip our styling for
-- the first (POOL_BATCH - maxFrameCount) initializeFrame calls. Grid2 skips
-- the FIRST N, i.e. it treats the TAIL of the pool as the part the engine
-- displays.
--
-- >>> THAT ORDERING IS AN INFERENCE FROM GRID2'S CODE, NOT A VERIFIED ENGINE
-- >>> FACT. Nothing in Grid2 states it (its `_buttons` array is accumulated
-- >>> and never read), and Grid2's default maxIcons of 3 would make a wrong
-- >>> guess easy to miss. If the engine displays from the HEAD instead, the
-- >>> visible icons are the unstyled ones.
-- >>>
-- >>> v85: the skip is UNCONDITIONAL. It used to sit behind
-- >>> BF:IsAuraSkipEnabled() / "/bf auraskip"; the owner ruled 2026-08-16 that
-- >>> optimizations are not gated behind kill switches, so the switch, its
-- >>> saved flag and the fully-styled fallback arm are gone. The tail-ordering
-- >>> inference above is therefore load-bearing with no escape hatch: if
-- >>> blank or unstyled icons are ever observed, that is the first thing to
-- >>> re-examine, and the revert is to make MakeInitFn style every button
-- >>> (drop `skip` entirely), not to reintroduce a toggle.
--
-- There is no in-combat recovery: region creation is refused while
-- InCombatLockdown or the secret-aura window is open, so a displayed-but-
-- skipped button would stay blank for the whole fight. The top-up below only
-- ever runs out of combat.
-- ============================================================
local POOL_BATCH = 10

-- Build the initializeFrame closure for ONE group.
--
-- MUST be called per group, never shared: EnsureAuraGridContainer's `groups`
-- form adds two groups from one call (debuffs primary+secondary; bigDef's
-- bd+ext too, until v79 merged them into one group) and a single shared
-- `skip` upvalue would be consumed entirely by the first of them, leaving the
-- second fully styled and mis-counted.
-- v77b: per-group-CLASS attribution for /bf loadreport. The totals alone
-- cannot say where 11,750 pooled buttons come from, and the obvious
-- arithmetic does not close: 11,750/10 = 1,175 groups over 40 main-header
-- frames + 10 CFG frames needs 8a + 2b = 235, which has no integer solution.
-- So either the pool is not uniformly POOL_BATCH, or frames inside one header
-- get different group sets, or some builds land outside the harness window.
-- This tells us which. (The pool-size arm has since been settled: v77
-- confirmed the pool IS uniformly POOL_BATCH = 10 per group, so any residual
-- mismatch is group-set variance or harness-window coverage, not pool size.)
--
-- Keys are NORMALIZED (bfc7 -> bfc*, sp12345 -> sp*) or the table would have
-- one row per spell. Rows record groups created, buttons actually pooled
-- (init calls seen), styled, and skipped -- so pooled/groups IS the measured
-- pool size per class, per row.
local function HBKey(featureKey, groupKey)
    local f = tostring(featureKey or "?")
        :gsub("^bfc%d+$", "bfc*"):gsub("^dbc%d+$", "dbc*")
    local g = tostring(groupKey or "?")
        :gsub("^sp%d+$", "sp*"):gsub("^sb.+$", "sb*"):gsub("^pre.+$", "pre*")
    return f .. "/" .. g
end

-- v85: slot-key normalizer for the per-key slot census. The dispel keys
-- (dispelBorder / dispelDot / dispelOverlay and the merged dvOB / dvOD / dvBD /
-- dvOBD) are kept WHOLE -- telling them apart is the entire point of the census
-- -- while the per-spell fx and single-buff keys collapse to a class.
function BF.HBSlotKey(featureKey)
    local k = tostring(featureKey or "?")
    if k:match("^fx%d+$") then return "fx*" end
    if k:match("^sbc%d+$") then return "sbc*" end
    return k
end

-- v85: what the frames ACTUALLY hold, walked at seal time. The counter above
-- only sees slots created INSIDE the headersBuilt span, so a slot built later
-- is invisible to it; comparing the two columns is what distinguishes "never
-- created" from "created late".
--
-- WALKS BF.registeredFrames, NOT BF.activeFrames. This is the whole correctness
-- of the comparison: `registeredFrames` is BFLayout's "all frames created, used
-- and unused" registry, written by BF:RegisterFrame -- the very function that
-- calls BuzzardFrame_Init, and therefore the same population LoadHBFrame counts
-- and CreateIndicators builds slots for. `activeFrames` is the ALIAS of
-- activatedFrames, i.e. only frames currently assigned to a unit: solo that is
-- ~2 frames against 45 created ones, so the first version of this walk compared
-- two different populations and the at-seal column read 2 for every key.
--
-- Keyed by frame NAME with the frame as the VALUE (see the declaration in
-- BFLayout.lua), hence `for _, frame in pairs(...)`.
--
-- Preview frames are skipped for the same reason the in-span counter never sees
-- them: they are not registered here and build no slots (every slot-owning
-- :Create returns early on _isPreviewFrame). The guard is belt-and-braces so
-- the two columns can never diverge on population again.
function BF.HBSlotSnapshot()
    local out, frames = {}, BF.registeredFrames
    if not frames then return out end
    for _, frame in pairs(frames) do
        if type(frame) == "table" and not frame._isPreviewFrame then
            local t = frame._bf_auraSlots
            if t then
                for key in pairs(t) do
                    local k = BF.HBSlotKey(key)
                    out[k] = (out[k] or 0) + 1
                end
            end
        end
    end
    return out
end

local function HBGroupRow(hbKey)
    local hb = BF._loadHB
    if not hb then return nil end
    local by = hb.byKey
    if not by then by = {}; hb.byKey = by end
    local row = by[hbKey]
    if not row then
        row = { key = hbKey, groups = 0, pooled = 0, styled = 0, skipped = 0 }
        by[hbKey] = row
    end
    return row
end

-- Count one group's creation. Called at every AddAuraGroup site.
local function HBCountGroup(hbKey)
    local row = HBGroupRow(hbKey)
    if row then row.groups = row.groups + 1 end
end

local function MakeInitFn(spec, maxN, hbKey)
    local skip = POOL_BATCH - (maxN or POOL_BATCH)
    -- v85: unconditional (the /bf auraskip gate is gone -- see the block above).
    local doSkip = (skip > 0)
    return function(button)
        local row = hbKey and HBGroupRow(hbKey)
        if row then row.pooled = row.pooled + 1 end
        if doSkip and skip > 0 then
            skip = skip - 1
            local hb = BF._loadHB
            if hb and hb.skipped then hb.skipped = hb.skipped + 1 end
            if row then row.skipped = row.skipped + 1 end
            return
        end
        if row then row.styled = row.styled + 1 end
        InitAuraButton(button, spec)
    end
end

-- How many of a group's pool we styled at creation. Recorded so the geometry
-- pass can notice a RISE in the cap and top up.
local function RecordGroupStyled(c, gk, maxN)
    c._bf_groupStyled = c._bf_groupStyled or {}
    local n = maxN or POOL_BATCH
    if n > POOL_BATCH then n = POOL_BATCH end
    c._bf_groupStyled[gk] = n
end

-- Style every unstyled button in a group's pool. Called when the group's cap
-- rises above what was styled at creation (a Max Buffs / Max Icons edit, a
-- container geometry change). Returns true when the group is fully styled.
--
-- Styles the WHOLE pool rather than "the next few": which end of the pool the
-- engine draws from is exactly the unverified thing above, so guessing here
-- would reintroduce the same risk. The cost is bounded (POOL_BATCH buttons for
-- one group, once) and only ever paid on an increase, out of combat.
--
-- _bf_icon is the "already styled" marker and the test is load-bearing, not an
-- optimization: InitAuraButton is not idempotent.
-- v98: deferred top-up queue (see the call site in ApplyAuraGridGeometry).
-- pendingTopUps[c][gk] = wanted cap. Drained a few groups per tick so no
-- single frame pays more than ~25 ms; a refused top-up (combat / secret
-- auras) stays queued and is retried from PLAYER_REGEN_ENABLED.
local pendingTopUps, topUpDrainArmed = {}, false
local TOPUP_GROUPS_PER_TICK = 8
local TopUpGroupStyling  -- forward
local function DrainTopUps()
    topUpDrainArmed = false
    if BF:IsAuraCreationRestricted() then return end
    local done, touched = 0, {}
    for c, groups in pairs(pendingTopUps) do
        for gk, want in pairs(groups) do
            if done >= TOPUP_GROUPS_PER_TICK then break end
            done = done + 1
            if TopUpGroupStyling(c, gk) then
                groups[gk] = nil
                c._bf_curGroupMax = c._bf_curGroupMax or {}
                if c._bf_curGroupMax[gk] ~= want then
                    c._bf_curGroupMax[gk] = want
                    pcall(c.SetAuraGroupMaxFrameCount, c, gk, want)
                    touched[c] = true
                end
            else
                return  -- restricted mid-drain: retry on regen
            end
        end
        if next(groups) == nil then pendingTopUps[c] = nil end
        if done >= TOPUP_GROUPS_PER_TICK then break end
    end
    for c in pairs(touched) do pcall(c.UpdateAllAuras, c) end
    if next(pendingTopUps) ~= nil then
        topUpDrainArmed = true
        C_Timer.After(0, DrainTopUps)
    end
end
local function QueueTopUp(c, gk, want)
    local g = pendingTopUps[c]
    if not g then g = {}; pendingTopUps[c] = g end
    g[gk] = want
    if not topUpDrainArmed then
        topUpDrainArmed = true
        C_Timer.After(0, DrainTopUps)
    end
end
-- Combat catch-up (called from BF:PLAYER_REGEN_ENABLED).
function BF:DrainPendingTopUps()
    if next(pendingTopUps) ~= nil and not topUpDrainArmed then
        topUpDrainArmed = true
        C_Timer.After(0, DrainTopUps)
    end
end

TopUpGroupStyling = function(c, gk)
    if BF:IsAuraCreationRestricted() then return false end
    local spec = (c._bf_groupSpecs and c._bf_groupSpecs[gk]) or c._bf_buttonSpec
    if not spec then return false end
    local okN, n = pcall(c.GetAuraGroupFrameCount, c, gk)
    if not okN or not n or n == 0 then return false end
    for i = 1, n do
        local okB, b = pcall(c.GetAuraGroupFrame, c, gk, i)
        if okB and b and not b._bf_icon then
            if not pcall(InitAuraButton, b, spec) then return false end
            -- v88: a pcall that RETURNED does not mean the walk completed --
            -- InitAuraButton's own inner pcalls swallow individual denials.
            -- Surface the half-built case rather than recording it as styled.
            if not b._bf_initDone then
                ReportHalfBuiltButton("group " .. tostring(gk))
                return false
            end
        elseif okB and b and not b._bf_initDone then
            -- Started before and never finished. Cannot be repaired: the
            -- regions it did build can never be removed, and re-running
            -- InitAuraButton over them would duplicate every engine binding
            -- and attach a second MaskTexture that can never be detached once
            -- auras are secret. Report and leave it alone.
            ReportHalfBuiltButton("group " .. tostring(gk))
        end
    end
    c._bf_groupStyled = c._bf_groupStyled or {}
    c._bf_groupStyled[gk] = n
    return true
end

-- 2026-09-11: this census block (and its snapshot helpers) used to sit just
-- above ApplyAuraGridButtonSpec. It moved here, ABOVE EnsureAuraGridContainer /
-- EnsureAuraGridSpellGroup, because both creation paths now seed the style
-- snapshot with StoreSpecSnapshot -- a local is only in scope below its
-- declaration.
--
-- v99 PERF: ONE FIELD CENSUS, TWO CONSUMERS.
-- ButtonSpecSig used to spell its fields out inline. It is now driven by the
-- two descriptor tables below, and so is the allocation-free comparator that
-- replaced it on the per-group path (ApplyAuraGridGroupButtonSpec). Sharing
-- the census is the point: a field added to the signature but forgotten in the
-- comparator would silently stop that setting from ever applying live -- the
-- exact class of bug the v92/v94/v95 notes in this file record. Add a field
-- HERE and both paths pick it up.
--
-- Why the group path needed the comparator at all: the container twin
-- (ApplyAuraGridButtonSpec) short-circuits on a cheap _cacheGen pre-guard and
-- only builds a signature when that guard moves. The group twin has no such
-- pre-guard and CANNOT reuse that one -- group specs carry per-spell
-- customization fields (solidIcon, iconEffect, glow*, pandemic*, stack
-- styling) that never bumped _cacheGen at all, so a gen-based guard would
-- silently swallow per-spell style edits. (v99 then removed that pre-guard from
-- the container path too, for the same reason generalised -- see the note in
-- ApplyAuraGridButtonSpec.) The full field comparison is the only authority on
-- both paths now; it is just no longer built out of ~36
-- tostring calls, ~25 concats, a 43-element table and a table.concat on every
-- call. Measured: 2806 calls / 1111 ms in a 530 s raid window, all of it
-- inside the ApplyProfile burst that owns the party<->raid join stall.
local BUTTON_SPEC_SCALARS = {
    "showDuration", "durationFont", "durationFontSize", "durationBorder",
    "durationScale", "durationCurve",
    "showStacks", "stackFont", "stackSize", "stackBorder", "stackScale",
    "stackAnchor", "stackX", "stackY",
    "hideDurationAbove1Min", "durationSquare", "blizzardBorders", "borderStyle",
    -- v84 §9.9: the Icon Effect model (replaces the numeric visualAlert).
    "showGlow", "glowType", "glowPulse", "iconEffect",
    "iconDesaturate", "iconRecolor", "pandemic",
    "borderThickness", "dispelBorderThickness", "colorBorderByDispel",
    "dispelTypeIcon", "dispelTypeIconScale",
    "disableSwipe", "disableSpark", "reverseSwipe",
    "tooltipEnabled", "tooltipInCombat",
    -- v71: per-group size multiplier (preset Relative Size) -- folded in so a
    -- ratio change re-runs the restyle walk (which re-stores the spec's
    -- _bf_sizeMult; the geometry re-layout then reads the new value).
    "_bf_sizeMult",
    -- v98 PERF: tooltipPos / tooltipFrameY are deliberately NOT here.
    -- tooltipFrameY is a pure function of the frame HEIGHT, so every
    -- party<->raid flip moved every container's signature and ran the full
    -- 10-button x 12-applier restyle walk on every frame -- 208 ms of a 532 ms
    -- join stall, measured -- to move a tooltip offset. Both callers compare
    -- the pair directly and run a tooltip-only walk (ApplyTooltipStyle) when
    -- only they changed.
    -- `size` is NOT here either: the live-size path owns it (see the keepSize
    -- handling in both callers).
}
-- Color fields. kind "rgba" reads .r/.g/.b/.a; kind "array" reads [1]..[4].
-- `def` carries the SAME `or` defaults the signature has always applied, so a
-- nil component and its default stay indistinguishable on both paths (a
-- stricter compare here would only cost extra restyle walks, never miss an
-- edit -- but it would also cost hit rate, so match the old behavior exactly).
local BUTTON_SPEC_COLORS = {
    { key = "solidIcon",        kind = "rgba",  def = { 0, 0, 0, 1   } },
    { key = "iconEffectColor",  kind = "array", def = { 1, 1, 1, 1   } },
    { key = "iconRecolorColor", kind = "rgba",  def = { 1, 1, 1, 0.5 } },
    { key = "pandemicColor",    kind = "rgba",  def = { 0, 0, 0, 0   } },
    { key = "glowColor",        kind = "array", def = { 1, 1, 1, 1   } },
    { key = "fontColor",        kind = "rgba",  def = { 1, 1, 1, 1   } },
    { key = "borderColor",      kind = "rgba",  def = { 0, 0, 0, 1   } },
}
local RGBA_KEYS = { "r", "g", "b", "a" }

-- One component of one color field, with the descriptor's default applied.
-- Never returns nil, which is what lets a nil slot in a stored snapshot mean
-- "the color table itself was absent" (see SpecSnapshotMatch).
local function ColorComponent(t, cd, i)
    local v
    if cd.kind == "rgba" then v = t[RGBA_KEYS[i]] else v = t[i] end
    if v == nil then return cd.def[i] end
    return v
end

-- Signature (container path + RestyleSlotButton). Kept, because both compare
-- against a stored STRING; only its construction changed -- driven by the
-- census above, and writing into one reused module-level buffer instead of
-- minting a fresh 43-element table per call. The element count is a constant,
-- so no stale tail can survive between calls.
local sigBuf = {}
local function ButtonSpecSig(spec)
    local n = 0
    for i = 1, #BUTTON_SPEC_SCALARS do
        n = n + 1
        sigBuf[n] = tostring(spec[BUTTON_SPEC_SCALARS[i]])
    end
    for i = 1, #BUTTON_SPEC_COLORS do
        local cd = BUTTON_SPEC_COLORS[i]
        local t  = spec[cd.key]
        n = n + 1
        if t then
            sigBuf[n] = ColorComponent(t, cd, 1) .. "," .. ColorComponent(t, cd, 2)
                .. "," .. ColorComponent(t, cd, 3) .. "," .. ColorComponent(t, cd, 4)
        else
            sigBuf[n] = "-"
        end
    end
    return table.concat(sigBuf, "|", 1, n)
end
-- 2026-09-11 (restricted recreate): exported so the in-key sbc compare in
-- BuffsAndContainers derives the SAME sig RestyleSlotButton stamps
-- (btn._bf_specSig) without writing anything. Pure: no engine work.
BF.ButtonSpecSig = ButtonSpecSig

-- Allocation-free equivalent of "ButtonSpecSig(spec) == storedSig", for the
-- per-group path. Early-exits on the first differing field, so a genuine MISS
-- is cheaper than a hit as well -- the old form paid for the whole string
-- before it could discover the difference.
--
-- snap.s holds the scalars positionally (a nil scalar is a legitimate hole;
-- nothing here takes # of it). snap.c holds 4 components per color field, and
-- a nil first component marks "this color table was absent" -- unambiguous,
-- because ColorComponent always substitutes a default.
local function SpecSnapshotMatch(snap, spec)
    if not snap then return false end
    -- 2026-09-11 (restricted recreate diag): a miss also returns the NAME of
    -- the first differing field, so an in-key rebuild reason can say which
    -- field creation and Layout disagree on. Boolean callers are unaffected.
    local sc = snap.s
    for i = 1, #BUTTON_SPEC_SCALARS do
        if sc[i] ~= spec[BUTTON_SPEC_SCALARS[i]] then
            return false, BUTTON_SPEC_SCALARS[i]
        end
    end
    local cl = snap.c
    for i = 1, #BUTTON_SPEC_COLORS do
        local cd = BUTTON_SPEC_COLORS[i]
        local t  = spec[cd.key]
        local b  = (i - 1) * 4
        if t == nil then
            if cl[b + 1] ~= nil then return false, cd.key end
        else
            if cl[b + 1] == nil then return false, cd.key end
            if cl[b + 1] ~= ColorComponent(t, cd, 1) then return false, cd.key end
            if cl[b + 2] ~= ColorComponent(t, cd, 2) then return false, cd.key end
            if cl[b + 3] ~= ColorComponent(t, cd, 3) then return false, cd.key end
            if cl[b + 4] ~= ColorComponent(t, cd, 4) then return false, cd.key end
        end
    end
    return true
end

-- Commit a snapshot (creating it on first use, reusing its tables after).
-- Colors are stored BY COMPONENT, never by reference: the source color tables
-- are mutated in place by the setters -- the same reason StoreAcSpecFields
-- copies components -- so holding a reference would compare a table against
-- itself and the guard would never fire again.
local function StoreSpecSnapshot(snap, spec)
    if not snap then snap = { s = {}, c = {} } end
    local sc = snap.s
    for i = 1, #BUTTON_SPEC_SCALARS do
        sc[i] = spec[BUTTON_SPEC_SCALARS[i]]
    end
    local cl = snap.c
    for i = 1, #BUTTON_SPEC_COLORS do
        local cd = BUTTON_SPEC_COLORS[i]
        local t  = spec[cd.key]
        local b  = (i - 1) * 4
        if t == nil then
            cl[b + 1], cl[b + 2], cl[b + 3], cl[b + 4] = nil, nil, nil, nil
        else
            cl[b + 1] = ColorComponent(t, cd, 1)
            cl[b + 2] = ColorComponent(t, cd, 2)
            cl[b + 3] = ColorComponent(t, cd, 3)
            cl[b + 4] = ColorComponent(t, cd, 4)
        end
    end
    return snap
end

-- 2026-09-11 (review): seeding a style snapshot at creation is only honest
-- when creation actually FINISHED on every styled button. InitAuraButton
-- swallows individual engine denials in its own pcalls, so a button can leave
-- initializeFrame with `_bf_icon` set but `_bf_initDone` false (a restricted
-- reload, a late initializeFrame on a tainted stack). Before the seed existed
-- the first unrestricted restyle walk always MISSED and re-walked every
-- button, which is what repaired those; TopUpGroupStyling only looks at
-- buttons with no `_bf_icon` at all. So: seed only when no styled button in
-- the group is half-done, otherwise leave the snapshot nil and let the first
-- walk repair exactly as before. Returns true when it is safe to seed.
local function GroupInitComplete(c, groupKey)
    local n = c:GetAuraGroupFrameCount(groupKey) or 0
    for i = 1, n do
        local b = c:GetAuraGroupFrame(groupKey, i)
        if b and b._bf_icon and not b._bf_initDone then return false end
    end
    return true
end

-- ============================================================
-- Container creation / geometry
-- ============================================================

-- Create (once) the container for featureKey on frame.
-- spec: { buttonSpec, spacing, rowSpacing, maxFrameCount, sortMethod,
--         sortDirection, filter }               -- single-group form, OR
--       { buttonSpec, ..., groups = { {key, filter, maxFrameCount?,
--         sortMethod?, sortDirection?}, ... } } -- multi-group form.
-- Multi-group: groups sharing one container are auto-deduped by the
-- engine (same aura never assigned twice within a container), and can be
-- made disjoint outright with !-negated filters.
function BF:EnsureAuraGridContainer(frame, featureKey, spec)
    frame._bf_auraContainers = frame._bf_auraContainers or {}
    local c = frame._bf_auraContainers[featureKey]
    if c then return c end

    c = CreateFrame("AuraContainer", nil, frame, "CustomAuraContainerTemplate")
    do local hb = BF._loadHB; if hb then hb.containers = hb.containers + 1 end end
    c._bf_featureKey = featureKey
    c._bf_groupKeys = {}
    c._bf_curFilters = {}
    MarkVehicleTainted(c)

    -- Frame level: lift the container above the unit frame's border and
    -- text elements (name/health text etc.) — the default parent+1 level
    -- rendered aura icons UNDER the frame border. Offsets mirror the
    -- legacy icon pools so relative ordering between features is kept:
    -- buffs/debuffs/custom containers +223, BigDef/Important/CC +224
    -- (the old +23/+24 plus the "+200 native-overlay lift" that puts
    -- text/icons above Blizzard_PrivateAurasUI's absolute child levels
    -- 125–200; see Auras/PrivateAuraDispelOverlay.lua:Layout).
    -- Pool-created AuraButtons are container children, so they stack
    -- above it automatically.
    -- pcall: PTR-VERIFY SetFrameLevel on an AuraContainer (its Untrusted
    -- layout restrictions target sizing/anchoring, not frame level).
    pcall(c.SetFrameLevel, c,
        frame:GetFrameLevel() + (spec.frameLevelOffset or 223))

    local buttonSpec = spec.buttonSpec
    c._bf_buttonSpec = buttonSpec  -- mutated by ApplyAuraGridGeometry on live size change
    c._bf_groupStyled = {}
    -- v77: the initializeFrame closure is built PER GROUP inside the loop
    -- below, not once here. It carries a per-group skip counter (see
    -- MakeInitFn) and the `groups` form of this call adds two groups from one
    -- invocation -- one shared closure would let the first group eat the
    -- second's skip budget.

    local groups = spec.groups or { {
        key = "main", filter = spec.filter,
        maxFrameCount = spec.maxFrameCount,
        sortMethod = spec.sortMethod, sortDirection = spec.sortDirection,
        layoutIndex = spec.layoutIndex,
    } }
    for _, g in ipairs(groups) do
        local layout = {
            elementSpacing = spec.spacing or 1,
            lineSpacing = spec.rowSpacing or 1,
            -- groupSpacing stays at its engine default (0): elementSpacing
            -- already applies ACROSS group boundaries within a flow line,
            -- and groupSpacing stacks ON TOP of it (PTR-observed: setting
            -- it to the element gap doubled the boundary gap).
        }
        -- v43: explicit flow order (per-spell groups sort ahead of the
        -- main group). Recorded so ApplyAuraGridGeometry re-includes it
        -- in every SetAuraGroupLayout call (layout tables may replace,
        -- not merge — PTR-VERIFY).
        if g.layoutIndex then
            layout.layoutIndex = g.layoutIndex
            c._bf_groupLayoutIndex = c._bf_groupLayoutIndex or {}
            c._bf_groupLayoutIndex[g.key] = g.layoutIndex
        end
        local gMax = g.maxFrameCount or spec.maxFrameCount or 1
        local hbKey = HBKey(featureKey, g.key)
        HBCountGroup(hbKey)
        c:AddAuraGroup(g.key, g.filter, {
            maxFrameCount = gMax,
            initializeFrame = MakeInitFn(buttonSpec, gMax, hbKey),
            sortMethod = g.sortMethod or spec.sortMethod or AuraContainerSortMethod.Default,
            sortDirection = g.sortDirection or spec.sortDirection or AuraContainerSortDirection.Normal,
            layout = layout,
        })
        c._bf_groupKeys[#c._bf_groupKeys + 1] = g.key
        c._bf_curFilters[g.key] = g.filter
        -- v77: seed here, at CREATION. BuffsAndContainers:Layout runs
        -- ApplyAuraGridGeometry BEFORE ApplyBuffFilters creates the sp*/pre*/
        -- sb* groups, so a count seeded only in the geometry arm would be nil
        -- on a new group's first pass and trigger a pointless full re-style.
        RecordGroupStyled(c, g.key, gMax)
    end

    -- 2026-09-11 (field report 2026-09-10: after a /reload inside a keystone
    -- "only some buff customizations are active, some reverted to default"):
    -- seed the style snapshot with the spec every button is BORN with. Nothing
    -- stored one here, and SpecSnapshotMatch(nil, ...) is false, so the first
    -- ApplyAuraGridButtonSpec always missed -- and while restricted (the whole
    -- key) a miss commits nothing, so it missed on every pass and never
    -- converged. Seeded, an unchanged profile hits on the first Layout; a
    -- genuinely different Layout spec still misses exactly as before. The
    -- tooltip pair is seeded the same way the commit path stores it, so the
    -- tooltip-only walk runs only if placement actually moved since creation.
    -- _bf_groupSpecs[gk] groups are not covered by this snapshot (they carry
    -- their own; see EnsureAuraGridSpellGroup), matching the walk's scope.
    if buttonSpec then
        local complete = true
        for i = 1, #c._bf_groupKeys do
            if not GroupInitComplete(c, c._bf_groupKeys[i]) then complete = false; break end
        end
        if complete then
            c._bf_styleSig = StoreSpecSnapshot(nil, buttonSpec)
            c._bf_styleTTY, c._bf_styleTPos = buttonSpec.tooltipFrameY, buttonSpec.tooltipPos
            -- 2026-09-11 (restricted recreate, plan §3.2 A / §6): InitAuraButton
            -- bakes spec.size into every styled button, so the geometry pass's
            -- size guard is seeded with it too. Unseeded, the first geometry
            -- pass on a container rebuilt inside a key would see nil ~= size,
            -- ask for yet another rebuild, and trip the drift guard.
            if buttonSpec.size then c._bf_curButtonSize = buttonSpec.size end
            c._bf_curGridTag = BF.PixelGridTag and BF:PixelGridTag() or nil
        end
    end

    -- 2026-09-11 (owner report: a single buff anchored into the Buffs row
    -- wrapped one icon early on every load, and any Max/size edit fixed it
    -- until the next reload). Before the creation-time seeds above, the first
    -- Layout after load always MISSED its restyle guard and ended in the
    -- engine rebuild (UpdateAllAuras) that ApplyAuraGridGroupButtonSpec /
    -- the sizeChanged arm run -- by accident, but it was what re-flowed the
    -- row after the flow settings and the late-added per-spell / single-buff
    -- groups landed. With the seeds the first pass is a clean hit and nothing
    -- rebuilt. Ask for it explicitly, once, at creation: UpdateAllAuras only
    -- schedules the engine's rebuild for the next OnUpdate, so the calls a
    -- creation pass makes coalesce into one.
    pcall(c.UpdateAllAuras, c)

    frame._bf_auraContainers[featureKey] = c
    return c
end

-- ============================================================
-- PER-SPELL GROUPS (v43 Aura Customizations redesign)
-- Dynamically add a per-spell aura group to an existing grid container.
-- The group carries its OWN buttonSpec (own initializeFrame closure) and
-- its own maxFrameCount (1), and participates in the container's shared
-- flow layout at g.layoutIndex — customized spells flow together with
-- the main group's buffs, ordered ahead of them, with no reserved gaps
-- when absent. Groups can't be removed: callers park stale ones via
-- SetAuraGridGroupDormant.
-- PTR-VERIFY (v43): AddAuraGroup after container creation (post-facto
-- groups), and the per-group pool overhead at scale (pools batch by 10).
-- g: { filter, buttonSpec, layoutIndex, maxFrameCount?, spacing?,
--      rowSpacing?, sortMethod?, sortDirection? }
-- Re-call with only { layoutIndex = n } to reorder an existing group.
-- ============================================================
function BF:EnsureAuraGridSpellGroup(frame, featureKey, groupKey, g)
    local c = frame._bf_auraContainers and frame._bf_auraContainers[featureKey]
    if not c then return end
    c._bf_groupSpecs = c._bf_groupSpecs or {}
    c._bf_groupLayoutIndex = c._bf_groupLayoutIndex or {}
    c._bf_groupOwnMax = c._bf_groupOwnMax or {}
    if c._bf_groupSpecs[groupKey] then
        -- Exists: record the layoutIndex, then PUSH it.
        --
        -- v67 BUGFIX: this used to only record, on the assumption that "the
        -- next geometry pass (ApplyAuraGridGeometry group loop) pushes it to
        -- the engine". For the buffs container there is no next pass in the
        -- same Layout -- BuffsAndContainers:Layout runs
        -- ApplyAuraGridGeometry(parent, "buffs", geo) FIRST and only then
        -- ApplyBuffFilters -> ApplySingleBuffGroups, which is what computes
        -- and records the new index. So a changed Order sat in
        -- _bf_groupLayoutIndex unpushed until some UNRELATED edit happened to
        -- trigger another Layout. Symptom: Order / Relative Order on a
        -- Buffs-anchored single buff appeared to do nothing, while the same
        -- entry reordered correctly the moment anything recreated its group
        -- (the create path below passes layoutIndex straight to AddAuraGroup).
        --
        -- The layout table is rebuilt in FULL rather than pushed as a lone
        -- layoutIndex: layout tables are believed to REPLACE rather than merge
        -- (see the v43 note in ApplyAuraGridGeometry), so a partial push would
        -- drop elementSpacing / lineSpacing / the per-group cell size. Every
        -- input is recoverable -- c._bf_lastGeo is retained by the geometry
        -- pass for exactly this kind of out-of-band re-push, and the cell size
        -- comes from the group's own spec multiplier.
        if g.layoutIndex and c._bf_groupLayoutIndex[groupKey] ~= g.layoutIndex then
            c._bf_groupLayoutIndex[groupKey] = g.layoutIndex
            local lg = c._bf_lastGeo
            local layout = {
                elementSpacing = (lg and lg.spacing) or g.spacing or 1,
                lineSpacing    = (lg and lg.rowSpacing) or g.rowSpacing or 1,
                layoutIndex    = g.layoutIndex,
            }
            local cell = c._bf_curButtonSize
            if cell then
                local gkSpec = c._bf_groupSpecs[groupKey]
                cell = cell * ((gkSpec and gkSpec._bf_sizeMult) or 1)
                layout.elementWidth  = cell
                layout.elementHeight = cell
            end
            -- v86: this is an out-of-band layout push. Drop the geometry
            -- pass's signature for this group so its next run re-asserts the
            -- full table instead of skipping on a stale match.
            if c._bf_curLayoutSig then c._bf_curLayoutSig[groupKey] = nil end
            pcall(c.SetAuraGroupLayout, c, groupKey, layout)
        end
        return c
    end
    local spec = g.buttonSpec
    if not spec then return end
    -- Keep new buttons in lockstep with a live-resized container
    -- (enlarged groups scale by their spec multiplier).
    local size = c._bf_curButtonSize or (c._bf_buttonSpec and c._bf_buttonSpec.size)
    if size then spec.size = size * (spec._bf_sizeMult or 1) end
    local gMax = g.maxFrameCount or 1
    local hbKey = HBKey(featureKey, groupKey)
    HBCountGroup(hbKey)
    local ok = pcall(c.AddAuraGroup, c, groupKey, g.filter, {
        maxFrameCount = gMax,
        initializeFrame = MakeInitFn(spec, gMax, hbKey),
        sortMethod = g.sortMethod or AuraContainerSortMethod.Default,
        sortDirection = g.sortDirection or AuraContainerSortDirection.Normal,
        -- Include set from the start, mirroring AddAuraSlot below: if the
        -- post-creation SetAuraGroupCandidateFilters were ever denied, a
        -- group whose aura-type filter is a bare "HELPFUL" would match
        -- EVERY helpful aura instead of its handful of spell ids. Callers
        -- that narrow by spell id should pass g.candidateFilters AND keep
        -- their post-creation setter (it re-applies on spec change).
        candidateFilters = g.candidateFilters,
        layout = {
            elementSpacing = g.spacing or 1,
            lineSpacing = g.rowSpacing or 1,
            -- groupSpacing: engine default 0 (see EnsureAuraGridContainer).
            layoutIndex = g.layoutIndex,
        },
    })
    if not ok then return end
    c._bf_groupKeys[#c._bf_groupKeys + 1] = groupKey
    c._bf_curFilters[groupKey] = g.filter
    c._bf_groupSpecs[groupKey] = spec
    c._bf_groupLayoutIndex[groupKey] = g.layoutIndex
    c._bf_groupOwnMax[groupKey] = gMax
    RecordGroupStyled(c, groupKey, gMax)   -- v77
    -- 2026-09-11: seed this group's style snapshot + tooltip pair with the
    -- spec its buttons are born with -- same reason and same shape as the
    -- seed in EnsureAuraGridContainer (ApplyAuraGridGroupButtonSpec's commit).
    -- Seeded only when every styled button finished init (GroupInitComplete).
    if GroupInitComplete(c, groupKey) then
        c._bf_groupStyleSigs = c._bf_groupStyleSigs or {}
        c._bf_groupStyleTT   = c._bf_groupStyleTT or {}
        c._bf_groupStyleSigs[groupKey] = StoreSpecSnapshot(nil, spec)
        c._bf_groupStyleTT[groupKey] = { spec.tooltipFrameY, spec.tooltipPos }
    end
    -- A group added after the geometry pass changes the row's flow; the engine
    -- re-flows only on its own rebuild -- see the matching note in
    -- EnsureAuraGridContainer (owner report 2026-09-11).
    pcall(c.UpdateAllAuras, c)
    return c
end

-- ============================================================
-- v86 DIAG (temporary — remove with the bisect): guard A/B.
--
-- v86 put two engine calls in ApplyAuraGridGeometry behind change guards
-- that were previously unconditional every Layout pass:
--     SetAuraGroupMaxFrameCount   guarded by c._bf_curGroupMax[gk]
--     SetAuraGroupLayout          guarded by c._bf_curLayoutSig[gk]
-- An unconditional re-push papers over any engine-side reset of those two
-- properties. If one exists, a guard that is correct about what BF last
-- pushed is still wrong about what the engine currently holds, and the
-- symptom is a group that renders nothing after a transition that reset it.
--
-- This drops both caches so the next geometry pass re-asserts them in full,
-- i.e. reproduces the pre-v86 behavior without a file swap. Diagnostic
-- ONLY: if wiping fixes a broken display, the bug is a missing invalidation
-- point and that is what gets fixed — not this.
--
-- Walks registeredFrames (every frame created, in service or not), the same
-- population HBSlotSnapshot walks and for the same reason: a spare frame's
-- containers carry the stale guard into service with them.
-- ============================================================
function BF:_WipeLayoutGuardCaches()
    local n, frames = 0, self.registeredFrames
    if not frames then return 0 end
    for _, frame in pairs(frames) do
        if type(frame) == "table" then
            local t = frame._bf_auraContainers
            if t then
                for _, c in pairs(t) do
                    if type(c) == "table" then
                        if c._bf_curGroupMax then c._bf_curGroupMax = nil; n = n + 1 end
                        if c._bf_curLayoutSig then c._bf_curLayoutSig = nil; n = n + 1 end
                    end
                end
            end
        end
    end
    return n
end

-- Live filter swap, change-guarded (settings/mode changes; out of combat
-- via the scoped refreshes — in-combat callability is V12).
function BF:SetAuraGridGroupFilter(frame, featureKey, groupKey, filter)
    local c = frame._bf_auraContainers and frame._bf_auraContainers[featureKey]
    if not c then return end
    if c._bf_curFilters[groupKey] ~= filter then
        c._bf_curFilters[groupKey] = filter
        c:SetAuraGroupFilterString(groupKey, filter)
        -- Option setters don't re-evaluate EXISTING aura assignments
        -- (PTR-observed on maxFrameCount; long-duration auras may not
        -- fire UNIT_AURA for minutes) — force the engine's rebuild.
        pcall(c.UpdateAllAuras, c)
    end
end

-- v84 (Stage 5 §9.6): live sort swap, change-guarded.
-- SetAuraGroupSortMethod(key, method, direction) is one of the documented LIVE
-- group setters, so a user-facing Sort Order dropdown costs no rebuild and no
-- pool. Change-guarded on the pair so routine Layout passes pay one compare.
-- UpdateAllAuras for the same reason every other option setter here needs it:
-- setters do NOT re-evaluate EXISTING aura assignments, so a re-sort of what is
-- already displayed only lands on the engine's next full rebuild.
function BF:SetAuraGridGroupSort(frame, featureKey, groupKey, method, direction)
    local c = frame._bf_auraContainers and frame._bf_auraContainers[featureKey]
    if not c then return end
    method = method or AuraContainerSortMethod.Default
    direction = direction or AuraContainerSortDirection.Normal
    local cur = c._bf_curSort
    if not cur then cur = {}; c._bf_curSort = cur end
    local sig = method .. ":" .. direction
    if cur[groupKey] == sig then return end
    cur[groupKey] = sig
    if pcall(c.SetAuraGroupSortMethod, c, groupKey, method, direction) then
        pcall(c.UpdateAllAuras, c)
    end
end

-- v84 (Stage 5 §9.10): live flow-order swap for a CONTAINER-LEVEL group (one
-- created through EnsureAuraGridContainer's `groups` list, so it has no
-- _bf_groupSpecs entry and EnsureAuraGridSpellGroup's reorder arm — which keys
-- off that table — would try to CREATE it instead of reordering it).
--
-- The layout table is rebuilt in FULL, never pushed as a lone layoutIndex:
-- layout tables are believed to REPLACE rather than merge (the v43 note in
-- ApplyAuraGridGeometry), so a partial push would drop elementSpacing /
-- lineSpacing / the per-group cell size. Same reconstruction the
-- EnsureAuraGridSpellGroup reorder arm does, from c._bf_lastGeo.
function BF:SetAuraGridGroupLayoutIndex(frame, featureKey, groupKey, layoutIndex)
    local c = frame._bf_auraContainers and frame._bf_auraContainers[featureKey]
    if not c or not layoutIndex then return end
    c._bf_groupLayoutIndex = c._bf_groupLayoutIndex or {}
    if c._bf_groupLayoutIndex[groupKey] == layoutIndex then return end
    c._bf_groupLayoutIndex[groupKey] = layoutIndex
    local lg = c._bf_lastGeo
    local layout = {
        elementSpacing = (lg and lg.spacing) or 1,
        lineSpacing    = (lg and lg.rowSpacing) or 1,
        layoutIndex    = layoutIndex,
    }
    local cell = c._bf_curButtonSize
    if cell then
        local gkSpec = c._bf_groupSpecs and c._bf_groupSpecs[groupKey]
        cell = cell * ((gkSpec and gkSpec._bf_sizeMult) or 1)
        layout.elementWidth  = cell
        layout.elementHeight = cell
    end
    -- v86: out-of-band layout push — see EnsureAuraGridSpellGroup.
    if c._bf_curLayoutSig then c._bf_curLayoutSig[groupKey] = nil end
    pcall(c.SetAuraGroupLayout, c, groupKey, layout)
    pcall(c.UpdateAllAuras, c)
end

-- v84 (Stage 5 §9.10): re-point a group's OWN max frame count.
-- _bf_groupOwnMax is stamped once at EnsureAuraGridSpellGroup time and read as
-- `wantMax` by ApplyAuraGridGeometry, which is why a category group first
-- created under party geometry kept the party Max Debuffs forever (the defect
-- recorded in _PLAN_AuraButtonCreation.md §5). The type groups of the Debuffs
-- row are now permanent, so the stale pin would be visible on every profile;
-- re-stamping it here lets the geometry pass push the current value (and its
-- own top-up test then styles any newly displayable pooled buttons).
-- v93 `create`: _bf_groupOwnMax is only ever STAMPED by
-- EnsureAuraGridSpellGroup, so a group created through the container's own
-- `groups` list (the debuffs row's `primary`) has no entry and the nil-guard
-- below refuses it forever -- ApplyAuraGridGeometry then falls back to
-- geo.maxIcons for it. That was right while the row had one cap; "Other
-- Debuffs" now carries its own Max Debuffs like every other type, so its
-- caller passes create = true to open the entry. Default (nil) behavior is
-- byte-for-byte what it was: re-point only, never grant.
function BF:SetAuraGridGroupOwnMax(frame, featureKey, groupKey, maxN, create)
    local c = frame._bf_auraContainers and frame._bf_auraContainers[featureKey]
    if not c or not maxN then return end
    local t = c._bf_groupOwnMax
    if not t then
        if not create then return end
        t = {}
        c._bf_groupOwnMax = t
    end
    if t[groupKey] == nil and not create then return end
    if t[groupKey] == maxN then return end
    t[groupKey] = maxN
end

-- Group dormancy (groups can't be removed — reconfigure instead).
-- PTR-CONFIRMED BUG FIX: "HELPFUL|HARMFUL" is NOT an impossible filter
-- for containers — the engine treats the polarity tokens as a mask, so
-- a group "parked" that way matched EVERYTHING (all debuffs duplicated
-- through the parked secondary debuff group). Park via candidateFilters
-- { maxDuration = 0 } instead: a documented empty set — every timed
-- aura exceeds the bound, and any non-nil bound hides permanents.
local DORMANT_CANDIDATES = { maxDuration = 0 }
function BF:SetAuraGridGroupDormant(frame, featureKey, groupKey, dormant)
    local c = frame._bf_auraContainers and frame._bf_auraContainers[featureKey]
    if not c then return end
    dormant = dormant and true or false
    c._bf_dormantGroups = c._bf_dormantGroups or {}
    -- nil counts as LIVE: every group is born live (AddAuraGroup with a real
    -- filter) and creation never seeds this flag. Without the `or false`, the
    -- first unpark call on a never-parked group fell through the guard and
    -- cleared its creation-time candidateFilters to {} (PTR-observed: debuff
    -- category presets widened to ALL debuffs on the 2nd Layout pass) while
    -- also paying a spurious UpdateAllAuras engine re-evaluation.
    local prevDormant = c._bf_dormantGroups[groupKey]
    if (prevDormant or false) == dormant then return end
    c._bf_dormantGroups[groupKey] = dormant
    -- Unparking clears to an empty candidate set; callers that use
    -- candidateFilters while live (custom containers' includeSpellIDs)
    -- re-apply their own set immediately after unparking.
    --
    -- v94 FIX: pcall'd, with the flag ROLLED BACK on refusal. This was the only
    -- unprotected engine call in the function, and BF's belief was already
    -- written on the line above it. A denial (restricted / secret-aura window)
    -- therefore left the engine holding DORMANT_CANDIDATES while BF recorded the
    -- group as LIVE -- and because the error escaped an un-pcall'd call site in
    -- ApplyPresetGroups, it also skipped that group's candidate re-apply, the
    -- rest of the preset loop and the stale sweep. Rolling back keeps BF and the
    -- engine in step, so the next pass simply retries the transition.
    if not pcall(c.SetAuraGroupCandidateFilters, c, groupKey,
                 dormant and DORMANT_CANDIDATES or {}) then
        c._bf_dormantGroups[groupKey] = prevDormant
        return
    end
    -- See SetAuraGridGroupFilter: force re-evaluation of existing
    -- assignments (change-guarded above).
    pcall(c.UpdateAllAuras, c)
end

-- aurasAbovePowerBar lift: bottom-anchored aura grids anchor to the
-- health bar's clip frame while the power bar is shown. Mirrors the
-- legacy gate exactly (AuraGroupHelpers isBottomAnchor +
-- _bf_auraAnchorTarget = healthBar.clipFrame or healthBar). Reads live
-- IsShown (not _bf_powerBarShown — PowerBar:Update refreshes that flag
-- AFTER the aura re-anchor hook fires).
function BF.AuraLiftAnchorFrame(frame, ac, anchor)
    if ac and ac.aurasAbovePowerBar
       and frame.powerBar and frame.powerBar:IsShown() and frame.healthBar
       and (anchor == "BOTTOM" or anchor == "BOTTOMLEFT" or anchor == "BOTTOMRIGHT") then
        return frame.healthBar.clipFrame or frame.healthBar
    end
    return nil
end

-- Apply/refresh live geometry + group options (safe to call repeatedly;
-- runs from the feature's Layout). Does NOT touch button visuals.
function BF:ApplyAuraGridGeometry(frame, featureKey, geo)
    local c = frame._bf_auraContainers and frame._bf_auraContainers[featureKey]
    if not c then return end

    local grow = GROW_MAP[geo.growDirection or "RIGHT_DOWN"] or GROW_MAP.RIGHT_DOWN
    local anchor = (geo.anchor and geo.anchor ~= "") and geo.anchor or "CENTER"
    -- Wrap boundary: perRow×size + (perRow−1)×spacing.
    -- PTR-VERIFY (V14): units are assumed to be pixels.
    local perRow = math.max(1, geo.perRow or 5)
    local size   = geo.size or 24
    local spacing = geo.spacing or 1
    -- geo.lineSizeSlack (v54 enlarged debuff groups): the wrap boundary
    -- is PIXEL-based, so one 1.5x icon ate the perRow budget and wrapped
    -- a row one icon early. The slack admits ONE enlarged icon alongside
    -- (perRow-1) regulars; it can never admit an extra REGULAR icon
    -- (slack of half an icon < icon + gap). Rows with several enlarged
    -- icons still wrap early — accepted (Blizzard's chain layout has the
    -- same pixel-budget character).
    -- + ONE PHYSICAL PIXEL of tolerance (owner report 2026-09-11: Max 5 /
    -- per row 3, a single buff anchored at position 1 -- the third icon
    -- wrapped). With an anchored entry the row's content is exactly
    -- entry + (perRow-1) regulars + gaps = this budget to the pixel, and the
    -- entry's size (base x eSize/base, pixel-rounded on its own) can land a
    -- fraction over, so the engine's fit test wrapped the last icon. A pixel
    -- absorbs that and can never admit an extra REGULAR icon (that needs a
    -- whole icon plus a gap).
    local lineSize = perRow * size + (perRow - 1) * spacing
        + (geo.lineSizeSlack or 0)
        + (BF.PixelsToUI and BF:PixelsToUI(1) or 1)
    -- v92 PERF: the four flow-layout setters are change-guarded with one
    -- scalar signature, matching the v86 guards on the max-count and
    -- layout-table pushes below (~6 engine calls x ~5 containers x ~45
    -- frames of redundant pushes per full Layout sweep when nothing moved).
    -- Every input is addon-side config.
    local flowSig = (geo.growDirection or "RIGHT_DOWN") .. "|" .. anchor
        .. "|" .. lineSize
    if c._bf_flowSig ~= flowSig then
        c._bf_flowSig = flowSig
        c:SetFlowLayoutAxis(grow.axis)
        c:SetFlowLayoutGrowthDirection(grow.h, grow.v)
        c:SetFlowLayoutAnchorPoint(anchor)
        c:SetFlowLayoutMaximumLineSize(lineSize)
    end

    -- Live icon-size (V3 path). elementWidth/Height alone was PTR-confirmed
    -- to size only the layout CELLS (buttons keep their baked size — looks
    -- like grown spacing), so the buttons themselves must be SetSize-d:
    -- walk each group's pool (GetAuraGroupFrameCount = pool size, not
    -- visible count) and resize out of combat. pcall guards the V3
    -- unknown (DenyTaintedAccessWhenAurasAreSecret implies native calls
    -- are allowed while auras aren't secret — unverified). On denial:
    -- leave baked sizes fully intact (no spec mutation, no element
    -- overrides) → reload-only, per the plan's V3 fallback.
    -- Change-guarded by c._bf_curButtonSize: the walk runs only when the
    -- size setting actually changed, never on routine Layout passes.
    -- PTR-VERIFY: SetSize callability post-PEW; buttons pool-created
    -- later inherit the new size via the mutated c._bf_buttonSpec.
    local sizeOK = true
    -- Did the button size actually change this pass? Drives the same forced
    -- engine rebuild that maxChanged does (see the UpdateAllAuras note below):
    -- SetSize + a fresh SetAuraGroupLayout(elementWidth) do NOT make the
    -- container re-flow its ALREADY-displayed icons on their own, so a
    -- size-only edit sat committed on our side yet unrendered by the engine
    -- until the next UNIT_AURA or an UNRELATED edit forced a rebuild -- the
    -- "Icon Size applies one edit behind" report. Change-guarded like the
    -- resize itself, so routine Layout passes never rebuild.
    local sizeChanged = false
    local walkSize = (c._bf_curButtonSize ~= size)
    -- 2026-09-11 (restricted recreate, plan §3.1; field report 2026-09-10):
    -- inside a keystone every post-creation SetSize on a pooled button is
    -- denied (verified in game: writes to a button after AddAuraGroup returned
    -- are refused), so this walk used to pay a denied pcall per pass, commit
    -- nothing and retry forever. In the recreate window, ask for a rebuilt
    -- container instead -- the new one is born at the new size inside its
    -- initializeFrame window -- and skip the walk entirely. sizeOK = false
    -- keeps cells at the baked size for this pass, exactly as a denied walk
    -- did. Outside the window nothing changes.
    if walkSize and self:IsAuraCreationRestricted() and self:IsAuraRecreateWindow() then
        self:RequestAuraRecreate(frame, "container", featureKey,
            "size:" .. tostring(c._bf_curButtonSize) .. ">" .. tostring(size)
            .. " grid:" .. tostring(c._bf_curGridTag) .. ">"
            .. (BF.PixelGridTag and BF:PixelGridTag() or "?"))
        walkSize = false
        sizeOK = false
    end
    if walkSize then
        for _, gk in ipairs(c._bf_groupKeys) do
            local gkSpec = (c._bf_groupSpecs and c._bf_groupSpecs[gk]) or c._bf_buttonSpec
            -- Enlarged groups (v54: enlarge*Debuffs) scale off the shared
            -- size by their spec's multiplier.
            local gSize = size * ((gkSpec and gkSpec._bf_sizeMult) or 1)
            local n = c:GetAuraGroupFrameCount(gk) or 0
            for i = 1, n do
                local b = c:GetAuraGroupFrame(gk, i)
                if b and not pcall(b.SetSize, b, gSize, gSize) then
                    sizeOK = false
                    break
                end
                -- Re-size the presence-glow ring + ants geometry
                -- (proportional to the button).
                if b and (b._bf_glowTex or b._bf_antsTex) then
                    pcall(ApplyGlowGeometry, b, gSize)
                end
                -- Re-stamp icon/cooldown insets: they are pixel offsets
                -- derived from the button size (v49: the blizz-mode
                -- swipe inset is proportional).
                if b and b._bf_icon and gkSpec then
                    pcall(ApplyBorderInsets, b, gkSpec)
                end
                -- Square (Color by Duration): glyph scale AND rect follow
                -- the button size (offsets live in the scaled space).
                if b and b._bf_duration and gkSpec and gkSpec.durationSquare then
                    ApplySquareGlyphGeometry(b, gkSpec, gSize)
                end
            end
            if not sizeOK then break end
        end
        if sizeOK then
            c._bf_curButtonSize = size
            sizeChanged = true
            if c._bf_buttonSpec then c._bf_buttonSpec.size = size end
            -- v43: per-spell group specs follow the shared size too
            -- (scaled by the enlarge multiplier where one is set).
            if c._bf_groupSpecs then
                for _, s in pairs(c._bf_groupSpecs) do
                    s.size = size * (s._bf_sizeMult or 1)
                end
            end
        end
    end

    local maxChanged = false
    for _, gk in ipairs(c._bf_groupKeys) do
        -- v43: per-spell groups own their maxFrameCount (1) — don't stomp
        -- it with the feature-wide maxIcons.
        local ownMax = c._bf_groupOwnMax and c._bf_groupOwnMax[gk]
        local wantMax = ownMax or geo.maxIcons or 1
        -- v77: the cap ROSE above what we styled at creation, so the extra
        -- buttons are now displayable and must be styled.
        --
        -- Deliberately tested BEFORE and INDEPENDENTLY of the _bf_curGroupMax
        -- guard below: that guard records the new value up front, so folding
        -- the top-up into it would lose the shortfall permanently on any pass
        -- where the top-up was refused (combat / secret-aura window). Tested
        -- every pass instead, so a refused top-up simply retries on the next
        -- geometry pass once the restriction lifts.
        local styledN = c._bf_groupStyled and c._bf_groupStyled[gk]
        if styledN and wantMax > styledN then
            -- v98 PERF: the top-up is DEFERRED off the layout pass. It was
            -- ~155 ms of InitAuraButton inside a 532 ms raid-join stall
            -- (482 buttons, one-shot per group per session). Until the
            -- group's pool is fully styled the pushed cap stays CLAMPED at
            -- the styled count, so the engine can never display an unstyled
            -- button; the drain re-pushes the real cap + UpdateAllAuras.
            QueueTopUp(c, gk, wantMax)
            wantMax = styledN
        end
        -- v86 PERF: the setter used to sit OUTSIDE this guard, so every
        -- Layout pass re-pushed an unchanged integer for every group of
        -- every container — ~70 engine calls per unit frame, ~4900 per
        -- layout reload. _bf_curGroupMax is written nowhere else and groups
        -- are never removed from a container (they are made dormant, see
        -- SetAuraGridGroupDormant), so the recorded value is by construction
        -- exactly what was last pushed for this key. Note the TopUpGroupStyling
        -- test above deliberately stays outside and ahead of this guard —
        -- see its comment; folding it in would lose a refused top-up.
        c._bf_curGroupMax = c._bf_curGroupMax or {}
        if c._bf_curGroupMax[gk] ~= wantMax then
            c._bf_curGroupMax[gk] = wantMax
            maxChanged = true
            c:SetAuraGroupMaxFrameCount(gk, wantMax)
        end

        -- v86 PERF: same story one step further. The layout table below is a
        -- fresh allocation pushed unconditionally on every pass — another ~70
        -- tables and ~70 engine calls per unit frame, and NONE of its inputs
        -- (spacing, rowSpacing, flow order, cell size) depend on the frame's
        -- width or height, which is the only thing that changed when a
        -- context flip dispatches this. Build a scalar signature first and
        -- skip the whole block when it matches what we last pushed.
        --
        -- Correctness against the three out-of-band pushers
        -- (EnsureAuraGridSpellGroup's reorder arm, SetAuraGridGroupLayoutIndex,
        -- ApplyAuraGridGroupSize): each of them wipes this cache entry after
        -- pushing, so the next geometry pass always re-asserts the full table
        -- rather than trusting a signature that describes a value the engine
        -- no longer holds. The v43 "layout tables may replace rather than
        -- merge" rule is unaffected — when we do push, we still push in full.
        local gkSpecL = c._bf_groupSpecs and c._bf_groupSpecs[gk]
        local cell = sizeOK and (size * ((gkSpecL and gkSpecL._bf_sizeMult) or 1)) or nil
        local li   = c._bf_groupLayoutIndex and c._bf_groupLayoutIndex[gk]
        local lsig = spacing .. "|" .. (geo.rowSpacing or 1)
                  .. "|" .. (li or -1) .. "|" .. (cell or -1)
        c._bf_curLayoutSig = c._bf_curLayoutSig or {}
        if c._bf_curLayoutSig[gk] ~= lsig then
            c._bf_curLayoutSig[gk] = lsig
            local layout = {
                elementSpacing = spacing,
                lineSpacing = geo.rowSpacing or 1,
                -- groupSpacing: engine default 0 (see EnsureAuraGridContainer).
            }
            -- v43: re-include the recorded flow order on every layout push
            -- (layout tables may replace rather than merge — PTR-VERIFY).
            if li then
                layout.layoutIndex = li
            end
            if sizeOK then
                -- Keep layout cells in lockstep with the (now-applied) button
                -- size; omitted entirely when the resize was denied so cells
                -- fall back to the buttons' natural (baked) size.
                -- v54: PER-GROUP — an enlarged group's cells must match its
                -- multiplied button size. Base-sized cells under 1.5x
                -- buttons was PTR-observed as big icons overlapping the
                -- neighboring group.
                layout.elementWidth = cell
                layout.elementHeight = cell
            end
            c:SetAuraGroupLayout(gk, layout)
        end
    end

    -- Max-count change: SetAuraGroupMaxFrameCount alone was PTR-observed
    -- NOT to re-evaluate which auras display (Max Buffs edits did
    -- nothing). UpdateAllAuras schedules the engine's documented full
    -- rebuild on the next OnUpdate (the same mechanism the filter
    -- setters trigger internally). Change-guarded so routine Layout
    -- passes never rebuild; this path runs out of combat.
    --
    -- sizeChanged rides the SAME rebuild: an Icon Size edit resizes the
    -- pooled buttons and pushes a new elementWidth, but the container does
    -- not re-flow its currently-displayed icons off those on its own, so the
    -- new size did not render until the next UNIT_AURA or an unrelated edit
    -- happened to force a rebuild ("applies one edit behind"). Both flags are
    -- change-guarded, so a Layout with neither a size nor a max change still
    -- pays nothing.
    if maxChanged or sizeChanged then
        pcall(c.UpdateAllAuras, c)
    end

    -- Anchor target resolution: aurasAbovePowerBar lift when geo.canLift
    -- (bottom anchor + power bar shown → health bar clipFrame), else an
    -- explicit geo.anchorFrame, else the unit frame. geo is retained on
    -- the container so ReanchorFrameAuraContainers can re-resolve the
    -- lift when the power bar shows/hides without a full Layout.
    c._bf_lastGeo = geo
    local target = (geo.canLift and BF.AuraLiftAnchorFrame(frame, BF:GetAuraCacheForFrame(frame), anchor))
        or geo.anchorFrame or frame
    -- v92 PERF: anchor push change-guarded on (point, target, x, y) — same
    -- sweep-churn class as the flow setters above. ReanchorAuraContainer
    -- (the power-bar lift hook) writes through its own path below and keeps
    -- these fields coherent, so a lift flip always re-anchors correctly.
    local ax, ay = geo.offsetX or 0, geo.offsetY or 0
    if c._bf_anchorPt ~= anchor or c._bf_anchorTo ~= target
       or c._bf_anchorX ~= ax or c._bf_anchorY ~= ay then
        c._bf_anchorPt, c._bf_anchorTo, c._bf_anchorX, c._bf_anchorY
            = anchor, target, ax, ay
        c:ClearAllPoints()
        c:SetPoint(anchor, target, anchor, ax, ay)
    end
end

-- Power-bar show/hide hook: re-resolve the lift target for every grid
-- container on the frame using its last-applied geometry. pcall-guarded:
-- power-bar visibility can flip in combat (V12 — container SetPoint
-- callability while combat-locked is unverified; on denial the anchor
-- corrects on the next out-of-combat Layout).
-- v53 PHASE 3 (report R6): hoisted out of the pcall below so the guard
-- costs no closure. Semantics unchanged.
local function ReanchorAuraContainer(c, anchor, target, geo)
    -- v92: keep the ApplyAuraGridGeometry anchor guard coherent — this hook
    -- re-resolves the lift target outside that function.
    c._bf_anchorPt, c._bf_anchorTo = anchor, target
    c._bf_anchorX, c._bf_anchorY = geo.offsetX or 0, geo.offsetY or 0
    c:ClearAllPoints()
    c:SetPoint(anchor, target, anchor,
        geo.offsetX or 0, geo.offsetY or 0)
end
function BF:ReanchorFrameAuraContainers(frame)
    local t = frame and frame._bf_auraContainers
    if not t then return end
    local ac = BF:GetAuraCacheForFrame(frame)
    for _, c in pairs(t) do
        local geo = c._bf_lastGeo
        if geo and not c._bf_isSlotVisual then
            local anchor = (geo.anchor and geo.anchor ~= "") and geo.anchor or "CENTER"
            local target = (geo.canLift and BF.AuraLiftAnchorFrame(frame, ac, anchor))
                or geo.anchorFrame or frame
            pcall(ReanchorAuraContainer, c, anchor, target, geo)
        end
    end
end

-- v53 PHASE 3 (report R6): the per-button bodies of the two restyle
-- walls, lifted out of the pcall calls below. The WALLS stay -- they are
-- BF's house pattern and the only thing that keeps a denied 12.1 setter
-- from leaving half a button restyled -- but they no longer allocate a
-- closure per button per walk. Abort-on-denial semantics are byte-for-
-- byte the same: any error raised by a step propagates to the caller's
-- pcall exactly as before, and ApplyIconEffects still swallows its own
-- (see its note) so the alert step can never cancel the commit.
--
-- The inner pcalls inside these steps were AUDITED and KEPT (see the
-- Phase 3 note in Docs/Aura_Performance_Investigation.md): every one of
-- them either guards a call class that is also reached from the
-- unwalled InitAuraButton path (ApplyIconEffects, ApplyGlow) or has
-- tolerated-denial semantics the wall would convert into a full-walk
-- abort (ApplySolidIcon's SetIcon rebinds, which are documented as
-- "on denial the switch completes on reload").
-- v98: tooltip-placement-only restyle. groupKey nil = the container's
-- base-spec groups (every group WITHOUT its own spec, exactly the set the
-- full walk in ApplyAuraGridButtonSpec covers); a groupKey = that group
-- only. Returns false on the first denied setter (nothing committed).
local function TooltipOnlyWalk(c, newSpec, groupKey)
    local keys = groupKey and { groupKey } or c._bf_groupKeys
    for _, gk in ipairs(keys) do
        if groupKey or not (c._bf_groupSpecs and c._bf_groupSpecs[gk]) then
            local n = c:GetAuraGroupFrameCount(gk) or 0
            for i = 1, n do
                local b = c:GetAuraGroupFrame(gk, i)
                if b and b._bf_icon then
                    if not pcall(ApplyTooltipStyle, b, newSpec) then return false end
                end
            end
        end
    end
    return true
end

local function RestyleButton(b, spec)
    ApplyBorderMode(b, spec)
    ApplyBorderStyle(b, spec)
    ApplyBorderInsets(b, spec)
    ApplyDispelBorderBinding(b, spec)
    ApplyDispelTypeIcon(b, spec)
    ApplyCooldownStyle(b, spec)
    ApplyDurationTextStyle(b, spec)
    BindDurationText(b, spec)
    ApplyStackCountStyle(b, spec)
    ApplyTooltipStyle(b, spec)
    ApplyGlow(b, spec)
    ApplyIconEffects(b, spec)
end
-- Per-spell variant: identical order plus ApplySolidIcon (per-spell icon
-- types), matching ApplyAuraGridGroupButtonSpec's original inline body.
local function RestyleButtonWithSolidIcon(b, spec)
    ApplyBorderMode(b, spec)
    ApplyBorderStyle(b, spec)
    ApplyBorderInsets(b, spec)
    ApplyDispelBorderBinding(b, spec)
    ApplyDispelTypeIcon(b, spec)
    ApplySolidIcon(b, spec)
    ApplyCooldownStyle(b, spec)
    ApplyDurationTextStyle(b, spec)
    BindDurationText(b, spec)
    ApplyStackCountStyle(b, spec)
    ApplyTooltipStyle(b, spec)
    ApplyGlow(b, spec)
    ApplyIconEffects(b, spec)
end

-- Style signature: cheap change-guard so the restyle walk only runs
-- when a style-relevant setting actually changed. Curve identity stands
-- in for the threshold settings baked into the curve (cache rebuilds
-- create fresh curve objects — settings-driven, out of combat).
-- v86 DIAG: restyle hit/miss census, read by the /bf join harness. Answers
-- the one question the timings cannot: when ApplyAuraGridButtonSpec and its
-- per-group twin run, are they short-circuiting on an unchanged signature, or
-- doing the full 10-button x 12-applier restyle walk? "Miss" is not
-- automatically waste -- on a genuine party<->raid flat flip the spec really
-- does change and the walk is correct work -- but a high miss rate when
-- nothing visual changed means a guard is still broken.
-- Costs one boolean test per call when the harness is not collecting.
BF.restyleStatsOn = false
BF.restyleStats = BF.restyleStats or { hit = 0, miss = 0, groupHit = 0,
    groupMiss = 0, missCombat = 0, groupMissCombat = 0 }

-- (The v99 field census -- BUTTON_SPEC_SCALARS / BUTTON_SPEC_COLORS,
-- SpecSnapshotMatch, StoreSpecSnapshot -- lives above EnsureAuraGridContainer.)

-- Live button restyle (companion to the live-size path in
-- ApplyAuraGridGeometry). Called from each feature's Layout with a
-- freshly built buttonSpec; walks the pooled buttons and re-applies
-- duration text style/binding, cooldown draw toggles, border color and
-- tooltip settings. On success the container's stored buttonSpec is
-- updated IN PLACE (the initializeFrame closure captured that table, so
-- buttons pool-created later match). On denial (pcall) nothing is
-- mutated — baked styles stay consistent and the walk retries on the
-- next out-of-combat Layout. Stack text style IS covered now (see
-- ApplyStackCountStyle and the stack terms in ButtonSpecSig); the
-- dispel-border toggle is still baked.
function BF:ApplyAuraGridButtonSpec(frame, featureKey, newSpec)
    local c = frame._bf_auraContainers and frame._bf_auraContainers[featureKey]
    local spec = c and c._bf_buttonSpec
    if not spec then return end
    -- v99: ONE COMPLETE GUARD, replacing the v53 two-tier arrangement
    -- (cheap _cacheGen pre-guard -> expensive ButtonSpecSig string).
    --
    -- That arrangement existed only because building the signature was
    -- expensive enough to be worth an approximate check first. It is not any
    -- more: SpecSnapshotMatch compares the same census field by field with no
    -- allocation and an early exit, measured 2.4x faster than the string
    -- compare on a hit and ~100x on a miss. With the cost gone, the reason for
    -- an incomplete pre-guard goes with it.
    --
    -- What that buys beyond speed is the end of a whole bug class. The cheap
    -- guard's premise -- "every field of a feature buttonSpec is a pure
    -- function of the aura settings cache, which bumps _cacheGen" -- was false
    -- for any spec carrying container- or spell-level fields out of acDB /
    -- options storage, which bump nothing. Each discovery of another such
    -- field was a silent reload-only-edit bug, patched either by widening
    -- AC_SPEC_SCALARS (v92: container border + duration) or by nil-ing
    -- _bf_styleGen at the call site to defeat the guard entirely (v64: the bfc
    -- and single-buff restamps; the dbc restamp in DebuffIcons, which needed it
    -- for the 15 fields v92's widening still did not cover -- the whole v92
    -- per-container Icon Effect set among them). Comparing the FULL census
    -- makes every one of those fields guarded by construction: there is no
    -- longer a list to forget a field from, so both defeats are deleted at
    -- their call sites and _bf_styleGen / _bf_styleAC are gone.
    --
    -- The two tooltip fields stay outside the census for the v98 reason (see
    -- BUTTON_SPEC_SCALARS) and keep their own directly-compared pair.
    local tty, tpos = newSpec.tooltipFrameY, newSpec.tooltipPos
    local snap = c._bf_styleSig
    local snapHit, snapMiss = SpecSnapshotMatch(snap, newSpec)
    if snapHit then
        if BF.restyleStatsOn then BF.restyleStats.hit = BF.restyleStats.hit + 1 end
        -- v98: only the tooltip placement moved (frame height / tooltip
        -- position setting) -- re-anchor tooltips, nothing else. Denied ->
        -- leave the recorded pair stale so the next pass retries.
        if c._bf_styleTTY ~= tty or c._bf_styleTPos ~= tpos then
            if not self:IsAuraCreationRestricted() then
                if not TooltipOnlyWalk(c, newSpec, nil) then return end
                spec.tooltipPos, spec.tooltipFrameY = tpos, tty
            else
                -- Restricted: the walk is denied. Deliberately NOT a rebuild
                -- request (2026-09-11 first in-key run: every frame's bigDef
                -- and custom debuff container was rebuilt once on its first
                -- Layout for this alone -- the creation seed takes the frame
                -- height from the header, the Layout measures the frame, and
                -- a tooltip anchor is not worth an engine container). The
                -- pair stays uncommitted, so the key-end replay re-anchors
                -- the tooltips exactly as before.
                return
            end
        end
        c._bf_styleTTY, c._bf_styleTPos = tty, tpos
        return
    end
    -- v99 DIAG: split the miss by whether it could do anything about it. A
    -- restricted miss commits NOTHING (see the retry contract below), so it
    -- misses again on the very next pass and every pass after, for as long as
    -- the restriction lasts -- a whole boss fight. A stream of missCombat is
    -- that convergence hole, not churn; a stream of plain miss is churn.
    if BF.restyleStatsOn then
        if self:IsAuraCreationRestricted() then
            BF.restyleStats.missCombat = (BF.restyleStats.missCombat or 0) + 1
        else
            BF.restyleStats.miss = BF.restyleStats.miss + 1
        end
    end
    if self:IsAuraCreationRestricted() then  -- also skips while auras are engine-secret (ShouldAurasBeSecret); retried out of combat
        -- 2026-09-11 (restricted recreate, plan §3.1 / §3.2 A): inside a key
        -- the walk below would be denied on every button, so a restyle means a
        -- rebuilt container. Outside the recreate window: today's deferral.
        if self:IsAuraRecreateWindow() then
            self:RequestAuraRecreate(frame, "container", featureKey,
                "spec:" .. tostring(snapMiss or (snap == nil and "unseeded" or "?")))
        end
        return
    end
    -- v62 (plan 3.67 slice 2): a SINGLE BUFF's icon lives in its container's
    -- MAIN group, and its per-entry Icon Type ("Square"/"Bordered Square")
    -- arrives here as newSpec.solidIcon on the container-level spec -- a shape
    -- this walk never carried before (feature base specs have no solidIcon).
    -- RestyleButton omits ApplySolidIcon, so the walk styled everything BUT
    -- the solid icon: existing buttons kept the plain spell texture and only
    -- pool-created ones (initializeFrame) picked it up. Use the solid-aware
    -- walker when either side of the transition involves a solid icon (the
    -- old committed spec covers the revert back to "Icon"). All other
    -- callers pass specs with solidIcon nil on both sides and keep the exact
    -- previous walk.
    local restyle = (newSpec.solidIcon or spec.solidIcon)
        and RestyleButtonWithSolidIcon or RestyleButton
    for _, gk in ipairs(c._bf_groupKeys) do
        -- v43: per-spell groups carry their own spec — restyled separately
        -- via ApplyAuraGridGroupButtonSpec, never with the base spec.
        if not (c._bf_groupSpecs and c._bf_groupSpecs[gk]) then
        local n = c:GetAuraGroupFrameCount(gk) or 0
        for i = 1, n do
            local b = c:GetAuraGroupFrame(gk, i)
            if b and b._bf_icon then  -- only buttons our initializeFrame built
                local ok, wErr = pcall(restyle, b, newSpec)
                if not ok then
                    -- TEMP DIAGNOSTIC: silent aborts left settings dead
                    -- with no trace — surface the first error once.
                    if not BF._walkErrPrinted then
                        BF._walkErrPrinted = true
                        DevPrint("|cffff0000BuzzardFrames restyle error:|r", tostring(wErr))
                    end
                    return  -- denied: leave everything baked
                end
            end
        end
        end
    end
    -- All buttons restyled — commit: future pool-created buttons pick up
    -- the new style via the shared (closure-captured) spec table.
    -- size: the live-size path owns it.
    local keepSize = c._bf_curButtonSize or spec.size
    for k in pairs(spec) do spec[k] = nil end
    for k, v in pairs(newSpec) do spec[k] = v end
    spec.size = keepSize
    c._bf_styleSig = StoreSpecSnapshot(snap, newSpec)
    c._bf_styleTTY, c._bf_styleTPos = tty, tpos
end

-- v68: per-group live resize, for a group whose OWN size changed while the
-- container's shared size did not (Buffs-anchored single buffs: the entry's
-- Icon Size edits its spec._bf_sizeMult, never the Buffs size, so the
-- ApplyAuraGridGeometry resize walk -- change-guarded on c._bf_curButtonSize,
-- the CONTAINER size -- never fires for it).
--
-- The previous workaround (ApplySingleBuffGroups nilled c._bf_curButtonSize so
-- "the next geometry pass walks") applied every edit ONE REFRESH LATE:
-- BuffsAndContainers:Layout runs ApplyAuraGridGeometry BEFORE ApplyBuffFilters
-- -> ApplySingleBuffGroups (the same ordering the v67 layoutIndex note in
-- EnsureAuraGridSpellGroup records), so the pass that could see the new mult
-- had already resized with the OLD one, and the new value only rendered on the
-- NEXT refresh -- user-visible as the Icon Size slider "reverting" to a
-- previous value on release.
--
-- Body mirrors the ApplyAuraGridGeometry walk for ONE group: SetSize the
-- pooled buttons (plus glow + inset re-stamps), re-push the group layout in
-- FULL (layout tables replace rather than merge -- v43 note above), then force
-- the engine rebuild exactly as sizeChanged does there (SetSize + a fresh
-- elementWidth do NOT re-flow already-displayed icons on their own).
-- On SetSize denial: stop, leaving baked sizes intact (the V3 reload-only
-- fallback, same as the container-wide walk).
function BF:ApplyAuraGridGroupSize(frame, featureKey, groupKey)
    local c = frame._bf_auraContainers and frame._bf_auraContainers[featureKey]
    if not c then return end
    local spec = c._bf_groupSpecs and c._bf_groupSpecs[groupKey]
    local size = c._bf_curButtonSize or (c._bf_buttonSpec and c._bf_buttonSpec.size)
    if not (spec and size) then return end
    local gSize = size * (spec._bf_sizeMult or 1)
    local n = c:GetAuraGroupFrameCount(groupKey) or 0
    for i = 1, n do
        local b = c:GetAuraGroupFrame(groupKey, i)
        if b then
            if not pcall(b.SetSize, b, gSize, gSize) then return end
            if b._bf_glowTex or b._bf_antsTex then
                pcall(ApplyGlowGeometry, b, gSize)
            end
            if b._bf_icon then
                pcall(ApplyBorderInsets, b, spec)
            end
            -- Square (Color by Duration): glyph scale AND rect follow the
            -- entry's Icon Size (same re-stamp as the container-wide walk).
            if b._bf_duration and spec.durationSquare then
                ApplySquareGlyphGeometry(b, spec, gSize)
            end
        end
    end
    local lg = c._bf_lastGeo
    local layout = {
        elementSpacing = (lg and lg.spacing) or 1,
        lineSpacing    = (lg and lg.rowSpacing) or 1,
        elementWidth   = gSize,
        elementHeight  = gSize,
    }
    if c._bf_groupLayoutIndex and c._bf_groupLayoutIndex[groupKey] then
        layout.layoutIndex = c._bf_groupLayoutIndex[groupKey]
    end
    -- v86: out-of-band layout push — see EnsureAuraGridSpellGroup.
    if c._bf_curLayoutSig then c._bf_curLayoutSig[groupKey] = nil end
    pcall(c.SetAuraGroupLayout, c, groupKey, layout)
    pcall(c.UpdateAllAuras, c)
end

-- Per-spell-group variant of ApplyAuraGridButtonSpec (v43): same walk
-- and commit semantics, scoped to one group with its own spec table and
-- signature. Adds ApplySolidIcon to the walk (per-spell icon types).
function BF:ApplyAuraGridGroupButtonSpec(frame, featureKey, groupKey, newSpec)
    local c = frame._bf_auraContainers and frame._bf_auraContainers[featureKey]
    local spec = c and c._bf_groupSpecs and c._bf_groupSpecs[groupKey]
    if not spec then return end
    -- Square (Color by Duration): the glyph scale is derived from spec.size
    -- inside ApplyDurationTextStyle, but derive-fresh group specs carry the
    -- BASE container size — the AddAuraGroup / live-resize paths multiply by
    -- the entry's Icon Size (_bf_sizeMult) and this walk historically does
    -- not. Without this stamp a color-only restyle of an enlarged entry
    -- would shrink its square to base size. Scoped to durationSquare specs
    -- so every other spec keeps the walk's exact previous size semantics.
    if newSpec.durationSquare then
        local base = c._bf_curButtonSize
            or (c._bf_buttonSpec and c._bf_buttonSpec.size) or newSpec.size
        if base then newSpec.size = base * (newSpec._bf_sizeMult or 1) end
    end
    c._bf_groupStyleSigs = c._bf_groupStyleSigs or {}
    c._bf_groupStyleTT   = c._bf_groupStyleTT or {}
    -- v99 PERF: field-by-field compare against the stored snapshot instead of
    -- building a ButtonSpecSig string on every call. Same field census (see
    -- BUTTON_SPEC_SCALARS / BUTTON_SPEC_COLORS), same semantics, no allocation
    -- and an early exit on the first differing field. _bf_groupStyleSigs still
    -- holds one entry per group and is still cleared wholesale by
    -- BF:_WipeStyleGuards -- a nil entry misses and runs the full walk, exactly
    -- as a wiped string did. Snapshots are runtime-only, never serialized.
    local snap = c._bf_groupStyleSigs[groupKey]
    -- The tooltip pair as two stored scalars, not a concatenated key: same
    -- reason as the compare above, and the same shape the container twin uses
    -- (_bf_styleTTY / _bf_styleTPos).
    local tty, tpos = newSpec.tooltipFrameY, newSpec.tooltipPos
    local snapHit, snapMiss = SpecSnapshotMatch(snap, newSpec)
    if snapHit then
        if BF.restyleStatsOn then BF.restyleStats.groupHit = BF.restyleStats.groupHit + 1 end
        -- v98: tooltip placement only (see the BUTTON_SPEC_SCALARS note).
        local tt = c._bf_groupStyleTT[groupKey]
        if not tt or tt[1] ~= tty or tt[2] ~= tpos then
            if not self:IsAuraCreationRestricted() then
                if TooltipOnlyWalk(c, newSpec, groupKey) then
                    spec.tooltipPos, spec.tooltipFrameY = newSpec.tooltipPos, newSpec.tooltipFrameY
                    if not tt then tt = {}; c._bf_groupStyleTT[groupKey] = tt end
                    tt[1], tt[2] = tty, tpos
                end
            end
            -- Restricted: no rebuild for a tooltip anchor -- see the note in
            -- ApplyAuraGridButtonSpec's tooltip arm; the key-end replay owns it.
        end
        return
    end
    -- v99 DIAG: see the twin split in ApplyAuraGridButtonSpec -- a restricted
    -- miss commits nothing and therefore repeats every pass until regen.
    if BF.restyleStatsOn then
        if self:IsAuraCreationRestricted() then
            BF.restyleStats.groupMissCombat = (BF.restyleStats.groupMissCombat or 0) + 1
        else
            BF.restyleStats.groupMiss = BF.restyleStats.groupMiss + 1
        end
    end
    if self:IsAuraCreationRestricted() then  -- also skips while auras are engine-secret (ShouldAurasBeSecret); retried out of combat
        -- 2026-09-11 (restricted recreate, plan §3.2 A): rebuild the HOST
        -- container; see the tooltip arm above for why not the group.
        if self:IsAuraRecreateWindow() then
            self:RequestAuraRecreate(frame, "container", featureKey,
                "groupSpec:" .. tostring(groupKey) .. ":"
                .. tostring(snapMiss or (snap == nil and "unseeded" or "?")))
        end
        return
    end
    -- v71: per-group size multiplier (preset Relative Size). The container-level
    -- resize (ApplyAuraGridGeometry) only re-SetSizes buttons when the CONTAINER
    -- base size changes -- a per-group mult change on an existing group would
    -- otherwise leave the button frames at their old size. So when this group
    -- carries a mult, SetSize its buttons here (base × mult) as part of the same
    -- guarded restyle walk. mult == 1 groups keep the base size the geometry
    -- path already applied.
    -- v84: the test is "does this group CARRY a multiplier", not "is the
    -- multiplier != 1". The old `mult ~= 1` form could never shrink a group back
    -- DOWN to the base size: the container-wide resize is change-guarded on the
    -- CONTAINER size, which does not move when only a per-group Relative Size
    -- does, so a group edited from 1.4x to 1.0x kept 1.4x-sized buttons under
    -- 1.0x layout cells until a reload. Groups with no _bf_sizeMult at all keep
    -- the previous behavior exactly (gSize stays nil).
    local mult = newSpec._bf_sizeMult
    local gBase = c._bf_curButtonSize or (c._bf_buttonSpec and c._bf_buttonSpec.size)
    local gSize = (mult and gBase) and (gBase * mult) or nil
    local n = c:GetAuraGroupFrameCount(groupKey) or 0
    for i = 1, n do
        local b = c:GetAuraGroupFrame(groupKey, i)
        if b and b._bf_icon then
            local ok, wErr = pcall(RestyleButtonWithSolidIcon, b, newSpec)
            if not ok then
                if not BF._walkErrPrinted then
                    BF._walkErrPrinted = true
                    DevPrint("|cffff0000BuzzardFrames restyle error:|r", tostring(wErr))
                end
                return
            end
            if gSize then
                pcall(b.SetSize, b, gSize, gSize)
                if b._bf_glowTex or b._bf_antsTex then pcall(ApplyGlowGeometry, b, gSize) end
                if b._bf_icon then pcall(ApplyBorderInsets, b, newSpec) end
                -- v93: the glyph was MISSING from this walk (its two siblings
                -- at ~:2727 and ~:3204 both re-stamp it). A Relative Size edit
                -- moved the button, the border insets and the glow ring while
                -- the square kept a stale scale and anchor.
                if b._bf_duration and newSpec.durationSquare then
                    pcall(ApplySquareGlyphGeometry, b, newSpec, gSize)
                end
            end
        end
    end
    local keepSize = c._bf_curButtonSize or spec.size
    -- durationSquare AND any multiplied group: commit the MULTIPLIED size so the
    -- stored spec (read by later geometry/glyph passes) carries the final size,
    -- not the container base.
    if newSpec.durationSquare and newSpec.size then keepSize = newSpec.size end
    if gSize then keepSize = gSize end
    for k in pairs(spec) do spec[k] = nil end
    for k, v in pairs(newSpec) do spec[k] = v end
    spec.size = keepSize
    c._bf_groupStyleSigs[groupKey] = StoreSpecSnapshot(snap, newSpec)
    local tt = c._bf_groupStyleTT[groupKey]
    if not tt then tt = {}; c._bf_groupStyleTT[groupKey] = tt end
    tt[1], tt[2] = tty, tpos
end

-- ============================================================
-- SLOT VISUALS (single-aura displays: dispel border / overlay / dot,
-- the per-spell frame effects). The slot's AuraButton IS the visual —
-- we build its textures and anchor it manually (slots have no flow
-- layout); the engine shows/hides it with the matched aura.
--
-- v53 PERF (Phase 2): ONE SHARED SLOT CONTAINER PER UNIT FRAME.
-- Every slot visual used to own a private AuraContainer holding a
-- single slot "v": the three dispel styles, THREE PER CUSTOMIZED SPELL,
-- and four more for the Resto Druid set — on every one of the 40-120
-- pre-created unit frames. Nothing about a slot is container-scoped
-- (slots do no layout; filter, candidates and sort are per slot key),
-- so they all now live on ONE container per frame,
-- frame._bf_auraContainers.slots, keyed by featureKey — which is
-- already unique per feature / per spell / per effect type. The one
-- thing lost is the per-container frame-level lift, replaced by a
-- per-button SetFrameLevel carrying the same offset.
--
-- Per-slot state lives in frame._bf_auraSlots[featureKey] (the "slot
-- record"), which every slot API below takes and returns:
--   c              the hosting container (shared, or private in the
--                  fallback mode below)
--   key            slot key inside that container
--   _bf_slotButton the slot's AuraButton (field named for the
--                  pre-Phase-2 idiom the restamp helpers still use)
--   level          frame-level offset from the unit frame
--   filter         current filter string (change guard)
--   cand           the slot's OWN candidateFilters (fx include sets),
--                  restored whenever the slot is unparked
--   shown/parked   feature visibility gate / staleness gate; the slot
--                  is dormant unless both say otherwise
--
-- PTR-VERIFY (Phase 2, HIGH): the engine must be able to assign the
-- SAME aura to more than one slot of ONE container — all three dispel
-- styles pointed at the same debuff, or health tint + border + overlay
-- on the same customized spell. Within-container auto-dedup was assumed
-- during the migration, but the OPPOSITE was later PTR-CONFIRMED for
-- groups (a secondary debuff group parked with a matching filter
-- DUPLICATED every debuff — see DORMANT_CANDIDATES above), and slots
-- are expected to behave the same way. If a shared slot is ever seen
-- stealing the aura from its neighbor, set
-- BF._sharedSlotContainers = false and /reload: that restores one
-- container per slot visual and changes nothing else.
-- PTR-VERIFY: AddAuraSlot on a container that is ALREADY live (has a
-- unit and other slots) — the fx slots of a spell customized
-- mid-session take that path.
-- PTR-VERIFY: AuraButton:SetFrameLevel post-PEW (the reference
-- implementation calls it inside initializeFrame). On denial the first
-- failure prints once and every slot visual renders at the shared
-- container's level.
-- ============================================================
BF._sharedSlotContainers = true

-- The shared container sits at the lowest offset any slot uses (v59: the
-- per-spell health color tint, +1 — it took that spot from the
-- non-priority frame-effect overlay when the tint was moved below both
-- overlays; see FX_LEVEL_* in Indicators/BuffsAndContainers.lua). Every
-- button lifts itself from there to its own legacy offset.
local SLOT_CONTAINER_LEVEL = 1

-- Never mutated: the "no restriction" candidate set (unparked slots
-- with no include set of their own).
local EMPTY_CANDIDATES = {}

-- Per-button frame level in shared mode; per-container lift in the
-- fallback mode (exactly the pre-Phase-2 behavior).
-- The +1 is NOT cosmetic: a pool-created AuraButton is a child of its
-- container and therefore rendered one level above it, so a private
-- container lifted to parent+N put its button at parent+N+1. The
-- shared container sits at the bottom of the stack, so each button has
-- to reproduce that level itself or every slot visual drops one level
-- — which for the lane floor (the non-prioritised buff health tint,
-- offset 1 — v92: the lowest offset any slot uses) would TIE it with
-- the health bar and render it under the bar fill (the exact bug the
-- dispel overlay's "+2" comment records).
-- v84 (Stage 5 §9.7/§9.8): PER-KIND LEVEL HOSTS.
-- A MERGED slot carries several visual kinds that used to own a slot each, and
-- those kinds sat at different frame levels. One button cannot be at three
-- levels, so nothing renders on the merged button itself: every kind's regions
-- live on a child host Frame of the button whose level is ABSOLUTE --
-- frame:GetFrameLevel() + <that kind's offset> + 1, i.e. byte-for-byte the
-- level the kind's own slot button used to get from the math below.
--
-- Absolute (not relative to the button) is the load-bearing part: the button's
-- own level is then an inert base, so moving it -- which the fx "Prioritise"
-- path does -- can never cascade into the other kinds sharing the button. Each
-- host is re-stamped from exactly here, so a parent-frame level change reaches
-- hosts and button together.
local function StampSlotLevelHosts(s)
    local hosts = s.hosts
    if not hosts then return end
    local base = s.frame:GetFrameLevel()
    for _, h in pairs(hosts) do
        local want = base + h._bf_levelOffset + 1
        if h._bf_curLevel ~= want then
            if pcall(h.SetFrameLevel, h, want) then h._bf_curLevel = want end
        end
    end
end

-- ============================================================
-- v88c: DENIAL LEDGER
--
-- Every engine call on the slot path is pcall'd, deliberately -- a denied 12.1
-- setter must not take the frame down. The cost of that wall is that a denial
-- is INVISIBLE: no error, no trace, and the display is simply wrong until
-- something re-applies it. Three fixes were attempted for this bug on three
-- different theories about WHICH call was being denied, and all three were
-- guesses, because the code destroys the evidence at every site.
--
-- So the wall now keeps a receipt. Each protected call records its own name and
-- whether the restriction was up at the time, and /bf sbdiag prints the tally.
-- One reproduction then names the failing call outright instead of another
-- round of reasoning from the source.
--
-- Cost is nil on the success path (the recorder is only reached from the
-- already-exceptional `not ok` branch), and the tables are only allocated once
-- something has actually failed.
-- ============================================================
-- v88j: the ledger and the creation-window traces are OFF by default and
-- toggled by `/bf slotdiag` (persisted in db.global.slotDiagEnabled, because
-- the evidence has to be captured during a combat /reload -- a session-only
-- flag would be gone by the time it mattered).
--
-- Resolved once per session rather than cached at load: this file loads before
-- the DB does. The toggle writes both the saved value and this cache, so a flip
-- takes effect immediately without a reload.
function BF:IsSlotDiagEnabled()
    local v = self._slotDiag
    if v == nil then
        v = (self.db and self.db.global and self.db.global.slotDiagEnabled)
            and true or false
        self._slotDiag = v
    end
    return v
end

function BF:NoteSlotCallFail(name, err)
    -- Gate FIRST: with diag off nothing is allocated and nothing is formatted,
    -- so BF:SlotCall below is a bare pcall plus one `not ok` test -- byte-for-
    -- byte the cost of the plain pcall this code replaced.
    if not self:IsSlotDiagEnabled() then return end
    local t = self._slotFails
    if not t then t = {}; self._slotFails = t end
    local key = name .. (self:IsAuraCreationRestricted() and " [restricted]" or " [free]")
    t[key] = (t[key] or 0) + 1
    if not self._slotFailFirst then
        self._slotFailFirst = key .. " :: " .. tostring(err)
    end
end

-- Protected call + ledger entry, for the slot path's engine calls. Returns the
-- same truthiness pcall does, so it drops into every existing `if pcall(...)`
-- site without changing behavior.
function BF:SlotCall(name, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then self:NoteSlotCallFail(name, err) end
    return ok
end

local function ApplySlotFrameLevel(s)
    local off = s.level
    if not off then return end
    if not s.c._bf_sharedSlots then
        BF:SlotCall("container:SetFrameLevel", s.c.SetFrameLevel, s.c,
            s.frame:GetFrameLevel() + off)
        StampSlotLevelHosts(s)
        return
    end
    local btn = s._bf_slotButton
    if not btn then return end
    local ok, err = pcall(btn.SetFrameLevel, btn, s.frame:GetFrameLevel() + off + 1)
    if not ok then
        BF:NoteSlotCallFail("button:SetFrameLevel", err)
        if not BF._slotLevelErrPrinted then
            BF._slotLevelErrPrinted = true
            DevPrint("|cffff0000BuzzardFrames aura slot level error:|r", tostring(err))
        end
    end
    StampSlotLevelHosts(s)
end
BF.StampSlotLevelHosts = StampSlotLevelHosts

-- The shared container is shown while at least one of its slots is
-- live (and the frame isn't running preview dummies). A hidden
-- container never gets a unit — same rule SyncAuraGridContainer uses.
local function SlotContainerShown(s)
    local c = s.c
    local frame = s.frame
    local want = ((c._bf_activeSlots or 0) > 0)
        and not frame._bf_containersSuspended
    if c._bf_shown ~= want then
        c._bf_shown = want
        c:SetShown(want)
    end
    -- PERF: enabled tracks shown at every flip site (this is the one writer
    -- of the shared slot container's shown state — it flips from layout
    -- transitions and slot activity too, not just SyncAuraSlotVisual, so the
    -- enable lives here rather than only in that recovery arm; the arm's
    -- duplicate then no-ops on its `_bf_enabled == false` guard). Hidden =
    -- parked DISABLED, same rationale as SyncAuraGridContainer's park arm:
    -- a shown-false container still costs engine-side candidate evaluation
    -- per aura update on its bound unit unless disabled. Both arms are
    -- change-guarded to one table read in steady state.
    --
    -- The park half is OUT OF COMBAT ONLY, for the reason spelled out at
    -- SyncAuraGridContainer's park arm (a refused setter turns into a retry
    -- loop on the aura hot path, and the Grid2 precedent the park was
    -- justified with does not say what it was read as saying). The re-enable
    -- half is NOT guarded: it must be able to run whenever a slot comes back,
    -- and it only ever runs against a flag this guarded park set, so it can
    -- never strand a container disabled.
    if want then
        if c._bf_enabled == false and pcall(c.SetEnabled, c, true) then
            c._bf_enabled = true
            pcall(c.UpdateAllAuras, c)
        end
    -- The suppression term carries the SAME RULE as the grid park arm, in
    -- full force: a slot host hidden while its unit is hostile/charmed is
    -- NEVER parked. Transient state, seconds long, and the exit edge has to
    -- bring every fx / dispel / single-buff slot back at once. Read the
    -- "NEVER PARK A TRANSIENT STATE" block at SyncAuraGridContainer before
    -- touching either term. (Here the test can also decline a park the slot
    -- count alone would have earned, when a suppressed unit's host happens to
    -- empty at the same moment -- that is the safe direction and is not worth
    -- a second predicate to avoid.)
    elseif c._bf_enabled ~= false and not InCombatLockdown()
        and not IsUnitAuraSuppressed(frame.unit)
        and pcall(c.SetEnabled, c, false) then
        c._bf_enabled = false
    end
    -- The alpha this path never wrote. The shared slot container sits in the
    -- same frame._bf_auraContainers table as the grid containers, so the grid
    -- sweeps drop ITS alpha to 0 whenever the union says hidden — including
    -- the moment a layout transition takes _bf_activeSlots to 0 — and the
    -- change-guard then keeps it at 0 forever, because nothing here ever
    -- raised it back. Same function the grid path uses; see the header block.
    ApplyContainerVisAlpha(c, frame.unit, want)
    return want
end

-- Slots can't be removed, so a slot that is switched off (feature
-- gated / stale spell) is parked with the FULL park idiom RetireSlotKey
-- already uses on abandoned keys: a candidate set nothing can match PLUS a
-- blanked filter string. The blank is what makes a parked slot genuinely
-- free: candidate filters are plain Lua evaluated per candidate aura per
-- slot, so DORMANT_CANDIDATES alone still paid that evaluation just to fail
-- it, on every aura update, for as long as any OTHER slot kept the shared
-- container enabled. An empty filter string short-circuits ahead of all of
-- it ("" = match nothing -- production-verified by the v83 single-buff slot
-- release path and RetireSlotKey). s.filter stays on the record while
-- parked; unpark restores both it and s.cand.
-- dormantApplied commits only when BOTH setters succeed and stays nil on
-- any denial, so the next Update retries the pair -- same contract as
-- before, now covering two calls.
local function ApplySlotDormancy(s)
    local dormant = not s.active
    if s.dormantApplied == dormant then return end
    local c = s.c
    if not BF:SlotCall("SetAuraSlotCandidateFilters(dormancy)",
            c.SetAuraSlotCandidateFilters, c, s.key,
            dormant and DORMANT_CANDIDATES or (s.cand or EMPTY_CANDIDATES)) then
        s.dormantApplied = nil
        return
    end
    if not BF:SlotCall("SetAuraSlotFilterString(dormancy)",
            c.SetAuraSlotFilterString, c, s.key,
            dormant and "" or (s.filter or "HELPFUL")) then
        s.dormantApplied = nil
        return
    end
    s.dormantApplied = dormant
    -- Option setters do NOT re-evaluate existing assignments
    -- (PTR-observed) — force the engine's rebuild. Change-guarded
    -- above: this runs on feature/staleness edges only, never per
    -- update. NOTE it rebuilds every slot on the shared container;
    -- that is the price of consolidation and is why the guard matters.
    pcall(c.UpdateAllAuras, c)
end

local function UpdateSlotActive(s)
    local active = (s.shown and not s.parked) and true or false
    if s.active == active then return end
    s.active = active
    local c = s.c
    c._bf_activeSlots = (c._bf_activeSlots or 0) + (active and 1 or -1)
    ApplySlotDormancy(s)
    SlotContainerShown(s)
end

-- ============================================================
-- v88: SLOT CREATION IS FALLIBLE, AND FAILURE MUST NOT LATCH.
--
-- The bug this block exists to prevent (owner-reported, raid, 2026-08-18): a
-- /reload taken in combat lands INSIDE the secret-aura window with
-- DenyTaintedAccessWhenAurasAreSecret already armed on every aura button
-- (PLAYER_ENTERING_WORLD; Docs/AuraContainer_API_Reference_12.1.md). A library
-- taint inherited from another addon turns any button access on that stack into
-- a denial. Creation still RUNS -- deliberately, the no-deferral requirement is
-- not negotiable and is not what broke -- but it can now half-fail, and the old
-- code recorded the failure as a success:
--
--   * `AddAuraSlot` was the one un-pcall'd engine creation call in this file
--     (its group twin, EnsureAuraGridSpellGroup, has been pcall'd since v43 and
--     records NOTHING on failure, which is why groups retry and slots did not);
--   * `slots[featureKey] = s` was written unconditionally -- even with no
--     button and with initButton never run -- and that record is the "already
--     created" marker every caller's creation gate tests. So one denied styling
--     walk left a permanently blank display that no later pass, and no
--     PLAYER_REGEN_ENABLED flush, could tell apart from a healthy one.
--
-- Three rules fix it, and the ORDER matters:
--   1. every engine call in the creation path is protected;
--   2. the record is committed ONLY on a creation that produced a button whose
--      initButton ran to completion -- otherwise the caller's gate sees nothing
--      and rebuilds on the next pass, exactly like the group path;
--   3. a retry NEVER reuses the engine slot key. Slots cannot be removed and
--      the engine exposes no HasAuraSlot/GetAuraSlot introspection, so whether
--      a failed AddAuraSlot registered the key is unknowable -- re-adding it
--      would either error or strand a duplicate (verified 2026-09-11: a hard
--      error). Every creation takes a key never used on that container before
--      -- `<featureKey>` the first time, then `<featureKey>~<n>` with `n` a
--      per-container counter that only goes up (c._bf_usedSlotKeys /
--      c._bf_slotKeySeq, see EnsureAuraSlotVisual) -- and the abandoned key is
--      PARKED. The record carries the engine `key` separately from its table
--      index (`featureKey`), so nothing downstream cares which engine key it
--      ended up on.
--
-- The leak is bounded: SLOT_MAX_ATTEMPTS buttons per feature per recovery
-- generation (the in-key recreate path has its own cap), worst
-- case, each of them parked to a candidate set nothing matches. Past the cap we
-- stop trying and say so once, rather than leaking a button per Layout forever.
-- ============================================================
local SLOT_MAX_ATTEMPTS = 4

-- frame -> true; nil while empty (no allocation on the common path, and no cost
-- to a session that never sees a denial). Drained by FlushPendingAuraContainers,
-- the same PLAYER_REGEN_ENABLED replay that already owns pendingCreates and
-- pendingFrameBuilds. Deliberately NOT a per-frame flag polled from the render
-- path: leaving combat is the one moment a denied creation can start succeeding,
-- and this file already has the queue for exactly that, so the aura hot path
-- pays nothing at all for the recovery machinery.
local pendingSlotRebuilds

-- v88: attempts are counted PER RECOVERY GENERATION, and leaving combat starts a
-- new one (BF:BumpAuraRecoveryGeneration, called from the regen flush). This is
-- not bookkeeping neatness -- it is what makes the budget useful. Attempts made
-- DURING the restricted window are the ones expected to fail, and if they shared
-- a budget with the retries they would burn it before the retries could run, so
-- the display would still be dark for the rest of the session. A generation
-- counter resets every frame's budget in O(1), without a frame walk.
BF._auraRecoveryGen = 0
function BF:BumpAuraRecoveryGeneration()
    self._auraRecoveryGen = (self._auraRecoveryGen or 0) + 1
end

-- frame -> { gen = n, [featureKey] = attempts }. Lazily allocated: a session
-- with no denial never allocates it. A table from an older generation is
-- discarded wholesale rather than cleared key by key.
local function SlotAttemptCount(frame, featureKey)
    local t = frame._bf_slotAttempts
    if not t or t.gen ~= BF._auraRecoveryGen then return 0 end
    return t[featureKey] or 0
end

local function BumpSlotAttempt(frame, featureKey)
    local t = frame._bf_slotAttempts
    if not t or t.gen ~= BF._auraRecoveryGen then
        t = { gen = BF._auraRecoveryGen }
        frame._bf_slotAttempts = t
    end
    local n = (t[featureKey] or 0) + 1
    t[featureKey] = n
    return n
end

-- Retire an engine slot key we are abandoning. It can never be removed, so the
-- best available disposal is BF's standard park idiom: a candidate set nothing
-- can match, plus a filter string that matches nothing either. Fully protected
-- -- this runs on the failure path, where denials are exactly what is expected.
local function RetireSlotKey(c, key)
    pcall(c.SetAuraSlotCandidateFilters, c, key, DORMANT_CANDIDATES)
    pcall(c.SetAuraSlotFilterString, c, key, "")
end

-- True when this feature has burned its attempts. Callers use it to stop
-- re-entering creation every pass once the situation is hopeless.
function BF:AuraSlotCreationExhausted(frame, featureKey)
    return SlotAttemptCount(frame, featureKey) >= SLOT_MAX_ATTEMPTS
end

-- Retire a slot whose button exists but is unusable (a styling walk that
-- started and never finished -- see ReportHalfBuiltButton). Drops the record so
-- the owning feature's normal creation gate builds a FRESH slot on the next
-- pass; the engine slot key it was using is parked on the way out.
--
-- A discard COUNTS against the same budget as a failed creation, and that is
-- load-bearing rather than tidy: the discard path can be reached for a slot
-- whose record was committed (initButton returned, but one of InitAuraButton's
-- own inner pcalls swallowed a denial, so the completion marker is missing).
-- Without a shared budget that case would discard and rebuild on every single
-- Layout, leaking one engine button each time -- and slots can never be
-- removed. Sharing the counter caps the whole failure family at
-- SLOT_MAX_ATTEMPTS buttons per feature per recovery generation, however the
-- failures are distributed between creation and repair.
function BF:DiscardAuraSlotVisual(frame, featureKey)
    local slots = frame._bf_auraSlots
    local s = slots and slots[featureKey]
    if not s then return false end
    BumpSlotAttempt(frame, featureKey)
    if s.active then
        s.c._bf_activeSlots = (s.c._bf_activeSlots or 1) - 1
        s.active = false
        SlotContainerShown(s)
    end
    RetireSlotKey(s.c, s.key)
    slots[featureKey] = nil
    return true
end

-- spec: { filter, sortMethod?, frameLevelOffset?, candidateFilters?,
--         initButton = function(button, frame) ... build textures /
--         AddDispelTypeTexture bindings / anchor ... }
-- Returns the slot RECORD (see the header), not a container.
-- v88: returns NIL when creation failed. Callers must nil-guard (they already
-- do -- the record has always been the create-gate marker) and must not treat a
-- nil return as permanent: the next pass retries until the attempt cap.
function BF:EnsureAuraSlotVisual(frame, featureKey, spec)
    local slots = frame._bf_auraSlots
    if slots then
        local existing = slots[featureKey]
        if existing then return existing end
    else
        slots = {}
        frame._bf_auraSlots = slots
    end
    -- v88: attempt cap. Reported once per feature per frame, then silent.
    local attempt = SlotAttemptCount(frame, featureKey)
    if attempt >= SLOT_MAX_ATTEMPTS then return nil end

    frame._bf_auraContainers = frame._bf_auraContainers or {}
    do
        local hb = BF._loadHB
        if hb then
            hb.slots = hb.slots + 1
            -- v85: per-key slot census. Normalized the same way HBKey does it
            -- for groups, or the table would grow one row per spell id.
            local sk = hb.slotKeys
            if sk then
                local k = BF.HBSlotKey(featureKey)
                sk[k] = (sk[k] or 0) + 1
            end
        end
    end
    local c
    if BF._sharedSlotContainers then
        c = frame._bf_auraContainers.slots
        if not c then
            c = CreateFrame("AuraContainer", nil, frame, "CustomAuraContainerTemplate")
            do local hb = BF._loadHB; if hb then hb.containers = hb.containers + 1 end end
                    c._bf_featureKey   = "slots"
            c._bf_isSlotVisual = true
            c._bf_sharedSlots  = true
            c._bf_activeSlots  = 0
            MarkVehicleTainted(c)
            pcall(c.SetFrameLevel, c, frame:GetFrameLevel() + SLOT_CONTAINER_LEVEL)
            frame._bf_auraContainers.slots = c
        end
    else
        c = CreateFrame("AuraContainer", nil, frame, "CustomAuraContainerTemplate")
        do local hb = BF._loadHB; if hb then hb.containers = hb.containers + 1 end end
            c._bf_featureKey   = featureKey
        c._bf_isSlotVisual = true
        c._bf_activeSlots  = 0
        MarkVehicleTainted(c)
        frame._bf_auraContainers[featureKey] = c
    end

    -- v88: the ENGINE slot key, which is the featureKey only on the first
    -- attempt. Retries must not reuse it (see the block comment above): slots
    -- cannot be removed and there is no way to ask the container whether a key
    -- is taken, so a failed attempt's key is retired, never reused. `s.key` has
    -- always been read separately from the record's table index, so every slot
    -- API below and every caller keeps working unchanged.
    --
    -- 2026-09-11 (restricted recreate, plan §2.2 / §3.2 B): the key is now
    -- MONOTONIC PER CONTAINER instead of attempt-derived. The attempt count
    -- resets per recovery generation and on relevance changes, so the old
    -- `featureKey` / `featureKey~(attempt+1)` scheme could hand out a key a
    -- retired slot already owns -- and a duplicate AddAuraSlot key is a hard
    -- engine error (verified in game 2026-09-11), not a silent strand. Every
    -- key ever passed to AddAuraSlot on this container is remembered (marked
    -- BEFORE the call: a failed call may still have registered it) and the
    -- suffix counter never goes back, so no caller -- first build, v88 retry,
    -- or an in-key recreate -- can collide.
    local usedKeys = c._bf_usedSlotKeys
    if not usedKeys then usedKeys = {}; c._bf_usedSlotKeys = usedKeys end
    local slotKey = featureKey
    if usedKeys[slotKey] then
        local seq = (c._bf_slotKeySeq or 0) + 1
        c._bf_slotKeySeq = seq
        slotKey = featureKey .. "~" .. seq
    end
    usedKeys[slotKey] = true

    local s = {
        c      = c,
        key    = slotKey,
        -- 2026-09-11: the record's own registry index. `key` is the ENGINE key
        -- and differs from it after any retry or recreate; the recreate
        -- requests (RestampDispelSlot, SetSlotHostLevel) need the index.
        featureKey = featureKey,
        frame  = frame,
        level  = spec.frameLevelOffset,
        filter = spec.filter,
        cand   = spec.candidateFilters,
        shown  = true,
        parked = false,
        active = false,
        -- v88: set by callers whose initButton is the full InitAuraButton walk
        -- (the single-buff slots). It is what makes BF:AuraSlotStylingState
        -- able to read the `_bf_initDone` completion marker; slots with a
        -- bespoke initButton (fx / dispel visuals) leave it nil and are never
        -- probed for a marker they do not stamp.
        needsFullInit = spec.fullInit and true or nil,
    }
    ApplySlotFrameLevel(s)   -- fallback mode: lifts the private container

    local initButton = spec.initButton
    -- v84 §9.7/§9.8: per-kind level hosts, created INSIDE the init window with
    -- the button's other regions. Frames created on an already-configured
    -- pooled button are unproven (the Forbidden Partition), so every host a
    -- slot key can ever need is baked here -- which is safe because the slot
    -- KEY encodes its kind set, so that set is fixed for the button's life.
    local hostDefs = spec.levelHosts
    local function BuildLevelHosts(btn)
        if not hostDefs or s.hosts then return end
        local hosts = {}
        for i = 1, #hostDefs do
            local d = hostDefs[i]
            local h = CreateFrame("Frame", nil, btn)
            h:SetAllPoints(btn)
            h._bf_levelOffset = d.level
            hosts[d.key] = h
        end
        s.hosts = hosts
        btn._bf_levelHosts = hosts
    end
    -- v88: initButton is PROTECTED and its outcome is RECORDED. `s.initOK`
    -- carries three distinct states and all three are meaningful:
    --   true  -- initializeFrame ran and initButton returned normally;
    --   false -- it ran and initButton was interrupted (a denial on a tainted
    --            stack while auras are secret). The button is unusable and the
    --            record must NOT be committed;
    --   nil   -- initializeFrame never ran during AddAuraSlot, i.e. the engine
    --            defers it. That is the documented-unverified lazy path, NOT a
    --            failure: the record is committed and the owning feature's
    --            maintenance arm checks the button's completion marker later.
    local okInit, button
    do
        local ok, res = pcall(c.AddAuraSlot, c, slotKey, spec.filter, {
            initializeFrame = function(btn)
                s._bf_slotButton = btn
                BuildLevelHosts(btn)
                ApplySlotFrameLevel(s)
                local ok = pcall(initButton, btn, frame, s.hosts)
                s.initOK = ok and true or false
                -- v88 HEALTH BIT. Derived ONCE, here, so the per-Layout
                -- maintenance arms cost a single boolean read instead of
                -- re-deriving "is this slot's button actually usable" from four
                -- fields every pass. Set on this callback rather than at the
                -- commit gate below because the engine may run initializeFrame
                -- LATE -- after the gate has already accepted the slot on the
                -- strength of the returned button -- and the bit has to stay
                -- correct on that path too.
                s.healthy = ok
                    and ((not spec.fullInit) or btn._bf_initDone == true)
                    or nil
            end,
            sortMethod = spec.sortMethod or AuraContainerSortMethod.Default,
            -- Include set from the start (fx slots): if the post-creation
            -- setter were ever denied, an fx slot with no candidate filter
            -- would match EVERY helpful aura instead of its one spell.
            -- UpdateSlotActive re-applies the same set below.
            candidateFilters = spec.candidateFilters,
        })
        okInit = ok
        if ok then button = res else BF:NoteSlotCallFail("AddAuraSlot", res) end
        if s.initOK == false then BF:NoteSlotCallFail("initButton", "denied") end
    end
    -- initializeFrame timing: for GROUPS it is CONFIRMED (v77) to run eagerly
    -- and completely inside AddAuraGroup. The SLOT path here remains
    -- unverified (PTR-VERIFY: whether initializeFrame ran during AddAuraSlot
    -- or runs lazily) — the level is stamped on both paths, the second call
    -- is a no-op repeat.
    if button and not s._bf_slotButton then
        s._bf_slotButton = button
        -- Hosts only: initButton is deliberately NOT called here. If the engine
        -- runs initializeFrame lazily instead of inside AddAuraSlot it calls
        -- initButton itself, and a second call would build a second region set
        -- on the same button (the F1 double-init hazard). BuildLevelHosts is
        -- self-guarded, so the lazy path reuses these hosts.
        BuildLevelHosts(button)
        ApplySlotFrameLevel(s)
    end

    -- v88 COMMIT GATE. This is the whole fix in one condition: the record --
    -- which IS the "already created" marker every caller's creation gate reads
    -- -- is written only for a slot that actually produced a usable button.
    -- Anything else retires the engine key it burned, counts the attempt and
    -- returns nil, leaving the caller's gate open so the next Layout / render
    -- pass rebuilds. Byte-for-byte the group path's `if not ok then return end`.
    if (not okInit) or (not s._bf_slotButton) or (s.initOK == false) then
        local n = BumpSlotAttempt(frame, featureKey)
        RetireSlotKey(c, slotKey)
        if s.initOK == false then
            ReportHalfBuiltButton("slot " .. tostring(featureKey))
        end
        -- v88: the slot creation FAILED, so something has to come back and try
        -- again -- Layout is not guaranteed to run after combat drops
        -- (FlushPendingAuraContainers returns on the built latch). Enqueue on
        -- the regen replay this file already owns rather than polling a flag
        -- from :Update: same recovery guarantee as pendingCreates and
        -- pendingFrameBuilds, and ZERO cost on the aura hot path.
        -- Deliberately not enqueued on the attempt-cap early return above: past
        -- the cap there is nothing left to drive.
        pendingSlotRebuilds = pendingSlotRebuilds or {}
        pendingSlotRebuilds[frame] = true
        if n >= SLOT_MAX_ATTEMPTS and BF._slotGiveUpGen ~= BF._auraRecoveryGen then
            BF._slotGiveUpGen = BF._auraRecoveryGen
            DevPrint("|cffff0000BuzzardFrames:|r gave up rebuilding aura slot '"
                .. tostring(featureKey) .. "' after " .. n .. " attempts. "
                .. "/reload out of combat to restore it.")
        end
        return nil
    end

    slots[featureKey] = s
    UpdateSlotActive(s)  -- applies the slot's candidate set + shows the container
    return s
end

-- v88: does this slot's button still need its styling walk, and can it be
-- repaired in place? Answers for the owning feature's maintenance arm:
--   "ok"      -- nothing to do;
--   "init"    -- the walk never started (no _bf_icon). Safe to run initButton
--               now: nothing has been built, so there is no double-build and no
--               duplicated engine binding to worry about;
--   "discard" -- the walk started and stopped. Unrepairable in place (regions
--               cannot be removed, bindings cannot be undone, a second
--               MaskTexture could never be detached once auras are secret), so
--               the slot has to be retired and rebuilt on a fresh key;
--   nil       -- no button yet, or creation is restricted right now. Wait.
-- Only ever meaningful for slots whose initButton is the full InitAuraButton
-- walk; a slot with a bespoke initButton (the fx/dispel visuals) has no
-- completion marker and correctly reports "ok".
function BF:AuraSlotStylingState(frame, featureKey)
    local s = frame._bf_auraSlots and frame._bf_auraSlots[featureKey]
    local btn = s and s._bf_slotButton
    if not btn then return nil end
    -- A record can only carry initOK == false when initializeFrame ran LATE --
    -- after the commit gate had already accepted the slot on the strength of
    -- the returned button (the engine's lazy-init path, which the 12.1 notes
    -- flag as unverified). Applies to every slot kind, bespoke initButtons
    -- included, so it is tested before the completion-marker branch.
    -- 2026-09-11 (restricted recreate, plan §3.1): inside the recreate window
    -- both repairs mean "discard". Running initButton on a button after
    -- AddAuraSlot returned is denied in a key (verified in game), so "init"
    -- cannot repair in place there either; the caller routes "discard" to
    -- RequestAuraRecreate(frame, "slot", ...) in that window. Outside the
    -- window a restricted state still answers nil (wait), as before.
    if s.initOK == false then
        if BF:IsAuraCreationRestricted() then
            if BF:IsAuraRecreateWindow() then return "discard" end
            return nil
        end
        return "discard"
    end
    if not s.needsFullInit then return "ok" end
    if btn._bf_initDone then return "ok" end
    if BF:IsAuraCreationRestricted() then
        if BF:IsAuraRecreateWindow() then return "discard" end
        return nil
    end
    return btn._bf_icon and "discard" or "init"
end

-- v82: exported for the single-buff slot path (BuffsAndContainers'
-- EnsureSingleBuffSlot styles its slot button with the same full aura-button
-- treatment the container pool gets). Safe to expose: re-entry-guarded
-- internally on _bf_icon, so no caller can double-init a button.
BF.InitAuraButton = InitAuraButton

-- v83: LIVE RESTYLE for slot buttons — the single-button mirror of
-- ApplyAuraGridGroupButtonSpec (same walk: RestyleButtonWithSolidIcon, same
-- ButtonSpecSig change-guard, same pcall wall so a denied 12.1 setter never
-- leaves a half-restyled button; the sig commits only on a completed walk, so
-- a denial retries on the next Layout). This is what makes border / duration /
-- icon-type edits on a slot-mode single buff apply live instead of on /reload.
-- seedOnly: record the sig without walking — used right after InitAuraButton
-- at creation, whose styling already IS this spec.
function BF.RestyleSlotButton(btn, spec, seedOnly)
    if not btn or not btn._bf_icon or not spec then return end
    local sig = ButtonSpecSig(spec)
    if btn._bf_specSig == sig then return end
    if seedOnly or BF:SlotCall("RestyleSlotButton", RestyleButtonWithSolidIcon,
            btn, spec) then
        btn._bf_specSig = sig
    end
end

function BF:GetAuraSlotButton(frame, featureKey)
    local s = frame._bf_auraSlots and frame._bf_auraSlots[featureKey]
    return s and s._bf_slotButton or nil
end

function BF:SetAuraSlotVisualFilter(frame, featureKey, filter)
    local s = frame._bf_auraSlots and frame._bf_auraSlots[featureKey]
    if not s then return end
    if s.filter ~= filter then
        -- Same store-always / push-only-when-live shape as
        -- SetAuraSlotCandidates: a PARKED slot's engine filter is blanked by
        -- ApplySlotDormancy, and pushing here would silently un-blank it --
        -- the record takes the new value and the unpark restore is what
        -- delivers it. (Every current caller operates on a slot it just
        -- ensured live, so this arm is theirs.)
        if s.dormantApplied ~= false then
            s.filter = filter
            return
        end
        -- pcall'd like every other post-creation slot setter (denial-prone
        -- in restricted windows); the record commits only on success so the
        -- next settings pass retries with the old value still on file.
        -- Option setters do NOT re-evaluate existing assignments
        -- (PTR-observed, ApplySlotDormancy) — force the engine rebuild on a
        -- real filter change. Change-guarded, so steady state never pays it.
        if BF:SlotCall("SetAuraSlotFilterString",
                s.c.SetAuraSlotFilterString, s.c, s.key, filter) then
            s.filter = filter
            pcall(s.c.UpdateAllAuras, s.c)
        end
    end
end

-- The slot's own candidate set (fx include lists). Stored on the record
-- so unparking can restore it; pushed immediately when the slot is live.
function BF:SetAuraSlotCandidates(frame, featureKey, cand)
    local s = frame._bf_auraSlots and frame._bf_auraSlots[featureKey]
    if not s then return end
    s.cand = cand
    if s.dormantApplied == false then
        if BF:SlotCall("SetAuraSlotCandidateFilters(live)",
                s.c.SetAuraSlotCandidateFilters, s.c, s.key,
                cand or EMPTY_CANDIDATES) then
            pcall(s.c.UpdateAllAuras, s.c)
        end
    end
end

-- v84 (Stage 5 §9.8): the slot's per-kind level HOSTS, and a live level change
-- for ONE of them (the fx "Prioritise" toggles). Because host levels are
-- ABSOLUTE, re-levelling one kind can never disturb the others sharing the
-- button — which is the whole reason a merged slot can carry kinds that used to
-- sit at different levels.
-- PTR-VERIFY: SetFrameLevel on a BF-owned child host frame of a slot button
-- post-PEW (pcall-guarded; on denial the host keeps its previous level and the
-- next out-of-combat pass retries, since the offset is only committed on
-- success).
function BF:GetSlotHosts(frame, featureKey)
    local s = frame._bf_auraSlots and frame._bf_auraSlots[featureKey]
    return s and s.hosts or nil
end

function BF:SetSlotHostLevel(frame, featureKey, hostKey, offset)
    local s = frame._bf_auraSlots and frame._bf_auraSlots[featureKey]
    local h = s and s.hosts and s.hosts[hostKey]
    if not h or h._bf_levelOffset == offset then return end
    -- 2026-09-11 (restricted recreate, plan §3.1 row 8; field report
    -- 2026-09-10): inside a key the host re-level is denied. Compare only --
    -- the stored offset already said it differs -- write NOTHING, and ask for
    -- a rebuilt slot, whose hosts are born at the wanted level (FxHostDefsFor
    -- bakes the Prioritise rung at creation).
    if BF:IsAuraCreationRestricted() and BF:IsAuraRecreateWindow() then
        BF:RequestAuraRecreate(frame, "slot", featureKey, "level")
        return
    end
    local want = s.frame:GetFrameLevel() + offset + 1
    if pcall(h.SetFrameLevel, h, want) then
        h._bf_levelOffset = offset
        h._bf_curLevel = want
    end
end

-- Live frame-level change (whole-slot; the merged fx path re-levels HOSTS).
function BF:SetAuraSlotFrameLevel(frame, featureKey, offset)
    local s = frame._bf_auraSlots and frame._bf_auraSlots[featureKey]
    if not s or s.level == offset then return end
    s.level = offset
    ApplySlotFrameLevel(s)
end

-- Slot-visual dormancy (v46 per-spell frame effects): staleness parking
-- (effect removed / spell hidden / un-flagged). Combines with the
-- feature visibility gate in BF:SyncAuraSlotVisual — a slot is dormant
-- unless it is both unparked and shown. Unparking restores the slot's
-- own candidate set automatically (record field `cand`); callers only
-- have to update it first if the set itself changed.
function BF:SetAuraSlotVisualDormant(frame, featureKey, dormant)
    local s = frame._bf_auraSlots and frame._bf_auraSlots[featureKey]
    if not s then return end
    dormant = dormant and true or false
    if s.parked == dormant then return end
    s.parked = dormant
    UpdateSlotActive(s)
    SlotContainerShown(s)
end

-- ============================================================
-- v88k DIAG (temporary — remove with the bisect): FORCED SLOT RE-PUSH.
--
-- /bf sbdiag reports a slot that is healthy by every measure BF tracks --
-- record committed, button built, initOK, unparked, host container shown and
-- bound to the unit -- while nothing renders. Every measure in that list is
-- BF's own bookkeeping. The one thing it cannot see is what the ENGINE
-- currently holds for the slot, and the three setters that establish it are
-- all change-guarded against BF's cache:
--
--   SetAuraSlotFilterString      guarded by s.filter
--   SetAuraSlotCandidateFilters  guarded by s.dormantApplied / s._bf_sbSid
--   SetUnit                      guarded by c:GetUnit()
--
-- So if the engine drops a slot's filter or candidate set on some transition
-- (frame recycle, unit swap, container re-parent), BF believes it is already
-- pushed and no Layout, RefreshAllAuras or /reload-free recovery re-asserts
-- it. The slot then matches nothing, forever, while reading perfectly healthy.
--
-- This forgets the cached values and re-asserts all three from the record,
-- then forces the engine rebuild. It is a PROBE, not a fix: if it lights the
-- display back up, the bug is that one of those transitions needs to
-- invalidate the cache, and that invalidation is the fix.
-- ============================================================
function BF:_ForceSlotRepush()
    local slotsN, containers, out = 0, {}, {}
    local frames = self.registeredFrames
    if not frames then return 0, out end
    for _, frame in pairs(frames) do
        local sl = (type(frame) == "table") and not frame._isPreviewFrame
            and frame._bf_auraSlots
        if sl then
            for featureKey, s in pairs(sl) do
                local c = s.c
                if c then
                    slotsN = slotsN + 1
                    containers[c] = frame.unit or containers[c] or false
                    -- Filter string: drop the guard, re-push, restore.
                    local okF = true
                    if s.filter then
                        okF = pcall(c.SetAuraSlotFilterString, c, s.key, s.filter)
                    end
                    -- Candidate set: same shape ApplySlotDormancy uses, chosen
                    -- from the record's CURRENT active state rather than from
                    -- dormantApplied (which is the cache we are distrusting).
                    local want = s.active and (s.cand or EMPTY_CANDIDATES)
                        or DORMANT_CANDIDATES
                    local okC = pcall(c.SetAuraSlotCandidateFilters, c, s.key, want)
                    s.dormantApplied = okC and (not s.active) or nil
                    if not (okF and okC) then
                        out[#out + 1] = ("%s/%s: filter=%s cand=%s"):format(
                            tostring(frame.unit), tostring(featureKey),
                            tostring(okF), tostring(okC))
                    end
                end
            end
        end
    end
    for c, unit in pairs(containers) do
        if unit then pcall(c.SetUnit, c, unit) end
        pcall(c.UpdateAllAuras, c)
    end
    return slotsN, out
end

-- ============================================================
-- v88l DIAG (temporary — remove with the bisect): STYLE-GUARD WIPE.
--
-- The counterpart to _WipeLayoutGuardCaches, for the three signature guards
-- that suppress a restyle walk:
--     btn._bf_specSig        RestyleSlotButton        (per slot button)
--     c._bf_styleSig         ApplyAuraGridButtonSpec  (per container)
--     c._bf_groupStyleSigs   ApplyAuraGridGroupButtonSpec (per group)
--
-- Why these are suspect NOW and were not before: ButtonSpecSig folds
-- tostring(spec.durationCurve) into the signature, and until the v86 curve
-- memoisation every call minted a fresh curve object, so the signature could
-- never match and all three walks ran unconditionally on every Layout. A
-- stable curve makes the guards work as designed -- and anything that was
-- relying on the unconditional walk to re-apply a button's visuals after they
-- were cleared now gets nothing.
--
-- v99: _bf_styleGen is gone from the codebase -- the cheap pre-guard it keyed
-- was removed in favour of one complete comparison, so there is nothing left
-- that could short-circuit ahead of the wiped snapshot.
--
-- A PROBE. If wiping these lights the display back up, the fix is to clear the
-- signature at whatever point invalidates the button -- not to un-memoise the
-- curve and go back to restyling everything on every pass.
-- ============================================================
function BF:_WipeStyleGuards()
    local nC, nB = 0, 0
    local frames = self.registeredFrames
    if not frames then return 0, 0 end
    for _, frame in pairs(frames) do
        if type(frame) == "table" and not frame._isPreviewFrame then
            local t = frame._bf_auraContainers
            if t then
                for _, c in pairs(t) do
                    if type(c) == "table" then
                        c._bf_styleSig = nil   -- v99: snapshot table, not a string
                        c._bf_styleTTY, c._bf_styleTPos = nil, nil
                        c._bf_groupStyleSigs = nil
                        nC = nC + 1
                    end
                end
            end
            local sl = frame._bf_auraSlots
            if sl then
                for _, s in pairs(sl) do
                    local btn = s._bf_slotButton
                    if btn then btn._bf_specSig = nil; nB = nB + 1 end
                end
            end
        end
    end
    return nC, nB
end

-- ============================================================
-- v88n DIAG: SHARED-CONTAINER SLOT ROSTER.
--
-- /bf sbdiag reports one slot at a time, which is why four rounds of it read
-- "healthy" on a slot that renders nothing. Slots on a shared container are
-- not independent: the engine assigns each matching aura to ONE slot, so a
-- sibling with an over-broad candidate set silently takes auras that belong to
-- another slot. The victim keeps its own correct filter, candidates, unit and
-- button, and shows nothing -- indistinguishable, per-slot, from healthy.
--
-- The dangerous value is an EMPTY candidate table. SetAuraSlotCandidateFilters
-- with {} is not "match nothing", it is "no candidate narrowing" -- everything
-- the slot's FILTER STRING allows. A single-buff slot's filter is a bare
-- HELPFUL scope, so an empty set there matches every buff on the unit.
-- BF:SetAuraSlotCandidates and ApplySlotDormancy both fall back to
-- EMPTY_CANDIDATES when the record's `cand` is nil, so a lost candidate set
-- degrades to greedy rather than to silent.
--
-- One line per slot, grouped by container, so the roster reads as a whole.
-- Goes to a COPYABLE WINDOW (BF:ShowTextWindow), same as /bf sbdiag and
-- BF:PrintLoadReport -- diagnostic text exists to be pasted somewhere, and
-- chat output cannot be. `/bf slotroster chat` keeps the plain print for a
-- quick glance.
-- ============================================================

-- Read a getter that may return a secret, without ever COMPARING the result --
-- comparing a secret throws rather than answering, and inside a diagnostic that
-- means the rest of the report vanishes with no trace (the failure recorded at
-- the top of this file). Mirrors SafeGet in BuffsAndContainers' sbdiag.
local _issecret = issecretvalue or function() return false end
local function SafeNum(obj, method)
    if not obj then return "nil" end
    local fn = obj[method]
    if not fn then return "no-method" end
    local ok, v = pcall(fn, obj)
    if not ok then return "err" end
    if _issecret(v) then return "<secret>" end
    return tostring(v)
end

local function CandSummary(cand)
    if cand == nil then
        return "|cffff5555nil -> EMPTY (matches any)|r"
    end
    if type(cand) ~= "table" then return tostring(cand) end
    local parts = {}
    local ids = cand.includeSpellIDs or cand.includeSpellIds
    if ids then
        local n, first = 0, nil
        for k in pairs(ids) do
            n = n + 1
            if not first then first = k end
        end
        parts[#parts + 1] = ("ids=%d(%s)"):format(n, tostring(first))
    end
    local dt = cand.includeDispelTypes
    if dt then
        local t = {}
        for k, v in pairs(dt) do t[#t + 1] = tostring(v ~= true and v or k) end
        parts[#parts + 1] = "dispel=" .. table.concat(t, ",")
    end
    if cand.maxDuration ~= nil then
        parts[#parts + 1] = "maxDuration=" .. tostring(cand.maxDuration)
    end
    if #parts == 0 then
        return "|cffff5555{} EMPTY (matches any)|r"
    end
    return table.concat(parts, " ")
end

function BF:_DebugSlotRoster(arg)
    local L = {}
    local function add(fmt, ...)
        L[#L + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
    end
    add("BuzzardFrames /bf slotroster")
    add("")
    -- v88q: CENSUS FIRST, over registeredFrames -- every frame BF created, not
    -- just the ones with slots and not just the ones in service.
    --
    -- The earlier versions of this probe walked activeFrames and skipped any
    -- frame with no _bf_auraSlots, which makes the one failure it most needs to
    -- show invisible: a frame that came INTO service without ever building its
    -- slots renders nothing and is silently absent from the report, while a
    -- frame that went OUT of service keeps its healthy slot records and is
    -- reported in full. Read that pair and everything looks fine on a frame you
    -- cannot see, with nothing at all said about the one you can.
    --
    -- shown/unit are printed per frame so the visible player frame can be
    -- identified rather than assumed.
    local reg = self.registeredFrames
    if reg then
        add("FRAME CENSUS (every registered frame carrying a unit)")
        local rows = {}
        for name, frame in pairs(reg) do
            if type(frame) == "table" and not frame._isPreviewFrame and frame.unit then
                local sl, n = frame._bf_auraSlots, 0
                if sl then for _ in pairs(sl) do n = n + 1 end end
                rows[#rows + 1] = ("  %-22s unit=%-8s gt=%-12s shown=%-9s slots=%d built=%s"):
                    format(tostring(name), tostring(frame.unit),
                        tostring(self.ResolveGroupTypeKey
                            and self:ResolveGroupTypeKey(frame)),
                        SafeNum(frame, "IsShown"), n,
                        tostring(frame._bf_auraContainersBuilt and true or false))
            end
        end
        table.sort(rows)
        for i = 1, #rows do add(rows[i]) end
        add("")
    end
    local frames = self.activeFrames
    if not frames then
        add("no active frames")
    else
        local any = false
        for frame in pairs(frames) do
            local sl = frame.unit and not frame._isPreviewFrame and frame._bf_auraSlots
            if sl then
                any = true
                local gt = self.ResolveGroupTypeKey and self:ResolveGroupTypeKey(frame)
                -- Group by container so a shared host's slots read together --
                -- competition for an aura only happens WITHIN one container.
                local byC, order = {}, {}
                for featureKey, s in pairs(sl) do
                    local c = s.c
                    if c then
                        local rows = byC[c]
                        if not rows then rows = {}; byC[c] = rows; order[#order + 1] = c end
                        rows[#rows + 1] = { featureKey, s }
                    end
                end
                -- v88p: DRAW ORDER. The slot container's level is written ONCE,
                -- at creation, as an ABSOLUTE number (frame level + 1). Nothing
                -- re-asserts it, so a frame that is re-levelled afterwards
                -- leaves its container stranded at the old depth -- shown,
                -- anchored, unit-bound and behind the frame's own art.
                --
                -- Why the two player frames could diverge on this: a CFG header
                -- shows the player whatever the group state, so a raid->party
                -- transition does not reconfigure it; the party header is
                -- exactly what that transition rebuilds. Both are secure
                -- headers -- the difference is which one the transition
                -- touched, not what kind of header it is.
                --
                -- Two frames rendering the same slot differently, with
                -- byte-identical slot records, is what this column exists to
                -- catch.
                local okL, rawL = pcall(frame.GetFrameLevel, frame)
                local wantLvl = "?"
                if okL and not _issecret(rawL) and type(rawL) == "number" then
                    wantLvl = rawL + SLOT_CONTAINER_LEVEL
                end
                add("frame %s (%s)  level=%s strata=%s alpha=%s",
                    tostring(frame.unit), tostring(gt),
                    SafeNum(frame, "GetFrameLevel"),
                    SafeNum(frame, "GetFrameStrata"), SafeNum(frame, "GetAlpha"))
                local hb = frame.healthBar
                if hb then
                    add("   healthBar level=%s   powerBar level=%s",
                        SafeNum(hb, "GetFrameLevel"),
                        frame.powerBar and SafeNum(frame.powerBar, "GetFrameLevel")
                            or "none")
                end
                for i = 1, #order do
                    local c = order[i]
                    local rows = byC[c]
                    table.sort(rows, function(a, b) return tostring(a[1]) < tostring(b[1]) end)
                    add("  container %s  shared=%s activeSlots=%s",
                        tostring(c._bf_featureKey), tostring(c._bf_sharedSlots),
                        tostring(c._bf_activeSlots))
                    -- v88u: _bf_visAlpha is BF's OWN record of the last alpha it
                    -- pushed, so unlike GetAlpha it is never secret. It is the
                    -- change-guard for every c:SetAlpha in this file -- and the
                    -- slot path has no alpha writer, so a 0 written by one of
                    -- the grid sweeps can never be raised again from here.
                    add("     level=%s (want %s) strata=%s alpha=%s visAlpha=%s parentOK=%s",
                        SafeNum(c, "GetFrameLevel"), tostring(wantLvl),
                        SafeNum(c, "GetFrameStrata"), SafeNum(c, "GetAlpha"),
                        tostring(c._bf_visAlpha),
                        tostring(c:GetParent() == frame))
                    for j = 1, #rows do
                        local featureKey, s = rows[j][1], rows[j][2]
                        add("    %-10s key=%-12s act=%s park=%s filter=%s",
                            tostring(featureKey), tostring(s.key),
                            s.active and "Y" or "n", s.parked and "Y" or "n",
                            tostring(s.filter))
                        add("        cand: %s", CandSummary(s.cand))
                    end
                end
                add("")
            end
        end
        if not any then add("no in-service frames with slots") end
    end
    local text = table.concat(L, "\n")
    if not (arg and arg:find("chat", 1, true)) then
        if BF:ShowTextWindow("BuzzardFrames aura slot roster", text, {
            status = "Every slot on each shared container, with its candidate set. Re-runnable with /bf slotroster.",
            width  = 820, height = 560,
        }) then
            return
        end
    end
    for i = 1, #L do print(L[i]) end
end

-- ============================================================
-- v88t DIAG: PUT SOMETHING VISIBLE WHERE THE SLOT BUTTON IS.
--
-- Every field the probes can read is BF's own bookkeeping, and the two that
-- would actually settle this -- the slot button's rect and its shown state --
-- are SECRET (AuraButton:IsShown() returns a secret boolean; GetNumPoints
-- likewise). So stop reading and draw.
--
-- Two markers per frame, both plain BF-owned textures with no secret aspects:
--   MAGENTA, parented to the FRAME, at the slot button's exact anchor and size.
--            Answers "is this screen position visible on this frame at all?"
--   CYAN,    half size, same point, parented to the SLOT CONTAINER.
--            Answers "does this container render its own children here?"
--
-- Reading the pair:
--   both on both frames      -> position and container are fine; the engine is
--                               hiding the button, i.e. the aura is not
--                               matching on that container.
--   magenta only             -> the container is not rendering children on that
--                               frame (clipping / auto-size / draw order).
--   neither on the bad frame -> the resolved anchor does not correspond to a
--                               drawable position, and every geometry readout
--                               so far has been describing a place that is not
--                               where the button ends up.
--
-- Re-run to clear. Textures are BF-owned and created outside the aura button
-- hierarchy, so none of the DenyTaintedAccessWhenAurasAreSecret rules apply.
-- ============================================================
function BF:_DebugSlotMarkers(featureKey)
    featureKey = (featureKey and featureKey ~= "") and featureKey or "sbc4"
    local frames = self.activeFrames
    if not frames then
        print("|cffd3ff7dBuzzardFrames:|r no active frames.")
        return
    end
    local made, cleared = 0, 0
    for frame in pairs(frames) do
        local s = frame.unit and not frame._isPreviewFrame
            and frame._bf_auraSlots and frame._bf_auraSlots[featureKey]
        if s then
            if frame._bf_slotMarkA then
                -- Toggle off. Textures cannot be destroyed, so hide and drop
                -- the references; a re-run reuses nothing and simply remakes.
                pcall(frame._bf_slotMarkA.Hide, frame._bf_slotMarkA)
                if frame._bf_slotMarkB then
                    pcall(frame._bf_slotMarkB.Hide, frame._bf_slotMarkB)
                end
                frame._bf_slotMarkA, frame._bf_slotMarkB = nil, nil
                cleared = cleared + 1
            else
                local gt = self.ResolveGroupTypeKey and self:ResolveGroupTypeKey(frame)
                local sz = 16
                local anchor = "TOP"
                -- Re-derive from the same source the real anchor pass uses, so
                -- the marker cannot drift from the button by construction.
                local ac = self:GetAuraCacheForFrame(frame)
                local lift = self.AuraLiftAnchorFrame
                    and self.AuraLiftAnchorFrame(frame, ac, anchor)
                local target = lift or frame

                local a = BF.Texture(frame, nil, "OVERLAY")
                a:SetColorTexture(1, 0, 1, 0.85)
                a:SetSize(sz, sz)
                a:SetPoint(anchor, target, anchor, 0, 0)
                a:Show()
                frame._bf_slotMarkA = a

                local c = s.c
                if c then
                    local okB, b = pcall(c.CreateTexture, c, nil, "OVERLAY")
                    if okB and b then
                        b:SetColorTexture(0, 1, 1, 0.95)
                        b:SetSize(sz / 2, sz / 2)
                        b:SetPoint(anchor, target, anchor, 0, 0)
                        b:Show()
                        frame._bf_slotMarkB = b
                    end
                end
                made = made + 1
                print(("|cffd3ff7dBuzzardFrames:|r %s (%s): markers placed"):
                    format(tostring(frame.unit), tostring(gt)))
            end
        end
    end
    if cleared > 0 then
        print(("|cffd3ff7dBuzzardFrames:|r cleared markers on %d frame(s)."):format(cleared))
    end
    if made > 0 then
        print("|cffd3ff7dBuzzardFrames:|r magenta = frame-parented, cyan = container-parented."
            .. " Re-run /bf slotmark to clear.")
    end
    if made == 0 and cleared == 0 then
        print(("|cffd3ff7dBuzzardFrames:|r no frame carries slot '%s'."):format(featureKey))
    end
end

-- ============================================================
-- v88s DIAG: RAISE THE SLOT CONTAINER ABOVE THE FRAME'S OWN ART.
--
-- SLOT_CONTAINER_LEVEL is 1, so a slot container sits at frame level + 1 --
-- which on a BF unit frame is the SAME level as healthBar and powerBar
-- (measured: frame 3, healthBar 4, powerBar 4, container 4). Two frames at the
-- same level have no defined stacking order between them; the winner is
-- decided by creation order. So whether a slot's button draws above or below
-- the health bar is not something BF is choosing -- and anything that
-- re-creates the health bar can flip it, on that frame only, permanently.
--
-- This is consistent with every negative result so far: the record is healthy,
-- the filters and candidates are right, the engine has the aura assigned and
-- has the button shown. Nothing is broken in the aura path. The button is
-- underneath something opaque. It also survives "I made the health bar
-- transparent" -- the bar's BACKGROUND texture is a separate region from its
-- fill.
--
-- Sets the container (and, for a shared container, each slot button) to an
-- explicit level well clear of the frame's own art. A probe: if this reveals
-- the display, the fix is for SLOT_CONTAINER_LEVEL to clear the bars by
-- construction and to be re-asserted when the frame's level changes, rather
-- than being written once at creation.
-- ============================================================
function BF:_ForceSlotLevel(n)
    n = tonumber(n) or 5
    local frames = self.activeFrames
    if not frames then
        print("|cffd3ff7dBuzzardFrames:|r no active frames.")
        return
    end
    local nc, nb = 0, 0
    for frame in pairs(frames) do
        local sl = frame.unit and not frame._isPreviewFrame and frame._bf_auraSlots
        if sl then
            local okL, base = pcall(frame.GetFrameLevel, frame)
            if okL and type(base) == "number" then
                local seen = {}
                for _, s in pairs(sl) do
                    local c = s.c
                    if c and not seen[c] then
                        seen[c] = true
                        if pcall(c.SetFrameLevel, c, base + n) then nc = nc + 1 end
                    end
                    local btn = s._bf_slotButton
                    if btn and pcall(btn.SetFrameLevel, btn, base + n + 1) then
                        nb = nb + 1
                    end
                end
            end
        end
    end
    print(("|cffd3ff7dBuzzardFrames:|r raised %d container(s) to frame+%d and %d"
        .. " button(s) to frame+%d. Look at your single buffs NOW.")
        :format(nc, n, nb, n + 1))
end

-- ============================================================
-- v88r DIAG: HARD RE-BIND OF THE SLOT CONTAINER.
--
-- Where the evidence has landed: two containers on two frames, identical in
-- every BF-side field, identical in draw order (level 4 of a level-3 frame on
-- both), both shown, both bound to "player", both carrying the same six slots
-- with the same filters and candidate sets -- and one renders the tracked buff
-- while the other does not. Nothing BF stores can explain that, so the engine's
-- own per-container aura assignment is the only remaining difference.
--
-- Nothing BF does re-establishes that assignment after a layout transition:
--   * SetUnit is change-guarded on c:GetUnit(), and the unit does not change --
--     it is "player" before and after -- so the engine is never re-bound;
--   * UpdateAllAuras rebuilds the display from the binding the container
--     already holds, which is exactly the thing suspected of being stale.
-- BF:_ForceSlotRepush already proved a same-unit SetUnit + UpdateAllAuras is
-- not enough.
--
-- So break the binding before remaking it: clear the unit, cycle enabled, set
-- the unit back, rebuild. Each step is pcall'd and the unit is restored even if
-- an intermediate step is denied, so a failure leaves the container bound
-- rather than blank.
--
-- If this restores the display, the fix is a hard re-bind on the transition
-- that invalidates the assignment -- NOT this function, which is a probe.
-- ============================================================
function BF:_ForceSlotRebind()
    local frames, n = self.activeFrames, 0
    if not frames then
        print("|cffd3ff7dBuzzardFrames:|r no active frames.")
        return
    end
    local seen = {}
    for frame in pairs(frames) do
        local sl = frame.unit and not frame._isPreviewFrame and frame._bf_auraSlots
        if sl then
            for _, s in pairs(sl) do
                local c = s.c
                if c and not seen[c] then
                    seen[c] = true
                    local unit = frame.unit
                    pcall(c.SetUnit, c, nil)
                    pcall(c.SetEnabled, c, false)
                    pcall(c.SetEnabled, c, true)
                    c._bf_enabled = true
                    pcall(c.SetUnit, c, unit)
                    pcall(c.UpdateAllAuras, c)
                    n = n + 1
                end
            end
        end
    end
    print(("|cffd3ff7dBuzzardFrames:|r hard re-bound %d slot container(s)."
        .. " Look at your single buffs NOW."):format(n))
end

-- ============================================================
-- v88o DIAG: ADD A SLOT TO A LIVE CONTAINER, IN ISOLATION.
--
-- The roster diff between a working and a broken frame is one slot: a merged
-- dispel visual (dvOB) that does not exist on a fresh solo reload and IS
-- created, on an already-live shared container, during a group transition.
-- Every other field on every other slot is byte-identical between the two
-- states, so slot creation on a live container is the only candidate left.
--
-- The hazard this tests is the one the file header already flags as unverified
-- ("PTR-VERIFY: AddAuraSlot on a container that is ALREADY live (has a
-- unit)"). If the engine re-pools the container's buttons when a slot is
-- added, every EXISTING slot's s._bf_slotButton becomes a reference to a
-- button the engine no longer draws that slot on -- and BF cannot tell,
-- because the button still exists, still reports _bf_initDone, and still
-- carries the styling BF gave it. Which is precisely the state every probe so
-- far has reported as healthy.
--
-- This reproduces that single event with nothing else changing: one slot,
-- added to the live shared container, with a filter and a candidate set that
-- can never match anything. If a single buff goes dark on a frame that was
-- rendering it a moment earlier, the mechanism is confirmed and no group
-- transition was involved.
--
-- LEAKS ONE ENGINE BUTTON PER RUN, permanently -- slots cannot be removed.
-- That is the cost of the experiment; the key is uniquified per run so a
-- second invocation cannot collide with the first, and the slot is inert.
-- Diagnostic only, and it should be deleted once the question is answered.
-- ============================================================
function BF:_DebugAddLiveSlot()
    local frames = self.activeFrames
    if not frames then
        print("|cffd3ff7dBuzzardFrames:|r no active frames.")
        return
    end
    self._slotTestN = (self._slotTestN or 0) + 1
    local key = "_bftest" .. self._slotTestN
    local n = 0
    for frame in pairs(frames) do
        if frame.unit and not frame._isPreviewFrame then
            local c = frame._bf_auraContainers and frame._bf_auraContainers.slots
            if c then
                local ok, err = pcall(c.AddAuraSlot, c, key, "HARMFUL|DISPELLABLE", {
                    -- maxDuration = 0: the documented empty set. This slot can
                    -- never be assigned an aura, so anything that changes on
                    -- the frame is caused by the ADD, not by the slot competing.
                    candidateFilters = DORMANT_CANDIDATES,
                    initializeFrame  = function() end,
                })
                if ok then
                    n = n + 1
                else
                    print(("|cffd3ff7dBuzzardFrames:|r %s AddAuraSlot failed: %s")
                        :format(tostring(frame.unit), tostring(err)))
                end
            end
        end
    end
    print(("|cffd3ff7dBuzzardFrames:|r added inert slot '%s' to %d live"
        .. " container(s). Look at your single buffs NOW."):format(key, n))
end

-- ============================================================
-- v84 (Stage 5 §9.7): MERGED DISPEL-VISUAL SLOT
--
-- The three dispellable-debuff highlights -- border, dot, overlay -- each owned
-- a slot (one engine button) of the shared slot container. When two or three of
-- them are enabled with the SAME mode, everything the engine actually keys on is
-- identical: the filter string, the candidate set (including the warlock
-- Magic-only narrowing) and the button's shown/hidden state. So they can share
-- ONE button, saving up to 2 buttons per frame AND -- the part that matters in
-- combat -- 2 of 3 per-candidate slot filter passes per frame, since slots pay
-- the same Lua DoesAuraPassCandidateFilters that groups do.
--
-- NOVEL vs Grid2, which runs one slot per indicator and has no merged-visual
-- precedent (owner-approved explicitly).
--
-- THE HAZARD this design exists to solve: each visual's restamp opened with
-- button:ClearDispelTypeTextures(), assuming sole ownership of the button's
-- binding set, and each kept its OWN bind signature. Merged, whichever ran last
-- silently wiped the other two. So a merged button gets ONE combined restamp
-- that clears once and rebinds every kind under a COMBINED signature.
-- (Index-based RemoveDispelTypeTexture was rejected: index stability after a
-- removal is unverified.)
--
-- Levels: nothing renders on the button. Each kind's regions live on its own
-- child host frame at an ABSOLUTE level (see StampSlotLevelHosts).
--
-- SPLIT is not a special case -- a kind that shares with nobody gets a
-- single-kind slot under its own legacy key, on the same host machinery, at the
-- same level it always had. The merged keys ("dvOB", "dvOBD", ...) encode their
-- kind SET, so a button's baked region set is fixed for its life and a
-- partition change can only ever move between keys, never re-bake a button.
--
-- v85: merging is UNCONDITIONAL. It used to sit behind
-- BF:IsDispelMergeEnabled() / "/bf dvmerge"; the owner ruled 2026-08-16 that
-- optimizations are not gated. The merge-vs-split RESOLUTION stays exactly as
-- it was -- it is driven by the settings (mode plus the per-visual "only while
-- my dispel is ready" gate), which is behavior, not a gate.
-- ============================================================
-- dispelHealthColor (owner): the Debuff Health Color Change tint, a FOURTH
-- kind on this same machinery. It renders like the per-spell buff Change Health
-- Color tint (RestampFxHealth, Indicators/BuffsAndContainers.lua) -- anchored
-- over the health FILL -- and sits under every overlay, exactly like the buff
-- tint. Registered from DispelDebuffOverlay.lua alongside the overlay kind.
BF.DISPEL_VISUAL_ORDER = { "dispelOverlay", "dispelBorder", "dispelDot", "dispelHealthColor" }
-- Per-kind frame-level offsets. Each kind's host lands at parent+offset+1
-- (StampSlotLevelHosts).
--
-- v92: these are the DISPEL rungs of the three-lane frame-level map that is
-- single-sourced in Indicators/BuffsAndContainers.lua (the FX_LEVEL_* block) --
-- read it, including its CROSS-LANE TIE POLICY, before touching a number here.
-- Each lane runs
--     buff (Prioritise OFF)  <  container  <  dispel  <  buff (Prioritise ON)
-- so a dispel kind sits exactly one rung above its per-container twin
-- (BF.CONTAINER_FX_LEVEL) and one below a prioritised buff effect:
--
--   tint     buff 1  < container 2  < DISPEL 3  < buff-prio 4   (host +2/+3/+4/+5)
--   overlay  buff 2  < container 3  < DISPEL 4  < buff-prio 5   (host +3/+4/+5/+6)
--   border   buff 10 < container 11 < DISPEL 12 < buff-prio 13  (host +11/+12/+13/+14)
--
-- ONE number moved for this feature: dispelHealthColor 1 -> 3, opening the
-- container tint rung at 2 and ending the old buff/dispel tie at offset 1
-- (same winner, now explicit). dispelOverlay stays 4, dispelBorder 12 and
-- dispelDot 223 -- untouched.
--
-- Absorb art is hBar-relative and hBar is parent+1, so it lives at parent+7/+8
-- (AbsorbBars.lua:99/114/201 and :131/246) and parent+11 (:262) -- ABOVE this
-- whole tint/overlay block. An older comment here claimed an absorb fill at
-- parent+4 and used it to justify dispelOverlay's offset; that was wrong,
-- nothing sits at parent+4. The real ceiling is offset 5 (parent+6): offset 6
-- would tie absorbClip.
--
-- Cross-KIND ties are policy, not oversight: eight tint+overlay rungs do not
-- fit in the usable integers 1..5, so per-LANE order is strict and cross-kind
-- ties (this overlay 4 vs a prioritised buff tint 4; the container overlay 3 vs
-- this tint 3) resolve by draw order -- as they always have (pre-v92 this
-- overlay outdrew a prioritised buff tint outright).
BF.DISPEL_VISUAL_LEVEL = { dispelOverlay = 4, dispelBorder = 12, dispelDot = 223, dispelHealthColor = 3 }
local DISPEL_VISUAL_TAG = { dispelOverlay = "O", dispelBorder = "B", dispelDot = "D", dispelHealthColor = "H" }
-- Filled at load by the indicator files:
--   resolve(frame, ac) -> enabled, mode, show
--   build(button, host, frame, ac)          init window: regions on `host`
--   bind(button, host, frame, ac)           restamp: AddDispelTypeTexture calls
--   sig(frame, ac)  -> string               that kind's restamp signature
--   geom(button, host, frame, ac)           live non-binding geometry (optional)
BF.DispelVisualDefs = {}

-- Every slot key this feature can ever use, and the kind list behind each.
-- Precomputed so the hot path never builds a table or a key string.
local DISPEL_SET_KINDS, DISPEL_SET_KEY = {}, {}
do
    local order = BF.DISPEL_VISUAL_ORDER
    -- 2^#order - 1: every non-empty subset of the kind list (15 with four
    -- kinds). Keep this in sync with DISPEL_VISUAL_ORDER above.
    for mask = 1, bit.lshift(1, #order) - 1 do
        local kinds, tag = {}, ""
        for i = 1, #order do
            if bit.band(mask, bit.lshift(1, i - 1)) ~= 0 then
                kinds[#kinds + 1] = order[i]
                tag = tag .. DISPEL_VISUAL_TAG[order[i]]
            end
        end
        -- A single kind keeps its LEGACY slot key, so the split shape is
        -- byte-for-byte the pre-v84 slot inventory.
        local key = (#kinds == 1) and kinds[1] or ("dv" .. tag)
        DISPEL_SET_KINDS[key] = kinds
        DISPEL_SET_KEY[mask] = key
    end
end

-- Mode -> small integer, so the per-update shape signature is arithmetic and
-- allocates nothing. Anything not listed is the "dispellable by me" mode.
local DISPEL_MODE_ID = { all = 1, allDispellable = 2 }

-- Reused scratch (one table, never handed out) — the resolve pass runs on the
-- aura update path and must not allocate.
-- _dvMerge is the MERGE KEY: mode id plus the "only while my dispel is ready"
-- setting. Mode equality alone is not enough — onlyIfReady is per visual, and
-- two kinds sharing one button share one shown/hidden state, so a border with
-- the gate off could not coexist with a dot that has it on. Folding it into the
-- merge key splits that pair instead of picking a winner. (The third `show`
-- term, hasDebuffHighlightFeatures, is the OR of every kind's enable toggle —
-- true whenever any kind is enabled — so it can never divide a live set.)
local _dvOn, _dvMode, _dvShow, _dvMerge = {}, {}, {}, {}

-- 2026-09-11: RC is the restricted-recreate state table (see the RECREATE
-- INSTEAD OF RESTYLE block below BF:IsAuraCreationRestricted for the design).
-- It is declared HERE, the first place in the file that needs it, because a
-- local is only in scope below its declaration; it is the one new file-level
-- local of that work (the chunk is near Lua 5.1's 200-locals limit).
local RC = {
    QUIET        = 0.30,   -- s of quiet after the last new request
    MOUSE_POLL   = 0.25,   -- re-check interval while the left button is down
    SPACING      = 1.5,    -- min s between two rebuilds of one (frame, kind:key)
    PER_TICK     = 2,      -- frames per C_Timer.After(0) tick (TOPUP shape)
    SUSPEND_POLL = 1.0,    -- re-check while only preview-suspended frames wait
    LOG_SIZE     = 60,     -- 2026-09-11: 10 hid the reasons behind a 177-run key
    REPEAT_WINDOW = 10,    -- s: a same-reason re-request this soon after a landed rebuild is a repeat
    LEAK_BUDGET  = 0,      -- 2026-09-11 owner ruling: no leak budget (status shows the total)
    CAP          = {},     -- 2026-09-11 owner ruling: no per-object cap (status only)
    OWNER_ORDER  = { "buffsAndContainers", "debuffIcons", "bigDefIcons" },

    pending      = {},     -- frame -> { ["kind:key"] = reason }
    handlers     = {},     -- kind -> fn(frame, key) -> ok, leakedButtons
    lastRun      = setmetatable({}, { __mode = "k" }), -- frame -> { kk = GetTime() }
    used         = setmetatable({}, { __mode = "k" }), -- frame -> { kk = rebuilds }
    capped       = setmetatable({}, { __mode = "k" }), -- frame -> { kk = true }
    drift        = setmetatable({}, { __mode = "k" }), -- frame -> { kk = true }
    reasons      = setmetatable({}, { __mode = "k" }), -- frame -> { kk = { reason = count } }
    lastReason   = setmetatable({}, { __mode = "k" }), -- frame -> { kk = reason of the last landed rebuild }
    repeats      = setmetatable({}, { __mode = "k" }), -- frame -> { kk = consecutive same-reason repeats }
    retired      = setmetatable({}, { __mode = "k" }), -- frame -> weak-valued list
    cappedNotice = {},     -- kind -> true (once per session per kind)
    last         = {},     -- ring buffer of the last LOG_SIZE rebuilds
    lastPos      = 0,
    leaked       = 0,      -- pooled buttons parked this session
    runs         = 0,      -- successful rebuilds this session
    keyRuns      = 0,      -- successful rebuilds since the last key-end summary
    -- timer / executor state
    timer        = nil,    -- the single C_Timer.NewTimer handle
    ticking      = false,  -- a C_Timer.After(0) tick is scheduled
    running      = false,  -- the executor is on the stack
    quietUntil   = nil,
    inRecreate   = nil,    -- frame whose owner Layout the executor is running
    batch        = nil,    -- { kk = true } being rebuilt on inRecreate
}

-- 2026-09-11 (restricted recreate, plan §3.1): optional geometry signature for
-- a dispel set. Declared above EnsureDispelSlot (stamps it at creation) and
-- RestampDispelSlot (compares it inside the recreate window).
function RC.DispelGeomSig(frame, kinds, ac)
    -- Optional: only when EVERY kind in the set exposes geomSig(frame, ac).
    -- None does today, so this returns nil and geometry keeps its own
    -- self-guarded pcall path; a kind that adds geomSig opts into
    -- compare-then-recreate for its geometry too.
    local gs = ""
    for i = 1, #kinds do
        local d = BF.DispelVisualDefs[kinds[i]]
        if not (d and d.geomSig) then return nil end
        gs = gs .. tostring(d.geomSig(frame, ac)) .. ";"
    end
    return gs
end

local function EnsureDispelSlot(frame, slotKey, kinds, mode, unit)
    local existing = frame._bf_auraSlots and frame._bf_auraSlots[slotKey]
    if existing then return existing end
    -- The :Update path (unit given) runs on the aura hot path; creating a slot
    -- there IN COMBAT is the combat-path creation the v74/v88 notes forbid
    -- (a denial burns SLOT_MAX_ATTEMPTS engine keys per fight). The create-only
    -- build pass (unit nil, inside the init window) and the out-of-combat
    -- keystone case still create -- that is the whole point of dropping the
    -- secrecy gate below.
    if unit and InCombatLockdown() then return nil end
    -- 2026-09-11 (field report 2026-09-10: after a /reload inside a keystone
    -- "only some buff customizations are active"): there was an
    -- IsAuraCreationRestricted() early-out here. Auras stay secret for the
    -- whole key, so it kept overlay/border/dot/health-color absent until the
    -- key ended. Creation through EnsureAuraSlotVisual + initButton IS allowed
    -- in that window (the single-buff slots prove it, see the v88h note in
    -- BuffsAndContainers.lua); a genuine denial still comes back as nil and the
    -- caller's retry (shapeSig = nil) covers it.
    -- v91: the "by me" arm resolves from the frame's aura cache (the two By-Me
    -- toggles) plus the player's spec/talents.
    local filter, cand = BF.DispelVisualFilterFor(mode, BF:GetAuraCacheForFrame(frame))
    local hostDefs, lowest = {}, nil
    for i = 1, #kinds do
        local lvl = BF.DISPEL_VISUAL_LEVEL[kinds[i]]
        hostDefs[i] = { key = kinds[i], level = lvl }
        if not lowest or lvl < lowest then lowest = lvl end
    end
    return BF:EnsureAuraSlotVisual(frame, slotKey, {
        -- The record's own level is the LOWEST kind's offset: an inert base, as
        -- every kind renders from its own absolute-level host.
        frameLevelOffset = lowest,
        filter = filter,
        candidateFilters = cand and { includeDispelTypes = cand } or nil,
        levelHosts = hostDefs,
        initButton = function(btn, f, hosts)
            btn:EnableMouse(false)
            -- Geometrically inert: the hosts carry every anchor. Full-frame so
            -- the button can never be a zero-rect ancestor of visible art.
            pcall(btn.SetAllPoints, btn, f)
            local a = BF:GetAuraCacheForFrame(f)
            for i = 1, #kinds do
                local d = BF.DispelVisualDefs[kinds[i]]
                local h = hosts and hosts[kinds[i]]
                if d and h then d.build(btn, h, f, a) end
            end
            -- 2026-09-11 (same field report): the AddDispelTypeTexture bindings
            -- used to happen only in RestampDispelSlot, i.e. POST-creation --
            -- and every post-creation button write is denied for the whole
            -- key, so a slot born after a reload inside one had its regions but
            -- no bindings (nothing ever lit). Bind here, in the one window the
            -- engine allows, then run the live geometry. On success the
            -- combined signature is stamped exactly as RestampDispelSlot builds
            -- it, so its first pass finds the bindings committed and only runs
            -- geom. _bf_dvGen/_bf_dvStyle stay unset on purpose so that first
            -- pass is not skipped. One pcall for the whole set (same reasoning
            -- as RestampDispelSlot: a partial set must not commit the sig).
            local sig = ""
            for i = 1, #kinds do
                local d = BF.DispelVisualDefs[kinds[i]]
                sig = sig .. (d and d.sig and d.sig(f, a) or "") .. ";"
            end
            if pcall(function()
                for i = 1, #kinds do
                    local k = kinds[i]
                    local d = BF.DispelVisualDefs[k]
                    if d then d.bind(btn, hosts and hosts[k], f, a) end
                end
            end) then btn._bf_dvSig = sig end
            for i = 1, #kinds do
                local k = kinds[i]
                local d = BF.DispelVisualDefs[k]
                if d and d.geom then d.geom(btn, hosts and hosts[k], f, a) end
            end
            -- 2026-09-11: the geometry the button was born with (nil unless
            -- every kind exposes geomSig -- see DispelGeomSig).
            btn._bf_dvGeomSig = RC.DispelGeomSig(f, kinds, a)
        end,
    })
end

-- THE combined restamp. One ClearDispelTypeTextures for the whole button, then
-- every kind rebinds, all under one signature — so no kind can wipe another's
-- bindings. Guarded on the aura-cache generation plus the frame's border style
-- (the border kind's ring follows the latter, which does not live in the aura
-- cache) so the signature string is only built when something could have moved.
--
-- 2026-09-11 (restricted recreate, plan §1 row 10 / §3.1):
--   * The generation guard used to commit BEFORE the rebind, so a denied rebind
--     was never retried until _cacheGen moved -- and the key-end replay (a
--     Layout) does not move it, so a stale binding could outlive the key.
--     _bf_dvGen/_bf_dvStyle now commit only when the bindings are known current
--     (sig already matched, or the rebind succeeded) and the frame is
--     unrestricted. While restricted, a separate try-stamp (_bf_dvTryGen/
--     _bf_dvTryStyle) limits the attempt to once per (gen, style), so a denied
--     rebind does not become a pcall per UNIT_AURA; the first unrestricted pass
--     ignores the try-stamp and retries.
--   * Inside the recreate window a binding (or optional geometry-signature)
--     mismatch is not attempted at all -- the rebind is a post-creation button
--     write, denied in a key -- it requests a rebuilt slot instead, whose
--     initButton binds at creation. `slotKey` is the record's registry index.
local function RestampDispelSlot(frame, s, kinds, ac, gen, bstyle, slotKey)
    local btn = s._bf_slotButton
    if not btn then return end
    if btn._bf_dvGen == gen and btn._bf_dvStyle == bstyle then return end
    local restricted = BF:IsAuraCreationRestricted()
    if restricted then
        if btn._bf_dvTryGen == gen and btn._bf_dvTryStyle == bstyle then return end
        btn._bf_dvTryGen, btn._bf_dvTryStyle = gen, bstyle
    end
    local hosts = s.hosts
    local sig = ""
    for i = 1, #kinds do
        local d = BF.DispelVisualDefs[kinds[i]]
        sig = sig .. (d and d.sig and d.sig(frame, ac) or "") .. ";"
    end
    if restricted and BF:IsAuraRecreateWindow() then
        local gsig = btn._bf_dvGeomSig and RC.DispelGeomSig(frame, kinds, ac)
        if btn._bf_dvSig ~= sig or (gsig and gsig ~= btn._bf_dvGeomSig) then
            local why = "dispel:bind"
            if btn._bf_dvSig == sig then
                -- Diag: name the kind whose geometry moved, with both values.
                why = "dispel:geom"
                local was = btn._bf_dvGeomSig or ""
                local pos = 1
                for i = 1, #kinds do
                    local d = BF.DispelVisualDefs[kinds[i]]
                    local now = d and d.geomSig and tostring(d.geomSig(frame, ac)) or ""
                    local nxt = string.find(was, ";", pos, true)
                    local old = nxt and string.sub(was, pos, nxt - 1) or ""
                    pos = (nxt or #was) + 1
                    if old ~= now then
                        why = "dispel:geom:" .. tostring(kinds[i]) .. ":" .. old .. ">" .. now
                        break
                    end
                end
            end
            BF:RequestAuraRecreate(frame, "slot", slotKey or s.featureKey, why)
            return
        end
    end
    local bound = (btn._bf_dvSig == sig)
    if not bound then
        -- One pcall around the WHOLE rebind: a partial binding set is worse
        -- than the previous one, and the signature only commits on success, so
        -- a denial retries on the next pass (same shape as the walls above).
        if pcall(function()
            btn:ClearDispelTypeTextures()
            for i = 1, #kinds do
                local k = kinds[i]
                local d = BF.DispelVisualDefs[k]
                if d then d.bind(btn, hosts and hosts[k], frame, ac) end
            end
        end) then
            btn._bf_dvSig = sig
            bound = true
        end
    end
    -- Non-binding live geometry (sizes, anchors, alpha). Each kind carries its
    -- own change guard and its own pcall.
    for i = 1, #kinds do
        local k = kinds[i]
        local d = BF.DispelVisualDefs[k]
        if d and d.geom then d.geom(btn, hosts and hosts[k], frame, ac) end
    end
    if bound and not restricted then
        btn._bf_dvGen, btn._bf_dvStyle = gen, bstyle
        btn._bf_dvGeomSig = RC.DispelGeomSig(frame, kinds, ac)
    end
end

-- The single owner of every dispel visual on a frame. Called from each of
-- the registering indicators' :Update (idempotent and change-guarded, so whichever
-- runs first does the work and the other two cost a handful of compares — and
-- no ordering assumption is needed between them).
-- `unit` nil = CREATE-ONLY. The indicator :Create methods call it that way during
-- the frame BUILD pass (BuzzardFramePrototype:CreateIndicators), so the slots
-- are born in the same cheap out-of-combat window every other aura object is --
-- and, incidentally, inside the /bf loadreport headersBuilt span, where they
-- were counted before v84 moved creation onto the :Update path. Step 3 (the
-- show gate) is skipped without a unit; the first real :Update runs it.
function BF:SyncDispelVisualSlots(frame, unit)
    if frame._isPreviewFrame then return end
    local defs = BF.DispelVisualDefs
    local order = BF.DISPEL_VISUAL_ORDER
    local ac = BF:GetAuraCacheForFrame(frame)

    -- 1. Resolve every kind. Allocation-free: scratch tables + an integer sig.
    local shapeSig, anyOn = 0, false
    for i = 1, #order do
        local kind = order[i]
        local d = defs[kind]
        local on, mode, show, ready = false, nil, false, false
        if d then on, mode, show, ready = d.resolve(frame, ac) end
        _dvOn[kind], _dvMode[kind], _dvShow[kind] = on, mode, show
        local mk = (DISPEL_MODE_ID[mode] or 3) * 2 + (ready and 1 or 0)
        _dvMerge[kind] = mk
        shapeSig = shapeSig * 8 + (on and mk or 0)
        if on then anyOn = true end
    end

    -- v91 FIX (owner bug 2026-08-17: "the two Dispellable by Me toggles do
    -- nothing for the dispel visuals"). ROOT CAUSE: step 2 below is the ONLY
    -- place a slot's includeDispelTypes map is (re)pushed, and its guard was
    -- `shapeSig` alone -- which folds each kind's enable / MODE / only-if-ready
    -- and nothing else. The resolved TYPE SET is an independent input: flipping
    -- "Only when talented" or "Include Long-Cooldown Dispels", or changing spec
    -- or talents, moves BF:MyDispelTypes without moving a single shape term, so
    -- the guard held and every slot kept the candidate map it was born with in
    -- EnsureDispelSlot (which computes filter+candidates ONCE, at creation).
    -- The per-slot `_bf_dvCand` guard further down was already type-set aware --
    -- it simply never got reached.
    --
    -- dvTypeSig is the missing term, kept arithmetic and allocation-free for
    -- this per-update path: BF.MyDispelGen (DebuffIcons.lua) bumps on every
    -- spec/talent/login re-resolve, and the two toggles are read straight off
    -- the frame's aura cache (which is where AuraConfig/DebuffIcons UpdateDB
    -- stamp them, for both the global and the per-CFG cache). Defaults match
    -- BF:MyDispelTypes exactly -- talented ON unless explicitly false, longCd
    -- OFF unless explicitly true -- so a cache that predates the keys resolves
    -- to the same term the resolver will.
    -- 2026-08-25: the VISUALS' own governors, not the debuff-icon pair -- the
    -- two are independent settings now, so this guard has to fold the ones
    -- DispelVisualFilterFor actually resolves through.
    local dvTypeSig = (BF.MyDispelGen or 0) * 4
        + (((ac and ac.dispelVisualDispMeTalented) == false) and 0 or 2)
        + (((ac and ac.dispelVisualDispMeLongCd) == true) and 1 or 0)

    -- 2. Partition, but only when the shape actually moved. Everything here
    -- either creates slots or flips dormancy — never per-update work.
    if frame._bf_dvShapeSig ~= shapeSig or frame._bf_dvTypeSig ~= dvTypeSig then
        local live = frame._bf_dvLive
        if not live then live = {}; frame._bf_dvLive = live end
        wipe(live)
        -- Did the partition actually RUN? A frame that is not in service yet
        -- (never carried a unit) skips it, and committing the signature then
        -- would be a permanent kill: the next pass would see a matching sig,
        -- skip step 2 forever, and step 3 would early-return on the empty
        -- `live` -- dispel visuals dead on that frame until some unrelated
        -- SETTING changed. Same failure the creation-refused branch below
        -- already guards against by nilling the signature.
        local partitioned = false
        if anyOn and not BF:ShouldDeferFrameAuraContainers(frame) then
            partitioned = true
            local seen = 0
            for i = 1, #order do
                if _dvOn[order[i]] and bit.band(seen, bit.lshift(1, i - 1)) == 0 then
                    local mask = bit.lshift(1, i - 1)
                    -- Everything else enabled with the SAME merge key joins it.
                    -- A kind that matches nobody falls out as a one-kind set and
                    -- keeps its legacy slot key -- the split shape is a natural
                    -- outcome of this loop, never a separate mode.
                    for j = i + 1, #order do
                        if _dvOn[order[j]] and _dvMerge[order[j]] == _dvMerge[order[i]] then
                            mask = mask + bit.lshift(1, j - 1)
                        end
                    end
                    seen = seen + mask
                    local key = DISPEL_SET_KEY[mask]
                    live[key] = _dvMode[order[i]]
                end
            end
        end
        -- Ensure the wanted slots, park every other dispel slot this frame has.
        for key, mode in pairs(live) do
            local s = EnsureDispelSlot(frame, key, DISPEL_SET_KINDS[key], mode, unit)
            if s then
                -- Mode can change without the kind set changing.
                local dvAC = BF:GetAuraCacheForFrame(frame)
                local filter, cand = BF.DispelVisualFilterFor(mode, dvAC)
                BF:SetAuraSlotVisualFilter(frame, key, filter)
                -- v91: the include map is no longer a constant, so the change
                -- guard folds the resolved TYPE SET signature -- a spec, talent
                -- or By-Me-toggle change re-applies the slot's candidates.
                local want = "off"
                if cand then
                    -- 2026-08-25: through the visual-side view, so this sig
                    -- describes the type set `cand` was actually built from.
                    local _, mySig = BF:MyDispelTypes(BF.DispelVisualDispMeAC(dvAC))
                    want = mySig or "on"
                end
                if s._bf_dvCand ~= want then
                    s._bf_dvCand = want
                    BF:SetAuraSlotCandidates(frame, key,
                        cand and { includeDispelTypes = cand } or nil)
                end
                BF:SetAuraSlotVisualDormant(frame, key, false)
            else
                -- Creation refused (combat / secret-aura window): leave the
                -- shape signature unset so the next update retries.
                shapeSig = nil
            end
        end
        local slots = frame._bf_auraSlots
        if slots then
            for key in pairs(DISPEL_SET_KINDS) do
                if slots[key] and not live[key] then
                    BF:SetAuraSlotVisualDormant(frame, key, true)
                end
            end
        end
        -- Commit ONLY when the partition ran (or when there was nothing to
        -- partition -- every kind off is a legitimate steady state that
        -- must not re-run every update). A skipped partition leaves the
        -- signature unset so the next pass retries.
        -- v91 FIX: the type-set term commits on exactly the same condition and
        -- is cleared on exactly the same failures. Committing it while the
        -- shape signature stayed unset would be the "stale signature" trap:
        -- the retry pass would find dvTypeSig matching, and only the shape
        -- mismatch would still force step 2 -- so a second toggle flip (which
        -- moves ONLY dvTypeSig) could be swallowed.
        local commit = (partitioned or not anyOn) and shapeSig or nil
        frame._bf_dvShapeSig = commit
        frame._bf_dvTypeSig  = commit and dvTypeSig or nil
    end

    -- Create-only pass (no unit yet): the slots exist, the show gate is the
    -- caller's next :Update.
    if not unit then return end

    -- v93 hostile/charmed gate (see the suppression block near the top of
    -- this file). The dispel visuals are dispel-TYPE driven, never spell-id
    -- driven, so nothing about a charmed member stops the engine feeding
    -- them -- they would light up for every dispellable DoT the raid has on
    -- it. Folded into `show` rather than left to the container alpha so the
    -- slots go dormant and stop being evaluated. One table read.
    local dvSuppressed = IsUnitAuraSuppressed(unit)

    -- 3. Per-update: the combined restamp (its own generation guard) and the
    -- show gate. A merged slot shows while ANY of its kinds wants to show --
    -- the kinds share one button, and each kind's own visuals are already
    -- gated by its bindings.
    local live = frame._bf_dvLive
    if not live or not next(live) then return end
    local slots = frame._bf_auraSlots
    -- Resolved ONCE per call, not per slot: the border kind's ring follows the
    -- frame's border style, which does not live in the aura cache and so cannot
    -- ride _cacheGen alone.
    local gen = (ac and ac._cacheGen) or 0
    local bstyle = (BF:GetSectionProfileForFrame("borders", frame) or {}).borderStyle
    for key in pairs(live) do
        local s = slots and slots[key]
        if s then
            local kinds = DISPEL_SET_KINDS[key]
            RestampDispelSlot(frame, s, kinds, ac, gen, bstyle, key)
            local show = false
            for i = 1, #kinds do
                if _dvShow[kinds[i]] then show = true; break end
            end
            BF:SyncAuraSlotVisual(frame, key, unit, show and not dvSuppressed)
        end
    end
end

-- ============================================================
-- v50 COMBAT-CONDITIONAL AURA FILTERING (Aura Customizations →
-- Aura Filtering). Long-term debuff categories (Sated / Deserter /
-- Skyriding / Arcane Empowerment / Time Trial): toggled OFF = never
-- shown (always excluded); toggled ON = shown OUT OF COMBAT only
-- (excluded while in combat) — legacy injection parity. These are
-- NeverSecret meta-debuffs, so harmful spellID excludes are honored.
-- Raid-buff OOC display is the "raidbuffs" group in BuffsAndContainers.
-- Re-applied at Layout and at both combat edges (V12: in-combat setter
-- callability unverified — pcall'd; on denial the state corrects at the
-- next opposite edge / OOC Layout).
-- ============================================================
local _ltdExcludes = {}
function BF:GetLongTermDebuffExcludes(inCombat)
    local acp = BF.acDB and BF.acDB.profile
    local sated    = acp and acp.showSatedDebuffs or false
    local deserter = acp and acp.showDeserterDebuffs or false
    local skyride  = acp and acp.showSkyridingDebuffs or false
    local arcane   = acp and acp.showArcaneEmpowermentDebuffs or false
    local trial    = acp and acp.showTimeTrialDebuffs or false
    local sig = (inCombat and "c" or "o")
        .. (sated and 1 or 0) .. (deserter and 1 or 0) .. (skyride and 1 or 0)
        .. (arcane and 1 or 0) .. (trial and 1 or 0)
    table.wipe(_ltdExcludes)
    local function addSet(set, shown)
        if not set then return end
        if shown and not inCombat then return end  -- shown out of combat
        for sid in pairs(set) do _ltdExcludes[sid] = true end
    end
    addSet(BF.SATED_SPELL_IDS,              sated)
    addSet(BF.DESERTER_SPELL_IDS,           deserter)
    addSet(BF.SKYRIDING_SPELL_IDS,          skyride)
    addSet(BF.ARCANE_EMPOWERMENT_SPELL_IDS, arcane)
    addSet(BF.TIME_TRIAL_SPELL_IDS,         trial)
    return _ltdExcludes, sig
end

-- Combat-edge dispatcher (called from the PLAYER_REGEN handlers in
-- Initialization.lua). The per-feature appliers register themselves on
-- BF (ApplyDebuffLTDExcludes / ApplyRaidBuffGroupState).
function BF:ReapplyCombatConditionalAuraFilters()
    if not self.registeredFrames then return end
    -- Grid2 rule: config reaches every registered frame, spares included.
    for _, frame in next, self.registeredFrames do
        if frame and frame._bf_auraContainers then
            if BF.ApplyDebuffLTDExcludes then BF.ApplyDebuffLTDExcludes(frame) end
            if BF.ApplyRaidBuffGroupState then BF.ApplyRaidBuffGroupState(frame) end
        end
    end
end

-- ============================================================
-- PREVIEW COEXISTENCE: while dummy/preview auras render on a real frame,
-- its containers are suspended so live auras don't double-render under
-- the dummies. Called from ShowDummyAuras/HideDummyAuras.
-- ============================================================
function BF:SuspendFrameAuraContainers(frame)
    if not frame or frame._bf_containersSuspended then return end
    frame._bf_containersSuspended = true
    local t = frame._bf_auraContainers
    if not t then return end
    for _, c in pairs(t) do
        c._bf_shown = false
        c:Hide()
        -- PERF: suspended containers are parked DISABLED like any other
        -- hidden container (see SyncAuraGridContainer's park arm) — preview
        -- dummies can stay up for a while, and a suspended-but-bound
        -- container otherwise keeps paying engine-side candidate evaluation
        -- per aura update. The post-preview full refresh runs the Sync paths,
        -- whose recovery arms re-enable + UpdateAllAuras.
        if c._bf_enabled ~= false and pcall(c.SetEnabled, c, false) then
            c._bf_enabled = false
        end
    end
end

function BF:ResumeFrameAuraContainers(frame)
    if not frame or not frame._bf_containersSuspended then return end
    frame._bf_containersSuspended = nil
    -- Shown state is re-applied by the next indicator Update pass (the
    -- preview exit path runs a full refresh); nothing to do here.
end

-- ============================================================
-- v53 PERF: CREATE-ON-FIRST-ENABLE
--
-- Containers used to be built for every migrated feature on every unit
-- frame at frame-creation time, because the init window was believed to
-- be the only place aura infrastructure could be built. It is not:
-- container / group / slot creation is legal at ANY time while
-- UNRESTRICTED — out of combat and outside a secret-aura window. Each
-- feature's :Create now bails when the feature is switched off in that
-- frame's profile, and the feature's :Update calls
-- BF:EnsureFeatureAuraContainer the first time it sees itself enabled.
--
-- While restricted the request is queued and replayed when the
-- restriction lifts (PLAYER_REGEN_ENABLED → BF:FlushPendingAuraContainers,
-- Initialization.lua), so a profile switch mid-combat still lands.
--
-- PTR-VERIFY: AddAuraGroup / AddAuraSlot on a container created after
-- PLAYER_ENTERING_WORLD, out of combat, with
-- C_Secrets.ShouldAurasBeSecret() false. If the engine denies it, the
-- feature stays invisible until /reload — the pcall'd creation path
-- prints nothing, so watch for a feature that never appears after being
-- toggled on live.
-- ============================================================
-- ============================================================
-- v88b: THE RESTRICTED-LAYOUT REPLAY -- the actual fix for
-- "reloaded in combat, a display never came back until I reloaded again".
--
-- The v88 slot work below assumed the failure was slot CREATION. It was the
-- wrong level to fix it at. Look at what a Layout that runs inside the
-- restricted window actually does: EVERY engine call it makes is pcall'd --
-- SetPoint on the slot button (AnchorSingleBuffSlot), SetSize,
-- SetFrameLevel, SetAuraSlotFilterString, SetAuraSlotCandidateFilters,
-- SetAuraGroupCandidateFilters, the whole InitAuraButton styling walk. That
-- wall of pcalls is correct and deliberate: a denied 12.1 setter must not
-- take the frame down. But it means a Layout performed while auras are
-- secret can leave the frame in ANY partially-applied state, silently, and
-- the recovery story for every one of those sites was the same three words:
-- "the next Layout retries".
--
-- There is no next Layout. Nothing in the addon re-runs the aura indicators'
-- :Layout when combat drops. PLAYER_REGEN_ENABLED runs
-- FlushPendingAuraContainers, which only replays things that were explicitly
-- QUEUED as deferred (pendingCreates / pendingFrameBuilds) -- and a
-- combat /reload queues nothing, because by design nothing is deferred: the
-- frames build eagerly in their init window (v75), inside the restricted
-- window, and are then never revisited.
--
-- So: any frame whose aura Layout ran while restricted is flagged here, and
-- the flag is what makes the regen replay re-run that Layout. This fixes the
-- whole class at once instead of one denial site at a time, and it needs no
-- theory about WHICH call was denied -- which is the property the two
-- previous attempts lacked. Layout is idempotent and change-guarded
-- throughout, so the replay is close to free on a frame that came through
-- the window intact.
--
-- Cost: one boolean write per Layout that runs while restricted (i.e. never,
-- outside a combat reload), and one walk of the in-service frames when
-- combat ends. Nothing on the aura hot path.
-- ============================================================
function BF:NoteAuraLayoutRestricted(frame)
    if frame and not frame._isPreviewFrame and self:IsAuraCreationRestricted() then
        frame._bf_auraLayoutRestricted = true
    end
end

-- Resolved per call, not cached at load: this file loads early and
-- C_Secrets is a namespace whose contents can be populated by the client
-- after addon load. Only ever reached when a container is missing.
function BF:IsAuraCreationRestricted()
    if InCombatLockdown() then return true end
    local cs = C_Secrets
    if cs and cs.ShouldAurasBeSecret and cs.ShouldAurasBeSecret() then
        return true
    end
    return false
end

-- ============================================================
-- 2026-09-11: RECREATE INSTEAD OF RESTYLE, INSIDE A KEYSTONE
-- (plan: BuzzardFrames_RestrictedRecreate_Plan.md §3-§6, WP-A)
--
-- The problem (field report 2026-09-10): inside an active keystone auras are
-- secret for the whole run, so every POST-creation write to an aura button is
-- denied. Every live restyle path in this file (the button-spec walks, the
-- SetSize walk, slot host levels, the dispel rebind) therefore missed, committed
-- nothing, and waited for the key to end -- a settings edit made between pulls
-- did not show for 30+ minutes.
--
-- What IS allowed there (verified in game 2026-09-11, out of combat, secret
-- auras on, ChallengeMode restriction active): creating a container, adding
-- groups and slots to live containers, with initializeFrame running EAGERLY
-- inside the call, where every styling write is accepted; and parking a
-- container (SetEnabled/SetShown/SetAlpha/SetUnit). So inside that window an
-- edit that would restyle an engine object instead parks it and builds a new
-- one through the SAME creation path used at frame init -- remove the registry
-- entry, re-run the owning indicator's Layout, whose existence-guarded creation
-- arms rebuild from current settings.
--
-- Shape:
--   * Requests (BF:RequestAuraRecreate) are a set write and nothing else; they
--     are raised from inside Layouts and Updates, and the executor never runs
--     there -- only from its own timer -- so no Layout ever has its pass-local
--     container reference swapped under it.
--   * One timer, gesture-gated like BF:MouseUpOption: nothing runs while the
--     left mouse button is down, then 0.30 s of quiet, at most 2 frames per
--     tick, 1.5 s minimum spacing per (frame, kind:key) deferred to the
--     trailing edge.
--   * Parked objects leak until /reload (engine objects cannot be destroyed),
--     so every kind is capped per session and there is a global budget; at a
--     cap the edit falls back to today's key-end replay.
--   * Drift guard: a request for the very object being rebuilt, raised by the
--     rebuild's own Layout, means creation and restyle derive different specs.
--     That key is never recreated again this session (one DevPrint), so a
--     derivation gap costs one rebuild instead of the whole cap.
--
-- ALL recreate state lives in this one table: the file is close to Lua 5.1's
-- 200-locals-per-chunk limit.
-- ============================================================
-- (RC, the state table, is declared above EnsureDispelSlot: the dispel
-- geometry signature needs it there. Everything below extends it.)

-- restyleStats is created lazily by Profiler.lua and reset there field by field;
-- the recreate counters are session-long, so they are added on use.
function RC.Stat(k, n)
    local rs = BF.restyleStats
    if not rs then rs = {}; BF.restyleStats = rs end
    rs[k] = (rs[k] or 0) + (n or 1)
end

function RC.UnitOf(frame)
    return tostring(frame.unit or (frame.GetName and frame:GetName()) or "?")
end

-- Which indicator's Layout rebuilds this object. Same dispatch set as the
-- restricted-Layout replay in FlushPendingAuraContainers, plus bigDef (its own
-- Layout creates it) and the slot owners. nil = not rebuildable: the request
-- is refused and today's deferral stands.
function RC.OwnerFor(kind, key)
    if type(key) ~= "string" then return nil end
    if kind == "container" then
        if key == "bigDef" then return "bigDefIcons" end
        if key == "debuffs" or key:match("^dbc%d") then return "debuffIcons" end
        if key == "buffs" or key:match("^bfc%d") then return "buffsAndContainers" end
    elseif kind == "slot" then
        if DISPEL_SET_KINDS[key] then return "dispel" end
        if key:match("^sbc%d") or key:match("^fx") then return "buffsAndContainers" end
        if key:match("^dfx") then return "debuffIcons" end
    end
    return nil
end

function RC.DueAt(frame, kk)
    local t = RC.lastRun[frame]
    local last = t and t[kk]
    return last and (last + RC.SPACING) or 0
end

function RC.Err(err)
    geterrorhandler()(err)
end

-- ── Scheduler ────────────────────────────────────────────────────────────
function RC.Arm(delay)
    if RC.timer then RC.timer:Cancel() end
    RC.timer = C_Timer.NewTimer(math.max(delay or 0, 0), RC.OnTimer)
end

-- Decide what drives the next step once a tick is done: another tick right
-- away if a frame is ready, else the trailing edge of the earliest spacing
-- window, else a slow poll while only preview-suspended frames wait.
function RC.Reschedule()
    if not next(RC.pending) then return end
    local now, ready, nextDue, suspended = GetTime(), false, nil, false
    for frame, q in pairs(RC.pending) do
        if frame._bf_containersSuspended then
            suspended = true
        else
            for kk in pairs(q) do
                local due = RC.DueAt(frame, kk)
                if due <= now then ready = true; break end
                if not nextDue or due < nextDue then nextDue = due end
            end
        end
        if ready then break end
    end
    if ready then
        RC.ticking = true
        C_Timer.After(0, RC.Tick)
    elseif nextDue then
        RC.Arm(nextDue - now)
    elseif suspended then
        RC.Arm(RC.SUSPEND_POLL)
    end
end

function RC.OnTimer()
    RC.timer = nil
    if RC.ticking or RC.running then return end
    RC.Tick()
end

-- (RC.RunFrame is assigned below; RC.Tick only reaches it at run time.)
function RC.Tick()
    RC.ticking = false
    if not next(RC.pending) then return end
    -- Combat, or the key ended: leave everything queued. PLAYER_REGEN_ENABLED
    -- re-kicks (BF:KickAuraRecreate); the restriction-lift edge clears.
    if not BF:IsAuraRecreateWindow() then return end
    -- Gesture gate: a slider / color-picker drag collapses to ONE rebuild on
    -- the final value after release.
    if IsMouseButtonDown and IsMouseButtonDown("LeftButton") then
        RC.Arm(RC.MOUSE_POLL)
        return
    end
    local now = GetTime()
    if RC.quietUntil and now < RC.quietUntil then
        RC.Arm(RC.quietUntil - now)
        return
    end
    -- Pick up to PER_TICK frames first, run them after the walk: the owner
    -- Layouts raise new requests, and inserting keys into a table under
    -- pairs() is undefined in Lua 5.1.
    local frames, batches = {}, {}
    for frame, q in pairs(RC.pending) do
        if #frames >= RC.PER_TICK then break end
        if not frame._bf_containersSuspended then
            local b
            for kk, reason in pairs(q) do
                if RC.DueAt(frame, kk) <= now then
                    b = b or {}
                    b[kk] = reason
                end
            end
            if b then
                frames[#frames + 1] = frame
                batches[#batches + 1] = b
            end
        end
    end
    RC.running = true
    for i = 1, #frames do
        local frame, b = frames[i], batches[i]
        local q = RC.pending[frame]
        if q then
            for kk in pairs(b) do q[kk] = nil end
            if not next(q) then RC.pending[frame] = nil end
        end
        local ok, err = pcall(RC.RunFrame, frame, b)
        RC.inRecreate, RC.batch = nil, nil
        if not ok then RC.Err(err) end
    end
    RC.running = false
    RC.Reschedule()
end

-- ── Parking / retiring ───────────────────────────────────────────────────
-- A parked object is in no registry and no queue, so nothing will ever visit
-- it again: it must leave here fully parked. Every call is pcall'd (all were
-- verified allowed while secret, but a denial must not abort the batch). The
-- DORMANT candidate sweep runs only when SetEnabled(false) was refused, as a
-- container-level fallback that stops the engine assigning auras to it.
function RC.ParkContainer(c)
    local okE = pcall(c.SetEnabled, c, false)
    pcall(c.SetShown, c, false)
    pcall(c.SetAlpha, c, 0)
    -- Verified allowed in a key (2026-09-11). Unbinding stops the engine
    -- evaluating the parked container's candidates on every aura update.
    pcall(c.SetUnit, c, "none")
    c._bf_shown, c._bf_enabled, c._bf_visAlpha, c._bf_retired = false, false, 0, true
    if not okE and c._bf_groupKeys then
        for i = 1, #c._bf_groupKeys do
            pcall(c.SetAuraGroupCandidateFilters, c, c._bf_groupKeys[i], DORMANT_CANDIDATES)
        end
    end
    -- pendingTopUps is keyed by the container: its only strong ref outside the
    -- registry. A retired container must never be topped up (plan §3.3).
    pendingTopUps[c] = nil
end

-- Diagnostics only (plan §3.3): the one place a retired object is still named.
function RC.NoteRetired(frame, obj)
    local t = RC.retired[frame]
    if not t then
        t = setmetatable({}, { __mode = "v" })
        RC.retired[frame] = t
    end
    local n = (t.n or 0) + 1
    t.n = n
    t[n] = obj
end

-- Plan §3.2 B: DiscardAuraSlotVisual's body WITHOUT BumpSlotAttempt -- the
-- recreate caps replace the attempt budget here, which resets only while
-- unrestricted and would otherwise take the slot dark after ~3 in-key edits.
-- `detached` = a record already taken out of _bf_auraSlots (the executor is
-- create-before-retire: the old record is retired only once its replacement
-- exists). Without it, the live record at featureKey is retired and removed.
-- Returns the retired record.
function RC.RetireAuraSlotForRecreate(frame, featureKey, detached)
    local slots = frame._bf_auraSlots
    local s = detached or (slots and slots[featureKey])
    if not s then return nil end
    if s.active then
        s.c._bf_activeSlots = (s.c._bf_activeSlots or 1) - 1
        s.active = false
        SlotContainerShown(s)
    end
    RetireSlotKey(s.c, s.key)
    s._bf_retired = true
    if not detached and slots then slots[featureKey] = nil end
    RC.NoteRetired(frame, s)
    return s
end

-- True when every group of a container finished init on every styled button
-- (the same test that gates the creation-time style seeds).
function RC.GroupsComplete(c)
    local gks = c._bf_groupKeys
    if not gks then return false end
    for i = 1, #gks do
        local ok, done = pcall(GroupInitComplete, c, gks[i])
        if not ok or not done then return false end
    end
    return true
end

-- ── Caps ─────────────────────────────────────────────────────────────────
function RC.Cap(frame, kind, key, kk)
    local cp = RC.capped[frame]
    if not cp then cp = {}; RC.capped[frame] = cp end
    if cp[kk] then return end
    cp[kk] = true
    RC.Stat("recreateCapped")
    -- The key-end replay owns this edit now.
    if not frame._isPreviewFrame then frame._bf_auraLayoutRestricted = true end
    if not RC.cappedNotice[kind] then
        RC.cappedNotice[kind] = true
        print(("BuzzardFrames: live aura changes paused for %s on %s until the"
            .. " keystone ends (or /reload)."):format(kind, RC.UnitOf(frame)))
    end
end

-- Admit one rebuild: not drifted, not capped, under its per-object cap and the
-- global leak budget. Counts the use on admission (a failed rebuild can leak a
-- half-built object too, so failures spend the cap as well).
function RC.Admit(frame, kind, key, kk)
    local d = RC.drift[frame]
    if d and d[kk] then return false end
    local cp = RC.capped[frame]
    if cp and cp[kk] then return false end
    -- NO CAP (owner ruling 2026-09-11): rebuild counts are recorded for
    -- /bf recreate status only; nothing is refused for having rebuilt "too
    -- often". The one thing that stops a key is the loop guard in
    -- RequestAuraRecreate (same reason re-requested right after a landed
    -- rebuild), which names the offending key and reason so the compare
    -- behind it can be fixed. RC.CAP / RC.LEAK_BUDGET are kept as reporting
    -- reference values only.
    local u = RC.used[frame]
    if not u then u = {}; RC.used[frame] = u end
    u[kk] = (u[kk] or 0) + 1
    return true
end

function RC.Log(frame, e, ms)
    local p = (RC.lastPos % RC.LOG_SIZE) + 1
    RC.lastPos = p
    RC.last[p] = { unit = RC.UnitOf(frame), kind = e.kind, key = e.key,
        reason = e.reason, ms = ms, ok = e.ok and true or false }
end

-- ── Executor: one frame, every queued kind, ONE Layout per owner ─────────
function RC.RunFrame(frame, batch)
    local t0 = debugprofilestop()
    local reg = frame._bf_auraContainers
    local slots = frame._bf_auraSlots
    local entries, running, owners = {}, {}, {}
    local dispel = false
    for kk, reason in pairs(batch) do
        local kind, key = kk:match("^(%a+):(.*)$")
        local old, fn, owner
        if kind == "container" then
            owner = RC.OwnerFor(kind, key)
            old = owner and reg and reg[key]
        elseif kind == "slot" then
            owner = RC.OwnerFor(kind, key)
            -- Private-container fallback mode is not supported (plan §3.2 B).
            old = owner and BF._sharedSlotContainers ~= false and slots and slots[key] or nil
        elseif kind then
            fn = RC.handlers[kind]
        end
        if (old or fn) and RC.Admit(frame, kind, key, kk) then
            local e = { kind = kind, key = key, kk = kk, reason = reason,
                old = old, fn = fn, ok = false, leaked = 0 }
            entries[#entries + 1] = e
            running[kk] = true
            if kind == "container" then
                reg[key] = nil
                owners[owner] = true
            elseif kind == "slot" then
                slots[key] = nil
                if owner == "dispel" then dispel = true else owners[owner] = true end
            end
        end
    end
    if #entries == 0 then return end

    RC.inRecreate, RC.batch = frame, running
    -- Handler kinds first: "build" runs the full creation pass, which may
    -- itself rebuild what the owner Layouts below would.
    for i = 1, #entries do
        local e = entries[i]
        if e.fn then
            local okCall, ok, leaked = pcall(e.fn, frame, e.key)
            if okCall then
                e.ok = ok and true or false
                e.leaked = tonumber(leaked) or 0
            else
                RC.Err(ok)
            end
        end
    end
    local ind = BF.indicators
    for i = 1, #RC.OWNER_ORDER do
        local name = RC.OWNER_ORDER[i]
        local o = owners[name] and ind and ind[name]
        if o and o.Layout then
            local ok, err = pcall(o.Layout, o, frame)
            if not ok then RC.Err(err) end
        end
    end
    if dispel then
        -- SyncDispelVisualSlots' step 2 is the ONLY caller of EnsureDispelSlot
        -- and runs only when these signatures move (plan §1 row 10).
        frame._bf_dvShapeSig, frame._bf_dvTypeSig = nil, nil
        local ok, err = pcall(BF.SyncDispelVisualSlots, BF, frame, frame.unit)
        if not ok then RC.Err(err) end
    end
    RC.inRecreate, RC.batch = nil, nil

    -- Evaluate: success = a NEW, fully initialized object at the same index.
    reg = frame._bf_auraContainers
    if not reg then reg = {}; frame._bf_auraContainers = reg end
    slots = frame._bf_auraSlots
    if not slots then slots = {}; frame._bf_auraSlots = slots end
    for i = 1, #entries do
        local e = entries[i]
        if e.kind == "container" then
            local new = reg[e.key]
            if new and new ~= e.old and RC.GroupsComplete(new) then
                RC.ParkContainer(e.old)
                RC.NoteRetired(frame, e.old)
                e.ok = true
                e.leaked = #(e.old._bf_groupKeys or EMPTY_CANDIDATES) * POOL_BATCH
            else
                -- No new object, or a half-built one: put the old one back
                -- (untouched -- it was only out of the registry) and park the
                -- half-built one as leaked.
                if new and new ~= e.old then
                    RC.ParkContainer(new)
                    RC.NoteRetired(frame, new)
                    e.leaked = #(new._bf_groupKeys or EMPTY_CANDIDATES) * POOL_BATCH
                end
                reg[e.key] = e.old
            end
        elseif e.kind == "slot" then
            local new = slots[e.key]
            local nb = new and new._bf_slotButton
            if new and new ~= e.old and nb and new.initOK ~= false
               and ((not new.needsFullInit) or nb._bf_initDone == true) then
                RC.RetireAuraSlotForRecreate(frame, e.key, e.old)
                e.ok, e.leaked = true, 1
            else
                if new and new ~= e.old then
                    RC.RetireAuraSlotForRecreate(frame, e.key, new)
                    e.leaked = 1
                end
                slots[e.key] = e.old
                if DISPEL_SET_KINDS[e.key] then
                    -- The partition ran without this record: re-run it on the
                    -- next update so the restored slot is re-gated.
                    frame._bf_dvShapeSig, frame._bf_dvTypeSig = nil, nil
                end
            end
        end
    end

    local ms = debugprofilestop() - t0
    local now = GetTime()
    local lr = RC.lastRun[frame]
    if not lr then lr = {}; RC.lastRun[frame] = lr end
    local allOK, rebind = true, false
    local lrs = RC.lastReason[frame]
    if not lrs then lrs = {}; RC.lastReason[frame] = lrs end
    for i = 1, #entries do
        local e = entries[i]
        lr[e.kk] = now
        local rname = tostring(e.reason or "?")
        if lrs[e.kk] ~= rname then
            lrs[e.kk] = rname
            if RC.repeats[frame] then RC.repeats[frame][e.kk] = nil end
        end
        if e.leaked > 0 then
            RC.leaked = RC.leaked + e.leaked
            RC.Stat("leakedButtons", e.leaked)
        end
        if e.ok then
            -- Only the raid-frame kinds need the indicator re-bind below; an
            -- "ouf" batch runs on an oUF unit frame, which the raid
            -- indicators' Update must never see.
            if e.kind == "container" or e.kind == "slot" or e.kind == "build" then
                rebind = true
            end
            if e.kind == "build" then
                -- Creation only, nothing parked: not a rebuilt display.
                RC.Stat("recreateBuild")
            else
                RC.runs, RC.keyRuns = RC.runs + 1, RC.keyRuns + 1
                RC.Stat("recreate")
            end
        else
            allOK = false
            RC.Stat("recreateFail")
        end
        RC.Log(frame, e, ms)
    end
    -- A new container is born unbound; bind unit / shown / alpha now rather
    -- than on the next UNIT_AURA (plan §3.2 A step 5). Raid frames only
    -- (they own _bf_auraContainers; oUF unit frames do not).
    if rebind and frame.unit and frame._bf_auraContainers then
        local ok, err = pcall(BF.UpdateFrameIndicators, BF, frame, frame.unit)
        if not ok then RC.Err(err) end
    end
    -- The rebuild's own Layout re-flagged the frame (NoteAuraLayoutRestricted)
    -- and the flag is deliberately LEFT SET (review 2026-09-11): it is
    -- frame-wide and also covers refusals from owners and paths that never
    -- raise a request, so clearing it here could make the key-end replay
    -- skip them. The replay is idempotent and change-guarded -- on a frame
    -- where every rebuild landed it re-walks the settings and writes nothing
    -- -- so keeping the flag costs one no-op Layout per frame at key end.
    -- allOK is still reported through the stats/ring buffer.
end

-- "build" (plan §5): a relevance change inside a key. EnsureFrameAuraContainers
-- only ADDS containers that became relevant, so nothing leaks and there is no
-- cap. If it does not complete, the built latch goes back UP: with it down, the
-- first-render net in BuffsAndContainers:Update would run a full container
-- build on the aura hot path, possibly in combat. The pendingFrameBuilds entry
-- queued by InvalidateBuiltFrameContainerLatches still covers it at key end.
RC.handlers.build = function(frame)
    frame._bf_auraContainersBuilt = nil
    local ok = BF:EnsureFrameAuraContainers(frame)
    if not ok then frame._bf_auraContainersBuilt = true end
    return ok, 0
end

-- ── Exports ──────────────────────────────────────────────────────────────

-- The eligible window: kill switch on, creation restricted (auras secret),
-- out of combat, and inside an active, incomplete keystone. Outside it every
-- caller keeps today's in-place restyle / deferral exactly.
function BF:IsAuraRecreateWindow()
    local g = BF.db and BF.db.global
    if g and g.auraRecreateInKey == false then return false end
    if not self:IsAuraCreationRestricted() then return false end
    if InCombatLockdown() then return false end
    local cra = C_RestrictedActions
    local rt = Enum and Enum.AddOnRestrictionType
    if not (cra and cra.IsAddOnRestrictionActive and rt and rt.ChallengeMode) then
        return false
    end
    local ok, active = pcall(cra.IsAddOnRestrictionActive, rt.ChallengeMode)
    return (ok and active) and true or false
end

-- kind: "container" | "slot" | "ouf" | "build" (or any registered kind).
-- A set write, nothing else -- safe from inside any Layout or Update. Returns
-- true when queued. Outside the window: false, no state touched.
--
-- Only a NEW entry re-arms the quiet timer. The spec's "re-armed by every
-- request" would let a request repeated from a hot path (every UNIT_AURA)
-- starve the scheduler forever; drags are covered by the mouse-button gate.
function BF:RequestAuraRecreate(frame, kind, key, reason)
    if not frame or frame._isPreviewFrame or not kind or key == nil then return false end
    if not self:IsAuraRecreateWindow() then return false end
    if kind == "container" or kind == "slot" then
        if not RC.OwnerFor(kind, key) then return false end
        if kind == "slot" and BF._sharedSlotContainers == false then return false end
    elseif not RC.handlers[kind] then
        return false
    end
    local kk = kind .. ":" .. tostring(key)
    local d = RC.drift[frame]
    if d and d[kk] then return false end
    -- Drift guard (plan §4.3): the rebuild's own Layout asked to rebuild the
    -- object it just built.
    if RC.inRecreate == frame and RC.batch and RC.batch[kk] then
        if not d then d = {}; RC.drift[frame] = d end
        d[kk] = true
        RC.Stat("recreateDrift")
        DevPrint("|cffff0000BuzzardFrames:|r aura rebuild drift on "
            .. RC.UnitOf(frame) .. " (" .. kk .. ", " .. tostring(reason)
            .. "): creation and restyle disagree; that display now waits for"
            .. " the key end.")
        return false
    end
    local cp = RC.capped[frame]
    if cp and cp[kk] then return false end
    -- Per-key reason tally, for /bf recreate status (2026-09-11: the
    -- 10-entry ring hid why 140 first-Layout rebuilds fired).
    local rs = RC.reasons[frame]
    if not rs then rs = {}; RC.reasons[frame] = rs end
    local rk = rs[kk]
    if not rk then rk = {}; rs[kk] = rk end
    local rname = tostring(reason or "?")
    rk[rname] = (rk[rname] or 0) + 1
    -- Repeat guard (2026-09-11 field run: three single-buff slots rebuilt 10x
    -- each, two containers 6x, every rebuild "ok", every re-request from the
    -- NEXT Layout with the same reason -- a compare that can never be
    -- satisfied, which the in-Layout drift guard above cannot see). A request
    -- for a key whose last rebuild landed less than RC.REPEAT_WINDOW seconds
    -- ago, with the same reason as that rebuild, is a repeat. TALLY ONLY
    -- (2026-09-11, owner): an earlier build parked the object on the second
    -- repeat, which blocked a plain in-key Icon Size edit because the group
    -- compare misses once after every rebuild. Repeats show in
    -- /bf recreate status; nothing is refused here.
    local lr = RC.lastRun[frame]
    local lastAt = lr and lr[kk]
    if lastAt and (GetTime() - lastAt) < RC.REPEAT_WINDOW then
        local lastReason = RC.lastReason[frame] and RC.lastReason[frame][kk]
        if lastReason == rname then
            local rp = RC.repeats[frame]
            if not rp then rp = {}; RC.repeats[frame] = rp end
            rp[kk] = (rp[kk] or 0) + 1
        end
    end
    local q = RC.pending[frame]
    if not q then q = {}; RC.pending[frame] = q end
    local isNew = (q[kk] == nil)
    q[kk] = reason or q[kk] or "?"
    if isNew and not RC.running then
        RC.quietUntil = GetTime() + RC.QUIET
        if not RC.ticking then RC.Arm(RC.QUIET) end
    end
    return true
end

-- fn(frame, key) -> ok, leakedButtons. oUF_Shared registers "ouf".
function BF:RegisterAuraRecreateHandler(kind, fn)
    if type(kind) ~= "string" or type(fn) ~= "function" then return false end
    RC.handlers[kind] = fn
    return true
end

-- PLAYER_REGEN_ENABLED inside a key: FlushPendingAuraContainers cannot help
-- (it refuses while restricted), so the recreate queue is re-kicked here.
function BF:KickAuraRecreate()
    if next(RC.pending) and not RC.running then RC.Arm(RC.QUIET) end
end

-- Restriction-lift edge: the key-end replay owns whatever is still queued, and
-- rebuilding after the key would be a pure leak. Prints the key summary once
-- if anything was rebuilt during it.
function BF:ClearAuraRecreateQueue()
    wipe(RC.pending)
    if RC.timer then RC.timer:Cancel(); RC.timer = nil end
    RC.quietUntil = nil
    if RC.keyRuns > 0 then
        print(("BuzzardFrames: rebuilt %d aura displays during the key; /reload"
            .. " reclaims ~%d buttons."):format(RC.keyRuns, RC.leaked))
        RC.keyRuns = 0
    end
end

-- Snapshot for /bf recreate status and the profiler.
function BF:AuraRecreateStatus()
    local g = self.db and self.db.global
    local st = {
        enabled = not (g and g.auraRecreateInKey == false),
        window = self:IsAuraRecreateWindow(),
        pending = 0, byKind = {}, capsUsed = {}, capped = {}, drift = {},
        leakedButtons = RC.leaked, leakBudget = RC.LEAK_BUDGET,
        runs = RC.runs, keyRuns = RC.keyRuns, last = {},
    }
    for _, q in pairs(RC.pending) do
        for kk in pairs(q) do
            st.pending = st.pending + 1
            local kind = kk:match("^(%a+):") or "?"
            st.byKind[kind] = (st.byKind[kind] or 0) + 1
        end
    end
    for frame, u in pairs(RC.used) do
        for kk, n in pairs(u) do
            local kind, key = kk:match("^(%a+):(.*)$")
            local rs = RC.reasons[frame] and RC.reasons[frame][kk]
            local rlist
            if rs then
                rlist = {}
                for rname, cnt in pairs(rs) do rlist[#rlist + 1] = rname .. "x" .. cnt end
                table.sort(rlist)
            end
            st.capsUsed[#st.capsUsed + 1] = { unit = RC.UnitOf(frame), kind = kind,
                key = key, used = n, cap = RC.CAP[kind],
                reasons = rlist and table.concat(rlist, ",") or nil }
        end
    end
    for frame, t in pairs(RC.capped) do
        for kk in pairs(t) do st.capped[#st.capped + 1] = RC.UnitOf(frame) .. " " .. kk end
    end
    for frame, t in pairs(RC.drift) do
        for kk in pairs(t) do st.drift[#st.drift + 1] = RC.UnitOf(frame) .. " " .. kk end
    end
    -- Oldest first.
    for i = 1, RC.LOG_SIZE do
        local r = RC.last[((RC.lastPos + i - 1) % RC.LOG_SIZE) + 1]
        if r then st.last[#st.last + 1] = r end
    end
    return st
end

-- frame -> { featureKey = indicator }; nil while empty (no allocation on
-- the common path, no event registered).
local pendingCreates

-- Called from a feature's Update when the feature is ENABLED for this
-- frame. Returns true when the container exists afterwards. Steady-state
-- cost is two table indexes.
function BF:EnsureFeatureAuraContainer(frame, featureKey, indicator)
    -- v53 Phase 2: a slot-visual feature has no container of its own —
    -- its record on the shared slot container is the "created" marker.
    local t = frame._bf_auraContainers
    if t and t[featureKey] then return true end
    local sl = frame._bf_auraSlots
    if sl and sl[featureKey] then return true end
    if not indicator then return false end
    if BF:IsAuraCreationRestricted() then
        pendingCreates = pendingCreates or {}
        local q = pendingCreates[frame]
        if not q then
            q = {}
            pendingCreates[frame] = q
        end
        q[featureKey] = indicator
        return false
    end
    indicator:Create(frame)
    t = frame._bf_auraContainers
    if t and t[featureKey] then return true end
    sl = frame._bf_auraSlots
    return (sl and sl[featureKey]) and true or false
end

-- ============================================================
-- v72 PERF: FRAME-LEVEL CREATE-ON-DEMAND
--
-- Measured (owner's /bf loadreport, solo login, 45 unit frames = 8 main
-- headers x5 + 1 CFG x5): the span load:enter -> load:headersBuilt was
-- 7614 ms of a 10311 ms login (74%), of which InitAuraButton alone was
-- 3339.0 ms for 16,200 aura buttons and PreallocateContainerPools a
-- further 1129.4 ms. That is 900 aura containers — 20 containers and
-- 360 fully styled aura buttons on EVERY unit frame, because this
-- profile carries many custom buff/debuff containers and every one of
-- them was built on every frame at creation time.
--
-- Solo, exactly ONE of those 45 frames ever gets a unit. The other 44
-- built 880 containers and ~15,800 buttons that could never render
-- anything, and rebuilt them on every layout reload.
--
-- The fix is the one the feature containers already use one level down
-- (BF:EnsureFeatureAuraContainer above): don't build until the thing is
-- needed. The unit of "needed" here is the FRAME — a secure header child
-- with no unit assigned renders no aura, ever — so a frame gets its
-- containers the moment it enters service (BFLayout.lua OnUnitChanged),
-- with a one-field-read safety net on the first render pass that finds
-- them missing (BuffsAndContainers / DebuffIcons :Update).
--
-- Restriction handling is EnsureFeatureAuraContainer's, verbatim: while
-- BF:IsAuraCreationRestricted() (InCombatLockdown or a secret-aura
-- window) the request is QUEUED and replayed from PLAYER_REGEN_ENABLED
-- through BF:FlushPendingAuraContainers below. A frame whose first aura
-- arrives IN COMBAT therefore degrades exactly like a feature switched
-- on in combat does today: the containers are absent, every consumer's
-- `t and t[key]` guard turns that into a no-op, and the auras appear
-- when combat drops.
--
-- Pool SIZES are untouched. This changes WHEN a container is built, not
-- how many buttons it holds — everything downstream of
-- EnsureAuraGridContainer / AddAuraGroup is byte-for-byte as before.
--
-- Claims are unaffected by design: a container that is enabled claims
-- its spells out of the regular row from its DATA (container records —
-- ShouldSkipContainerForGroupType, ComputeDebuffContainerClaims,
-- GetClaimedSpells all read acDB records plus the frame's groupTypeKey,
-- never a container frame object), so a deferred container cannot leak
-- its spells back into the regular row while it waits.
-- ============================================================

-- frame -> true; nil while empty (no allocation on the common path).
local pendingFrameBuilds

-- Gate consulted by the aura indicators' :Create / :Layout container arms.
-- Returns true while this frame must not build grid containers yet.
--
-- SIDE EFFECT, deliberate and the same shape EnsureFeatureAuraContainer
-- already has: clearing the gate stamps _bf_auraContainersLive so that a
-- frame which later LOSES its unit still gets its existing containers
-- maintained by settings/geometry passes (they can never be destroyed, so
-- they must keep being re-stamped), and a refused request enqueues itself
-- for the regen replay instead of being silently dropped.
-- v75 NOTE: the v72 lazy-login deferral is RETIRED (owner ruling — it broke
-- combat reloads: every build was refused until PLAYER_REGEN_ENABLED, so a
-- mid-fight /reload showed no auras at all). BuzzardFrame_Init now stamps
-- _bf_auraContainersLive before its dispatches and _bf_auraContainersBuilt
-- after them, so every real frame is built eagerly in its init window again
-- and this gate short-circuits false for the frame's whole lifetime. The
-- gate and everything downstream of it (Update safety nets,
-- pendingFrameBuilds, the idle warm-up) remain as the REBUILD path for the
-- v74 relevance-change sweep, which clears the built latch.
function BF:ShouldDeferFrameAuraContainers(frame)
    if frame._bf_auraContainersLive then return false end
    if not frame.unit then return true end
    if self:IsAuraCreationRestricted() then
        pendingFrameBuilds = pendingFrameBuilds or {}
        pendingFrameBuilds[frame] = true
        return true
    end
    frame._bf_auraContainersLive = true
    return false
end

-- Build every grid container this frame needs, on demand. Idempotent;
-- steady-state cost is one field read.
--
-- Creation runs through the two aura indicators' own :Layout — the
-- existing settings-time path that creates, sizes, styles and filters the
-- containers (BuffsAndContainers:Layout -> EnsureBuffContainers +
-- ApplyBuffFilters; DebuffIcons:Layout -> :Create + ApplyDebuffLTDExcludes
-- + ApplyDebuffCustomContainers) — so there is still exactly ONE
-- container-building code path and nothing new lands in an :Update hot
-- path. The feature containers (bigDef, the three dispel visuals) are not
-- listed here: their own :Update already calls EnsureFeatureAuraContainer,
-- which is reached as soon as the frame has a unit.
-- v88: MAX_BUILD_FAILS. An error thrown out of the dispatches below leaves the
-- latch DOWN so the frame is rebuilt, but a build that fails deterministically
-- would then be retried on every render pass forever, spamming the error
-- handler. After this many failures the frame is marked built anyway: whatever
-- did land keeps working and the user gets one line saying a /reload is needed.
local MAX_BUILD_FAILS = 3

function BF:EnsureFrameAuraContainers(frame)
    if not frame or frame._isPreviewFrame then return false end
    if frame._bf_auraContainersBuilt then return true end
    -- v88 RE-ENTRANCY GUARD, split out of the built latch.
    --
    -- This used to be one flag, stamped BEFORE the dispatches, because the
    -- Layout calls below re-enter the gate and must not recurse. But "we are
    -- part-way through building this frame" and "this frame is built" are
    -- different claims, and conflating them made a build that ABORTED (an error
    -- thrown on a tainted stack part-way down EnsureBuffContainers, say)
    -- indistinguishable from one that completed -- permanently, because
    -- FlushPendingAuraContainers on PLAYER_REGEN_ENABLED routes straight back
    -- here and returns true on that same latch. Nothing short of a /reload
    -- recovered. Two flags: this one stops recursion, the built latch is set
    -- only after every dispatch has returned.
    if frame._bf_auraContainersBuilding then return true end
    if self:ShouldDeferFrameAuraContainers(frame) then return false end
    frame._bf_auraContainersBuilding = true
    local ok, err = pcall(function()
        local ind = self.indicators
        local b = ind and ind.buffsAndContainers
        if b then b:Layout(frame) end
        local d = ind and ind.debuffIcons
        if d then d:Layout(frame) end
        -- Legacy custom-container icon pool (the dummy/preview render path's
        -- pool, grown out of combat so the display-time growth path never runs
        -- mid-combat). Deferred off BuzzardFrame_Init with everything else —
        -- 1129.4 ms of the measured span for pools that 44 of 45 frames never
        -- rendered from.
        if self.PreallocateContainerPools then self:PreallocateContainerPools(frame) end
    end)
    frame._bf_auraContainersBuilding = nil
    if ok then
        frame._bf_auraContainersBuilt = true
        return true
    end
    -- Surface it exactly as an unprotected error would have -- the pcall is
    -- here to protect the LATCH, not to hide the failure.
    -- Same per-generation budget as the slot attempts above: a build aborted
    -- inside the restricted window must not spend the retries that run once it
    -- lifts.
    local n = ((frame._bf_auraBuildFailGen == BF._auraRecoveryGen)
        and frame._bf_auraBuildFails or 0) + 1
    frame._bf_auraBuildFails   = n
    frame._bf_auraBuildFailGen = BF._auraRecoveryGen
    geterrorhandler()(err)
    if n >= MAX_BUILD_FAILS then
        -- Stop the retry loop for THIS generation. The regen flush clears both
        -- flags, so leaving combat buys the frame one more full budget rather
        -- than condemning it for the session.
        frame._bf_auraContainersBuilt = true
        frame._bf_auraBuildGaveUp     = true
        if BF._buildGiveUpGen ~= BF._auraRecoveryGen then
            BF._buildGiveUpGen = BF._auraRecoveryGen
            DevPrint("|cffff0000BuzzardFrames:|r aura container build failed "
                .. n .. " times on a frame; giving up on it for this session. "
                .. "/reload out of combat to restore it.")
        end
        return true
    end
    return false
end

-- Replay of the queues above. Safe to call at any time; does nothing while
-- still restricted (the next call — or the feature's next Update — retries).
function BF:FlushPendingAuraContainers()
    -- ── v88: RECOVERY GENERATION ──────────────────────────────────────────
    -- Leaving combat is the one moment where a creation that was denied inside
    -- the secret-aura window can actually succeed, so it is the moment every
    -- give-up budget resets. Without this, a raid pull that denied a slot
    -- creation would have spent that slot's retries while the denial was
    -- guaranteed, and the display would stay dark until /reload -- the exact
    -- shape of the bug this whole block exists to close.
    --
    -- Guarded on the restriction, not on the event: this function is safe to
    -- call at any time and is also reached from paths other than
    -- PLAYER_REGEN_ENABLED, and bumping while still restricted would hand out
    -- budget that gets burned immediately.
    if not BF:IsAuraCreationRestricted() then
        BF:BumpAuraRecoveryGeneration()
        -- Frames that exhausted MAX_BUILD_FAILS had their built latch forced up
        -- to stop the retry loop. The new generation re-opens it, so they get
        -- one more full build attempt now that creation can succeed. Bounded
        -- walk (one pass over the in-service frames, once per combat drop) and
        -- only over frames that actually gave up.
        if self.registeredFrames then
            for _, frame in next, self.registeredFrames do
                if frame._bf_auraBuildGaveUp then
                    frame._bf_auraBuildGaveUp     = nil
                    frame._bf_auraContainersBuilt = nil
                    pendingFrameBuilds = pendingFrameBuilds or {}
                    pendingFrameBuilds[frame] = true
                end
            end
        end
        -- v88c: if anything was denied while the restriction was up, say so ONCE
        -- as combat ends. You should not have to type a diagnostic command
        -- mid-raid to find out which call failed -- and by this point the replay
        -- below is about to paper over the evidence by re-applying everything.
        if self._slotFails and not self._slotFailReported then
            self._slotFailReported = true
            DevPrint("|cffd3ff7dBuzzardFrames:|r aura slot calls were denied during"
                .. " combat -- run |cffffff00/bf sbdiag|r to see which.")
        end
        -- ── v88b: replay every Layout that ran inside the restricted window ──
        -- See the block comment on BF:NoteAuraLayoutRestricted. This is the arm
        -- that actually recovers a combat /reload: those frames were built
        -- eagerly and correctly (no deferral -- that requirement stands), but
        -- any individual engine call inside that build may have been denied and
        -- swallowed by its pcall. Re-running Layout now re-applies all of them.
        --
        -- Ordered BEFORE the queue drains below so a frame that is in both sets
        -- is rebuilt once, by the stronger path.
        --
        -- Layout is idempotent and every writer inside it is change-guarded, so
        -- a frame that came through the window intact re-walks its settings and
        -- writes nothing. Only frames actually flagged are touched, so outside a
        -- combat reload this loop does nothing at all.
        if self.registeredFrames then
            local ind = self.indicators
            for _, frame in next, self.registeredFrames do
                if frame._bf_auraLayoutRestricted and not frame._isPreviewFrame then
                    frame._bf_auraLayoutRestricted = nil
                    if not pendingFrameBuilds or not pendingFrameBuilds[frame] then
                        local b = ind and ind.buffsAndContainers
                        if b then pcall(b.Layout, b, frame) end
                        local d = ind and ind.debuffIcons
                        if d then pcall(d.Layout, d, frame) end
                        if frame.unit then
                            BF:UpdateFrameIndicators(frame, frame.unit)
                        end
                    end
                end
            end
        end
        -- Frames carrying a slot whose creation was denied. The built latch has
        -- to come down HERE and nowhere earlier: clearing it at failure time
        -- would arm the existing first-render net in BuffsAndContainers:Update,
        -- which would then run a full Layout -- CreateFrame included -- on the
        -- aura hot path mid-fight, the exact hazard the v74 relevance hook
        -- documents. Cleared here, inside the already-unrestricted branch, the
        -- rebuild rides the normal queue below.
        if pendingSlotRebuilds then
            local sq = pendingSlotRebuilds
            pendingSlotRebuilds = nil
            for frame in pairs(sq) do
                if not frame._isPreviewFrame then
                    frame._bf_auraContainersBuilt = nil
                    pendingFrameBuilds = pendingFrameBuilds or {}
                    pendingFrameBuilds[frame] = true
                end
            end
        end
    end
    -- v72: frame-level builds first. A frame that entered service while
    -- restricted has NO containers at all, and the per-feature replay below
    -- assumes the frame's own build has already happened.
    if pendingFrameBuilds and not BF:IsAuraCreationRestricted() then
        local fq = pendingFrameBuilds
        pendingFrameBuilds = nil
        for frame in pairs(fq) do
            -- v88e: a frame queued here by InvalidateBuiltFrameContainerLatches
            -- while restricted still has its built latch UP (deliberately -- so
            -- the render-path net could not rebuild it mid-fight). Clear it now
            -- that creation is legal, or EnsureFrameAuraContainers returns true
            -- on the latch and rebuilds nothing.
            frame._bf_auraContainersBuilt = nil
            if BF:EnsureFrameAuraContainers(frame) and frame.unit then
                -- Render with the fresh containers instead of waiting for
                -- the next UNIT_AURA (same reason the feature replay below
                -- re-runs the feature's Update).
                BF:UpdateFrameIndicators(frame, frame.unit)
            end
        end
    end
    if not pendingCreates then return end
    if BF:IsAuraCreationRestricted() then return end
    local q = pendingCreates
    pendingCreates = nil
    for frame, feats in pairs(q) do
        for featureKey, indicator in pairs(feats) do
            local t  = frame._bf_auraContainers
            local sl = frame._bf_auraSlots
            if not ((t and t[featureKey]) or (sl and sl[featureKey])) then
                indicator:Create(frame)
            end
            -- Re-run the feature's own Update so the fresh container gets
            -- its unit + shown state without waiting for the next event.
            if frame.unit then indicator:Update(frame, frame.unit) end
        end
    end
end

-- ============================================================
-- v73 IDLE WARM-UP FOR SPARE FRAMES
--
-- The problem v72 left behind. Container creation is combat- and
-- secret-restricted, so a header child that receives its FIRST unit
-- MID-COMBAT cannot build anything: OnUnitChanged's
-- EnsureFrameAuraContainers is refused, the frame is parked in
-- pendingFrameBuilds, and that unit shows NO auras until combat drops.
-- Before v72 every child was built at login, so a mid-combat join landed
-- on a fully built frame and just worked. Battle rez, a late joiner, a
-- roster shuffle at the pull, or simply zoning into an instance already in
-- combat all hit this.
--
-- The fix keeps v72's login win and buys the old behavior back with idle
-- time: after login, OUT OF COMBAT, walk the header children that have
-- never been built and build them in the background, so by the time a
-- fight starts every spare frame is already warm and a mid-combat join
-- lands on a built frame exactly like it did pre-v72.
--
-- BUDGET. Measured cost is ~7-8 ms per frame (20 containers / ~360 styled
-- aura buttons on the owner's profile — see the v72 header comment above).
-- ONE frame per tick is therefore about half of a 60 fps frame's 16.7 ms;
-- two would eat the whole budget in a single tick, so one it is. At a
-- 0.2 s interval the 44 spare frames of the measured solo login are warm
-- in ~9 s of idle time, spread one half-frame hitch at a time.
--
-- TERMINATION. The ticker cancels itself the moment its snapshot is
-- exhausted, and nothing polls: steady-state cost is exactly zero, not "a
-- cheap tick". It is re-armed from ONE hook — BF:ForceFramesCreation
-- (BFLayout.lua), the only place header children are ever materialised —
-- so login, a layout reload and a CFG header growing all re-arm, and
-- nothing else has to know this exists.
--
-- COMBAT. A restricted tick is SKIPPED, not queued. Warm-up frames are
-- deliberately kept OUT of pendingFrameBuilds: that queue is drained in
-- one go from PLAYER_REGEN_ENABLED because the frames in it have live
-- units whose auras the player is waiting on, and dropping 44 spare frames
-- into it would turn combat-end into a single ~350 ms freeze — precisely
-- the spike this is amortising away. The ticker simply keeps ticking and
-- resumes on its own when the restriction lifts.
--
-- COST OF BEING WARM. A warmed frame's containers must be MAINTAINED, or
-- it would enter service carrying geometry/styling from whenever it was
-- warmed. That is what setting _bf_auraContainersLive buys (see
-- WarmFrameAuraContainers below), and it means a warmed spare is walked
-- again by the per-header frame:Layout loop in BF:UpdateFramesSizeForHeader
-- on resizes and layout switches — i.e. exactly the pre-v72 cost, on
-- exactly the frames we chose to build. It is NOT paid on any steady-state
-- or aura-tick path: every maintenance and restyle walk in the addon
-- iterates activeFrames/activatedFrames (verified across Auras/,
-- Indicators/, AuraCustomizations/), and a warmed spare has no unit, so it
-- is not in there. It also renders nothing — a header child with no unit
-- is hidden, and its containers are its children.
-- ============================================================

-- 7-8 ms/frame measured; one frame is ~half a 60 fps frame budget.
local WARMUP_FRAMES_PER_TICK = 1
-- Idle pacing, not a deadline: 44 spare frames warm in ~9 s.
local WARMUP_TICK_INTERVAL   = 0.2
-- Armed from ForceFramesCreation, which at login fires once per header
-- inside the deferred LoadLayout. The delay both collapses that burst into
-- a single arm and keeps the first build well clear of the login tail.
local WARMUP_START_DELAY     = 5

local warmupTicker   -- C_Timer ticker while running; nil = not running
local warmupArmTimer -- one-shot start delay; nil = not armed
local warmupQueue    -- snapshot of unbuilt children; nil = needs re-snapshot
local warmupCursor   -- next index into warmupQueue

-- v74: warm-up telemetry (owner-reported residual post-login lag). Always
-- on: the cost is a debugprofilestop pair + a few adds PER WARMED FRAME,
-- only while the ticker runs. The login harness cannot see this window --
-- it seals 3s after PEW and the warm-up starts at 5s -- so this is the only
-- attribution the post-login hitches have. Reset when a fresh run starts;
-- a one-line chat summary prints when the queue is exhausted, and the raw
-- table stays readable via /dump BuzzardFrames._warmupStats.
-- buttons/buttonMs/containers/slots piggyback on the LoadHB counter fields
-- (InitAuraButton, EnsureAuraGridContainer, EnsureAuraSlotVisual increment
-- BF._loadHB when set); WarmFrameAuraContainers points BF._loadHB at this
-- table for the duration of each build. The login harness is sealed long
-- before the first tick, so nothing else writes those fields here.
local warmStats = {
    frames = 0, ms = 0, maxMs = 0,
    buttons = 0, buttonMs = 0, containers = 0, slots = 0,
    indCreates = 0,  -- belt: CreateIndicators' counter field, unreached here
    -- v77: MUST exist. BF._loadHB is repointed at this table for the duration
    -- of each warmed build, and the skip branch does `hb.skipped + 1`. A
    -- missing field would error inside AuraContainerWarmupTick, and because
    -- the tick's restore (`self._loadHB = hbSaved`) sits after the build, the
    -- error would strand BF._loadHB on this table for the rest of the session.
    skipped = 0,
    -- v85: MUST exist for the same reason as `skipped` above --
    -- EnsureAuraSlotVisual writes hb.slotKeys[...] while BF._loadHB points
    -- here during a warmed build, and a nil index would strand _loadHB on this
    -- table for the rest of the session.
    slotKeys = {},
}
BF._warmupStats = warmStats

local function ResetWarmupStats()
    warmStats.frames, warmStats.ms, warmStats.maxMs = 0, 0, 0
    warmStats.buttons, warmStats.buttonMs = 0, 0
    warmStats.containers, warmStats.slots = 0, 0
    warmStats.indCreates = 0
    warmStats.skipped = 0
    -- v85: wiped, not replaced -- the literal above is what BF._loadHB points
    -- at, so a fresh table here would be written to by nothing.
    if warmStats.slotKeys then wipe(warmStats.slotKeys) end
    -- v77b: HBGroupRow lazily attaches byKey to whatever BF._loadHB points at,
    -- so warm-up runs accumulate their own attribution here. Wipe per run.
    warmStats.byKey = nil
end

local function PrintWarmupSummary()
    if warmStats.frames == 0 then return end
    if not BF:IsDebugOutputEnabled() then return end
    BF:DebugPrint(string.format(
        "|cFF87CEEBBuzzardFrames|r warm-up: %d spare frames in %.0f ms"
        .. " (avg %.1f, worst %.1f) — %d containers, %d buttons"
        .. " (%.0f ms in button init)",
        warmStats.frames, warmStats.ms,
        warmStats.ms / warmStats.frames, warmStats.maxMs,
        warmStats.containers, warmStats.buttons, warmStats.buttonMs))
end

local function StopAuraContainerWarmup()
    if warmupTicker then warmupTicker:Cancel() end
    warmupTicker, warmupQueue, warmupCursor = nil, nil, nil
    PrintWarmupSummary()
end

-- Snapshot the not-yet-built children of every active header. Taken at
-- TICK time rather than arm time so it always reflects whatever the
-- header actually ended up with, however the arming call raced it.
local function SnapshotWarmupCandidates()
    local q = {}
    local groups = BF.groupsUsed
    if groups then
        for _, header in ipairs(groups) do
            local i = 1
            local child = header:GetAttribute("child1")
            while child do
                if not (child._bf_auraContainersBuilt or child._isPreviewFrame) then
                    q[#q + 1] = child
                end
                i = i + 1
                child = header:GetAttribute("child" .. i)
            end
        end
    end
    return q
end

local function AuraContainerWarmupTick()
    -- Restricted: skip this tick entirely. One check for the whole tick is
    -- sound because combat cannot begin part-way through it — nothing below
    -- yields.
    if BF:IsAuraCreationRestricted() then return end
    if not warmupQueue then
        warmupQueue  = SnapshotWarmupCandidates()
        warmupCursor = 0
    end
    local q = warmupQueue
    local budget = WARMUP_FRAMES_PER_TICK
    while budget > 0 do
        local i = warmupCursor + 1
        local frame = q[i]
        if not frame then
            -- Snapshot exhausted: every child that existed when it was taken
            -- is built. Stop for good — re-arming is ForceFramesCreation's job.
            StopAuraContainerWarmup()
            return
        end
        warmupCursor = i
        -- Already built (entered service on its own since the snapshot) is a
        -- single field read, so skipping costs nothing and is not budgeted.
        if not frame._bf_auraContainersBuilt then
            BF:WarmFrameAuraContainers(frame)
            budget = budget - 1
        end
    end
end

-- Arm (or re-arm) the warm-up. Cheap and idempotent — safe to call from
-- every ForceFramesCreation that actually created children.
function BF:StartAuraContainerWarmup()
    if warmupTicker then
        -- Running already: just make it re-snapshot, so children created
        -- after the current snapshot are picked up. Rewinding the cursor is
        -- free — built frames are skipped by a field read.
        warmupQueue = nil
        return
    end
    if warmupArmTimer then return end
    warmupArmTimer = C_Timer.NewTimer(WARMUP_START_DELAY, function()
        warmupArmTimer = nil
        warmupQueue, warmupCursor = nil, nil
        ResetWarmupStats()  -- v74: fresh attribution per run
        warmupTicker = C_Timer.NewTicker(WARMUP_TICK_INTERVAL, AuraContainerWarmupTick)
    end)
end

-- Explicit-warm-up entry: build a frame that has NEVER been in service.
--
-- Why this exists instead of just calling EnsureFrameAuraContainers. That
-- function routes through BF:ShouldDeferFrameAuraContainers, whose second
-- line is `if not frame.unit then return true end` — the whole point of
-- v72. A spare frame has no unit by definition, so the plain entry can
-- never build one; warm-up needs the in-service test bypassed and
-- everything else kept.
--
-- The bypass is one assignment: _bf_auraContainersLive. That flag is the
-- gate's own "this frame's containers are real, maintain them" latch (it
-- is what keeps a frame that LOSES its unit being maintained), and it is
-- read NOWHERE else in the tree, so stamping it up front is exactly
-- equivalent to the stamp ShouldDeferFrameAuraContainers would have made
-- one line later had the frame carried a unit. Every gate the indicators'
-- :Layout arms consult then clears, and the build below runs through the
-- one and only creation path — no second code path exists here.
--
-- The restriction check is NOT bypassed, and a refusal is not queued:
-- see the COMBAT paragraph in the block comment above.
function BF:WarmFrameAuraContainers(frame)
    if not frame or frame._isPreviewFrame then return false end
    if frame._bf_auraContainersBuilt then return true end
    if self:IsAuraCreationRestricted() then return false end
    frame._bf_auraContainersLive = true
    -- v74: telemetry wrap (see warmStats above). The saved/restored value is
    -- nil in practice (harness sealed long before the first tick); restoring
    -- it keeps this correct even for an early manual re-arm.
    local hbSaved = self._loadHB
    self._loadHB = warmStats
    local t0 = debugprofilestop()
    local ok = self:EnsureFrameAuraContainers(frame)
    local ms = debugprofilestop() - t0
    self._loadHB = hbSaved
    warmStats.frames = warmStats.frames + 1
    warmStats.ms     = warmStats.ms + ms
    if ms > warmStats.maxMs then warmStats.maxMs = ms end
    return ok
end

-- ============================================================
-- v74: CONTAINER-RELEVANCE CHANGE HOOK
--
-- Called from InvalidateClaimedSpellCache (AuraCustomizations.lua) when
-- the container creation-relevance set changes (spec change, or an edit
-- that gives a previously-empty container content -- see the CONTAINER
-- CREATION RELEVANCE block there). Clears the built latch on every real
-- frame so the one true creation path runs again and picks up containers
-- that just became relevant:
--   * in-service frames rebuild on their next render pass -- the v72
--     first-render safety net in BuffsAndContainers:Update calls
--     EnsureFrameAuraContainers when the latch is down;
--   * spares are handed back to the idle warm-up above.
-- Existing containers are untouched (the creation loops only ever ADD
-- what is missing, and a container that became IRRELEVANT keeps being
-- parked by the visibility resolvers exactly as before), so no frame's
-- already-applied state regresses -- the no-partial-effect invariant.
--
-- Cannot fire mid-combat in practice: every relevance input is blocked in
-- combat (spec switching by the game, edits by the setters' combat
-- guards).
--
-- IN-SERVICE FRAMES REBUILD EAGERLY, HERE. Deferring them to the Update
-- safety net would be a combat-creation hole: an in-service frame has
-- _bf_auraContainersLive set, which SHORT-CIRCUITS ShouldDefer before its
-- restriction check, so a latch cleared here and picked up by Update
-- after a pull would run CreateFrame("AuraContainer") on the aura hot
-- path IN COMBAT. Building them synchronously in this (by-construction
-- out-of-combat) call also re-stamps the latch immediately, so neither
-- the Update net nor the warm-up snapshot double-builds them -- exactly
-- one Layout pass per frame per relevance change. If the impossible
-- happens and this fires while restricted, in-service latches are left
-- ALONE: the frames keep rendering their existing (stale-but-consistent)
-- container set, which beats creating widgets in combat.
-- ============================================================
function BF:InvalidateBuiltFrameContainerLatches()
    -- Spares (no unit): clear the latch and hand them to the idle warm-up.
    -- In-service children are handled by the activeFrames walk below.
    local groups = self.groupsUsed
    local anySpare = false
    if groups then
        for _, header in ipairs(groups) do
            local i = 1
            local child = header:GetAttribute("child1")
            while child do
                if child._bf_auraContainersBuilt and not child.unit
                    and not child._isPreviewFrame then
                    child._bf_auraContainersBuilt = nil
                    -- v88: a relevance change is a fresh start, so the
                    -- give-up counters from a previous (combat / taint)
                    -- episode must not carry over into it.
                    child._bf_auraBuildFails = nil
                    child._bf_slotAttempts   = nil
                    anySpare = true
                end
                i = i + 1
                child = header:GetAttribute("child" .. i)
            end
        end
    end
    -- Raid-style twins (UnitFrames/Twins.lua) are not header children, and a
    -- twin whose feature is switched off has no unit -- so neither the spare
    -- walk above (groupsUsed) nor the activeFrames walk below reaches it, and
    -- a relevance change taken while it is off would be lost. Clearing the
    -- latch is the whole fix: its next activation goes through
    -- OnUnitChanged -> EnsureFrameAuraContainers and rebuilds against the new
    -- relevance set. Not handed to the idle warm-up (whose snapshot is
    -- header-scoped, and which exists for frames that may never enter
    -- service); an ACTIVE twin is in activeFrames and is handled there.
    if self.twinFrames then
        for _, twin in ipairs(self.twinFrames) do
            if not twin.unit and twin._bf_auraContainersBuilt
                and not twin._isPreviewFrame then
                twin._bf_auraContainersBuilt = nil
                twin._bf_auraBuildFails = nil
                twin._bf_slotAttempts   = nil
            end
        end
    end
    if anySpare and self.StartAuraContainerWarmup then
        self:StartAuraContainerWarmup()
    end
    -- ── v88e: RESTRICTED RELEVANCE CHANGES MUST NOT BE DROPPED ────────────
    -- The old code ran this arm ONLY when unrestricted, on the stated
    -- assumption that a relevance change "cannot fire mid-combat in practice
    -- (every relevance input is blocked in combat)". That assumption does not
    -- survive a COMBAT /RELOAD.
    --
    -- On a normal session the inputs really are combat-blocked: the game will
    -- not let you change spec, and the options setters carry combat guards. But
    -- on a reload taken mid-fight, BF.playerSpecID is being resolved for the
    -- FIRST time, not changed -- and that initial resolution runs
    -- InvalidateClaimedSpellCache, which lands here while InCombatLockdown is
    -- still up. Every in-service frame was then skipped outright, its built
    -- latch left standing, and -- the part that actually bit -- NOTHING queued
    -- it for later. The rebuild that was supposed to pick up containers that
    -- just became relevant simply never happened, for the rest of the session.
    --
    -- Restricted now means DEFER, not DISCARD: same queue the rest of this file
    -- uses (pendingFrameBuilds -> FlushPendingAuraContainers on
    -- PLAYER_REGEN_ENABLED). The latch is deliberately left UP while queued, so
    -- the first-render net in BuffsAndContainers:Update cannot pick it up and
    -- run a full container build on the aura hot path mid-fight; the flush
    -- clears it at a moment when creation is legal.
    if self.registeredFrames then
        local restricted = self:IsAuraCreationRestricted()
        for _, frame in next, self.registeredFrames do
            if frame._bf_auraContainersBuilt and not frame._isPreviewFrame then
                -- v88: see the spare arm above — fresh start, fresh budget.
                frame._bf_auraBuildFails = nil
                frame._bf_slotAttempts   = nil
                if restricted then
                    pendingFrameBuilds = pendingFrameBuilds or {}
                    pendingFrameBuilds[frame] = true
                    -- Also force a full re-Layout when the queue drains: the
                    -- relevance set changed, so this frame's settings pass is
                    -- stale as well as its container set.
                    frame._bf_auraLayoutRestricted = true
                    -- 2026-09-11 (restricted recreate, plan §5): inside a key,
                    -- out of combat, creation IS legal (verified in game), and
                    -- EnsureFrameAuraContainers only ADDS what became relevant
                    -- -- nothing is abandoned, so there is no leak. Build it
                    -- now through the recreate scheduler (gesture-gated, never
                    -- from inside this call); the queue entry above stays as
                    -- the backstop if the window closes first.
                    if self:IsAuraRecreateWindow() then
                        self:RequestAuraRecreate(frame, "build", "latches", "relevance")
                    end
                else
                    frame._bf_auraContainersBuilt = nil
                    self:EnsureFrameAuraContainers(frame)
                end
            end
        end
    end
end

-- IsUnitOffline and the visibility union it feeds moved to the top of this
-- file (see "CONTAINER VISIBILITY ALPHA — ONE WRITER, ONE UNION"): the SLOT
-- path needs them too, and it runs well above here.

-- Sync unit + shown state (called from the feature's indicator Update —
-- cheap, change-guarded).
function BF:SyncAuraGridContainer(frame, featureKey, unit, shown)
    local c = frame._bf_auraContainers and frame._bf_auraContainers[featureKey]
    if not c then return end
    if frame._bf_containersSuspended then shown = false end
    shown = shown and true or false
    if c._bf_shown ~= shown then
        c._bf_shown = shown
        c:SetShown(shown)
    end
    -- Re-enable recovery (Grid2 GridFrame.lua:188-210 parity). Grid2's
    -- UpdateAuraContainers asserts SetShown(true) AND SetEnabled(true) on
    -- every unit change, so a container that was ever disabled self-heals.
    -- Before the hidden-park arm below existed, BF's only SetEnabled writer
    -- was the zone-in resync sweep (ResyncAuraContainersAfterZone below): a
    -- container whose _bf_shown was false while the sweep ran (e.g. its unit
    -- not yet assistable/visible during the loading screen), or whose
    -- pcall'd re-enable was denied mid-sweep, was left DISABLED with no
    -- recovery path — SetShown/SetUnit here never re-enabled it, so that
    -- unit's frame rendered no auras for the rest of the session ("some raid
    -- members never show any buffs"). This arm is now also the standard
    -- resume path for containers the park arm disabled.
    -- Change-guarded: `_bf_enabled == false` is one table read in steady
    -- state (nil = never disabled = engine default enabled). UpdateAllAuras
    -- after a re-enable mirrors both Grid2's unchanged-token rebuild and the
    -- sweep's own cycle — the engine does not re-evaluate on enable alone.
    if shown and c._bf_enabled == false and pcall(c.SetEnabled, c, true) then
        c._bf_enabled = true
        pcall(c.UpdateAllAuras, c)
    end
    -- PERF: park hidden containers DISABLED. SetShown(false) only removes
    -- the container from render — the engine still evaluates every group's
    -- candidate filters against every aura update on the bound unit, per
    -- UNIT_AURA, per hidden-but-bound container. SetEnabled(false)
    -- short-circuits that evaluation for the whole container (all groups at
    -- once). Change-guarded: `_bf_enabled ~= false` covers nil (never
    -- disabled = engine default enabled) and true, one table read in steady
    -- state.
    --
    -- NOT A GRID2 PATTERN (correction, 2026-08-20). This arm and its two
    -- source citations (Performance_Review_2026-08-19 §4.1, Target Matrix §2)
    -- claimed parity with Grid2 GridFrame.lua:188-203. Reading that function:
    -- Grid2's SetEnabled(false) arm is the TEARDOWN branch for a frame with NO
    -- UNIT AT ALL; whenever a unit is present it unconditionally asserts
    -- SetShown(true) + SetEnabled(true). Grid2 never disables a live unit's
    -- container as a visibility or perf mechanism. So this park is BF-original
    -- and still carries the §4.1 "needs a PTR verify" that shipped with it.
    --
    -- OUT OF COMBAT ONLY (2026-08-20). Whether the engine honors SetEnabled
    -- in combat is exactly what was never verified, and a REFUSED setter
    -- leaves the flag un-false -- which means the next Sync pass retries, and
    -- Sync runs per UNIT_AURA per container: a failing park becomes a retry
    -- loop on the aura hot path, in combat, which is the one place it must not
    -- cost anything. §4.1's actual targets (spec-irrelevant containers,
    -- displays disabled for a layout, offline/invisible units) all begin out
    -- of combat, so the guard costs them nothing. Hiding never depended on
    -- this: SetShown(false) + the alpha gate do that, and both are plain frame
    -- ops. If the setter is ever verified callable in combat, deleting the
    -- InCombatLockdown term is the whole revert. The recovery arm above
    -- re-enables + UpdateAllAuras on the next shown edge either way.
    --
    -- ══ NEVER PARK A TRANSIENT STATE ══════════════════════════════════════
    -- `not IsUnitAuraSuppressed(unit)` below is NOT an optimization and NOT a
    -- tuning knob. It is a RULE, and it is owner-ruled (2026-08-20):
    --
    --   A container hidden because its unit went hostile or charmed must
    --   NEVER be disabled -- not in combat, not out of combat, not "just
    --   while it is safe to". Parking is categorically the wrong tool here.
    --
    -- WHY, so nobody re-derives it as a saving: the state lasts SECONDS. A
    -- mind control breaks, a faction flip reverts, and the unit is friendly
    -- again. Parking buys at most a few seconds of skipped engine evaluation
    -- on ONE unit, and pays for it with a disable on the entry edge and an
    -- enable + full UpdateAllAuras rebuild on the exit edge -- on the exact
    -- frame that is churning hardest, at the exact moment the auras have to
    -- come back instantly and correctly. That trade is bad even when the
    -- setter succeeds, and worse when it does not.
    --
    -- Hiding a suppressed unit is SetShown(false) + the alpha gate. That IS
    -- the mechanism, it is complete, and it needs nothing from this arm.
    -- Do not delete the term. Do not "restore parity" with the other gates.
    -- The other gates park durable states (a display disabled for a layout, a
    -- spec-irrelevant container, an offline unit); this one is a blink.
    -- ══════════════════════════════════════════════════════════════════════
    if not shown and c._bf_enabled ~= false and not InCombatLockdown()
        and not IsUnitAuraSuppressed(unit)
        and pcall(c.SetEnabled, c, false) then
        c._bf_enabled = false
    end
    if shown and unit and c:GetUnit() ~= unit then
        c:SetUnit(unit)
    end
    -- Hide auras on units we can't see (freshly invited, different phase,
    -- cross-shard) or who are offline: the engine AuraContainer keeps
    -- rendering stale, unfiltered aura data for a bound-but-unreachable unit,
    -- and candidate-filter parking cannot clear engine DISPLAY state, so the
    -- suppression is an alpha drop. Vehicle taint and the cinematic gate fold
    -- into the same decision. All of that now lives in one place — see the
    -- header block at the top of this file for why.
    ApplyContainerVisAlpha(c, unit, shown)
end

-- Re-evaluate the visibility gate for every grid container on every frame
-- showing `unit`. Called from the Offline status on BOTH connection
-- transitions (Statuses/Offline.lua). Needed because the gate above
-- otherwise only re-runs inside feature indicator Updates, which are
-- UNIT_AURA-driven — and UNIT_AURA goes silent for a disconnected unit,
-- so the containers of an offline cross-faction member sat at alpha 1
-- while the engine repainted them with junk. Same staleness class as the
-- missingRaidBuff offline binding (BFStatus.lua offline bind comment).
function BF:RefreshAuraContainerVisibilityForUnit(unit)
    if not unit then return end
    local bucket = self.frames_of_unit and rawget(self.frames_of_unit, unit)
    if not bucket then return end
    -- Same union as every other writer, including the cinematic term: a
    -- phase/connection event landing during a cinematic must not re-raise the
    -- alpha the gate is holding down.
    for frame in next, bucket do
        local t = frame._bf_auraContainers
        if t then
            for _, c in pairs(t) do
                ApplyContainerVisAlpha(c, unit, c._bf_shown)
            end
        end
        -- The SHARED SLOT HOST too (2026-08-20). It is not in
        -- _bf_auraContainers -- it hangs off _bf_auraSlots via s.c -- so
        -- every caller of this function (offline edge, phase edge, the
        -- ticker's visibility backstop) was refreshing the grid containers
        -- and silently leaving single-buff / fx / dispel-visual slots at
        -- whatever alpha they last held, showing the same engine junk the
        -- grid path had just been cleaned of. SlotContainerShown applies the
        -- identical union, so this is the same expression, not a second one.
        -- No dedup: a frame has one host, and ApplyContainerVisAlpha is
        -- change-guarded, so a repeat is a table read and a compare.
        local sl = frame._bf_auraSlots
        if sl then
            for _, s in next, sl do
                local sc = s.c
                if sc then ApplyContainerVisAlpha(sc, unit, sc._bf_shown) end
            end
        end
    end
end

-- ============================================================
-- v97 (2026-08-27): Grid2 GridFrame.lua:184-205 UpdateAuraContainers parity.
--
-- Grid2 runs this from every unit-change path (OnAttributeChanged,
-- UpdateFramesOfUnit(unit, true) in the roster sweep, and the unit-removed
-- branch). BF had no analog: SyncAuraGridContainer / SyncAuraSlotVisual are
-- change-guarded on the unit TOKEN, so a roster shuffle that swaps the
-- player behind an unchanged token (raid11 becomes raid10, a group move)
-- never reached the engine and the container kept the previous occupant's
-- icons indefinitely; and a frame that lost its unit left every container
-- bound and enabled on the departed token.
--
--   unit present : token differs  -> SetUnit(unit)      (Grid2 :191)
--                  token unchanged -> UpdateAllAuras()  (Grid2 :193, the
--                                     same-token / new-occupant rebuild)
--   no unit      : SetEnabled(false) + SetShown(false) + SetUnit('none')
--                                                       (Grid2 :200-202)
--
-- Deliberate deviation: Grid2 asserts SetShown(true)+SetEnabled(true) on
-- every present-unit pass. BF's shown/enabled flags are owned by
-- SyncAuraGridContainer / SlotContainerShown with their own gates (per-Layout
-- toggles, relevance, suppression), so this only re-enables what BF itself
-- parked on a container it wants shown, and re-runs the alpha gate. Covers
-- the grid containers AND the shared slot host (which hangs off
-- _bf_auraSlots, one host per frame). Everything engine-side is pcall'd:
-- the roster sweep runs inside combat.
-- ============================================================
local function EachFrameAuraContainer(frame, fn)
    local t = frame._bf_auraContainers
    if t then
        for _, c in pairs(t) do fn(c) end
    end
    local sl = frame._bf_auraSlots
    if sl then
        local seen
        for _, s in next, sl do
            local sc = s.c
            if sc and sc ~= seen then
                seen = sc
                fn(sc)
            end
        end
    end
end

local function UpdateAuraContainer_Unit(c, unit)
    if c:GetUnit() ~= unit then
        pcall(c.SetUnit, c, unit)
    else
        pcall(c.UpdateAllAuras, c)
    end
    if c._bf_shown and c._bf_enabled == false
        and pcall(c.SetEnabled, c, true) then
        c._bf_enabled = true
    end
    ApplyContainerVisAlpha(c, unit, c._bf_shown)
end

local function UpdateAuraContainer_NoUnit(c)
    if c._bf_enabled ~= false and pcall(c.SetEnabled, c, false) then
        c._bf_enabled = false
    end
    if c._bf_shown ~= false then
        c._bf_shown = false
        c:SetShown(false)
    end
    pcall(c.SetUnit, c, 'none')
end

function BF:UpdateFrameAuraContainers(frame, unit)
    if not frame or frame._isPreviewFrame then return end
    if unit then
        EachFrameAuraContainer(frame, function(c) UpdateAuraContainer_Unit(c, unit) end)
    else
        EachFrameAuraContainer(frame, UpdateAuraContainer_NoUnit)
    end
end

-- v99: `/bf gates` runtime switch. Flips one gate (or all), drops every
-- cached answer the gates fed, and re-runs the aura indicators + the alpha
-- union on every live frame so the change lands without a reload.
function BF:SetAuraGate(name, on)
    if name == "all" then
        for _, k in ipairs(BF.AURA_GATE_NAMES) do
            if k ~= "assist4" then SetGate(k, on) end
        end
    else
        SetGate(name, on)
    end
    wipe(auraSuppressed)
    if not GATE_VEHICLE or not GATE_CINEMATIC then
        self._cinematicGateActive = GATE_CINEMATIC and self._cinematicGateActive or false
        local frames = self.activatedFrames
        if frames and not GATE_VEHICLE then
            for frame in pairs(frames) do
                local ct = frame._bf_auraContainers
                if ct then for _, c in pairs(ct) do c._bf_vehicleTainted = nil end end
            end
            BF._bf_anyVehicleTainted = nil
        end
    end
    if self.UpdateAllIndicators then self:UpdateAllIndicators() end
    local frames = self.activatedFrames
    if frames then
        for _, unit in pairs(frames) do
            if unit and self.RefreshAuraContainerVisibilityForUnit then
                self:RefreshAuraContainerVisibilityForUnit(unit)
            end
        end
    end
end
function BF:AuraGateStatus()
    local out = {}
    for _, k in ipairs(BF.AURA_GATE_NAMES) do
        out[#out + 1] = k .. "=" .. (GateOn(k) and "|cff40ff40on|r" or "|cffff4040off|r")
    end
    return table.concat(out, "  ")
end

-- Cinematic alpha gate (2026-08-16). Cinematics briefly flip the player's
-- faction; the engine repaints every container with stale/unfiltered junk
-- the moment the flip lands, BEFORE UNIT_FACTION fires — so the rescan in
-- Auras/Auras.lua can only repair the junk after it has been on screen.
-- This gate closes on CINEMATIC_START/PLAY_MOVIE (the earliest signals the
-- client offers, wired in Auras/Auras.lua) and re-opens deferred after the
-- stop event, with the rescan running while everything is still invisible.
-- Same failure class and same alpha-gate shape as the vehicle-taint gate:
-- engine DISPLAY state that candidate-filter parking cannot clear. Grid2
-- registers no cinematic events at all (its containers show this junk), so
-- there is no Grid2 pattern to copy — the shape is BF's own vehicle gate.
--
-- Single-writer rule: this function NEVER writes an alpha the steady-state
-- writers wouldn't also compute — it sets the flag and re-runs the same
-- union expression per container, so an overlapping gate (vehicle taint,
-- visibility, offline) is never undone. Returns true on an actual edge.
function BF:ApplyCinematicAuraGate(on)
    on = on and true or false
    if not GATE_CINEMATIC then on = false end  -- v99
    if (self._cinematicGateActive or false) == on then return false end
    self._cinematicGateActive = on
    local frames = self.activatedFrames
    if not frames then return true end
    -- self._cinematicGateActive is already set above, and the shared union
    -- reads it — so this loop asserts exactly what every other writer would
    -- compute for the same container, which is the single-writer rule stated
    -- above expressed as code rather than as a comment.
    for frame, unit in pairs(frames) do
        local t = frame._bf_auraContainers
        if t then
            for _, c in pairs(t) do
                ApplyContainerVisAlpha(c, unit, c._bf_shown)
            end
        end
    end
    return true
end

-- v84 (2026-08-15): ZONE-IN CONTAINER RESYNC. SyncAuraGridContainer only
-- acts on a CHANGED unit token, so a dungeon→dungeon transition with
-- unchanged party tokens left engine containers carrying whatever internal
-- state the loading screen reset — owner-observed: one member's buffs gone
-- until his death/respawn (the aura wipe+reapply storm performed the rebuild
-- this sweep now does deliberately). The fix: after every zone transition,
-- force a full UpdateAllAuras engine rebuild on every container, unchanged
-- token or not.
--
-- Also re-fires BF_UnitUpdated per roster unit first — roster-refresh
-- semantics for a world boundary. Its three listeners are all caches that
-- WANT re-priming after a loading screen: the Offline status
-- (PARTY_MEMBER_ENABLE fired during OUR loading screen is missed forever,
-- and the visibility gate below folds the offline flag), the phase cache,
-- and the single-aura trackers. Then the visibility gate itself is re-run
-- per unit with fresh UnitIsVisible/offline reads.
--
-- Called from the PLAYER_ENTERING_WORLD chain (Range.lua wrapper),
-- non-login/reload only — once per loading screen, never on the combat
-- hot path. pcall'd per container: zone-in can overlap restricted windows.
function BF:ResyncAuraContainersAfterZone()
    local units = self.roster_guids
    if units then
        for unit in next, units do
            self:SendMessage("BF_UnitUpdated", unit)
        end
    end
    local frames = self.activatedFrames
    if not frames then return end
    for frame, unit in pairs(frames) do
        local t = frame._bf_auraContainers
        if t then
            for _, c in pairs(t) do
                -- v84c: FULL REBIND, not just UpdateAllAuras. A container
                -- whose unit BINDING went stale across the loading screen
                -- renders nothing even for fresh casts, and no amount of
                -- UpdateAllAuras on the stale binding repairs that
                -- (owner-observed: units still buff-less after the v84b
                -- rebuild sweep). Cycle the binding the way the engine sees
                -- a fresh assignment: disable, unbind, re-enable, rebind,
                -- rebuild. All pcall'd; enabled-state restored to match the
                -- container's shown bookkeeping afterwards.
                pcall(c.SetEnabled, c, false)
                c._bf_enabled = false
                pcall(c.SetUnit, c, 'none')
                if unit then
                    -- Book-keep the outcome: on a denied re-enable the flag
                    -- stays false and SyncAuraGridContainer's recovery arm
                    -- retries on the next indicator Update (this sweep runs
                    -- in the PEW window, where engine setters can be denied
                    -- — a fire-and-forget pcall here permanently killed the
                    -- frame's auras before the recovery arm existed).
                    if pcall(c.SetEnabled, c, true) then
                        c._bf_enabled = true
                    end
                    pcall(c.SetUnit, c, unit)
                    pcall(c.UpdateAllAuras, c)
                end
                if c._bf_shown == false then
                    -- Hidden container: parked disabled, exactly like Grid2's
                    -- unit-nil branch. The recovery arm re-enables it the
                    -- moment a Sync pass wants it shown again.
                    if pcall(c.SetEnabled, c, false) then
                        c._bf_enabled = false
                    end
                end
            end
            if unit and self.RefreshAuraContainerVisibilityForUnit then
                self:RefreshAuraContainerVisibilityForUnit(unit)
            end
        end
    end
end

-- Slot-visual counterpart of SyncAuraGridContainer (called from the
-- feature's indicator Update — cheap, change-guarded). `shown` gates the
-- FEATURE, which on a shared container means parking the slot rather
-- than hiding a container; the container itself follows the number of
-- live slots and owns the single SetUnit for all of them. Frame
-- recycling therefore needs nothing extra: the first slot feature to
-- update after the swap re-units the container for every other one.
function BF:SyncAuraSlotVisual(frame, featureKey, unit, shown)
    local s = frame._bf_auraSlots and frame._bf_auraSlots[featureKey]
    if not s then return end
    shown = shown and true or false
    if s.shown ~= shown then
        s.shown = shown
        UpdateSlotActive(s)
    elseif s.dormantApplied == nil then
        ApplySlotDormancy(s)  -- denied while restricted — retry
    end
    if SlotContainerShown(s) then
        local c = s.c
        -- Same re-enable recovery as SyncAuraGridContainer (the zone-in
        -- resync sweep cycles the shared slots container too, and a denied
        -- pcall'd re-enable there used to strand it disabled — killing every
        -- fx/dispel/single-buff slot visual on the frame for the session).
        -- One table read in steady state.
        if c._bf_enabled == false and pcall(c.SetEnabled, c, true) then
            c._bf_enabled = true
            pcall(c.UpdateAllAuras, c)
        end
        if unit and c:GetUnit() ~= unit then
            c:SetUnit(unit)
        end
    end
end
