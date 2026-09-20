--[[
BuzzardFrames: Indicators/BuffsAndContainers.lua
Unified buff + custom-container icon indicator. Replaces the
previous BuffIcons and CustomContainers indicators.

Design (see REFACTOR_PLAN_BuffsContainers.md):
  - One indicator bound to the buffs status.
  - Reads frame._bf_activeGroups (pre-filtered at layout / cache-build
    time) and renders each group via BF:RenderAuraGroup.
  - All settings-derived visibility decisions live in the active-groups
    list; the Update body does no settings checks.

Also carries the Resto-Druid swiftmendable + dead/offline cleanup work
that used to live in CustomContainers:Update (orthogonal to the
buffs+containers split, but lived there for lack of a better home).
]]

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")
-- Addon namespace: curated SpellData, read by SingleBuffNeedsOwnGroup's
-- defensive-category promotion term (v81).
local _, ns = ...

local UnitIsDeadOrGhost = UnitIsDeadOrGhost

-- v67: file-local _buffsStatus / _buffMatchStatus upvalues removed
-- (12.1-only). Their readers were the deleted Buffs:GetIcons render pass
-- and the buffmatch cache hand-off to the deleted buffHighlight indicator;
-- both grepped to zero references in this file.

local BuffsAndContainers = BF.indicatorPrototype:new("buffsAndContainers")

-- Per-indicator Create: build the buff icon pool.
-- Custom-container icons (parent.SF_CustomContainerIcons) are still
-- grown lazily on demand by ensureContainerIconPool in
-- AuraCustomizations.lua — not allocated here.
function BuffsAndContainers:CanCreate(parent) return not parent._isPreviewFrame end
-- GetFrame must be truthy on the container path too: the frame:Layout()/
-- LayoutFrameIndicators dispatch loops (RefreshAllAuras, profile change,
-- resize) gate on it — returning only the legacy pool made those paths
-- silently skip this indicator's Layout on 12.1 (global-auraText settings
-- changes appeared dead). The container IS the indicator's widget there.
function BuffsAndContainers:GetFrame(parent)
    return parent.buffFrames
        or (parent._bf_auraContainers and parent._bf_auraContainers.buffs)
end

-- ============================================================
-- 12.1 CONTAINER PATH
-- General buffs: one container ("buffs") with the mode filter +
-- category negations, whitelist via candidateFilters.includeSpellIDs,
-- container-claimed spells excluded. Custom BF-containers: one
-- AuraContainer each ("bfc"..ci) with includeSpellIDs = assigned spells.
-- NOT carried to this path (plan cut list): SotF glow, BuffMatch
-- highlights (separate slot redesign). Swiftmendable IS carried (v53):
-- name mirror + frame effects via slot visuals; health-text recolor
-- removed (no 12.1 path).
-- ============================================================
local function BuffButtonSpec(frame, size)
    local ac = BF:GetAuraCacheForFrame(frame)
    local db = BF:GetSectionProfileForFrame("tooltips", frame)
    local autoScale = ac.buffAutoScale
    local spec = {
        size             = size,
        showDuration     = ac.showBuffDuration and true or false,
        durationFont     = ac.buffDurationFont,
        durationFontSize = autoScale and 11 or (ac.buffFontSize or 11),
        durationBorder   = ac.buffDurationBorder or "OUTLINE",
        durationScale    = autoScale and (size / 12 * (ac.buffTimerScale or 1.0)) or nil,
        fontColor        = ac.buffFontColor,
        durationCurve    = ac.expiringCurveBuff,
        hideDurationAbove1Min = ac.hideDurAbove1MinBuff,
        disableSwipe     = ac.disableBuffSwipe,
        disableSpark     = ac.disableBuffSpark,
        reverseSwipe     = ac.reverseBuffSwipe,
        dispelBorder     = false,
        borderColor      = ac.buffBorderColor,
        blizzardBorders  = ac.buffBlizzardBorders,
        borderStyle      = ac.buffBorderStyle,
        borderThickness  = ac.buffBorderThickness,
        tooltipEnabled   = ac.showBuffTooltip or false,
        tooltipInCombat  = ac.showBuffTooltipInCombat or false,
        tooltipPos       = db and db.buffTooltipPosition or "default",
        tooltipFrameY    = BF.TooltipBelowFrameY(frame, ac.buffAnchor, ac.buffOffsetY, size),
    }
    -- Stack text (Aura Text > Stack Text). Folded onto the button spec so
    -- ContainerFactory's ApplyStackCountStyle can stamp it at creation and
    -- on every restyle walk -- see BF:ApplyStackTextSpec.
    return BF:ApplyStackTextSpec(spec, ac, size)
end

-- v65: the wrap budget a flow-anchored single buff costs its HOST.
--
-- The budget is computed from `perRow * size`, i.e. from the HOST's size -- an
-- over-sized group would overflow the line and, on the debuff path, was
-- PTR-observed as big icons overlapping the neighboring group. Under-sized
-- entries need no correction (they leave the line short, which is harmless),
-- so this only ever reports growth.
--
-- v92: a single buff can now flow inside THREE kinds of host (the buffs row,
-- Big Defensive, any multi-icon buff container), so this answers "the largest
-- icon size any entry anchored to THIS host resolves to" and each host's
-- geometry builder turns that into its own slack (size - hostBase). Reporting
-- the SIZE rather than a mult is what lets one walk serve all three bases.
--
-- MEMOISED per (ac, groupTypeKey): the consumers are per HOST, so without it
-- the bfc arm would re-walk every container for every container -- O(n^2) per
-- frame per Layout. The memo is dropped at the top of :Layout and :Create,
-- which is sufficient because every settings edit arrives as a fresh Layout
-- pass; nothing else can move an entry's size or its anchor.
--
-- The same walk answers a SECOND question -- "does this host have any anchored
-- entry at all" -- because the two have exactly one input (the resolver) and
-- splitting them would mean walking twice. The membership answer is what lets
-- BF.ApplyBigDefAnchoredGroups skip a whole flow collection; it is NOT
-- derivable from _sbSizeByHost, since a default-mode entry is anchored but
-- reports no size (see below).
local _sbSizeByHost = {}   -- hostKey -> largest CUSTOMIZED entry size
local _sbHostAny    = {}   -- hostKey -> true if ANY entry is anchored to it
local _sbSizeAC, _sbSizeGT = nil, nil
local function InvalidateSingleBuffHostSizes()
    _sbSizeAC, _sbSizeGT = nil, nil
end

local function EnsureSingleBuffHostMemo(ac, groupTypeKey)
    if _sbSizeAC == ac and _sbSizeGT == groupTypeKey then return end
    table.wipe(_sbSizeByHost)
    table.wipe(_sbHostAny)
    _sbSizeAC, _sbSizeGT = ac, groupTypeKey
    local containers = BF:GetActiveCustomBuffContainers()
    if not containers then return end
    for ci = 1, #containers do
        local c = containers[ci]
        local h = BF:GetSingleBuffAnchorHost(c, groupTypeKey)
        if h then
            -- Read h.ci NOW. Host descriptors are SHARED, interned and
            -- re-pointed per call -- never stash one across a call.
            local hk = (h.kind == "bfc") and ("bfc" .. h.ci) or h.kind
            _sbHostAny[hk] = true
            -- v92 (owner): a "Show (Default Buff)" entry renders at the HOST's
            -- size (mult 1 -- see EmitSingleBuffHostGroups), so it costs the
            -- line NO extra budget and is skipped for the SIZE answer. It must
            -- be skipped rather than measured: ResolveContainerGeometry answers
            -- the BUFFS baseline for these (they have no size of their own),
            -- which on a host with a smaller base would inflate the slack for
            -- pixels the icon never occupies -- a bfc at size 10 would report
            -- 12 and buy +2 of wrap budget for an icon drawn at 10. The
            -- rendered size and the wrap budget have to be derived by the SAME
            -- rule or the row wraps against a number nothing renders at.
            -- It still counts for _sbHostAny: it is anchored, it renders.
            if c.singleBuffCustomized ~= false then
                local eSize = BF:ResolveContainerGeometry(c, groupTypeKey, ac)
                if eSize and eSize > 0 and eSize > (_sbSizeByHost[hk] or 0) then
                    _sbSizeByHost[hk] = eSize
                end
            end
        end
    end
end

-- hostKey is the flow builder's bucket token: "buffs" / "bigDef" / "bfc"..ci.
local function MaxSingleBuffSizeFor(ac, groupTypeKey, hostKey)
    if not ac then return nil end
    EnsureSingleBuffHostMemo(ac, groupTypeKey)
    return _sbSizeByHost[hostKey]
end
-- Exposed for BigDefIcons.lua's geometry builder (the bigDef host's slack).
BF.MaxSingleBuffSizeFor = MaxSingleBuffSizeFor

-- Deliberately CONSERVATIVE: it ignores singleBuffHidden and the per-Layout
-- visibility the collection pass applies, so it can answer "yes" for an entry
-- that will collect to nothing. A false yes costs one walk; a false no would
-- lose an icon.
local function HostHasAnchoredSingleBuffs(ac, groupTypeKey, hostKey)
    if not ac then return false end
    EnsureSingleBuffHostMemo(ac, groupTypeKey)
    return _sbHostAny[hostKey] == true
end

-- Stamp geo.lineSizeSlack for one host. Same arithmetic the v65 buffs arm did
-- (slack = entrySize - hostSize), just expressed once for all three hosts.
local function ApplyHostLineSlack(geo, ac, groupTypeKey, hostKey)
    local base = geo.size
    if not (base and base > 0) then return end
    local m = MaxSingleBuffSizeFor(ac, groupTypeKey, hostKey)
    if m and m > base then geo.lineSizeSlack = m - base end
end

local function BuffGeneralGeo(frame)
    local ac = BF:GetAuraCacheForFrame(frame)
    local groupTypeKey = BF.ResolveGroupTypeKey and BF:ResolveGroupTypeKey(frame)
    local geo = {
        size          = ac._roundedBuffSize or 12,
        anchor        = ac.buffAnchor or "BOTTOMRIGHT",
        offsetX       = ac.buffOffsetX,
        offsetY       = ac.buffOffsetY,
        growDirection = ac.buffGrowDir or "LEFT",
        perRow        = ac.buffsPerRow,
        spacing       = ac.buffSpacing,
        rowSpacing    = ac.buffRowSpacing,
        maxIcons      = ac.maxBuffs or 8,
        canLift       = true,  -- aurasAbovePowerBar (resolved in ApplyAuraGridGeometry)
    }
    ApplyHostLineSlack(geo, ac, groupTypeKey, "buffs")
    return geo
end

-- v44 REWRITE: the old version read fields that don't exist on container
-- configs (c.size / c.iconsPerRow / c.maxIcons — stored names are
-- buffSize / buffsPerRow / maxBuffs) and truthy-checked
-- containerUsesBuffSettings (nil means TRUE in the legacy resolver).
--
-- v61: all field resolution moved out to BF:ResolveContainerGeometry
-- (AuraCustomizations.lua), the one resolver shared with the legacy engine
-- path. It takes the per-Layout scope key, so a container's
-- groupSettings[<flatID>] GEOMETRY overrides now apply on this path too —
-- previously only its *visibility* override was honored here (see
-- ApplyBuffFilters below), and the geometry was silently dropped while the
-- legacy path always applied it.
--
-- `ac` is a real parameter now (it feeds the resolver's Buffs baseline)
-- rather than the dead argument it used to be; every caller already holds
-- one, and this runs per container per frame. `frame` is gone with
-- BuffGeneralGeo — the resolver supplies every field that used to be
-- inherited from it.
--
-- The returned table must stay a FRESH allocation: ApplyAuraGridGeometry
-- retains it as container._bf_lastGeo for the power-bar re-anchor path.
--
-- v92: `ci` is optional and exists for ONE reason -- a multi-icon container can
-- now be the HOST of flow-anchored single buffs, and an over-sized anchored
-- entry costs the container's line the same wrap budget it costs the buffs row
-- (see ApplyHostLineSlack). Callers with no index in hand (the single-buff slot
-- arm, the sbdiag probe) pass none and get no slack -- correct either way,
-- since a single buff is never a host.
local function ContainerGeo(c, ac, groupTypeKey, ci)
    local size, maxIcons, spacing, rowSpacing, perRow, anchor, offX, offY, growDir
        = BF:ResolveContainerGeometry(c, groupTypeKey, ac)
    local geo = {
        size          = size,
        anchor        = anchor,
        offsetX       = offX,
        offsetY       = offY,
        -- Anchor-aware normalization of legacy single-axis values (v34
        -- parity with the Auras sections; CalcAuraOffsets does the same
        -- for the legacy engine). Done here, not in the resolver: the
        -- legacy CalcContainerOffsets matches single-axis strings.
        growDirection = BF.NormalizeGrowDirection(growDir, anchor),
        perRow        = perRow,
        spacing       = spacing,
        rowSpacing    = rowSpacing,
        maxIcons      = maxIcons,
        -- Legacy custom containers lift too (AuraGroupHelpers stamps
        -- canLiftAboveBar on the container group config).
        canLift       = true,
    }
    if ci and not c.singleBuff then
        ApplyHostLineSlack(geo, ac, groupTypeKey, "bfc" .. ci)
    end
    return geo
end

-- v61: per-container caster scope. Custom containers have always fetched
-- "HELPFUL|PLAYER" -- only auras YOU cast (owner decision, v59). The Single
-- Buff entry's Conditions tab exposes that as an "Own only" toggle, so a
-- container can opt out of the PLAYER restriction. (v63: it used to live on the
-- creation form and on the Position subtab, under the name "Only auras I cast".
-- A new entry's default is derived from the curated buff list's category --
-- see defaultOwnOnlyFor in Options_AuraCustomizations.lua.)
--
-- (v64: `containerAnyCaster` is superseded by `containerCasterScope` -- see the
-- storage note below. It is still READ, for profiles written before v64.)
--
-- All THREE container filter sites must agree (creation below, the main-group
-- re-stamp and the per-spell groups in ApplyBuffFilters); a container created
-- under one filter and re-stamped under another would flip behavior on the
-- next settings pass. This is why the scope stays a single derived filter
-- string from one function, rather than something each site computes.
--
-- 12.1 container path only. The legacy 12.0.7 renderer scans once per frame
-- with the spec-wide filter string (_fbsAuraFilter), which has no per-container
-- dimension, so this option cannot be honored there.
-- v64: two states became three -- "Applied By": Me Only / Not Me / Anyone.
--
-- STORAGE, and why there is no migration. The v61-v63 field was
-- `containerAnyCaster`, an OPT-OUT boolean (nil = me only, true = anyone). The
-- new field is `containerCasterScope` ("notme" / "any"; nil = me only), and the
-- old one is translated HERE, at read time, rather than rewritten in the DB --
-- so an untouched profile keeps behaving exactly as it did and only a
-- deliberate edit ever writes the new field. Owner mapping: Own only ON -> Me
-- Only, Own only OFF -> Anyone.
--
-- MECHANISM: the aura filter string, matching Grid2, which expresses the same
-- three-way choice as 'HELPFUL|PLAYER' / 'HELPFUL|!PLAYER' / 'HELPFUL'
-- (Grid2Options StatusAurasNew.lua, Grid2 GridDefaults.lua, both reaching
-- AddAuraGroup / AddAuraSlot). The `!TOKEN` grammar is already proven against
-- this engine by our own general-buffs filter, which ships
-- "|!BIG_DEFENSIVE|!EXTERNAL_DEFENSIVE|!IMPORTANT" through
-- SetAuraGroupFilterString.
--
-- Deliberately NOT candidateFilters.isFromPlayerOrPlayerPet, though the engine
-- supports it: candidate filters are set per group by four separate sites that
-- each REPLACE the whole table, so caster scope would have to be threaded into
-- all of them and the "three sites must agree" invariant below would become
-- five. It also silently includes PET-cast auras, which "PLAYER" does not --
-- a behavior change nobody asked for.
--
-- Returns are interned string constants, so SetAuraGridGroupFilter's identity
-- guard (c._bf_curFilters[groupKey] ~= filter) still no-ops on a steady-state
-- Layout pass. Do not build these strings dynamically.
local CASTER_SCOPE_FILTERS = {
    mine  = "HELPFUL|PLAYER",
    notme = "HELPFUL|!PLAYER",
    any   = "HELPFUL",
}
-- "mine" | "notme" | "any". Shared with the options side via BF so the widget
-- and the filter can never disagree about what a stored value means.
local function ContainerCasterScope(c)
    if type(c) ~= "table" then return "mine" end
    local s = c.containerCasterScope
    if CASTER_SCOPE_FILTERS[s] then return s end
    if c.containerAnyCaster then return "any" end   -- legacy opt-out boolean
    return "mine"
end
BF.GetContainerCasterScope = ContainerCasterScope

local function ContainerAuraFilter(c)
    return CASTER_SCOPE_FILTERS[ContainerCasterScope(c)]
end

-- Forward declaration: defined below the per-spell-group section, needed by
-- EnsureBuffContainers for single-buff containers (see the creation site).
local DeriveSpellButtonSpec

-- v62: a single-buff container whose entry has its own visuals must have its
-- buttonSpec DERIVED (DeriveSpellButtonSpec) rather than the plain
-- BuffButtonSpec. This matters most at CREATION: the engine pre-creates the
-- button pool at AddAuraGroup, and InitAuraButton is the only point where a
-- button can be born UNBOUND (spec.solidIcon skips SetIcon). A button born
-- engine-bound is turned solid later by ApplySolidIcon's ClearIcon() unbind,
-- which is pcall-guarded because it is denial-prone; a denied unbind bails
-- before painting rather than leaving SetVertexColor tinting the
-- engine-painted aura texture. (Until v63 that unbind called SetIcon(nil),
-- which is not nil-tolerant on the 12.1 mixin -- it threw every time, so this
-- path ALWAYS bailed and Square/Bordered Square never took effect on
-- single-buff main groups.) Restamps of an already-created container remain
-- best-effort (same "completes on reload" caveat as the curated per-spell
-- groups' live Icon<->Square switch).
-- v64: stamp a container's own Border onto a buttonSpec, in place.
--
-- BuffButtonSpec takes no container argument -- it reads the Buffs section's
-- cache -- so before v64 every custom container was hard-wired to the Buffs
-- border with no opt-out. This is the override, applied at BOTH spec sites
-- (creation and the Layout restamp); they must agree or the container flips
-- appearance on the next settings pass, the same invariant the caster filter
-- carries above.
--
-- Skipped for single buffs: their spec comes from DeriveSpellButtonSpec, which
-- has already applied that entry's OWN per-spell border color and icon type
-- (a solid icon forces borderStyle/thickness). Stamping a container border over
-- that would silently undo the per-entry visuals. Single buffs also never show
-- the Border group in options -- buildSingleBuffEntry trims the whole Container
-- Settings section -- so there is nothing there for a user to have set.
local function ApplyContainerBorder(spec, c, groupTypeKey, ac, kind)
    if not spec or type(c) ~= "table" or c.singleBuff then return spec end
    if not BF.ResolveContainerBorder then return spec end
    local style, color, thickness, blizz = BF:ResolveContainerBorder(c, groupTypeKey, ac, kind)
    spec.borderStyle     = style
    spec.borderColor     = color
    spec.borderThickness = thickness
    spec.blizzardBorders = blizz
    return spec
end

-- v68: stamp a container's own DURATION TEXT onto a buttonSpec, in place. The
-- sibling of ApplyContainerBorder, and applied at the SAME spec sites (creation
-- + Layout restamp) so a container never flips duration between passes. Reads
-- the resolved table from BF:ResolveContainerDuration (container-own settings
-- when the Use-Section-Duration toggle is off, else the section baseline) and
-- stamps it exactly as the per-spell cooldown-text block does, so a later
-- per-spell override (ResolveSpellCooldownText, dead on 12.1) still wins.
--
-- Skipped for single buffs: like the border, their duration comes from the
-- per-entry single-buff visual path (DeriveSpellButtonSpec), and Container
-- Settings is trimmed out of their options.
local function ApplyContainerDuration(spec, c, groupTypeKey, ac, kind)
    if not spec or type(c) ~= "table" or c.singleBuff then return spec end
    if not BF.ResolveContainerDuration then return spec end
    local r = BF:ResolveContainerDuration(c, groupTypeKey, ac, kind)
    if not r then return spec end
    local size = spec.size or 12
    spec.showDuration     = r.showDur
    spec.durationFont     = r.durationFont
    spec.durationBorder   = r.durationBorder
    spec.durationFontSize = r.autoScale and 11 or (r.fontSize or 11)
    spec.durationScale    = r.autoScale and (size / 12 * (r.timerScale or 1.0)) or nil
    spec.fontColor        = r.fontColor
    spec.durationCurve    = r.expCurve
    spec.hideDurationAbove1Min = r.curveHides
    spec.disableSwipe     = r.swipeDis
    spec.disableSpark     = r.sparkDis
    spec.reverseSwipe     = r.revSwipe
    return spec
end

local function SingleBuffSpec(parent, c, size)
    local sbSid = BF.GetSingleBuffSpellID and BF:GetSingleBuffSpellID(c)
    if sbSid and BF.GetSingleBuffVisualRoot and BF.GetSingleBuffVisualRoot(c) then
        return DeriveSpellButtonSpec(parent, size, sbSid, c)
    end
    return nil
end

-- v77: is the general Buffs display switched on for this frame? Mirrors the
-- exact expression :Update uses to decide whether to SHOW the container
-- (ac.showBuffs plus the CFG header's module toggle), so creation and
-- visibility can never disagree.
local function BuffsShownFor(parent)
    local ac = BF:GetAuraCacheForFrame(parent)
    local ph = parent._bf_parentHeader or parent:GetParent()
    local moduleOff = ph and ph.isCustomFrame and ph.moduleShowBuffs == false
    return (ac.showBuffs ~= false) and not moduleOff
end
BF.BuffsShownForFrame = BuffsShownFor

-- ── v82/v83: SINGLE-BUFF SLOTS (Target Matrix rows 3/6; DEFAULT ON since
-- v83, /bf sbslots = kill switch via db.global.singleBuffSlotsDisabled) ──────
-- A non-Buffs-anchored single buff is structurally a single-aura display: one
-- spell, one icon, manually positioned. On the shared slot host (the Phase-2
-- `slots` container in ContainerFactory) that is ONE button instead of a
-- bfc<ci> AuraContainer plus the engine-mandated 10-button group pool. Grid2
-- precedent: GridIndicatorAuras.lua hosts every single-aura indicator as a
-- slot of one shared per-frame container.
--
-- v82 shipped OPT-IN; PTR-verified same day (owner): InitAuraButton's full
-- styling works on a SLOT button, AddAuraSlot on an already-live container
-- works, and the frame-level lesson landed (slot spec MUST carry
-- frameLevelOffset = 223 or the button renders under the text band). v83 then
-- flipped the default ON and added LIVE restyle (BF.RestyleSlotButton in the
-- maintenance arm — sig-guarded single-button mirror of
-- ApplyAuraGridGroupButtonSpec), so border/duration/icon-type edits apply at
-- the next Layout instead of on /reload. Geometry (anchor/offset/size, incl.
-- the power-bar lift) is live too — re-applied every Layout. Remaining known
-- limit: creation-frozen button aspects (region set, mask binding, engine
-- bindings) still complete on /reload, same as every 12.1 button.
-- v83: DEFAULT ON (owner 2026-08-15: "i dont want users to have to do the
-- slash command bs"). /bf sbslots is its KILL SWITCH -- off + /reload restores
-- the pre-v83 shape and changes nothing else -- flipping
-- db.global.singleBuffSlotsDisabled. The v82 opt-in key
-- (singleBuffSlots) is obsolete and read by nothing. Default-ON was paired
-- with live restyle (BF.RestyleSlotButton in the maintenance arm below) so
-- visual edits no longer wait for /reload.
local function SingleBuffSlotMode()
    local g = BF.db and BF.db.global
    return not (g and g.singleBuffSlotsDisabled)
end

-- Mirrors ReanchorAuraContainer + the canLift rule ContainerGeo stamps for
-- containers: bottom-anchored displays ride above the power bar.
-- ============================================================
-- v88h: ANCHOR INSIDE THE INIT WINDOW.
--
-- PROVEN by the v88c denial ledger on a raid combat /reload:
--
--   button:ClearAllPoints [restricted] x609
--   button:SetPoint       [restricted] x609
--   button:SetSize        [restricted] x609
--   first: ... Attempt to access forbidden object from code tainted by an AddOn
--
-- A slot button is a FORBIDDEN OBJECT to tainted code while auras are secret,
-- and all BF code is tainted by BuzzardFrames (addon-registered handlers always
-- are). So the button was created, styled, unparked and given a unit -- and
-- never anchored. It rendered nowhere, all fight, with no error, because every
-- one of those calls sat behind a pcall.
--
-- THE DIVIDING LINE, straight out of the same ledger: everything BF did INSIDE
-- `initializeFrame` succeeded even while restricted (initOK=yes, initDone=yes,
-- and button:SetFrameLevel -- called from ApplySlotFrameLevel inside that
-- callback -- never appears in the denial list). Everything BF did AFTER
-- AddAuraSlot returned was denied. The engine grants access to the button for
-- the duration of the init callback and revokes it afterwards; that is the same
-- window the 12.1 notes already describe for region creation and bindings
-- ("mask geometry and mask binding are frozen at creation. Init is the only
-- window") -- geometry turns out to be governed by it too.
--
-- So the anchor moves INTO that window. This is why the container path was never
-- affected: it anchors the CONTAINER, an addon-created frame that is never
-- forbidden, and lets the engine's flow layout place the buttons.
--
-- The post-creation path is KEPT, because out of combat it is not denied and it
-- is what makes position/offset/size edits apply live. It simply no-ops during
-- the restricted window now instead of being the only attempt.
-- ============================================================
local function AnchorSingleBuffSlotButton(parent, btn, geo)
    if not btn then return false end
    local anchor = (geo.anchor and geo.anchor ~= "") and geo.anchor or "CENTER"
    local target = BF.AuraLiftAnchorFrame(parent,
        BF:GetAuraCacheForFrame(parent), anchor) or parent
    BF:SlotCall("button:ClearAllPoints", btn.ClearAllPoints, btn)
    return BF:SlotCall("button:SetPoint", btn.SetPoint, btn, anchor, target,
        anchor, geo.offsetX or 0, geo.offsetY or 0) and true or false
end

-- 2026-09-11 (restricted recreate, plan §3.1 sbc row): the geometry a slot
-- button was placed with, as one string -- size, anchor point, offsets and the
-- lift-target identity AnchorSingleBuffSlotButton resolves. Stamped on the
-- record where the geometry actually LANDS (creation, a live re-anchor), and
-- compared -- never written -- inside a key, where a re-anchor is denied and a
-- mismatch means "rebuild the slot" instead.
local function SingleBuffGeoSig(parent, geo)
    local anchor = (geo.anchor and geo.anchor ~= "") and geo.anchor or "CENTER"
    local target = BF.AuraLiftAnchorFrame(parent,
        BF:GetAuraCacheForFrame(parent), anchor) or parent
    return tostring(geo.size) .. "|" .. anchor .. "|" .. tostring(geo.offsetX or 0)
        .. "|" .. tostring(geo.offsetY or 0) .. "|" .. tostring(target)
end

local function AnchorSingleBuffSlot(parent, s, geo)
    local btn = s and s._bf_slotButton
    if not btn then return false end
    local ok = AnchorSingleBuffSlotButton(parent, btn, geo)
    -- Only ever RAISE the flag: a live re-anchor denied mid-combat must not
    -- erase the fact that the init-window anchor landed. s.anchored means
    -- "this button has a point", not "the last attempt succeeded".
    if ok then s.anchored = true end
    return ok
end

-- Same spec derivation as the container creation path, so a slot button is
-- born with (and live-restyled to) identical visuals to a bfc pool button.
-- Shared by creation below and the v83 live-restyle in the maintenance arm.
local function DeriveSingleBuffSlotSpec(parent, c, geo, ac, groupTypeKey)
    local bspec = SingleBuffSpec(parent, c, geo.size)
        or BuffButtonSpec(parent, geo.size)
    ApplyContainerBorder(bspec, c, groupTypeKey, ac)
    ApplyContainerDuration(bspec, c, groupTypeKey, ac)
    bspec.tooltipFrameY = BF.TooltipBelowFrameY(parent, geo.anchor, geo.offsetY, geo.size)
    return bspec
end

local function EnsureSingleBuffSlot(parent, ci, c, sid, ac, groupTypeKey)
    local geo = ContainerGeo(c, ac, groupTypeKey)
    local bspec = DeriveSingleBuffSlotSpec(parent, c, geo, ac, groupTypeKey)
    -- v88h: set by the init callback below, read after it returns. The record
    -- does not exist yet while initializeFrame runs, so the outcome rides out
    -- on an upvalue.
    local initAnchored = false
    local s = BF:EnsureAuraSlotVisual(parent, "sbc" .. ci, {
        -- Frame level parity with the container path: EnsureAuraGridContainer
        -- lifts grid containers to frame+223 (the "+200 native-overlay lift" —
        -- the text/status-icon band sits at +216..221), so a bfc pool button
        -- rendered at +224. ApplySlotFrameLevel adds the same +1 on top of
        -- this offset for slot buttons. Omitting this left the button at the
        -- shared host's baseline (+2) — BEHIND the name/status text
        -- (owner-observed on a Top-anchored single buff).
        frameLevelOffset = 223,
        filter = ContainerAuraFilter(c),
        -- Include set from the START (same reason the fx slots do): if a
        -- post-creation setter were ever denied, a bare entry-scope filter
        -- would match every qualifying aura instead of this one spell.
        candidateFilters = { includeSpellIDs = { [sid] = true } },
        -- v88: this slot's initButton IS the full InitAuraButton walk, so its
        -- button carries the `_bf_initDone` completion marker and the slot can
        -- be probed for a half-finished styling walk (BF:AuraSlotStylingState).
        -- The fx / dispel slots have bespoke initButtons and leave this nil.
        fullInit = true,
        initButton = function(btn)
            if BF.InitAuraButton then BF.InitAuraButton(btn, bspec) end
            -- v88h: SIZE + ANCHOR HERE, not after AddAuraSlot returns. This
            -- callback is the only window in which the engine lets tainted code
            -- touch the button while auras are secret -- see the block comment
            -- on AnchorSingleBuffSlotButton. Doing it here is what makes a
            -- single buff survive a combat /reload.
            BF:SlotCall("button:SetSize(init)", btn.SetSize, btn,
                geo.size, geo.size)
            initAnchored = AnchorSingleBuffSlotButton(parent, btn, geo)
        end,
    })
    -- v88: `s` is nil when creation failed (denied on a tainted stack while
    -- auras were secret). Nothing is recorded in that case, so this same call
    -- site rebuilds on the next Layout, and the frame is queued on the regen
    -- replay so one is guaranteed to come once combat drops. That is the whole
    -- point -- nothing else to do here.
    if s then
        s._bf_sbSid = sid  -- candidate-set change guard for the Layout arm
        s.anchored  = initAnchored
        -- Baked geometry (plan §3.1): what the init window placed the button
        -- with. The Layout arm compares against it inside a key.
        s._bf_sbGeoSig = SingleBuffGeoSig(parent, geo)
        local btn = s._bf_slotButton
        if btn then
            -- v88h: both of these already ran inside the init window above.
            -- They are repeated here ONLY to cover the case where the engine
            -- deferred initializeFrame (the documented-unverified lazy path),
            -- and they are change-guarded / seed-only, so the normal path pays
            -- a denied pcall at worst and nothing at all out of combat.
            if not initAnchored then
                BF:SlotCall("button:SetSize(create)", btn.SetSize, btn,
                    geo.size, geo.size)
                AnchorSingleBuffSlot(parent, s, geo)
            end
            -- v83: seed the restyle sig — InitAuraButton just applied exactly
            -- this spec, so the first Layout pass must not re-walk it.
            BF.RestyleSlotButton(btn, bspec, true)
        end
    end
    return s
end

-- v88: REPAIR ARM for a single-buff slot whose button exists but whose styling
-- walk did not complete. Runs from the per-Layout maintenance arm below, out of
-- combat only (BF:AuraSlotStylingState returns nil while restricted, so this is
-- a no-op mid-fight and retries on the next pass once combat drops). This is
-- the slot-side twin of TopUpGroupStyling, and the piece whose absence made a
-- denied styling walk permanent: RestyleSlotButton deliberately BAILS on a
-- button with no `_bf_icon` -- it restyles, it never builds -- and initButton
-- was called exactly once, from inside initializeFrame, and never again.
--
-- Returns true when the caller must re-create the slot (the record was
-- discarded), so it can call EnsureSingleBuffSlot again in the same pass rather
-- than leaving the display dark for one more Layout.
local function RepairSingleBuffSlot(parent, ci, c, ac, groupTypeKey)
    local skey = "sbc" .. ci
    local state = BF.AuraSlotStylingState and BF:AuraSlotStylingState(parent, skey)
    if not state or state == "ok" then return false end
    local s = parent._bf_auraSlots and parent._bf_auraSlots[skey]
    local btn = s and s._bf_slotButton
    if state == "init" then
        -- The walk never started: nothing has been built on this button, so
        -- running it now cannot double-build a region or duplicate an engine
        -- binding. Re-derive the spec rather than reusing a stale upvalue --
        -- settings may have changed since creation.
        local geo = ContainerGeo(c, ac, groupTypeKey)
        local bspec = DeriveSingleBuffSlotSpec(parent, c, geo, ac, groupTypeKey)
        if BF.InitAuraButton and pcall(BF.InitAuraButton, btn, bspec) then
            if btn._bf_initDone then
                local sized = pcall(btn.SetSize, btn, geo.size, geo.size)
                BF.RestyleSlotButton(btn, bspec, true)
                if AnchorSingleBuffSlot(parent, s, geo) and sized then
                    s._bf_sbGeoSig = SingleBuffGeoSig(parent, geo)
                end
                -- Repaired: flip the health bit so this arm costs one boolean
                -- read from here on and never re-enters.
                s.healthy = true
                return false
            end
        end
        -- Still not finished: it half-built this time. Fall through to the
        -- discard path so the next pass gets a clean button.
        state = "discard"
    end
    if state == "discard" and BF:IsAuraRecreateWindow() then
        -- 2026-09-11 (restricted recreate, plan §3.1): inside a key both
        -- half-built states arrive as "discard". Retiring here would burn the
        -- v88 attempt budget and the in-pass rebuild could not style the new
        -- button anyway; the recreate executor retires and rebuilds on its own
        -- budget instead. Nothing to re-create in this pass.
        BF:RequestAuraRecreate(parent, "slot", skey, "sbcRepair")
        return false
    end
    if state == "discard" then
        -- Unrepairable in place. Retire it (the engine key is parked; slots
        -- can never be removed) and rebuild on a FRESH key. The attempt cap in
        -- EnsureAuraSlotVisual bounds how many buttons this can ever burn.
        if BF.DiscardAuraSlotVisual and BF:DiscardAuraSlotVisual(parent, skey) then
            return true
        end
    end
    return false
end

local function EnsureBuffContainers(parent)
    -- v79: called for its cache-priming side effect only (EnsureFetchBuffSettings).
    -- The binding is gone with cfg.filter -- this function has no other cfg use,
    -- and unused locals are not free in this file (200-per-chunk limit).
    BF:GetContainerBuffConfig()
    -- General group. layoutIndex 1000: v43 per-spell groups (layoutIndex
    -- 1..N) flow AHEAD of the general buffs in the shared container flow.
    --
    -- v77 PERF: nothing at all for a frame whose Buffs display is OFF. This
    -- was previously created and fully styled regardless, with showBuffs only
    -- reaching SyncAuraGridContainer's show/hide -- so a profile with Buffs
    -- switched off still paid for the "buffs" container and EVERY group in it
    -- (main + the preset group + every sp<sid> + every sb<key> + raidbuffs).
    -- Custom bfc<ci> containers are deliberately NOT gated: they show
    -- independently of the regular-buffs toggle (see :Update).
    --
    -- Re-enabling is create-on-first-enable, the BigDefIcons.lua:112 pattern:
    -- :Update builds it on the first pass that sees the feature on.
    if not (parent._bf_auraContainers and parent._bf_auraContainers.buffs)
       and BuffsShownFor(parent) then
        local geo = BuffGeneralGeo(parent)
        BF:EnsureAuraGridContainer(parent, "buffs", {
            buttonSpec    = BuffButtonSpec(parent, geo.size),
            maxFrameCount = geo.maxIcons,
            sortMethod    = AuraContainerSortMethod.Default,  -- player-first
            spacing       = geo.spacing,
            rowSpacing    = geo.rowSpacing,
            -- v81: born on the same DEFAULT-SCOPE filter ApplyBuffFilters
            -- keeps it on. `main` is the whitelist bucket, not the ordinary
            -- row; PLAYER is the ruled default Applied By ("Me Only") — the
            -- string alone stays sane if the engine ever drops the candidate
            -- set (own casts only, minus classes other displays own).
            filter        = "HELPFUL|PLAYER|!BIG_DEFENSIVE|!EXTERNAL_DEFENSIVE",
            layoutIndex   = 1000,
        })
        -- v79 CRITICAL: park `main` the instant it exists.
        --
        -- Groups are born LIVE (AddAuraGroup with a real filter; creation never
        -- seeds the dormant flag). `main`'s filter is deliberately permissive --
        -- it is the whitelist bucket and its content comes from an
        -- includeSpellIDs set, NOT from the filter string. But that include set
        -- is not applied until the end of ApplyBuffFilters, so for the whole
        -- window between here and there the group is live, permissive and
        -- unrestricted: it matches EVERY helpful aura on the unit.
        --
        -- Anything that renders in that window floods the buff row with every
        -- buff on the target -- observed as "garbage auras", most visibly around
        -- vehicle and unit-visibility transitions, which is exactly when extra
        -- rescan / UpdateAllAuras passes fire.
        --
        -- Parking here closes the window: ApplyBuffFilters unparks it only once
        -- it has a real include set to hand over, and re-applies that set
        -- immediately after the unpark (unparking clears candidates to {}).
        BF:SetAuraGridGroupDormant(parent, "buffs", "main", true)
        BF:ApplyAuraGridGeometry(parent, "buffs", geo)
    end
    -- Custom BF-containers (create any missing).
    local containers = BF:GetActiveCustomBuffContainers() or {}
    -- v61: aura cache + per-Layout scope key are frame-constant, so they
    -- are resolved once per frame instead of once per container (the aura
    -- cache used to be re-fetched inside the loop). Lazily, so a frame
    -- whose containers all already exist still pays nothing.
    local ac, groupTypeKey
    for ci, c in ipairs(containers) do
        local key = "bfc" .. ci
        -- v65/v92: a FLOW-ANCHORED single buff has no container of its own --
        -- it is a group inside its host container (ApplySingleBuffGroups: the
        -- buffs row, Big Defensive, or a named multi-icon container). Skipping
        -- CREATION rather than merely parking it matters: AuraContainers can
        -- never be destroyed, so a container built once would linger for the
        -- session. Un-anchoring later still works, because this loop runs on
        -- every Layout and will build it then.
        --
        -- v92: the test is "has ANY host", not "is Buffs-anchored" -- the three
        -- hosts are interchangeable here, they all mean "renders inside someone
        -- else's flow". Only DELETION of a host falls back to Buffs, and that
        -- is rewritten in the DB by RemoveCustomBuffContainer before this runs.
        --
        -- The key must be resolved before the skip so the orphan sweep at the
        -- end of ApplyBuffFilters still sees a consistent 1..#containers range.
        --
        -- v74: also skip CREATION for a container with no possible content
        -- under the current spec (Grid2 suspend pattern -- see CONTAINER
        -- CREATION RELEVANCE in AuraCustomizations.lua). Creation-only gate:
        -- an already-existing container keeps being maintained by the
        -- existence-guarded restamp work and parked by the visibility
        -- resolvers exactly as before. Every downstream consumer of a missing
        -- bfc<ci> is nil-guarded (the v65 anchored skip proved the shape).
        local sbAnchored = BF:GetSingleBuffAnchorHost(c,
            BF.ResolveGroupTypeKey and BF:ResolveGroupTypeKey(parent)) ~= nil
        local sbRelevant = BF:IsContainerCreationRelevant("buff", ci)
        local skip = sbAnchored or not sbRelevant
        -- ── v88d: CREATION-WINDOW TRACE ───────────────────────────────────
        -- The question this answers: on a combat /reload, the "buffs" container
        -- above and this slot are created by the SAME function in the SAME
        -- pre-restriction window -- so why does one exist afterwards and the
        -- other not?
        --
        -- Because they are not gated alike. The buffs container's only
        -- precondition is BuffsShownFor(). A slot has FIVE, and every one of
        -- them reads state that may not be settled this early in a reload:
        -- the acDB container array, the frame's resolved groupTypeKey
        -- (sbAnchored), BF.playerSpecID + acDB.spellAssign via the
        -- PROCESS-WIDE _containerRelevance cache (sbRelevant), the entry's
        -- spell id, and the slot-mode flag.
        --
        -- Recorded on the FIRST pass per frame only, so a later out-of-combat
        -- Layout cannot overwrite what happened in the window that matters.
        -- Two table writes per single buff, once per frame, ever.
        if c.singleBuff and BF:IsSlotDiagEnabled()
           and not (parent._bf_sbTrace and parent._bf_sbTrace[ci]) then
            local t = parent._bf_sbTrace
            if not t then t = {}; parent._bf_sbTrace = t end
            local sid0 = BF:GetSingleBuffSpellID(c)
            local why
            if not SingleBuffSlotMode()      then why = "slot-mode-OFF"
            elseif sbAnchored                then why = "SKIP: flow-anchored"
            elseif not sbRelevant            then why = "SKIP: not-relevant"
            elseif not sid0                  then why = "SKIP: no-spellID"
            elseif parent._bf_auraSlots and parent._bf_auraSlots["sbc" .. ci]
                                             then why = "already-existed"
            else                                  why = "CREATE attempted"
            end
            t[ci] = ("%s | restricted=%s gt=%s spec=%s"):format(why,
                tostring(BF:IsAuraCreationRestricted()),
                tostring(BF.ResolveGroupTypeKey and BF:ResolveGroupTypeKey(parent)),
                tostring(BF.playerSpecID))
        end
        -- v82/v83 (default ON): a non-Buffs-anchored single buff becomes ONE slot on
        -- the shared host instead of a bfc<ci> container + 10-pool. The bfc
        -- container is deliberately NOT created; every downstream consumer of
        -- a missing bfc<ci> is already nil-guarded (the v65 anchored skip and
        -- v74 relevance skip proved the shape). Toggling the mode mid-session
        -- leaves the previously-built object of the OTHER mode live until
        -- /reload — the /bf sbslots command says so.
        if not skip and c.singleBuff and SingleBuffSlotMode() then
            if not (parent._bf_auraSlots and parent._bf_auraSlots["sbc" .. ci]) then
                local sid = BF:GetSingleBuffSpellID(c)
                if sid then
                    if not ac then
                        ac = BF:GetAuraCacheForFrame(parent)
                        groupTypeKey = BF.ResolveGroupTypeKey and BF:ResolveGroupTypeKey(parent)
                    end
                    EnsureSingleBuffSlot(parent, ci, c, sid, ac, groupTypeKey)
                end
            end
        elseif not skip and not (parent._bf_auraContainers and parent._bf_auraContainers[key]) then
            if not ac then
                ac = BF:GetAuraCacheForFrame(parent)
                -- May legitimately be nil (CFG header whose group went away
                -- mid-refresh); the resolver collapses to the shared
                -- container top level then. `ac` is the lazy-init sentinel.
                groupTypeKey = BF.ResolveGroupTypeKey and BF:ResolveGroupTypeKey(parent)
            end
            local geo = ContainerGeo(c, ac, groupTypeKey, ci)
            -- v52: Below Frame tooltip offset from the CONTAINER's own
            -- anchor (BuffButtonSpec computes it from the Buffs anchor).
            -- v62: single-buff visuals must be present at creation so the
            -- pool's buttons are born with them (see SingleBuffSpec above).
            local bspec = SingleBuffSpec(parent, c, geo.size)
                or BuffButtonSpec(parent, geo.size)
            -- v64: per-container Border. Applied at CREATION as well as at the
            -- restamp below because the pool's buttons are born with this spec.
            ApplyContainerBorder(bspec, c, groupTypeKey, ac)
            -- v68: per-container Duration. Same both-sites invariant as border.
            ApplyContainerDuration(bspec, c, groupTypeKey, ac)
            bspec.tooltipFrameY = BF.TooltipBelowFrameY(parent, geo.anchor, geo.offsetY, geo.size)
            BF:EnsureAuraGridContainer(parent, key, {
                buttonSpec    = bspec,
                maxFrameCount = geo.maxIcons,
                sortMethod    = AuraContainerSortMethod.Default,
                spacing       = geo.spacing,
                rowSpacing    = geo.rowSpacing,
                -- v59: PLAYER — custom containers show only auras YOU cast.
                -- Owner decision. Must match the two live re-apply sites in
                -- the custom-container loop (main group + per-spell groups);
                -- a container created here under one filter and re-stamped
                -- there under another would flip behavior on the next pass.
                -- v61: opt-out per container (see ContainerAuraFilter).
                filter        = ContainerAuraFilter(c),
                layoutIndex   = 1000,
            })
            BF:ApplyAuraGridGeometry(parent, key, geo)
        end
    end
end

-- ============================================================
-- v43 PER-SPELL GROUPS (Aura Customizations redesign)
-- Each master-flagged spell gets a dedicated 1-frame group inside its
-- home container ("buffs" or "bfc"..ci), styled for that spell at
-- creation, flowing with the main group's buffs at layoutIndex = its
-- Position rank (ties broken alphabetically — sorted upstream in
-- GetContainerBuffConfig). Stale groups (un-flagged / reassigned /
-- spec change) are parked dormant; groups can't be removed.
-- ============================================================

-- Derive the per-spell buttonSpec: base buff spec + AC overrides.
-- All BF.Get* helpers are master-flag-gated, so an override only
-- lands when actually configured AND the spell is flagged.
-- v62 (plan 3.67 slice 2): `sbC` is an optional single-buff CONTAINER. Every
-- BF.Get* helper below takes it as a trailing argument and reads that
-- container's own per-entry store instead of specSpell*[specId][sid] when it is
-- supplied. Curated per-spell groups pass nil and are byte-for-byte unchanged.
-- This function is Layout/settings-time on BOTH paths (ApplySpellGroups and the
-- single-buff main-group restamp in ApplyBuffFilters); no per-aura path reaches
-- it, so the branch costs the hot path nothing.
-- (Assigns the local forward-declared above EnsureBuffContainers.)
-- v87: resolve a single buff's border the SAME WAY ResolveContainerBorder
-- resolves a container's — one function returning (style, color, thickness,
-- blizz), PRE-RESOLVED and stamped once. "Use Buffs Border" is the per-spell
-- twin of containerUsesBuffBorder:
--   ON  → return the Buffs section base verbatim (style/color/thickness/blizz
--         straight off the aura cache) so the buff tracks the Buffs setting
--         exactly, alpha included — nothing per-spell leaks in.
--   OFF → return the buff's own: for SQUARE, showBorder gates it (off = flat,
--         thickness 0); ICON has no Show Border toggle and always draws a
--         border when opted out. borderStyle drives the shape, per-spell Border
--         Color (when its own toggle is on) overrides the color, else Buffs.
-- `sh` is the shared border-shape entry (specSpellSolidIcons row) that carries
-- showBorder/borderStyle/borderThickness/useBuffsBorder for both icon types.
local function ResolveSpellButtonBorder(ac, sh, isSquare, legacyBordered, perSpellColor)
    local baseStyle = ac.buffBorderStyle
    local baseColor = ac.buffBorderColor
    local baseThick = ac.buffBorderThickness
    local baseBlizz = ac.buffBlizzardBorders
    -- legacyBordered ("BorderedSquare") forces its own bordered look, never inherit.
    local inherit = not legacyBordered
        and BF.UseBuffsBorderOn and BF.UseBuffsBorderOn(sh, isSquare)
    if inherit then
        return baseStyle, baseColor, baseThick, baseBlizz
    end
    -- showBorder: SQUARE has a Show Border toggle (off = bare square, no
    -- border). ICON has none — an opted-out Icon always draws its own border
    -- (v87), so it is implicitly true there. legacyBordered forces it too.
    local showBorder = legacyBordered or (not isSquare) or (sh and sh.showBorder) or false
    if not showBorder then
        -- No border for this buff: flat family, zero thickness.
        return "flat", (perSpellColor or baseColor), 0, false
    end
    local bs = sh and sh.borderStyle
    local style, blizz
    if bs == "blizzard" then
        style, blizz = "blizzard", true
    elseif bs == "rounded" or bs == "rounded_thick" then
        style, blizz = bs, false
    else
        style, blizz = "flat", false
    end
    -- Thickness: per-spell when set, else the Buffs base. Blizzard ignores it.
    local thick = (sh and sh.borderThickness) or baseThick
    return style, (perSpellColor or baseColor), thick, blizz
end

function DeriveSpellButtonSpec(frame, size, sid, sbC)
    local spec = BuffButtonSpec(frame, size)
    local ac = BF:GetAuraCacheForFrame(frame)
    -- Icon type "Square" (v69: the only non-default type). The entry's
    -- thresholdEnabled flag picks the RENDER PATH:
    --   OFF → static solid texture (permanents render; cooldown text
    --         available on top).
    --   ON  → the square is DURATION TEXT in the all-square-glyph font,
    --         threshold-colored by the engine curve — the 12.1
    --         replacement for the cut texture-color threshold curves.
    --         No-duration auras render no square, and cooldown text is
    --         the square itself (subtab hidden in options).
    -- Border: Show Border (e.showBorder) + Border Style on both paths —
    -- the texture path rounds its fill via the mask/ring pipeline (works
    -- on our unbound WHITE8x8), the glyph path via a ROUNDED-CORNER
    -- GLYPH FONT radius-matched to the ring art (FontStrings cannot be
    -- masked). Border color is STATIC on both (textures have no engine
    -- color binding).
    -- Legacy stored values, read-time mapped (no migration): the
    -- "BorderedSquare" type = Square + border ON; the "SquareDuration"
    -- type = Square (its glyph path re-activates via the same
    -- thresholdEnabled flag it always stored).
    local it = BF.GetSpellIconType and BF.GetSpellIconType(sid, sbC)
    local legacyBordered = (it == "BorderedSquare")
    if legacyBordered or it == "SquareDuration" then it = "Square" end

    -- Border, PRE-RESOLVED (v87). One resolver, stamped once — the per-spell
    -- twin of ApplyContainerBorder/ResolveContainerBorder. The shared
    -- border-shape entry (specSpellSolidIcons row, read ignoring its `enabled`
    -- flag which governs only the Square FILL) carries this buff's own border
    -- fields; the per-spell Border Color (GetSpellBorderColor, its own enabled
    -- gate) supplies the color when the buff opts out and its color toggle is
    -- on. With Use Buffs Border ON the resolver returns the Buffs base straight
    -- off the cache, so no per-spell value — color OR alpha — leaks in.
    local sh = BF.GetSpellBorderShape and BF.GetSpellBorderShape(sid, sbC)
    local perSpellColor = BF.GetSpellBorderColor and BF.GetSpellBorderColor(sid, sbC)
    local isSquare = (it == "Square")
    local bStyle, bColor, bThick, bBlizz =
        ResolveSpellButtonBorder(ac, sh, isSquare, legacyBordered, perSpellColor)
    spec.borderStyle     = bStyle
    spec.borderColor     = bColor
    spec.borderThickness = bThick
    spec.blizzardBorders = bBlizz

    if it == "Square" then
        local e = (BF.GetSolidIconColor and BF.GetSolidIconColor(sid, sbC))
            or { r = 0, g = 0.7, b = 1, a = 1 }
        if e.thresholdEnabled then
            -- Glyph path. The icon region shows nothing: an ALPHA-0
            -- solidIcon reuses ApplySolidIcon's unbind machinery
            -- (ClearIcon + paint) so the engine never draws the aura
            -- texture, while the paint itself is invisible. COPY the
            -- entry — solidIcon rides the spec and must not alias the
            -- saved-vars table.
            spec.solidIcon = { r = e.r or 0, g = e.g or 0.7, b = e.b or 1, a = 0 }
            spec.durationSquare = true
            -- fontColor (the square's static/above-threshold color) is
            -- stamped in the durationSquare block BELOW the cooldown-text
            -- resolve, so the resolved font color cannot stomp it.
        else
            spec.solidIcon = e
        end
    end
    -- v84 (Stage 5 §9.9): per-spell ICON EFFECTS. Replaces both the v47
    -- "Glow Border" (specSpellExpirationGlow) and the v49 "Blizzard Visual
    -- Alert" (specSpellVisualAlert) resolves that used to live here.
    --
    -- Why the old Glow Border went: its stored shape was THRESHOLD-driven
    -- ("show when under N seconds"), and remaining duration is SECRET on 12.1
    -- — the threshold can never be evaluated, so v47 could only ever render a
    -- static always-on ring. The engine-computed Pandemic Effect is the
    -- replacement for "glow when expiring" (a fixed refresh window rather than
    -- a configurable seconds threshold).
    --
    -- One resolver, one apply, at the tail: BF.ApplyIconEffectToSpec folds the
    -- whole entry onto the spec in a single pass (a teardown-then-reapply
    -- would restart the animations visibly).
    do
        local ie = BF.GetSpellIconEffect and BF.GetSpellIconEffect(sid, sbC)
        if ie and BF.ApplyIconEffectToSpec then
            BF.ApplyIconEffectToSpec(spec, ie)
        end
    end
    -- Per-spell cooldown text (cached resolver, incl. threshold curve).
    local r = BF.ResolveSpellCooldownText
        and BF.ResolveSpellCooldownText(sid, BF:ResolveGroupTypeKey(frame),
            BF:GetAuraCacheForFrame(frame), sbC)
    if r then
        spec.showDuration     = r.showDur
        spec.durationFont     = r.durationFont
        spec.durationBorder   = r.durationBorder
        spec.durationFontSize = r.autoScale and 11 or (r.fontSize or 11)
        spec.durationScale    = r.autoScale and (size / 12 * (r.timerScale or 1.0)) or nil
        spec.fontColor        = r.fontColor
        spec.durationCurve    = r.expCurve
        -- hide-above-1-min must go through the formatter (the engine's
        -- textColor curve binding ignores alpha — PTR-CONFIRMED).
        spec.hideDurationAbove1Min = r.curveHides
        spec.disableSwipe     = r.swipeDis
        spec.disableSpark     = r.sparkDis
        spec.reverseSwipe     = r.revSwipe
    end
    -- Square (Color by Duration): duration text IS the visual, so it wins
    -- over every cooldown-text setting resolved above (the Cooldown Text
    -- subtab is hidden for this icon type; inherited/stale settings must
    -- not blank or restyle the square). Runs AFTER the r-block on purpose.
    if spec.durationSquare then
        -- Re-resolve the Icon Color: the r-block above may have replaced
        -- spec.fontColor with the cooldown-text font color.
        local c = (BF.GetSolidIconColor and BF.GetSolidIconColor(sid, sbC))
            or { r = 0, g = 0.7, b = 1 }
        spec.showDuration = true             -- hidden text = no square at all
        spec.hideDurationAbove1Min = false   -- constant format at every duration
        spec.durationCurve = BF.GetSolidIconColorCurve
            and BF.GetSolidIconColorCurve(sid, sbC) or nil
        spec.fontColor = { r = c.r or 0, g = c.g or 0.7, b = c.b or 1, a = c.a or 1 }
        -- No swipe/spark: with the icon invisible the wedge would float
        -- over bare frame; the square's color IS the timer display.
        spec.disableSwipe = true
        spec.disableSpark = true
    end
    return spec
end

-- v65: per-spell groups start at 500, not 1, leaving 1..499 free for the
-- Buffs-anchored single buffs that flow AHEAD of everything (see
-- ApplySingleBuffGroups). A constant offset, so the relative order among
-- "sp*" groups is unchanged.
--
-- The full flow-order map for the "buffs" container is now:
--   1..499     sb* Buffs-anchored single buffs, Relative Order = Before
--   500+rank   sp* customized spells, by Position
--   1000       main group (the regular buffs)
--   1500+i     pre* preset groups
--   2000       raidbuffs
--   2500+      sb* Buffs-anchored single buffs, Relative Order = After
local SPELL_GROUP_BASE       = 500
local SINGLE_BUFF_AFTER_BASE = 2500

local _spellGroupSeen = {}   -- scratch: groupKeys active this pass
local function ApplySpellGroups(parent, key, list, filter, size, spacing, rowSpacing, ttY)
    local c = parent._bf_auraContainers and parent._bf_auraContainers[key]
    if not c then return end
    table.wipe(_spellGroupSeen)
    if list then
        for rank, e in ipairs(list) do
            local gk = "sp" .. e.sid
            _spellGroupSeen[gk] = true
            local spec = DeriveSpellButtonSpec(parent, size, e.sid)
            if ttY then spec.tooltipFrameY = ttY end
            if not (c._bf_groupSpecs and c._bf_groupSpecs[gk]) then
                BF:EnsureAuraGridSpellGroup(parent, key, gk, {
                    filter = filter, buttonSpec = spec,
                    layoutIndex = SPELL_GROUP_BASE + rank, maxFrameCount = 1,
                    spacing = spacing, rowSpacing = rowSpacing,
                    -- v64: include set from the START, not only via the
                    -- post-creation setter below. EnsureAuraGridSpellGroup's
                    -- own note (ContainerFactory.lua) spells out why: if the
                    -- post-creation SetAuraGroupCandidateFilters were ever
                    -- denied, a group whose filter is a bare "HELPFUL" would
                    -- match EVERY helpful aura rather than this one spell.
                    -- Survivable while `filter` was always "HELPFUL|PLAYER";
                    -- it is NOT, because ContainerAuraFilter returns a bare
                    -- "HELPFUL" for any container with Own only switched off.
                    -- The setter below stays -- belt and braces, as documented.
                    candidateFilters = { includeSpellIDs = { [e.sid] = true } },
                })
                if c._bf_groupSpecs and c._bf_groupSpecs[gk] then
                    c:SetAuraGroupCandidateFilters(gk,
                        { includeSpellIDs = { [e.sid] = true } })
                end
            else
                -- Existing group: reorder + unpark + refresh everything.
                BF:EnsureAuraGridSpellGroup(parent, key, gk,
                    { layoutIndex = SPELL_GROUP_BASE + rank })
                BF:SetAuraGridGroupDormant(parent, key, gk, false)
                c:SetAuraGroupCandidateFilters(gk,
                    { includeSpellIDs = { [e.sid] = true } })
                BF:SetAuraGridGroupFilter(parent, key, gk, filter)
                BF:ApplyAuraGridGroupButtonSpec(parent, key, gk, spec)
            end
        end
    end
    -- Park stale spell groups (never removed — engine limitation).
    for _, gk in ipairs(c._bf_groupKeys) do
        if gk:sub(1, 2) == "sp" and not _spellGroupSeen[gk] then
            BF:SetAuraGridGroupDormant(parent, key, gk, true)
        end
    end
end

-- ── v65/v92: FLOW-ANCHORED SINGLE BUFFS ───────────────────────────────────
-- A single buff whose Anchor Point is a HOST rather than a frame point does
-- not get its own bfc<ci> container. It becomes a dedicated 1-frame aura group
-- inside that host's engine container, styled from the entry's OWN store and
-- placed by its Relative Order + Order.
--
-- v65 shipped one host ("Buffs" -> the general "buffs" container). v92 adds
-- two more, and the machinery below is the same shape parameterized over a
-- HOST DESCRIPTOR (BF:GetSingleBuffAnchorHost):
--   { kind = "buffs"  } -> container "buffs",   base size = Buffs size
--   { kind = "bigDef" } -> container "bigDef",  base size = Big Defensive size
--   { kind = "bfc", ci } -> container "bfc"..ci, base size = that container's
--
-- Key namespace is "sb" .. singleBuffKey, NOT "sp" .. spellID, for two
-- reasons: singleBuffKey is unique per entry so two entries of the same spell
-- cannot collide (spellID keys would), and the "sp" prefix is load-bearing --
-- ApplySpellGroups parks every "sp*" group it did not see this pass, exactly
-- as preset keys avoid it by starting with "pre". The sweeps below are the
-- mirror of that one and must stay equally narrow.
--
-- The key is GLOBALLY unique, not per host, and that is deliberate: engine
-- groups can never be removed, so a host switch parks the old host's copy
-- (its sweep) and creates or unparks the new host's under the same key. Two
-- copies of one key in two containers is the normal steady state after a
-- switch, exactly as un-anchoring already worked.
--
-- Sizing: the entry keeps its OWN icon size, like the enlarged debuff groups.
-- That needs all three of spec.size, spec._bf_sizeMult (which drives the
-- per-group layout.elementWidth/Height in ContainerFactory) and the HOST's
-- lineSizeSlack wrap budget -- see ApplyHostLineSlack. Setting only the first
-- two was PTR-observed on the debuff path as big icons overlapping the
-- neighbor. The mult is relative to the HOST's base size, so an entry keeps
-- its configured pixel size whichever flow it lands in.
--
-- v92 scratch, all POOLED and wiped per pass. Entry tables are never allocated
-- per pass: ApplyBuffFilters runs per FRAME, so a fresh table per anchored
-- entry would be 45x the churn of the settings-time cfg._custEntryPool this
-- mirrors. The pools persist and are never shrunk.
local _sbPool       = {}   -- flat pool of entry tables
local _sbPoolUsed   = 0    -- how many of them this pass has handed out
local _sbBucket     = {}   -- hostKey -> array of PROMOTED entries this pass
local _sbSeen       = {}   -- hostKey -> set of groupKeys emitted this pass
-- v78/v92: spell ids of anchored entries that do NOT need a group of their own
-- -- they join their HOST's shared include set instead ("main" for the buffs
-- row and for a bfc host; bigDef has no such set, see SingleBuffSharesHostGroup).
local _sbShared     = {}   -- hostKey -> set of shared sids
-- Every hostKey ever seen this SESSION, not just this pass. Two jobs: it drives
-- the per-pass wipes, and it is what lets a host that lost its last entry still
-- be swept -- a container is only ever added here by having hosted something.
local _sbHostKeys   = {}

local function SbHostState(hostKey)
    local b = _sbBucket[hostKey]
    if not b then
        b = {}
        _sbBucket[hostKey] = b
        _sbSeen[hostKey]   = {}
        _sbShared[hostKey] = {}
        _sbHostKeys[#_sbHostKeys + 1] = hostKey
    end
    return b
end
-- The two fixed hosts always exist, so ApplySingleBuffGroups can hand back
-- _sbShared.buffs without a nil check and the bigDef arm can read its bucket.
SbHostState("buffs")
SbHostState("bigDef")

local function ResetSingleBuffPass()
    for i = 1, #_sbHostKeys do
        local hk = _sbHostKeys[i]
        table.wipe(_sbBucket[hk])
        table.wipe(_sbSeen[hk])
        table.wipe(_sbShared[hk])
    end
    _sbPoolUsed = 0
end

-- Set equality over map-shaped candidate sets. Used to decide whether a
-- candidate re-stamp needs the engine's UpdateAllAuras kick (option setters do
-- NOT re-evaluate existing aura assignments -- PTR-observed).
local function SbSetsMatch(a, b)
    if a == b then return true end
    if not a or not b then return false end
    for k in pairs(a) do if not b[k] then return false end end
    for k in pairs(b) do if not a[k] then return false end end
    return true
end

-- v78/v81: does this Buffs-anchored entry need a DEDICATED group, or can it
-- share the `main` group's include set?
--
-- A group exists to carry something per-entry. There are exactly THREE such
-- things (Docs/Buffs_Row_Architecture.md §3.2, owner-ruled 2026-08-15):
--   * per-entry VISUALS -- Display Type "Show (Customized Buff)". GetSingleBuff-
--     VisualRoot returns nil when singleBuffCustomized == false, which IS the
--     Display Type test (AuraCustomizationHelpers.lua).
--   * an ORDER -- layoutIndex orders GROUPS, not auras within a group, so a
--     position in the row is only expressible as a group. Read through
--     GetSingleBuffOrder, which deliberately bypasses the customized gate
--     ("an entry in Show (Default Buff) mode still occupies a place in the row
--     and the user still set it").
--   * a NON-DEFAULT APPLIED BY (v81, rule 3) -- a group's filter string is
--     group-wide: `main` expresses the default scope, "mine"
--     (HELPFUL|PLAYER|...), and cannot say "Not Me"/"Anyone" for one spell ID
--     in its include set. Non-default scopes keep the sb group that carries
--     ContainerAuraFilter(entry), exactly as today.
--
-- Plus one DERIVED edge (v81): `main`'s filter negates
-- !BIG_DEFENSIVE|!EXTERNAL_DEFENSIVE (the string must stay sane if the engine
-- ever drops the candidate set), so a whitelisted spell in a defensive curated
-- category would never render from `main` -- it promotes too. The curated
-- SpellData category is the best settings-time proxy for the engine's
-- classification; over-promotion is behavior-preserving (the entry just keeps
-- its own group), under-promotion would blank the icon, so unknown/uncurated
-- spells are NOT promoted on this term.
--
-- None of the three = "Show (Default Buff)", no Order, default scope = the
-- container's own settings and the engine's default sort, which is precisely
-- what the shared group already provides. Building a group for it costs a full
-- pooled button set to display one aura identically to how `main` would.
local function SingleBuffNeedsOwnGroup(sc)
    local root = BF.GetSingleBuffVisualRoot and BF.GetSingleBuffVisualRoot(sc)
    if root and next(root) ~= nil then return true end
    if BF:GetSingleBuffOrder(sc) ~= nil then return true end
    -- v81 rule 3: non-default Applied By promotes. ContainerCasterScope is the
    -- same file-local the sb filter path reads, so the widget, the sb filter
    -- and this test can never disagree about what a stored value means.
    if ContainerCasterScope(sc) ~= "mine" then return true end
    -- v81 derived edge: defensive-category spells promote (see above).
    local sid = BF.GetSingleBuffSpellID and BF:GetSingleBuffSpellID(sc)
    local e = sid and ns and ns.SpellData and ns.SpellData.BYID
        and ns.SpellData.BYID[sid]
    local cat = e and e.cat
    return cat == "Personal Defensive" or cat == "External Defensive"
end

-- v92: can this entry SHARE its host's group instead of promoting to its own?
--
-- Host-relative by construction -- "shared" means "the host's own group already
-- renders it exactly the way this entry wants", and each host's own group is a
-- different thing:
--
--   buffs   the v78/v81 rule above, unchanged. `main`'s filter is the DEFAULT
--           scope plus the !BIG_DEFENSIVE|!EXTERNAL_DEFENSIVE negations, so the
--           defensive-category term applies HERE and only here.
--   bfc     the same rule restated against the HOST's filter
--           (Docs/Buffs_Row_Architecture.md §3.2): no visuals, no Order, and
--           the entry's Applied By must match the container's. A bfc `main`
--           carries no category negations, so the defensive-category promotion
--           of the buffs arm deliberately does NOT apply -- a big defensive
--           renders from a bfc main perfectly well.
--   bigDef  never. `bd` is TOKEN-driven (HELPFUL|BIG_DEFENSIVE) with no include
--           set to join, and candidateFilters cannot express a category union
--           (Container_Flow_Anchors_Plan.md §A6), so there is no share path at
--           all -- every bigDef-anchored entry promotes.
--
-- Filters compare by IDENTITY: CASTER_SCOPE_FILTERS returns interned constants.
local function SingleBuffSharesHostGroup(sc, hostKind, hostC)
    if hostKind == "bigDef" then return false end
    if hostKind == "buffs"  then return not SingleBuffNeedsOwnGroup(sc) end
    if not hostC then return false end
    local root = BF.GetSingleBuffVisualRoot and BF.GetSingleBuffVisualRoot(sc)
    if root and next(root) ~= nil then return false end
    if BF:GetSingleBuffOrder(sc) ~= nil then return false end
    return ContainerAuraFilter(sc) == ContainerAuraFilter(hostC)
end

-- Order 0/None sorts after every numbered entry; container index is the stable
-- tiebreak so the flow cannot depend on pairs() order. Ranks WITHIN one host
-- and one band -- which is all Order ever meant, now that collection is
-- per-host (two entries in different hosts never compare).
local function SingleBuffFlowLess(x, y)
    if x.order ~= y.order then return x.order < y.order end
    return x.ci < y.ci
end

-- ── v92 §A3.1: COLLECTION ─────────────────────────────────────────────────
-- ONE walk of the container array per pass, bucketing every anchored entry by
-- its resolved host. Returns passValid -- see the sweep note below.
local function CollectSingleBuffFlow(parent, groupTypeKey)
    ResetSingleBuffPass()
    local containers = BF:GetActiveCustomBuffContainers() or {}
    local vis = parent._bf_bfcVisible
    -- v78: did this pass have a valid basis for deciding membership? See
    -- SweepStaleSingleBuffGroups -- a pass that could not resolve its inputs
    -- must not be read as "the user removed every entry".
    local passValid = (groupTypeKey ~= nil) and (#containers > 0)
    for ci = 1, #containers do
        local sc = containers[ci]
        -- vis[] is resolved earlier in this same pass (ApplyBuffFilters), and
        -- already folds in the per-Layout Enabled flag and the Spec condition.
        -- v65: singleBuffHidden ("Display Type = Hide") must be honored HERE
        -- too. vis[] carries the per-Layout flag and the Spec condition but not
        -- this one, and unlike the container path there is no include set to
        -- come up empty -- an sb group is built straight from the entry's spell
        -- id, so a hidden entry would render regardless. Now that every curated
        -- spell gets an entry, most of them hidden, this is the difference
        -- between a normal buff row and every buff in the game at once.
        --
        -- vis == nil means "not resolved yet on this frame" and reads as
        -- visible: the same first-pass semantics v65 had. It self-corrects,
        -- because ApplyBuffFilters re-runs this collection with a resolved
        -- vis[] later in the very same Layout.
        local h = BF:GetSingleBuffAnchorHost(sc, groupTypeKey)
        if h and not sc.singleBuffHidden and (vis == nil or vis[ci] ~= false) then
            local sid = BF:GetSingleBuffSpellID(sc)
            if sid then
                -- Read the descriptor's fields NOW and keep only scalars: host
                -- descriptors are SHARED, interned and re-pointed per call.
                local kind   = h.kind
                local hostCi = (kind == "bfc") and h.ci or nil
                local hostKey = hostCi and ("bfc" .. hostCi) or kind
                local hostC  = hostCi and containers[hostCi] or nil
                local bucket = SbHostState(hostKey)
                -- v78/v81/v92: an entry carrying nothing per-entry needs no
                -- group of its own -- it joins the host's shared include set.
                -- See SingleBuffSharesHostGroup and
                -- Docs/Buffs_Row_Architecture.md §2-3.
                --
                -- The settings-time claim (_fbsSingleBuffSpell ->
                -- cfg.generalExclude, AuraCustomizations.lua) is deliberately
                -- LEFT ALONE. It keeps every single-buff spell out of the
                -- PRESET groups, which is exactly right; the host renders these
                -- by include set, so being in the claim set costs them nothing.
                -- And this set is built PER FRAME, at Layout time, where
                -- anchoring is already resolved -- so an entry anchored on raid
                -- frames and floating on party frames is handled correctly on
                -- both, with no global answer required. An anchored entry has
                -- no bfc container of its own, so there is nothing to double
                -- against.
                if SingleBuffSharesHostGroup(sc, kind, hostC) then
                    _sbShared[hostKey][sid] = true
                else
                    _sbPoolUsed = _sbPoolUsed + 1
                    local e = _sbPool[_sbPoolUsed]
                    if not e then e = {}; _sbPool[_sbPoolUsed] = e end
                    e.c   = sc
                    e.ci  = ci
                    e.sid = sid
                    -- None sorts last within its band, not first.
                    e.order = BF:GetSingleBuffOrder(sc) or 99
                    e.after = BF:GetSingleBuffRelativeOrder(sc, groupTypeKey) == "AFTER"
                    bucket[#bucket + 1] = e
                end
            end
        end
    end
    for i = 1, #_sbHostKeys do
        local b = _sbBucket[_sbHostKeys[i]]
        if #b > 1 then table.sort(b, SingleBuffFlowLess) end
    end
    return passValid
end

-- ── v92 §A3.2: EMIT ONE HOST ──────────────────────────────────────────────
-- The v65 group build, parameterized by the host's container key and geometry.
-- Bands are per host and compatible with every host's existing indexes:
--   1..499     sb* Relative Order = Before
--   500+rank   sp* customized spells        (buffs / bfc)
--   1000       main                         (buffs / bfc) or bd (bigDef, §A5)
--   1500+i     pre* preset groups           (buffs / bfc)
--   2000       raidbuffs                    (buffs)
--   2500+      sb* Relative Order = After
--
-- `dormant` builds/keeps the groups PARKED. `sidMap`, when given, records
-- groupKey -> spellID. Both fed the v92 bigDef assist gate, which v94 removed
-- (see BigDefIcons:Update); the bigDef host now passes `false, nil` and no
-- current caller uses either. Kept as parameters for a host that needs to be
-- born parked for a DURABLE reason -- never for a transient unit state.
-- `hostC` (2026-09-14, owner ruling) is the HOST's container config when the
-- host is a multi-icon buff container. A "Show (Default Buff)" entry that
-- gets its own sb group there (an Order, or an Applied By that differs from
-- the host's -- otherwise it shares the host's `main` and needs nothing) is
-- still PART OF THAT CONTAINER, so it takes the container's border and
-- duration text as well as its size; without this it drew with the Buffs
-- section's styling inside a container styled differently. The Buffs and
-- Big Defensive hosts pass nothing and keep their own spec path.
local function EmitSingleBuffHostGroups(parent, featureKey, hostKey, ac, groupTypeKey,
                                        baseSize, spacing, rowSpacing, ttY,
                                        dormant, sidMap, hostC)
    local c = parent._bf_auraContainers and parent._bf_auraContainers[featureKey]
    if not c then return end
    local list = _sbBucket[hostKey]
    if not list or #list == 0 then return end
    -- The host's base size is the divisor of every mult below; the same "or 12"
    -- fallback every other size read in this file carries, so a host whose
    -- geometry has not resolved yet renders at a sane size instead of erroring
    -- on nil arithmetic in a render path.
    if not (baseSize and baseSize > 0) then baseSize = 12 end
    local seen = _sbSeen[hostKey]
    -- "This container has hosted sb groups at some point", which is exactly the
    -- condition under which its sweep has anything to do. Same lifetime as the
    -- groups themselves (both live on the engine container, which is never
    -- destroyed), so it can never miss one.
    c._bf_sbHosted = true
    local nBefore, nAfter = 0, 0
    for i = 1, #list do
        local e  = list[i]
        local gk = "sb" .. (e.c.singleBuffKey or tostring(e.ci))
        seen[gk] = true
        if sidMap then sidMap[gk] = e.sid end

        local layoutIndex
        if e.after then
            nAfter = nAfter + 1
            layoutIndex = SINGLE_BUFF_AFTER_BASE + nAfter
        else
            nBefore = nBefore + 1
            layoutIndex = nBefore
        end

        -- The entry's own size, expressed as a multiple of the HOST's size --
        -- that is the form ContainerFactory's per-group layout cell wants.
        --
        -- v92 (owner): "Show (Default Buff)" means the entry is PART OF THE
        -- GROUP it flows in, so it takes the HOST's size -- mult 1, whatever
        -- the host is (Big Defensive 24 -> 24, a container overridden to 10 ->
        -- 10). Only a CUSTOMIZED entry has a size of its own, and that one
        -- keeps its configured pixels as a mult of the host base.
        --
        -- Without this, a default entry rendered at the BUFFS size in every
        -- host: ResolveContainerGeometry forces useBuff = true for
        -- singleBuffCustomized == false (a Default entry has no size to
        -- resolve), so eSize is the Buffs baseline no matter which flow the
        -- entry landed in. Invisible while "Buffs" was the only host -- the two
        -- bases were the same number -- and wrong for both new ones.
        --
        -- MaxSingleBuffSizeFor applies the SAME rule, so the wrap budget and
        -- the rendered size can never disagree.
        local mult = 1
        if e.c.singleBuffCustomized ~= false then
            local eSize = BF:ResolveContainerGeometry(e.c, groupTypeKey, ac)
            if eSize and eSize > 0 then mult = eSize / baseSize end
        end

        local spec = DeriveSpellButtonSpec(parent, baseSize, e.sid, e.c)
        spec.tooltipFrameY = ttY
        spec._bf_sizeMult  = mult
        spec.size          = baseSize * mult
        -- The host container's own border and duration for a Default entry
        -- (see the note on `hostC` above). After the size: the duration
        -- stamp scales its text from spec.size.
        if hostC and not hostC.singleBuff and e.c.singleBuffCustomized == false then
            ApplyContainerBorder(spec, hostC, groupTypeKey, ac)
            ApplyContainerDuration(spec, hostC, groupTypeKey, ac)
        end

        -- The ENTRY's caster scope, not the host's. The host's filter would
        -- silently override an entry's "Applied By" setting the moment it moved
        -- into that flow; ContainerAuraFilter is what its own container used.
        local filter = ContainerAuraFilter(e.c)

        if not (c._bf_groupSpecs and c._bf_groupSpecs[gk]) then
            BF:EnsureAuraGridSpellGroup(parent, featureKey, gk, {
                filter = filter, buttonSpec = spec,
                layoutIndex = layoutIndex, maxFrameCount = 1,
                spacing = spacing, rowSpacing = rowSpacing,
                -- Include set from the START, for the reason spelled out in
                -- ApplySpellGroups: a group born with a bare "HELPFUL" would
                -- match every helpful aura if the post-creation setter were
                -- ever denied.
                candidateFilters = { includeSpellIDs = { [e.sid] = true } },
            })
            if c._bf_groupSpecs and c._bf_groupSpecs[gk] then
                c:SetAuraGroupCandidateFilters(gk,
                    { includeSpellIDs = { [e.sid] = true } })
                -- Groups are born LIVE (AddAuraGroup takes a real filter and
                -- creation never seeds the dormant flag), so a host that wants
                -- them hidden has to park immediately -- the same "park it the
                -- instant it exists" rule `main` runs on.
                if dormant then
                    BF:SetAuraGridGroupDormant(parent, featureKey, gk, true)
                end
            end
        else
            -- v65: a size change has to be forced through by hand. The group's
            -- baked size is applied at AddAuraGroup time and refreshed only by
            -- ApplyAuraGridGeometry's button walk, which is gated on the
            -- CONTAINER size (c._bf_curButtonSize ~= size) -- and editing this
            -- entry's own Icon Size leaves the host's size untouched, so the
            -- walk never ran. ButtonSpecSig covers neither `size` nor
            -- `_bf_sizeMult` either, so ApplyAuraGridGroupButtonSpec below
            -- early-returns and the stored mult (which drives the per-group
            -- layout.elementWidth) kept its old value. Net effect before this:
            -- Icon Size on an anchored entry was reload-only.
            --
            -- v68 FIX: apply the new size NOW, this pass. The v65 workaround
            -- (nil c._bf_curButtonSize so "the next ApplyAuraGridGeometry
            -- walks") ran ONE REFRESH LATE: geometry runs BEFORE this function
            -- inside the same Layout, so each edit was rendered by the
            -- FOLLOWING refresh with whatever mult that refresh found stored --
            -- the Icon Size slider visibly "reverted" to a previous value on
            -- release. ApplyAuraGridGroupSize is the geometry walk scoped to
            -- this one group (resize + full layout re-push + engine rebuild).
            --
            -- While restricted, leave the stored mult UNTOUCHED so the change
            -- guard re-fires and the resize is retried on the next unrestricted
            -- pass (same retry contract as ApplyAuraGridGroupButtonSpec).
            --
            -- Gated on IsAuraCreationRestricted, NOT InCombatLockdown alone:
            -- inside a Mythic+ keystone auras are secret for the whole run, in
            -- or out of combat, so an out-of-combat edit there used to commit
            -- the new mult and then have every write of the walk denied -- the
            -- change guard saw it as applied and never retried (field report
            -- 2026-09-10: customizations reverted after a reload in a key).
            -- Refused, the edit arms the Layout replay so it lands the moment
            -- the restriction lifts (BF:NoteAuraLayoutRestricted).
            local prev = c._bf_groupSpecs[gk]
            if prev and prev._bf_sizeMult ~= mult then
                if BF:IsAuraCreationRestricted() then
                    BF:NoteAuraLayoutRestricted(parent)
                    -- 2026-09-11 (restricted recreate, plan §3.1): inside a key
                    -- the host container is rebuilt with the new size baked in
                    -- at creation. A no-op outside the window.
                    BF:RequestAuraRecreate(parent, "container", featureKey, "sizeMult")
                else
                    prev._bf_sizeMult = mult
                    prev.size = baseSize * mult
                    BF:ApplyAuraGridGroupSize(parent, featureKey, gk)
                end
            end
            BF:EnsureAuraGridSpellGroup(parent, featureKey, gk, { layoutIndex = layoutIndex })
            -- A PARKED group (the bigDef assist gate) keeps its flow position,
            -- filter and styling maintained, so an edit made while it is hidden
            -- lands the moment it unparks -- but its candidate set is NEVER
            -- touched: parking IS a candidate set (DORMANT_CANDIDATES), and
            -- stamping the include set over it would silently unpark the group.
            -- The unpark path re-stamps it, here and in BigDefIcons:Update.
            if dormant then
                BF:SetAuraGridGroupDormant(parent, featureKey, gk, true)
            else
                BF:SetAuraGridGroupDormant(parent, featureKey, gk, false)
                -- Re-apply AFTER the unpark: unparking clears the candidate set.
                c:SetAuraGroupCandidateFilters(gk, { includeSpellIDs = { [e.sid] = true } })
            end
            BF:SetAuraGridGroupFilter(parent, featureKey, gk, filter)
            BF:ApplyAuraGridGroupButtonSpec(parent, featureKey, gk, spec)
        end
    end
end

-- ── v92 §A3.3: THE STALE SWEEP, PER HOST ──────────────────────────────────
-- Park sb groups this pass did not emit INTO THIS HOST. Narrow test, and it
-- must not catch "sp*".
--
-- Per host is the whole point: an entry that moved from one host to another is
-- "seen" this pass, but only in its NEW host -- the old host's copy has to be
-- parked here or the icon renders twice. Every potential host runs its own
-- sweep against its own seen set (v65 ran one sweep, on "buffs", which is why
-- an sb group in any other container would have been parked by nothing).
--
-- v78 GUARD: only when this pass could actually decide membership.
-- Symptom this fixes: "all buff icons stop showing on some units until I
-- toggle any buffs setting". Membership is decided by the anchor resolver,
-- which reads anchorPoint through the PER-LAYOUT groupSettings[groupTypeKey]. A
-- frame that runs a pass with a nil / not-yet-resolved groupTypeKey reads NO
-- entry as anchored, collects nothing, and this sweep then parks every sb group
-- it has. Nothing in :Update can undo that -- Update re-syncs the container's
-- shown state and unit, not group dormancy -- so the row stays empty until the
-- next Layout, i.e. until the user touches a setting. It is per FRAME
-- (groupTypeKey is resolved per frame), which is why it hits some units and not
-- others, and CFG frames have a documented window where they are built before
-- their header carries its CFG identity (Indicators/BigDefIcons.lua).
--
-- An empty result from a pass that could not resolve its inputs is not evidence
-- that the user removed the entries, so it must not be acted on. A genuine
-- "user un-anchored everything" still parks, because that pass has a real
-- groupTypeKey and a non-empty container list.
local function SweepStaleSingleBuffGroups(parent, featureKey, hostKey)
    local c = parent._bf_auraContainers and parent._bf_auraContainers[featureKey]
    if not (c and c._bf_sbHosted) then return end
    local seen = _sbSeen[hostKey]
    for _, gk in ipairs(c._bf_groupKeys) do
        if gk:sub(1, 2) == "sb" and not (seen and seen[gk]) then
            BF:SetAuraGridGroupDormant(parent, featureKey, gk, true)
        end
    end
end

-- ── v92 §A3.1: SHARED ENTRIES IN A bfc HOST ───────────────────────────────
-- The buffs row folds its shared sids into `main`'s include set at the bottom
-- of ApplyBuffFilters (c0._bf_mainIncl). A bfc host's equivalent is the
-- containerSpells stamp its own maintenance arm just wrote -- so this re-stamps
-- that group with the UNION, and must run AFTER that arm (it stamps
-- unconditionally, so an earlier union would simply be overwritten).
--
-- The host's `main` must be LIVE even when the container has no spells of its
-- own: a shared anchored sid IS content, and the arm above parks `main` on an
-- empty include set.
local function StampHostSharedInclude(parent, key, cc, hostC, hostCi, cfg, shared)
    if not (shared and next(shared) ~= nil) then
        -- Nothing shared into this host this pass: the per-container arm's own
        -- stamp stands (it re-stamps or parks every pass). Drop the bookkeeping
        -- so the next non-empty pass is treated as a change and kicks.
        cc._bf_sbMainIncl = nil
        cc._bf_sbInclGen  = nil
        return
    end
    local stamp = {}
    local spells = cfg and cfg.containerSpells and cfg.containerSpells[hostCi]
    if spells then for sid in pairs(spells) do stamp[sid] = true end end
    for sid in pairs(shared) do stamp[sid] = true end
    local wasParked = cc._bf_dormantGroups and cc._bf_dormantGroups.main
    BF:SetAuraGridGroupDormant(parent, key, "main", false)
    -- Change-guarded; needed because the arm above only stamps the filter on
    -- the non-empty branch, and this branch may be unparking an empty one.
    BF:SetAuraGridGroupFilter(parent, key, "main", ContainerAuraFilter(hostC))
    -- A FRESH table every time: the engine may retain whatever it is handed,
    -- and `stamp` doubles as our own bookkeeping copy.
    local ok = pcall(cc.SetAuraGroupCandidateFilters, cc, "main",
        { includeSpellIDs = stamp })
    if not ok then
        -- Denied. Never leave `main` live-and-permissive with no include set:
        -- re-park it if WE unparked it (if it was already live it still holds
        -- the arm's own narrower stamp, which is safe). The flipped dormancy
        -- makes the next Layout retry, same contract as the sb path.
        if wasParked then BF:SetAuraGridGroupDormant(parent, key, "main", true) end
        cc._bf_sbMainIncl = nil
        return
    end
    -- Candidate changes don't re-evaluate EXISTING aura assignments
    -- (PTR-observed). The container arm's own generation kick already ran, and
    -- ran BEFORE this stamp, so a generation bump has to be re-kicked here.
    local gen = cfg and cfg.generation
    if wasParked or cc._bf_sbInclGen ~= gen
       or not SbSetsMatch(cc._bf_sbMainIncl, stamp) then
        pcall(cc.UpdateAllAuras, cc)
    end
    cc._bf_sbMainIncl = stamp
    cc._bf_sbInclGen  = gen
end

-- ── v92 §A5: THE bigDef HOST ──────────────────────────────────────────────
-- Emit + sweep for the Big Defensive container, assuming the buckets are the
-- current pass's. Split out from BF.ApplyBigDefAnchoredGroups so both entry
-- points (ApplyBuffFilters, which has just collected, and BigDefIcons:Layout,
-- which has not) share one body.
local function ApplyBigDefAnchoredEmit(parent, ac, groupTypeKey, passValid)
    local cc = parent._bf_auraContainers and parent._bf_auraContainers.bigDef
    -- No container = Big Defensive is off (or deferred, or not built yet) for
    -- this frame. Owner decision: anchored entries HIDE WITH THEIR HOST; only
    -- deleting a host falls back to Buffs. Nothing to sweep either -- an engine
    -- container that does not exist holds no groups.
    if not cc then return end
    local list = _sbBucket.bigDef
    local n = list and #list or 0
    if n == 0 and not cc._bf_sbHosted then return end
    -- `bd` is created through EnsureAuraGridContainer's container-level `groups`
    -- list, which takes no layoutIndex -- so it has NONE, and the sb bands
    -- (1..499 / 2500+) would have nothing to sit before and after. 1000 is the
    -- same index `main` carries in the buffs row and in every bfc container.
    -- The setter exists precisely for container-level groups and is
    -- change-guarded, so this costs one table compare after the first pass.
    BF:SetAuraGridGroupLayoutIndex(parent, "bigDef", "bd", 1000)
    local size = ac._roundedBigDefSize or 24
    local ttY  = BF.TooltipBelowFrameY(parent, ac.bigDefAnchor, ac.bigDefOffsetY, size)
    -- v94: no `dormant` term and no sidMap. Both existed only for the per-group
    -- assist gate in BigDefIcons:Update, which is gone -- Big Defensive now
    -- hides the whole container on a unit we cannot assist, so nothing here
    -- parks for a transient unit state and nothing has to re-stamp an include
    -- set on the way back. Durable config still parks, through the stale sweep
    -- below and the per-entry hidden/spec gates inside the emit.
    EmitSingleBuffHostGroups(parent, "bigDef", "bigDef", ac, groupTypeKey,
        size, ac.bigDefSpacing, ac.bigDefRowSpacing, ttY, false, nil)
    if passValid then
        SweepStaleSingleBuffGroups(parent, "bigDef", "bigDef")
    end
    -- ── Duplicate mitigation ───────────────────────────────────────────────
    -- An anchored entry whose spell is itself engine-flagged BIG_DEFENSIVE
    -- matches BOTH `bd` and its own sb group. Cross-group overlap is deduped by
    -- the engine but the WINNER is unspecified (see the v79/v85 notes in
    -- BigDefIcons.lua), so the entry's custom visuals might or might not be the
    -- copy that renders. Excluding the promoted ids from `bd` makes the sb
    -- group the only candidate.
    --
    -- Spell-ID candidates are silently dropped for HELPFUL auras on
    -- NON-assistable units (the engine's identity carve-out), which makes this
    -- a no-op exactly there -- and there the sb groups are parked by the assist
    -- gate anyway, so no duplicate can appear either way.
    --
    -- `bd`'s own maxFrameCount, filter and sort are untouched: anchored entries
    -- render IN ADDITION to Max Defensives (owner decision, §A6).
    if cc._bf_dormantGroups and cc._bf_dormantGroups.bd then
        -- Parked: SetAuraGridGroupDormant owns bd's candidates while it is, and
        -- unparking clears them -- so forget our stamp and re-apply on the next
        -- pass rather than letting the change guard suppress it.
        cc._bf_bdExcl = nil
        return
    end
    local ex
    for i = 1, n do
        ex = ex or {}
        ex[list[i].sid] = true
    end
    if not SbSetsMatch(cc._bf_bdExcl, ex) then
        if pcall(cc.SetAuraGroupCandidateFilters, cc, "bd",
                 ex and { excludeSpellIDs = ex } or {}) then
            cc._bf_bdExcl = ex
            pcall(cc.UpdateAllAuras, cc)
        end
    end
end

-- v92 §A5: the bigDef host's maintenance, callable from BigDefIcons:Layout --
-- big-defensive creation and refresh live in that indicator (and in
-- BF:RefreshBigDefOnly), while all single-buff maintenance lives here, so the
-- host needs an entry point from the other side. A plain function on BF, not a
-- method: BigDefIcons calls it as BF.ApplyBigDefAnchoredGroups(parent, ...).
--
-- ApplyBuffFilters does NOT call this -- ApplySingleBuffGroups already emits
-- every host from the collection it has in hand, and a second walk would only
-- repeat it. So this exists for the passes that never reach ApplyBuffFilters:
-- BigDefIcons:Layout and its create-on-first-enable :Update.
--
-- EARLY-OUT, and it is the point of the function's cost profile. A flow
-- collection is a walk of every container plus a resolver, an Order and a
-- Relative Order read per single buff, plus a sort per host -- far too much to
-- pay per frame per Layout on the overwhelmingly common profile where NOTHING
-- is anchored to Big Defensive. Two questions decide it, and both are answered
-- without walking anything:
--
--   * does this host have an anchored entry RIGHT NOW -- from the (ac,
--     groupTypeKey) memo, which BigDefContainerSpecs has already warmed in this
--     same Layout for the slack, so this is a table lookup. Membership, not
--     size: a default-mode entry is anchored yet reports no size.
--   * did it host one BEFORE -- cc._bf_sbHosted, set by the emit and never
--     cleared. This is what keeps the SWEEP reachable: an entry that switched
--     away leaves a live sb group behind, and the pass that must park it is by
--     definition a pass where nothing is anchored here any more. Skipping on
--     "nothing anchored" alone would strand that group live forever.
--
-- Both false means the container has never held an sb group and holds no claim
-- to one, so the emit would no-op and the sweep has nothing to visit (it
-- early-returns on the same flag).
function BF.ApplyBigDefAnchoredGroups(parent, ac, groupTypeKey)
    if not parent or parent._isPreviewFrame then return end
    local cc = parent._bf_auraContainers and parent._bf_auraContainers.bigDef
    if not cc then return end
    ac = ac or BF:GetAuraCacheForFrame(parent)
    if not ac then return end
    if groupTypeKey == nil and BF.ResolveGroupTypeKey then
        groupTypeKey = BF:ResolveGroupTypeKey(parent)
    end
    if not cc._bf_sbHosted
       and not HostHasAnchoredSingleBuffs(ac, groupTypeKey, "bigDef") then
        return
    end
    ApplyBigDefAnchoredEmit(parent, ac, groupTypeKey,
        CollectSingleBuffFlow(parent, groupTypeKey))
end

-- ── v92 §A3: the flow builder ─────────────────────────────────────────────
-- One collection walk, then one emit per host. Returns the BUFFS host's shared
-- sid set (the include set ApplyBuffFilters hands to `main`); the other hosts'
-- shared sets are consumed here, in the bfc arm.
local function ApplySingleBuffGroups(parent, ac, groupTypeKey, cfg)
    local passValid = CollectSingleBuffFlow(parent, groupTypeKey)

    -- Host: the regular buffs row.
    local buffSize = ac._roundedBuffSize or 12
    EmitSingleBuffHostGroups(parent, "buffs", "buffs", ac, groupTypeKey,
        buffSize, ac.buffSpacing, ac.buffRowSpacing,
        BF.TooltipBelowFrameY(parent, ac.buffAnchor, ac.buffOffsetY, buffSize),
        false, nil)
    if passValid then
        SweepStaleSingleBuffGroups(parent, "buffs", "buffs")
    end

    -- Hosts: multi-icon buff containers. Every hostKey ever seen is visited,
    -- not just this pass's -- that is what parks the groups of a host an entry
    -- has just left (see SweepStaleSingleBuffGroups).
    local containers = BF:GetActiveCustomBuffContainers() or {}
    local vis = parent._bf_bfcVisible
    for hi = 1, #_sbHostKeys do
        local hostKey = _sbHostKeys[hi]
        local ciStr = hostKey:match("^bfc(%d+)$")
        if ciStr then
            local hostCi = tonumber(ciStr)
            local hostC  = containers[hostCi]
            local key    = "bfc" .. hostCi
            local cc     = parent._bf_auraContainers
                and parent._bf_auraContainers[key]
            -- A host that is not built on this frame (never created, or the
            -- v74 relevance gate), or that this Layout resolved as hidden,
            -- renders nothing -- and its anchored entries hide WITH it (owner
            -- decision; they are part of it). Its groups, sb ones included,
            -- were already parked wholesale by the maintenance arm, so there is
            -- nothing left for a sweep to do here either.
            if cc and hostC and (vis == nil or vis[hostCi] ~= false) then
                local cSize, _, cSpacing, cRowSpacing, _, cAnchor, _, cOffY
                    = BF:ResolveContainerGeometry(hostC, groupTypeKey, ac)
                EmitSingleBuffHostGroups(parent, key, hostKey, ac, groupTypeKey,
                    cSize, cSpacing, cRowSpacing,
                    BF.TooltipBelowFrameY(parent, cAnchor, cOffY, cSize),
                    false, nil, hostC)
                StampHostSharedInclude(parent, key, cc, hostC, hostCi, cfg,
                    _sbShared[hostKey])
                if passValid then
                    SweepStaleSingleBuffGroups(parent, key, hostKey)
                end
            end
        end
    end

    -- Host: Big Defensive (§A5). Runs from here as well as from
    -- BigDefIcons:Layout, so a Buffs-only Layout pass still maintains it.
    ApplyBigDefAnchoredEmit(parent, ac, groupTypeKey, passValid)

    return _sbShared.buffs
end

-- ── v64: PRESET GROUPS ────────────────────────────────────────────────────
-- One aura group per enabled preset, narrowed by a Blizzard FILTER TOKEN
-- instead of by spell id. Same call shape as the raidbuffs group above, minus
-- candidateFilters -- the token does the narrowing, so there is no include set
-- to lose. This is the ImportantIcons / BigDefIcons shape.
--
-- FOUR THINGS THAT WILL BITE ANYONE EDITING THIS:
--
-- 1. The key prefix is "pre", and it must not begin with "sp".
--    ApplySpellGroups parks every group in this container whose key starts
--    with "sp" and that it did not see on its pass; a preset group named
--    sp-anything would be parked the instant it was created.
-- 2. maxFrameCount MUST be passed. EnsureAuraGridSpellGroup defaults it to 1
--    and records that in _bf_groupOwnMax, which the geometry pass then honors
--    forever -- so an omitted value pins the preset to a single icon.
-- 3. Nothing else re-stamps these groups. ApplyBuffFilters' per-container loop
--    only touches "main" and sp*, so the filter, spec and dormancy handled here
--    are the only ones they ever get.
-- 4. Unparking clears candidateFilters to {}. Harmless here -- {} is exactly
--    the state a token-only group wants -- but it is why this shape must not
--    grow an include set later without re-applying it after every unpark.
--
-- Cross-container dedup does NOT exist: only filter-level negation works
-- across containers. So an "Important" preset shows the same auras the
-- separate Important feature container shows, if both are enabled. That is the
-- user's choice to make, not a bug to fix here.
local _presetGroupSeen = {}
-- v66: `ex` / `exGen` are cfg.excludeSpellIDs and cfg.generation, passed in by
-- the Buffs caller only (custom containers pass neither). See the note on the
-- exclude wiring inside.
-- Merge a preset def's static candidateFilters (e.g. isBossAura for debuff
-- category presets) with the dynamic excludeSpellIDs claim set. Returns a fresh
-- table (or nil when neither is present) so the engine call never aliases the
-- def's own candidateFilters table. Buff presets carry no candidateFilters, so
-- for them this returns exactly what the old `ex and {excludeSpellIDs=ex}` did.
local function _mergePresetCandidates(def, ex)
    local cand
    if def.candidateFilters then
        cand = {}
        for k, v in pairs(def.candidateFilters) do cand[k] = v end
    end
    if ex then
        cand = cand or {}
        cand.excludeSpellIDs = ex
    end
    return cand
end

-- ── v95 (2026-08-25): DETERMINISTIC CANDIDATE SIGNATURE ───────────────────
-- A byte-stable string for a candidateFilters table, so ApplyPresetGroups can
-- ask "is what I am about to push different from what this GROUP last landed?"
-- instead of relying on container-wide edge detectors (see the guard note in
-- ApplyPresetGroups for why those latched).
--
-- Written here rather than reusing ContainerFactory's CandSummary: that one is
-- a file-local /bf diagnostic (not exported), it iterates pairs() over the
-- include map and prints only a COUNT plus an arbitrary "first" key, and it
-- ignores the dispel-type and boolean candidates entirely. Two different
-- candidate sets can print the same summary, and one candidate set can print
-- two different summaries on two passes — either failure mode is fatal for a
-- change guard. So: keys SORTED, one level of recursion into the map-valued
-- candidates (includeDispelTypes / excludeDispelTypes / the include sets),
-- every boolean (isBossAura / isPriorityAura / isRoleAura, and the `false`
-- forms the de-dup negations write) and maxDuration folded in as plain
-- key=value pairs. processedAuraType and anything else scalar the engine grows
-- later rides the generic branch for free.
--
-- excludeSpellIDs is summarised by SIZE, not contents, on purpose. It is the
-- only unbounded map here (the single-buff claim set), it is passed ONLY by
-- the Buffs caller, and that caller already carries an exact generation for it
-- (cfg.generation -> exGen), which the gate tests separately: the documented
-- contract is that the generation moves whenever the buff settings are
-- re-fetched, which is the only thing that can reshape the claim set. Sorting
-- and concatenating every claimed spell id per group per frame per Layout
-- would be real per-pass cost for a change exGen has already reported.
--
-- Module-local scratch tables: this runs per preset group per container per
-- Layout, so it allocates nothing but the returned string. Safe to share —
-- the outer key list and the inner (sub-table) key list are separate tables,
-- recursion never goes deeper than one level, and there is nothing reentrant
-- in this path.
local _candSigParts, _candSigKeys, _candSigSub = {}, {}, {}
local function _candKeyLess(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return ta < tb end          -- mixed-type maps: group by type
    if ta == "number" or ta == "string" then return a < b end
    return tostring(a) < tostring(b)
end
local function CandidateSig(cand)
    if cand == nil then return "-" end
    if type(cand) ~= "table" then return tostring(cand) end
    local parts, keys = _candSigParts, _candSigKeys
    table.wipe(parts)
    table.wipe(keys)
    for k in pairs(cand) do keys[#keys + 1] = k end
    table.sort(keys, _candKeyLess)
    for i = 1, #keys do
        local k = keys[i]
        local v = cand[k]
        if type(v) ~= "table" then
            parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
        elseif k == "excludeSpellIDs" then
            local n = 0
            for _ in pairs(v) do n = n + 1 end
            parts[#parts + 1] = "excludeSpellIDs=#" .. n   -- see the note above
        else
            local sub = _candSigSub
            table.wipe(sub)
            for sk in pairs(v) do sub[#sub + 1] = sk end
            table.sort(sub, _candKeyLess)
            for j = 1, #sub do
                local sv = v[sub[j]]
                -- Read the value BEFORE overwriting the slot with the pair.
                -- A third level would have to be summarised (never tostring'd:
                -- a table address changes every rebuild and would make the
                -- signature differ on every pass) -- no such shape exists.
                sub[j] = tostring(sub[j]) .. "="
                    .. (type(sv) == "table" and "{..}" or tostring(sv))
            end
            parts[#parts + 1] = tostring(k) .. "={" .. table.concat(sub, ",") .. "}"
        end
    end
    return table.concat(parts, ";")
end

-- ── v92: the DEBUFF preset (filter, candidates) COMPOSITION, extracted ────
-- Lifted verbatim out of ApplyPresetGroups' loop so the per-container FRAME
-- EFFECT slots (DebuffIcons.lua) can present the ENGINE with exactly the same
-- question the preset's aura GROUP asks. They must match to the token: the slot
-- is a presence signal for "this container's <preset> matched something", and a
-- slot that filtered even slightly differently would light the effect for auras
-- the container is not showing (or miss ones it is).
--
-- Pure function of its arguments; allocates only what it returns.
--   def              the preset def (BF.DEBUFF_CONTAINER_PRESETS[pkey])
--   dedupPresent     the global present-preset set (nil = no negations)
--   containerMaxDur  seconds, or nil
--   ex               excludeSpellIDs claim set, or nil (container callers pass
--                    none -- see the LTD decision recorded in DebuffIcons.lua)
-- Returns (filterString, candidateFilters|nil).
local function ComposeDebuffPresetFilter(pkey, def, ac, dedupPresent,
                                         containerMaxDur, ex)
    local baseFilter = def.filter
    local baseCand   = _mergePresetCandidates(def, ex)
    -- v91 (owner ruling 2026-08-17): both dispel presets ride
    -- HARMFUL|DISPELLABLE and express their ARM as a candidate type set --
    -- By Me = includeDispelTypes(myTypes), By Others =
    -- includeDispelTypes(allTypes − myTypes). Exactly complementary by
    -- construction, and (unlike the retired RAID / !DISPELLABLE tokens) they
    -- compose with every negation below instead of OR-masking against them.
    if pkey == "meDispellable" or pkey == "othersDispellable" then
        local mf, myTypes = BF:MeDispelFilterParts(ac)
        baseFilter = mf
        baseCand = baseCand or {}
        if pkey == "meDispellable" then
            -- v94 FIX: COPY, never alias. BF:MyDispelTypes returns the module-
            -- CACHED map and states its contract in as many words -- "typesMap is
            -- SHARED and must never be mutated by a caller (copy before merging
            -- into a candidate table)". Every other consumer honors that through
            -- MergeDispelTypes, which always allocates. This site assigned the
            -- live reference, so every meDispellable group on every frame held a
            -- handle on the resolver cache: the first
            -- MergeDispelTypes(cand, "includeDispelTypes", ...) on a cand from
            -- this function would have folded new keys straight into the cache and
            -- poisoned every dispel filter, slot and claim in the addon until the
            -- next wipe. The By Others arm was already safe (OtherDispelTypes
            -- builds a fresh table per call).
            local copy = {}
            for k in pairs(myTypes) do copy[k] = true end
            baseCand.includeDispelTypes = copy
        else
            baseCand.includeDispelTypes = BF:OtherDispelTypes(myTypes)
        end
    end
    if BF._BuildDebuffPresetNegations then
        local negTok, negCand = BF._BuildDebuffPresetNegations(pkey, dedupPresent, ac)
        if negTok ~= "" then baseFilter = baseFilter .. negTok end
        if negCand then
            baseCand = baseCand or {}
            for k, v in pairs(negCand) do baseCand[k] = v end
        end
    end
    -- v89: stamp the container-wide Maximum Duration (nil = no filter, so the
    -- field is simply absent). Recomposed every pass, so a live re-apply picks
    -- up a change.
    if containerMaxDur then
        baseCand = baseCand or {}
        baseCand.maxDuration = containerMaxDur
    end
    return baseFilter, baseCand
end
BF.ComposeDebuffPresetFilter = ComposeDebuffPresetFilter

-- opts (optional): { specBuilder = function(parent, size, c, groupTypeKey, ac)
-- -> spec, sortMethod = <AuraContainerSortMethod> }. specBuilder lets the debuff
-- (dbc<ci>) caller supply a HARMFUL-appropriate button spec; when absent the
-- default builds the buff spec + container border, preserving prior behavior.
--
-- ── v92 §B3.4: the FLOWED-CONTAINER opts ──────────────────────────────────
-- A Debuffs-anchored debuff container builds its preset groups inside the
-- `debuffs` container instead of its own dbc<ci>. Five ADDITIVE opts express
-- that; every one of them is nil for every pre-v92 call site, and with all five
-- nil this function behaves exactly as before.
--
--   presetKind     "debuff" -- the kind dispatch below infers the vocabulary
--                  from the container key, and "debuffs" is not "dbc*". Without
--                  this the call would silently resolve the BUFF presets.
--   groupKeyPrefix replaces "pre" in the group key AND in the stale sweep, so
--                  two flowed containers sharing one target cannot park each
--                  other's groups. Must stay disjoint from sb/sp/pre.
--   cacheKey       VESTIGIAL since v95 (2026-08-25) -- accepted and ignored.
--                  It namespaced the per-container candidate caches that lived
--                  on the TARGET engine container (§B3.5): _bf_presetNegSig /
--                  _bf_lastMaxDur and their _bf_fpre* twins, which N sources on
--                  one target would otherwise have thrashed. Those caches are
--                  GONE -- the candidate guard is now PER GROUP
--                  (cc._bf_groupCandSig[gk], see the note in the loop), and
--                  group keys are ALREADY namespaced per source via
--                  groupKeyPrefix, so there is nothing left to key. Callers may
--                  keep passing it; nothing reads it.
--   sizeBase       the TARGET row's cell size. `size` is then the SOURCE
--                  container's own icon size, and the group's _bf_sizeMult
--                  becomes (size / sizeBase) * relativeSize -- which is what
--                  makes an overridden size mean "this many pixels IN the row"
--                  and keeps the row's maxMult/lineSizeSlack honest. Setting it
--                  also switches on the live mult re-push (see below).
--   layoutIndex    pkey -> layoutIndex map, replacing the 1500+ formula. The
--                  flowed groups take their position from the Debuff Category
--                  Priority list instead of from their own relative size.
--   maxFrameCount  the source container's resolved Max Icons (see note 2).
--
-- ── v92 (2026-08-20): the COMBINED-PAIR opts ──────────────────────────────
--   presetSet      overrides `c.presets` with the container's EFFECTIVE set on
--                  this Layout. A ticked Combine box makes the pair one unit
--                  owned by the FIRST member's container, so the owner gains
--                  the partner and every other container loses it -- a runtime
--                  follow, resolved per pass, with no data rewrite
--                  (EffectiveDebuffPresetSet, DebuffIcons.lua).
--   ratioAlias     map presetKey -> { first = <otherKey> }: read THAT key's
--                  Relative Size instead of this one's. It is the pair
--                  ownership table, passed straight through -- a virtual
--                  partner renders at the first member's size (owner decision
--                  3), matching the combined slider's read-first rule.
-- Both nil for every pre-v92 caller.
local function ApplyPresetGroups(parent, key, c, groupTypeKey, ac,
                                 size, spacing, rowSpacing, ttY, ex, exGen, opts)
    local cc = parent._bf_auraContainers and parent._bf_auraContainers[key]
    if not cc or not cc._bf_groupKeys then return end
    -- v65: the Buffs display has its OWN preset vocabulary (the retired Filter
    -- Mode values); custom containers keep the category presets. Debuff
    -- containers (dbc<ci>) have a third, HARMFUL vocabulary. Picked by container
    -- key -- see the note on BF.BUFFS_PRESETS for why they are not merged.
    -- v92: or stated outright by the caller, for the flowed case where the key
    -- is the target row's ("debuffs"), not the source container's.
    local isBuffs   = (key == "buffs")
    local isDebuffC = (key:sub(1, 3) == "dbc")
        or (opts ~= nil and opts.presetKind == "debuff")
    if isDebuffC then isBuffs = false end
    local defs  = isBuffs and BF.BUFFS_PRESETS
               or isDebuffC and BF.DEBUFF_CONTAINER_PRESETS
               or BF.CONTAINER_PRESETS
    local order = isBuffs and BF.BUFFS_PRESET_ORDER
               or isDebuffC and BF.DEBUFF_CONTAINER_PRESET_ORDER
               or BF.CONTAINER_PRESET_ORDER
    if not (defs and order) then return end
    local specBuilder = opts and opts.specBuilder
    local presetSort  = opts and opts.sortMethod
    -- v84 §9.6: sort DIRECTION rides alongside the method (the Sort Order
    -- dropdown's four options are two methods x two directions).
    local presetSortDir = opts and opts.sortDirection
    -- v71: debuff preset DE-DUP input (nil for buffs): the global present-preset
    -- set, from which ComposeDebuffPresetFilter builds this preset's negations.
    -- v95: opts.dedupSig is no longer read -- see the guard note below.
    local dedupPresent = isDebuffC and opts and opts.dedupPresent or nil
    -- v89: per-container Maximum Duration, folded uniformly into every preset
    -- group's candidateFilters (it is a container-wide filter, not per-preset).
    -- Container-wide, so resolved once here; it reaches the engine INSIDE each
    -- group's candidate table (ComposeDebuffPresetFilter), which is where the
    -- v95 per-group signature picks a change to it up.
    local containerMaxDur
    if isDebuffC and BF.DebuffContainerMaxDuration then
        containerMaxDur = BF.DebuffContainerMaxDuration(c, ac)
    end
    -- ── v95 FIX (2026-08-25): PER-GROUP CANDIDATE SIGNATURE ────────────────
    -- Replaces v94's "commit the container-wide guards only on a landed push".
    --
    -- WHAT v94 HAD. Two CONTAINER-WIDE, ONE-SHOT edge detectors --
    -- negChanged (_bf_presetNegSig / _bf_fpreNegSig[cacheKey] vs opts.dedupSig)
    -- and maxDurChanged (_bf_lastMaxDur / _bf_fpreMaxDur[cacheKey]) -- computed
    -- once at the top, ORed into every group's push gate, and committed once at
    -- the tail under candPushOK (true only if EVERY push this pass landed).
    --
    -- WHY THAT STILL LATCHED. The commit is container-wide but the pushes are
    -- per group, and the two can disagree without any push being DENIED. Any
    -- pass in which a group does not reach its push at all -- it was not in
    -- `presets` this pass (a preset toggled off, a combined pair reassigning
    -- ownership, a spec/role Layout swap), it was still being created, or the
    -- loop simply never produced it -- ends with candPushOK true and the
    -- scalars committed. The group's engine-side candidate set is then a
    -- generation behind FOREVER: on the next Layout the scalars match, so
    -- negChanged and maxDurChanged are false; exStamp[gk] ~= exGen is dead on
    -- both debuff call sites (they pass ex/exGen = nil); and wasDormant fires
    -- only on a park->unpark. Nothing is left to force the push. The reported
    -- symptom is a container stuck filtering on a stale maxDuration (300) that
    -- no settings change can shift -- and the v88b restricted-Layout replay
    -- cannot repair it either, because the replay re-runs exactly these guards.
    -- The container-wide scalar WAS the latch: it answers "did the container's
    -- inputs move", which is not the question the gate asks. The gate asks "is
    -- the engine holding what THIS GROUP should be filtering on".
    --
    -- WHAT REPLACES IT. That exact question, per group: candSig = the composed
    -- filter string + a deterministic serialisation of the composed candidate
    -- table (CandidateSig above), compared against cc._bf_groupCandSig[gk] --
    -- the last signature this group actually LANDED on the engine, stamped only
    -- inside the successful pcall. Properties that matter:
    --   * It is state ABOUT THE GROUP, so a group that skips a pass cannot be
    --     marked up to date by another group's success. Skipping is now free.
    --   * A denied push leaves the stamp alone, keeping v94's retry behavior
    --     (which was the right half of v94) without the container-wide commit.
    --   * It covers strictly more than negChanged + maxDurChanged did: both of
    --     those were proxies for "the composed candidates changed", and the
    --     negations and maxDuration are IN the composed table. It also covers
    --     changes neither noticed (e.g. the dispel-type arms recomputed from a
    --     spec change), and it does NOT fire when the de-dup sig moves for a
    --     reason that leaves this group's candidates identical.
    --   * BUFF containers (non-isDebuffC) get it too, and are strictly better
    --     off: their old gate was exStamp[gk] ~= exGen alone, and the signature
    --     is a superset of that -- exGen is still ORed in, so nothing that used
    --     to push stops pushing.
    -- _bf_presetNegSig / _bf_lastMaxDur / _bf_fpreNegSig / _bf_fpreMaxDur and
    -- candPushOK are gone with the scheme; nothing anywhere else read them
    -- (whole-tree grep, v95). opts.cacheKey and opts.dedupSig are now unread --
    -- see the opts notes above.
    -- v65: the standalone Buffs Blacklist is gone. Blacklisting is now a Single
    -- Buff entry with Display Type = Blacklist (singleBuffHidden), which claims
    -- the spell out of the regular row via cfg.generalExclude.
    --
    -- v66 FIX: that claim used to go nowhere on 12.1. cfg.generalExclude reaches
    -- the engine as cfg.excludeSpellIDs, whose only consumer was the `main`
    -- group -- and ApplyBuffFilters parks `main` unconditionally on this engine.
    -- So a Blacklist entry suppressed only the addon's own sb<key> group while
    -- the preset group below kept matching the aura by token, and a Whitelist
    -- entry moved to its own anchor point drew TWICE. Preset groups now carry
    -- the exclude set themselves, which is the same facility `main` used
    -- (SetAuraGroupCandidateFilters) and the one DebuffIcons' `primary` group
    -- already combines with a token filter on 12.1 -- see ApplyDebuffLTDExcludes.
    -- v92: no per-source keying needed here -- this table is already keyed by
    -- GROUP KEY, and the flowed group keys are namespaced per source.
    local exStamp = cc._bf_presetExGen
    if not exStamp then exStamp = {}; cc._bf_presetExGen = exStamp end
    -- v95: the per-group candidate signature stamp (see the guard note above).
    -- Same shape and same lifetime as exStamp, and keyed the same way -- by
    -- GROUP KEY, which is already namespaced per source in the flowed case, so
    -- like exStamp it needs no opts.cacheKey. Created lazily: containers that
    -- never build a preset group never grow the table.
    local candStamp = cc._bf_groupCandSig
    if not candStamp then candStamp = {}; cc._bf_groupCandSig = candStamp end
    -- v92: the group-key namespace. "pre" for every pre-v92 caller; the sweep at
    -- the end matches exactly this, so it can never reach another source's
    -- groups in a shared target container.
    local gkPrefix = (opts and opts.groupKeyPrefix) or "pre"
    local gkPrefixLen = #gkPrefix
    -- v92 §B4: the target row's cell size, when the caller expresses this
    -- container's size as a multiple of it. nil == `size` IS the cell size,
    -- which is the pre-v92 shape (mult is then just the relative size).
    local sizeBase = opts and opts.sizeBase
    local liMap    = opts and opts.layoutIndex
    -- Note 2 below: an omitted maxFrameCount pins the group to a single icon
    -- forever, so the default stays the historical 8 rather than nil.
    local maxFrames = (opts and opts.maxFrameCount) or 8
    -- v93: PER-PRESET max, for debuff containers. Their container-level Max
    -- Icons control is gone (owner ruling 2026-08-20) -- each debuff type
    -- carries its own "Max Debuffs" -- so there is no single number to apply
    -- to every group this call builds. A flag rather than a resolver closure:
    -- this runs per container per Layout pass, and the container is already in
    -- scope here. nil/false for buffs, where maxFrames stays the answer.
    local perPresetMax = opts and opts.presetMaxPerCategory
    -- v92: combined-pair ratio aliasing (debuff containers only -- the buff
    -- vocabulary has no pairs and no Relative Size).
    local ratioAlias = isDebuffC and opts and opts.ratioAlias or nil
    table.wipe(_presetGroupSeen)
    -- v65: the Buffs display resolves to exactly ONE preset -- spec override,
    -- else role override, else the global choice (BF:ResolveBuffsPreset, which
    -- walks the same precedence as ResolveActiveFlat). A custom container keeps
    -- its SET of presets, where several can run at once.
    --
    -- The resolved preset is expressed as a one-key set so the loop below is
    -- shared. "None" resolves to a real key whose def has NO filter, and the
    -- `def.filter` test then builds no group for it -- which is exactly what
    -- "show nothing" means: the Buffs display falls back to the things that do
    -- not come from a preset, i.e. Buffs-anchored single buffs and per-spell
    -- groups. Every other preset group is parked by the sweep at the end.
    -- v92: the caller's EFFECTIVE set wins when it supplied one. An empty table
    -- is meaningful (a container whose only preset the combine rule moved away
    -- renders nothing and the sweep parks its group), which is why this tests
    -- for nil rather than truthiness.
    local presets = c.presets
    if opts ~= nil and opts.presetSet ~= nil then presets = opts.presetSet end
    if isBuffs then
        presets = nil
        if BF.ResolveBuffsPreset then
            local pkey = BF:ResolveBuffsPreset()
            if pkey then presets = { [pkey] = true } end
        end
    end
    if presets then
        for i = 1, #order do
            local pkey = order[i]
            local def  = defs[pkey]
            local entry = presets[pkey]
            -- No filter == "None": nothing to build.
            if entry and not (def and def.filter) then entry = nil end
            if def and entry then
                local gk = gkPrefix .. pkey
                _presetGroupSeen[gk] = true
                -- v71: per-preset Relative Size (debuff containers only). The
                -- ENGINE sizes aura buttons by (container cell size × the group's
                -- _bf_sizeMult), NOT by spec.size alone (spec.size only drives
                -- dependent regions like the dispel-type corner icon and glow).
                -- So we mirror the enlarged-groups pattern (ApplyDebuffEnlarged-
                -- Groups): build the spec at the BASE size, then stamp
                -- _bf_sizeMult = ratio AND spec.size = base×ratio. presetRatio
                -- also drives layoutIndex so the LARGER group flows first.
                local presetRatio = 1.0
                if isDebuffC and BF._DebuffPresetRatio then
                    -- v92: a combined pair's partner reads the FIRST member's
                    -- Relative Size, so the two halves of one unit can never
                    -- render at two different sizes.
                    local rk = pkey
                    if ratioAlias then
                        local st = ratioAlias[pkey]
                        if st and st.first then rk = st.first end
                    end
                    -- 2026-09-14: `ac` is the per-Layout debuffs cache the
                    -- ratio now lives on; without it the resolver only ever
                    -- saw the container's (cleared) copy.
                    presetRatio = BF._DebuffPresetRatio(c, rk, ac)
                end
                local spec
                if specBuilder then
                    spec = specBuilder(parent, size, c, groupTypeKey, ac)
                else
                    spec = BuffButtonSpec(parent, size)
                    ApplyContainerBorder(spec, c, groupTypeKey, ac)
                    ApplyContainerDuration(spec, c, groupTypeKey, ac)
                end
                -- v92 §B4: the group's mult is against the TARGET container's
                -- cell size. Without sizeBase, base == size, so groupMult is
                -- exactly presetRatio and every pre-v92 caller is unchanged --
                -- including the spec.size expression, which is untouched.
                if sizeBase and sizeBase > 0 then
                    -- Stamped UNCONDITIONALLY in this mode: a mult of exactly 1
                    -- is a real answer here (an inherited size with no relative
                    -- size), not "nothing to do", and leaving _bf_sizeMult at
                    -- its previous value would render the group at a stale size.
                    local groupMult = ((size or sizeBase) / sizeBase) * presetRatio
                    spec._bf_sizeMult = groupMult
                    -- v93: PixelRound, not floor-to-whole-UI-unit. sizeBase is
                    -- already on the device-pixel grid; re-rounding to an
                    -- integer UI unit put spec.size on a THIRD grid, so it no
                    -- longer matched the gSize the button is SetSize'd with.
                    spec.size = math.max(2, BF:PixelRound(sizeBase * groupMult))
                elseif presetRatio ~= 1.0 then
                    spec._bf_sizeMult = presetRatio
                    spec.size = math.max(2, BF:PixelRound((spec.size or size) * presetRatio))  -- v93: see above
                end
                if ttY then spec.tooltipFrameY = ttY end
                -- v71: compose this group's effective FILTER STRING + CANDIDATE
                -- set. Start from the def; for debuff containers layer on (1) the
                -- warlock meDispellable swap and (2) the de-dup negations of every
                -- higher-ranked preset present in any container. Both paths below
                -- (create + live) consume the SAME baseFilter/baseCand.
                -- v92: extracted to ComposeDebuffPresetFilter above, so the
                -- per-container frame-effect SLOTS ask the engine exactly the
                -- question this GROUP asks. Buff/container presets keep the
                -- plain def + exclude-set shape.
                local baseFilter, baseCand
                if isDebuffC then
                    baseFilter, baseCand = ComposeDebuffPresetFilter(
                        pkey, def, ac, dedupPresent, containerMaxDur, ex)
                else
                    baseFilter = def.filter
                    baseCand   = _mergePresetCandidates(def, ex)
                end
                -- v95: this group's candidate SIGNATURE -- the whole question
                -- put to the engine below (filter token string + candidate
                -- table), in one comparable string. Built here, from the same
                -- two locals both branches consume, so the guard can never
                -- describe anything other than what is actually pushed. Cost is
                -- one small sort + concat per preset group per Layout; the
                -- unbounded exclude set is summarised rather than walked (see
                -- CandidateSig).
                local candSig = tostring(baseFilter) .. "|" .. CandidateSig(baseCand)
                -- v71: layoutIndex is SIZE-DRIVEN for debuff presets so the larger
                -- group flows FIRST. Lower index = earlier; ratio in [0.1,2.0], so
                -- floor((2-ratio)*1000) is bigger for smaller groups. `+i` keeps a
                -- stable tiebreak (preset order) when ratios are equal. Buffs keep
                -- the plain preset order.
                -- v92: a flowed container takes its position from the Debuff
                -- Category Priority list instead (opts.layoutIndex), so its
                -- icons land exactly where the unclaimed type would have.
                local presetLayoutIndex = liMap and liMap[pkey]
                if not presetLayoutIndex then
                    if isDebuffC then
                        presetLayoutIndex = 1500 + math.floor((2.0 - presetRatio) * 1000) + i
                    else
                        presetLayoutIndex = 1500 + i
                    end
                end
                -- v93: this group's own cap. Re-pointed BEFORE the
                -- create/update branch on purpose: maxFrameCount is pinned into
                -- _bf_groupOwnMax at creation, so a group first built under one
                -- Max Debuffs value would keep it forever (the defect
                -- SetAuraGridGroupOwnMax exists for -- _PLAN_AuraButtonCreation.md
                -- §5). On the creation pass the call is a no-op (nothing to
                -- re-point yet) and the value below does the work; on every pass
                -- after, this is what tracks the slider.
                local gMax = maxFrames
                if perPresetMax then
                    gMax = BF:ResolveDebuffPresetMax(ac, pkey)
                    BF:SetAuraGridGroupOwnMax(parent, key, gk, gMax)
                end
                if not (cc._bf_groupSpecs and cc._bf_groupSpecs[gk]) then
                    local created = BF:EnsureAuraGridSpellGroup(parent, key, gk, {
                        filter = baseFilter, buttonSpec = spec,
                        -- From the start, not post-creation: AddAuraGroup takes
                        -- candidateFilters, and a group that existed for even
                        -- one pass without its excludes would flash the claimed
                        -- auras back into the row. For debuff category presets
                        -- this also carries the isBossAura/isPriorityAura/
                        -- isRoleAura flag from the def, plus the v71 de-dup
                        -- negations composed above.
                        candidateFilters = baseCand,
                        sortMethod = presetSort, sortDirection = presetSortDir,
                        -- After the per-spell groups (their ranks start at 1)
                        -- and after the main group (1000); size-driven within.
                        layoutIndex = presetLayoutIndex,
                        maxFrameCount = gMax,   -- see note 2 above
                        spacing = spacing, rowSpacing = rowSpacing,
                    })
                    exStamp[gk] = exGen
                    -- v95: AddAuraGroup carries candidateFilters, so a group
                    -- that was really created is already holding candSig --
                    -- stamp it and the first live pass costs no redundant
                    -- push. But EnsureAuraGridSpellGroup CAN fail silently: it
                    -- pcalls AddAuraGroup (ContainerFactory.lua) and returns
                    -- nothing when the call is denied, or when no buttonSpec
                    -- reached it. It returns the container on success, so use
                    -- that as the success indicator and stamp only then -- a
                    -- denied creation leaves the stamp nil and the FIRST live
                    -- pass pushes.
                    -- (exStamp stays unconditional, exactly as before: on a
                    -- denied creation the group is still absent from
                    -- _bf_groupSpecs, so the next Layout re-enters this same
                    -- creation branch rather than the live one.)
                    if created then candStamp[gk] = candSig end
                else
                    -- Read BEFORE unparking: SetAuraGridGroupDormant resets a
                    -- group's candidate filters to {} on the way out of dormancy
                    -- (see note 3 above and its own comment), so a group that was
                    -- parked has lost its excludes whatever the generation says.
                    local wasDormant = cc._bf_dormantGroups and cc._bf_dormantGroups[gk]
                    -- ── v92 §B4: LIVE SIZE CHANGE ─────────────────────────
                    -- Only for the flowed shape (sizeBase set). The group's
                    -- baked size is applied at AddAuraGroup and refreshed only
                    -- by ApplyAuraGridGeometry's button walk, which is gated on
                    -- the CONTAINER's size -- and editing a flowed container's
                    -- Icon Size leaves the debuffs row's size untouched, so
                    -- that walk never runs. ButtonSpecSig covers neither `size`
                    -- nor `_bf_sizeMult` either, so ApplyAuraGridGroupButtonSpec
                    -- below early-returns and the stored mult (which drives the
                    -- per-group layout.elementWidth) would keep its old value:
                    -- Icon Size on a flowed container would be reload-only.
                    -- Same fix, same reasoning as EmitSingleBuffHostGroups.
                    --
                    -- While restricted (combat OR a keystone's whole-run secret
                    -- window -- see EmitSingleBuffHostGroups, field report
                    -- 2026-09-10), leave the stored mult UNTOUCHED so the change
                    -- guard re-fires, and arm the Layout replay so the resize
                    -- lands when the restriction lifts.
                    -- Deliberately NOT extended to the dbc path: there the mult
                    -- is the relative size alone, which also drives the group's
                    -- layoutIndex, and that reorder already re-pushes the cell.
                    if sizeBase then
                        local prev = cc._bf_groupSpecs and cc._bf_groupSpecs[gk]
                        if prev and prev._bf_sizeMult ~= spec._bf_sizeMult then
                            if BF:IsAuraCreationRestricted() then
                                BF:NoteAuraLayoutRestricted(parent)
                                -- 2026-09-11 (plan §3.1): in a key, rebuild the
                                -- host with the new relative size baked in.
                                BF:RequestAuraRecreate(parent, "container", key, "sizeMult")
                            else
                                prev._bf_sizeMult = spec._bf_sizeMult
                                prev.size = spec.size
                                BF:ApplyAuraGridGroupSize(parent, key, gk)
                            end
                        end
                    end
                    BF:SetAuraGridGroupDormant(parent, key, gk, false)
                    -- v71: composed filter (warlock swap + de-dup tokens). Self-
                    -- guarded, so calling it every pass no-ops in steady state.
                    BF:SetAuraGridGroupFilter(parent, key, gk, baseFilter)
                    BF:ApplyAuraGridGroupButtonSpec(parent, key, gk, spec)
                    -- v71: re-apply the size-driven layoutIndex live (a Relative
                    -- Size change reorders the groups). EnsureAuraGridSpellGroup
                    -- with only { layoutIndex } reorders an existing group and is
                    -- change-guarded (c._bf_groupLayoutIndex), so this no-ops in
                    -- steady state. The new icon size rides the buttonSpec above.
                    if isDebuffC then
                        BF:EnsureAuraGridSpellGroup(parent, key, gk, { layoutIndex = presetLayoutIndex })
                    end
                    -- v84 §9.6: live Sort Order follow. SetAuraGroupSortMethod
                    -- is a live setter; the helper is change-guarded, so this
                    -- costs one string compare per group per frame in steady
                    -- state (sortMethod is otherwise CREATION-only here).
                    if presetSort then
                        BF:SetAuraGridGroupSort(parent, key, gk, presetSort, presetSortDir)
                    end
                    -- Generation-guarded: ApplyBuffFilters runs per unit frame,
                    -- and SetAuraGroupCandidateFilters + UpdateAllAuras is a full
                    -- engine re-evaluation. cfg.generation only moves when the
                    -- buff settings are re-fetched, which is the only thing that
                    -- can change the exclude set, so the steady state costs one
                    -- number compare per group per frame.
                    --
                    -- wasDormant covers the only path that clears a live group's
                    -- candidate set: coming OUT of dormancy. A never-parked group
                    -- (dormant flag nil) keeps its creation-time candidateFilters
                    -- -- SetAuraGridGroupDormant treats nil as live and no-ops the
                    -- unpark (the guard there). The debuff category presets
                    -- (isBossAura/isPriorityAura/isRoleAura -- boolean candidates
                    -- over a bare "HARMFUL" token) depend on this: the 2nd-pass
                    -- widening to ALL debuffs was PTR-observed before that guard
                    -- treated nil as live, and briefly worked around here with an
                    -- unconditional `or def.candidateFilters` re-apply -- which
                    -- cost SetAuraGroupCandidateFilters + a full UpdateAllAuras
                    -- engine re-evaluation per category preset on EVERY Layout
                    -- pass. Steady state is one number compare again.
                    -- v71: also re-apply when the de-dup present-set changed --
                    -- exGen only moves on buff-settings changes, not on a
                    -- preset/container add/remove that reshapes the negations.
                    -- v95: that (and the container Maximum Duration) is now read
                    -- straight off THIS GROUP's composed candidate set via
                    -- candSig, instead of the two container-wide edge detectors
                    -- negChanged / maxDurChanged, which could commit on a pass
                    -- this group sat out and then latch it stale forever (see
                    -- the guard note above the loop). candSig ~= the stamp means
                    -- "the engine is not holding what this group should be
                    -- filtering on", which is exactly what has to force a push.
                    -- Steady state is one string compare per group, on top of
                    -- the number compare that was already here.
                    if wasDormant or exStamp[gk] ~= exGen
                       or candStamp[gk] ~= candSig then
                        -- v94/v95: stamp BOTH guards only on a push the engine
                        -- actually took. A denial (restricted or secret-aura
                        -- window) leaves them untouched, so the next Layout
                        -- computes the same "changed" answer and retries --
                        -- including the v88b restricted-Layout replay, which
                        -- re-runs exactly these guards.
                        if pcall(cc.SetAuraGroupCandidateFilters, cc, gk, baseCand or {}) then
                            exStamp[gk] = exGen
                            candStamp[gk] = candSig
                        end
                        -- Option setters do not re-evaluate existing
                        -- assignments; same reason ApplyDebuffLTDExcludes does
                        -- this. Inside the guard, so it is not a per-frame cost.
                        pcall(cc.UpdateAllAuras, cc)
                    end
                end
            end
        end
    end
    -- Park presets that were turned off. Groups can never be removed.
    -- v92: matched against THIS call's namespace. In the flowed case the target
    -- container hosts groups from several sources plus its own type groups, and
    -- an unscoped "pre" test would have parked every other source's groups on
    -- every pass. ("fpre1_"):sub(1,3) is "fpr", so the pre-v92 sweeps stay
    -- blind to the flowed groups in the other direction too.
    for _, gk in ipairs(cc._bf_groupKeys) do
        if gk:sub(1, gkPrefixLen) == gkPrefix and not _presetGroupSeen[gk] then
            BF:SetAuraGridGroupDormant(parent, key, gk, true)
        end
    end
    -- v95: the v94 deferred container-wide guard commit lived here and is GONE.
    -- Every guard this function owns is now stamped where its engine write
    -- lands -- per group, inside the pcall that took -- so there is nothing
    -- left to commit at the tail, and no pass in which one group's outcome can
    -- speak for another's.
end
-- Exposed so the debuff container render path (DebuffIcons.lua) can reuse the
-- same preset loop for its dbc<ci> containers via an opts.specBuilder.
BF.ApplyPresetGroups = ApplyPresetGroups

-- ============================================================
-- v46 PER-SPELL FRAME EFFECTS (Aura Customizations → Frame Effects)
-- One 1-slot container per configured (spell, effect); the slot's
-- button carries the effect texture(s) and the ENGINE shows/hides it
-- with the spell — works in combat under 12.1 secrecy.
--   fxh<sid>: health bar color tint (over the fill; stamped with the
--             profile's own health bar texture so a custom bar texture
--             survives the tint — see RestampFxHealth)
--   fxb<sid>: frame border (edge textures; Prioritise = frame level
--             13 vs 10, straddling the dispel border's 12)
--   fxo<sid>: health bar overlay (anchored to the gradient's strong
--             edge; Prioritise = level 5 vs 2 around the dispel
--             overlay's 4). durationMap IS ported via SetDurationBar.
-- See FX_LEVEL_* below for the full health-bar layer order.
-- All stamping is change-guarded and Layout-driven; the hot Update
-- path only syncs unit/visibility via the precomputed _bf_fxKeys list.
-- ============================================================

local FX_SOLID_TEX = "Interface\\Buttons\\WHITE8x8"

-- Frame level offsets for the health-bar fx slots. A slot BUTTON lands
-- at parent + offset + 1 (ApplySlotFrameLevel in Auras/ContainerFactory.lua),
-- and the health bar itself sits at parent+1 — so every offset here must
-- be >= 1 or the visual renders UNDER the bar fill.
--
-- ── v92: THE FULL MAP, THREE LANES × FOUR RUNGS ───────────────────────────
-- Single-sourced HERE. The dispel rungs are BF.DISPEL_VISUAL_LEVEL
-- (Auras/ContainerFactory.lua) and the container rungs are
-- BF.CONTAINER_FX_LEVEL (below); both mirror this table in their own comments
-- and neither may drift from it.
--
-- Each lane carries the same four rungs, in the owner's order:
--     buff (Prioritise OFF)  <  container  <  dispel  <  buff (Prioritise ON)
-- i.e. "Prioritise Over Debuff X" OFF => Dispellable > Container > Buffs, ON =>
-- Buffs > Dispellable > Container. Per-container debuff effects sit exactly one
-- rung below their dispel kind by construction (container = dispel - 1).
--
--   offset  host at   lane      what
--   ------  --------  --------  ---------------------------------------------
--        —  parent+1            health bar fill (hBar)
--        1  parent+2   tint     buff health tint         FX_LEVEL_HEALTH
--        2  parent+3   tint     CONTAINER health tint    BF.CONTAINER_FX_LEVEL.hc
--        2  parent+3   overlay  buff overlay             FX_LEVEL_OVERLAY
--        3  parent+4   tint     dispel health tint       DISPEL_VISUAL_LEVEL.dispelHealthColor
--        3  parent+4   overlay  CONTAINER overlay        BF.CONTAINER_FX_LEVEL.ov
--        4  parent+5   tint     buff tint, prioritised   FX_LEVEL_HEALTH_PRIO
--        4  parent+5   overlay  dispel overlay           DISPEL_VISUAL_LEVEL.dispelOverlay
--        5  parent+6   overlay  buff overlay, prio       FX_LEVEL_OVERLAY_PRIO
--        —  parent+7            absorbClip / healPred / overshield
--                               (Indicators/AbsorbBars.lua:99/114/201, hBar+6)
--        —  parent+8            absorbMissingHealth / overshieldGlow
--                               (Indicators/AbsorbBars.lua:131/246, hBar+7)
--        —  parent+10           frame border
--       10  parent+11  border   buff border              FX_LEVEL_BORDER
--        —  parent+11           healAbsorb  (AbsorbBars.lua:262, hBar+10)
--       11  parent+12  border   CONTAINER border         BF.CONTAINER_FX_LEVEL.bd
--       12  parent+13  border   dispel border            DISPEL_VISUAL_LEVEL.dispelBorder
--       13  parent+14  border   buff border, prioritised FX_LEVEL_BORDER_PRIO
--      223  parent+224          dispel dot               DISPEL_VISUAL_LEVEL.dispelDot
--
-- ABSORB ART is hBar-RELATIVE, and hBar is parent+1 — so hBar+6/+7/+10 are
-- parent+7/+8/+11, ABOVE this whole tint/overlay block. A pre-v92 version of
-- this comment claimed an "absorb (shield) fill" at parent+4; that was simply
-- WRONG (nothing sits at parent+4) and it is the reason an earlier draft of
-- this scheme tried to keep rungs "above the absorb". Do not reintroduce that
-- constraint: every tint/overlay rung here is below every piece of absorb art,
-- which is also why the overlay lane must not creep past offset 5 — offset 6
-- would put a prioritised buff overlay at parent+7, tying absorbClip.
--
-- ── CROSS-LANE TIE POLICY (read before renumbering) ────────────────────────
-- Eight rungs (four tint, four overlay) have to fit in the usable integers 1..5
-- — 1 is the floor (offset 0 renders under the bar fill) and 5 is the ceiling
-- (see absorbClip above). Eight into five does not go, so cross-KIND ordering
-- CANNOT be strict everywhere. The contract is therefore:
--
--   * PER LANE (same kind) the order is STRICT. That is what the Prioritise
--     toggles promise and what the container's dispel-1 rule needs, and it
--     holds in all three lanes.
--   * CROSS-KIND ties resolve by draw order (host creation order on the shared
--     button). Two exist by construction: container overlay 3 vs dispel tint 3,
--     and prioritised buff tint 4 vs dispel overlay 4.
--   * Cross-kind ordering was NEVER guaranteed before v92 either — the dispel
--     overlay (offset 4) always outdrew a prioritised buff tint (then offset 2),
--     and the buff tint and dispel tint sat tied at offset 1. v92 changes which
--     cross-kind pairs are ties, not whether they exist.
--
-- The one tie outside the health bar: the buff border host lands at parent+11,
-- the same level as healAbsorb. Negligible and deliberate — a border is edge art
-- around the frame's rim, healAbsorb is a strip inside the bar, so they barely
-- share pixels; the alternative was pushing the border lane's floor into the
-- frame border at parent+10.
--
-- v92 NOTE — the tint tie is gone. The buff tint and the dispel tint both sat
-- at offset 1 and "dispel won by draw order". They are now explicitly ordered
-- (1 vs 3) with the SAME winner; nothing about that pair changed visually, it
-- just stopped depending on frame creation order.
--
-- v59: the tint is a full-fill recolor of the bar, so it is the BASE
-- layer — the buff overlay draws over it while neither is prioritised. It
-- used to sit at offset 2 with the non-prioritised overlay at 1, which
-- put the tint on top of its own spell's overlay. "Prioritise Over Debuff
-- Overlay" still only moves the buff overlay across the DISPEL overlay; it
-- never affects the tint.
local FX_LEVEL_HEALTH       = 1
-- Prioritised buff health tint: one above the dispel health tint, so
-- "Prioritise Over Debuff Recolor" lifts the buff tint over it, mirroring the
-- overlay/border Prioritise toggles.
local FX_LEVEL_HEALTH_PRIO  = 4
local FX_LEVEL_OVERLAY      = 2
-- Ceiling of the overlay lane: offset 6 would land the host at parent+7 and TIE
-- absorbClip (AbsorbBars.lua:99). Unchanged since v59 for that reason.
local FX_LEVEL_OVERLAY_PRIO = 5
-- v92: named, because they are rungs of the same scheme and were literals in
-- three places (the two host tables and ApplyFxKinds). The non-prioritised
-- border moved 11 -> 10 to open the container rung at 11; it stays above the
-- frame border at parent+10 and crosses nothing on the way (nothing else ever
-- sat at +11 or +12).
local FX_LEVEL_BORDER       = 10
local FX_LEVEL_BORDER_PRIO  = 13

-- v92: the per-container debuff-effect rungs, exported for the DebuffIcons-side
-- consumer that builds those slots. Fixed offsets, one below each dispel kind,
-- so the consumer cannot drift from the map above. READ-ONLY: it is shared.
BF.CONTAINER_FX_LEVEL = { hc = 2, ov = 3, bd = 11 }

-- v59: one white alpha-ramp ASSET per Gradient Direction, each sampled
-- at IDENTITY texcoords.
--
-- The previous build carried a single vertical ramp and rotated it into
-- the horizontal directions with 8-arg SetTexCoord. That rendered flat —
-- consistent with the earlier PTR finding that texcoord remapping does
-- not stick on 12.1 slot-button textures (mirrors collapsed onto their
-- unmirrored rotation; the 90° rotations behaved no better in practice).
-- Texture:SetGradient is NOT an option either: it was PTR-tried on these
-- buttons and rendered no gradient at all (see the container migration
-- plan). Baking the rotation into the asset sidesteps both — identity
-- texcoords on a plain texture is the one combination confirmed to work.
--
-- The two horizontal assets are 64x4 rotations of the 4x64 vertical
-- pair; all four are white with only the alpha channel ramping, so the
-- configured color applies cleanly via SetVertexColor.
local FX_MEDIA = "Interface\\AddOns\\BuzzardFrames\\Media\\"
local FX_GRADIENT_TEX = {
    topToBottom = FX_MEDIA .. "debuff_overlay_gradient",          -- strong at TOP
    bottomToTop = FX_MEDIA .. "debuff_overlay_gradient_flipped",  -- strong at BOTTOM
    leftToRight = FX_MEDIA .. "buff_overlay_gradient_h",          -- strong at LEFT
    rightToLeft = FX_MEDIA .. "buff_overlay_gradient_h_flipped",  -- strong at RIGHT
}

-- Which file backs a given Overlay Style + Gradient Direction.
local function FxFillTexture(style, dir)
    if style == "solid" then return FX_SOLID_TEX end
    return FX_GRADIENT_TEX[dir] or FX_GRADIENT_TEX.topToBottom
end
BF.FxFillTexture = FxFillTexture

-- Paint a PLAIN texture (one we own the texcoords of) for the given
-- Overlay Style + Gradient Direction. Color rides SetVertexColor and
-- opacity rides SetAlpha, so the Overlay Color picker's alpha channel
-- drives both styles. The identity SetTexCoord is a one-shot reset that
-- clears any rotated coords left by a pre-v59 build in the same session;
-- it is inside the file guard so repeat stamps skip it.
--
-- NOT for StatusBar fill textures — a StatusBar rewrites its fill's
-- texcoords per value, so callers driving a bar set the file through the
-- fill directly (see BuffHighlight's durationMap path).
local function ApplyFxFill(tex, style, dir, r, g, b, a)
    local file = FxFillTexture(style, dir)
    if tex._bf_fxFile ~= file then
        tex:SetTexture(file)
        tex:SetTexCoord(0, 1, 0, 1)
        tex._bf_fxFile = file
    end
    tex:SetVertexColor(r, g, b, 1)
    tex:SetAlpha(a)
end
BF.ApplyFxFill = ApplyFxFill  -- shared with the preview paths

-- Overlay Color alpha with back-compat: profiles written before the
-- separate "Overlay Opacity" slider was folded into the color picker
-- carry `alpha` on the entry and no `a` on the color.
local function FxOverlayAlpha(e, col)
    return (col and col.a) or e.alpha or 0.5
end
BF.FxOverlayAlpha = FxOverlayAlpha

-- v84 (Stage 5 §9.8): ONE SLOT PER SPELL, all effect kinds on it.
--
-- A spell with several frame effects used to pay one slot (one engine button)
-- per (spell, effect) — fxh<sid>/fxb<sid>/fxo<sid>, and four for the
-- Swiftmendable set. They were always mergeable and never merged: every one of
-- them carries the IDENTICAL filter string (the winning entry's Applied-By
-- scope via CASTER_SCOPE_FILTERS — the fx entry carries ONE scope per spell,
-- lower container index wins in the cfg build — or "HELPFUL|PLAYER" for the
-- Swiftmendable set) and the IDENTICAL includeSpellIDs set by construction,
-- so the engine keys on exactly the same thing for all of them. Merged, a spell
-- with N effects saves N-1 buttons and, in combat, N-1 of its N per-candidate
-- slot filter passes per frame.
--
-- Unlike the dispel visuals (§9.7) there is no binding collision to solve here:
-- fx visuals are plain addon-owned textures riding the button's engine
-- show/hide, and the one single-binding API in play (SetDurationBar) is
-- overlay-only — a merged button still has exactly one overlay, so exactly one
-- bar.
--
-- LEVELS: nothing renders on the button. Each kind's regions live on its own
-- child host frame at an ABSOLUTE level, so the Prioritise toggles re-level
-- ONE host and never disturb the kinds sharing the button.
--
-- BAKE-ALL: every kind's regions are created at init even for kinds this spell
-- has not configured, because CreateTexture/CreateFrame on an
-- already-configured pooled button is UNPROVEN in either direction (see
-- Docs/Aura_Performance_Investigation.md). Adding an effect later is then
-- restamp-only, and removing one is visibility-only — both safe. The per-spell
-- region cost is trivial next to a whole extra pooled button.
local function InitFxMerged(button, parent, hosts)
    button:EnableMouse(false)
    pcall(button.SetAllPoints, button, parent)
    if not hosts then return end
    local bdHost = hosts.bd
    if bdHost then
        local edges = {}
        for i = 1, 4 do
            local t = BF.Texture(bdHost, nil, "OVERLAY", nil, 0)
            t:SetTexture("Interface\\Buttons\\WHITE8x8")
            t:Hide()
            edges[i] = t
        end
        bdHost._bf_fxEdges = edges
        -- Baked, not lazy: the rounded-style ring used to be created inside the
        -- restamp, i.e. on an already-configured button. Same bake-all rule.
        -- v58 pixel host (see PixelPerfect.lua EnsureHighlightRing).
        local ringHost = CreateFrame("Frame", nil, bdHost)
        ringHost:SetAllPoints(bdHost)
        ringHost:SetFrameLevel(bdHost:GetFrameLevel())
        local ring = BF.Texture(ringHost, nil, "OVERLAY", nil, 0)
        ring:SetTextureSliceMargins(BF.RoundedBorderSlice, BF.RoundedBorderSlice,
            BF.RoundedBorderSlice, BF.RoundedBorderSlice)
        ring:SetAllPoints(bdHost)
        ring:Hide()
        bdHost._bf_fxRingHost = ringHost
        bdHost._bf_fxRing = ring
    end
    local hcHost = hosts.hc
    if hcHost then
        -- The profile's health bar texture is stamped in the restamp (it can
        -- change with the profile).
        local tex = BF.Texture(hcHost, nil, "OVERLAY", nil, 0)
        tex:SetTexture(FX_SOLID_TEX)
        tex:Hide()
        hcHost._bf_fxTex = tex
        -- Rounded border style: clip the health-bar tint to the frame's rounded
        -- shape (attach-once; inert while hidden).
        BF:AttachFrameRoundMask(parent, tex)
    end
    local ovHost = hosts.ov
    if ovHost then
        -- Neutral start; the restamp swaps in the Overlay Style / Gradient
        -- Direction file via ApplyFxFill.
        local tex = BF.Texture(ovHost, nil, "OVERLAY", nil, 0)
        tex:SetTexture(FX_SOLID_TEX)
        tex:Hide()
        ovHost._bf_fxTex = tex
        BF:AttachFrameRoundMask(parent, tex)
        -- durationMap support: a StatusBar driven ENGINE-SIDE from the aura's
        -- REMAINING time (SetDurationBar -> statusBar:SetTimerDuration(dur,
        -- interpolation, direction); direction default is ElapsedTime, which
        -- FILLS -- we bind RemainingTime so the bar drains). Orientation/fill
        -- side are stamped per Gradient Direction in the restamp. Bound
        -- unconditionally at init (bindings are only safe in the configuration
        -- window); shown/hidden by the restamp. The binding is single-valued on
        -- the BUTTON, which is exactly why only the overlay kind may own a bar.
        local bar = BF.StatusBar(nil, ovHost)
        bar:SetStatusBarTexture(FX_SOLID_TEX)
        bar:Hide()
        ovHost._bf_fxBar = bar
        BF:AttachFrameRoundMask(parent, bar:GetStatusBarTexture())
        pcall(button.SetDurationBar, button, bar, {
            direction = (Enum.StatusBarTimerDirection
                and Enum.StatusBarTimerDirection.RemainingTime) or 1,
        })
    end
    local nmHost = hosts.nm
    if nmHost then
        pcall(nmHost.SetClipsChildren, nmHost, true)  -- long-name clip parity
        local fs = nmHost:CreateFontString(nil, "OVERLAY")
        nmHost._bf_fxFS = fs
        parent._bf_smNameFS = fs
    end
    button._bf_init = true
end

-- Hide one kind's regions without touching the slot: removing an effect from a
-- spell that still has others must not park the shared slot.
--
-- pcall-GUARDED (V3 class, same as the RestampFx* siblings below): these regions
-- are descendants of the engine SLOT BUTTON, which becomes a FORBIDDEN object
-- whenever aura data is secret (in combat, or a combat /reload, or when foreign
-- taint has entered the frame). An UNGUARDED region:Hide() then throws
-- "calling 'Hide' on bad self ... forbidden object" from the secure-frame
-- machinery — which is exactly how this hide, reached on a live restamp under a
-- secret window, took BuzzardFrames down. A denied hide is harmless to skip: the
-- region was already hidden or will be re-hidden on the next unrestricted restamp
-- (the sig is cleared above so the next pass re-evaluates). Guard EACH call
-- independently so one denied region can't skip the rest.
local function HideFxKind(host, kind)
    if not host then return end
    -- ALREADY-HIDDEN GUARD. This function is reached on the arm taken BECAUSE
    -- the kind is not configured, so for any partly-configured slot it used to
    -- fire every pass, per frame, per Layout, re-hiding regions that were
    -- already hidden -- 5 pcalls for "bd", 2 each for hc/ov, 1 for nm. A spell
    -- with only a health tint paid 7; the Swiftmendable slot with only a name
    -- recolor paid 9. Cleared at the top of every RestampFx*, so any restamp
    -- attempt re-arms the hide.
    --
    -- LATCHED ONLY ON A FULLY SUCCESSFUL HIDE. Every Hide below can be DENIED
    -- (that is why they are pcall'd -- see the header block above), and the
    -- recovery contract is that a denied hide is retried by the next pass.
    -- Latching before the result would break exactly that: this arm never
    -- calls a RestampFx*, so nothing would ever clear the flag, and regions
    -- denied mid-combat would stay painted on the frame until the user
    -- re-enabled that same effect. Track every call and only latch if they
    -- all took. `_bf_fxSig` stays unconditional -- the next pass must
    -- re-evaluate either way.
    if host._bf_fxHidden then return end
    host._bf_fxSig = nil
    local allHidden = true
    local function hide(region)
        if region and not pcall(region.Hide, region) then allHidden = false end
    end
    if kind == "bd" then
        local edges = host._bf_fxEdges
        if edges then for i = 1, 4 do hide(edges[i]) end end
        hide(host._bf_fxRing)
    elseif kind == "nm" then
        hide(host._bf_fxFS)
    else
        hide(host._bf_fxTex)
        hide(host._bf_fxBar)
    end
    host._bf_fxHidden = allHidden or nil
end


-- (Re)stamp helpers: anchors + colors from the live config entry.
-- Sig-guarded (config tables are edited in place, so value sigs catch
-- every change); pcall-guarded (V3 class: native calls on pooled
-- buttons out of combat).
-- v53 Phase 2: `c` is the SLOT RECORD (frame._bf_auraSlots[key]), not a
-- container — it still carries _bf_slotButton, so these are unchanged.
-- Health bar color tint.
--
-- 12.1 cannot recolor the health StatusBar itself for an aura: aura
-- presence is secret in combat, so Lua never learns when to call
-- SetStatusBarColor. The tint is therefore a slot-button texture the
-- ENGINE shows over the fill. To keep that from reading as a flat bar,
-- the texture is stamped with the SAME texture file the health bar is
-- using and tinted with SetVertexColor — so a custom bar texture keeps
-- its shading through the tint instead of being covered by a solid
-- block. Grid2's IndicatorBar recolors one textured bar for the same
-- reason; this is the closest 12.1 can get to that.
-- v84 §9.8: `host` is the kind's absolute-level host frame on the merged slot
-- button. Every anchor and every signature is now per HOST, not per button —
-- the button is shared and geometrically inert.
-- 2026-09-11 (restricted recreate, plan §3.1 fx row): `peek` -- return the sig
-- this restamp WOULD commit, and write nothing (not even the hidden latch).
-- The in-key compare in ApplyFxKinds uses it so both sides share ONE sig
-- derivation; a second copy would drift and loop the rebuild (plan §4.3).
local function RestampFxHealth(parent, host, e, peek)
    if host and not peek then host._bf_fxHidden = nil end  -- see HideFxKind
    local hBar = parent.healthBar
    if not (host and host._bf_fxTex and hBar) then return end
    local hp = BF:GetSectionProfileForFrame("healthPower", parent)
    local hbTex = (hp and hp.useCustomHealthBarTexture)
        and BF:ResolveBarTexture(hp.healthBarTexture) or FX_SOLID_TEX
    local sig = (e.r or 0) .. "," .. (e.g or 1) .. "," .. (e.b or 0)
        .. "," .. (e.a or 1) .. "|" .. hbTex
    if peek then return sig end
    if host._bf_fxSig == sig then return end
    if pcall(function()
        local hFill = hBar:GetStatusBarTexture()
        local anchorTo = hFill or hBar
        host:ClearAllPoints()
        host:SetPoint("TOPLEFT", anchorTo, "TOPLEFT", 0, 0)
        host:SetPoint("BOTTOMRIGHT", anchorTo, "BOTTOMRIGHT", 0, 0)
        local tex = host._bf_fxTex
        tex:SetTexture(hbTex)
        tex:SetTexCoord(0, 1, 0, 1)
        tex._bf_fxFile = hbTex
        tex:SetAlpha(1)
        tex:SetAllPoints(host)
        tex:SetVertexColor(e.r or 0, e.g or 1, e.b or 0, e.a or 1)
        tex:Show()
    end) then host._bf_fxSig = sig end
end

local function RestampFxBorder(parent, host, e, peek)
    if host and not peek then host._bf_fxHidden = nil end  -- see HideFxKind (peek: above RestampFxHealth)
    if not (host and host._bf_fxEdges) then return end
    local col = e.color or { r = 0, g = 1, b = 0 }
    local widthPx = e.thickness
        or (BF.db and BF.db.profile and BF.db.profile.buffBorderWidth) or 2
    local px = BF:PixelsToUI(widthPx)
    -- Rounded frame border style: this per-spell border replaces its 4
    -- square edges with a sliced highlight ring at its own width (same
    -- visual contract as BF:SetHighlightBorder for the other highlights).
    local bp = BF:GetSectionProfileForFrame("borders", parent)
    local rounded = BF.IsRoundedBorderStyle(bp and bp.borderStyle)
    local sig = (col.r or 0) .. "," .. (col.g or 1) .. "," .. (col.b or 0)
        .. "," .. (col.a or 1) .. "|" .. px .. "|" .. tostring(rounded)
    if peek then return sig end
    if host._bf_fxSig == sig then return end
    if rounded then
        if pcall(function()
            host:ClearAllPoints()
            host:SetAllPoints(parent)
            local ring = host._bf_fxRing
            -- v84: baked at init (see InitFxMerged) rather than created here on
            -- an already-configured button.
            -- v58: scale + snapped texture via the shared pixel-host stamp.
            BF:StampRingPixelHost(host._bf_fxRingHost, ring, parent,
                BF:GetHighlightRing(widthPx))
            ring:SetVertexColor(col.r or 0, col.g or 1, col.b or 0, col.a or 1)
            ring:Show()
            for i = 1, 4 do host._bf_fxEdges[i]:Hide() end
        end) then host._bf_fxSig = sig end
        return
    end
    if pcall(function()
        if host._bf_fxRing then host._bf_fxRing:Hide() end
        local edges = host._bf_fxEdges
        host:ClearAllPoints()
        host:SetAllPoints(parent)
        local top, bottom, left, right = edges[1], edges[2], edges[3], edges[4]
        top:ClearAllPoints()
        top:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
        top:SetPoint("TOPRIGHT", host, "TOPRIGHT", 0, 0)
        top:SetHeight(px)
        bottom:ClearAllPoints()
        bottom:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", 0, 0)
        bottom:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", 0, 0)
        bottom:SetHeight(px)
        left:ClearAllPoints()
        left:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -px)
        left:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", 0, px)
        left:SetWidth(px)
        right:ClearAllPoints()
        right:SetPoint("TOPRIGHT", host, "TOPRIGHT", 0, -px)
        right:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", 0, px)
        right:SetWidth(px)
        for i = 1, 4 do
            edges[i]:SetVertexColor(col.r or 0, col.g or 1, col.b or 0, col.a or 1)
            edges[i]:Show()
        end
    end) then host._bf_fxSig = sig end
end

-- Health bar overlay.
--
-- Geometry follows the Gradient Direction: the strip is anchored to the
-- direction's STRONG edge and grows away from it, so shrinking the size
-- slider always eats into the weak end.
--   topToBottom → anchored TOP,    full width,  Overlay Height
--   bottomToTop → anchored BOTTOM, full width,  Overlay Height
--   leftToRight → anchored LEFT,   full height, Overlay Width
--   rightToLeft → anchored RIGHT,  full height, Overlay Width
-- durationMap spans the whole bar along the mapped axis (the size
-- slider is hidden while it's on) and drains toward the strong edge.
--
-- `initW` / `initH` (optional): the frame's INITIAL size, used only while the
-- live bar still measures 0. That is the :Create window -- the fx slot's
-- initButton now stamps the effect at creation (see StampFxAtCreation), before
-- the frame's first Layout has sized the bar, and inside a keystone that
-- creation stamp is the only one that lands (field report 2026-09-10). The
-- header's frameWidth / frameHeight (what BuzzardFrame_GetInitialSize hands
-- the frame) is the stand-in; the first unrestricted Layout re-measures the
-- real bar and the size term in the sig re-stamps it exactly.
local function RestampFxOverlay(parent, host, e, initW, initH, peek)
    if host and not peek then host._bf_fxHidden = nil end  -- see HideFxKind (peek: above RestampFxHealth)
    local hBar = parent.healthBar
    if not (host and host._bf_fxTex and hBar) then return end
    local col = e.color or { r = 0, g = 1, b = 0 }
    local fillOnly = e.fillOnly and true or false
    local alpha = FxOverlayAlpha(e, col)
    local style = e.style or "gradient"
    local dm = (e.durationMap and host._bf_fxBar) and true or false
    local dir = e.gradientDir or "topToBottom"
    local horizontal = (dir == "leftToRight" or dir == "rightToLeft")
    local frac = dm and 1
        or (horizontal and (e.width or 0.7) or (e.height or 0.7))
    local hFill = hBar:GetStatusBarTexture()
    local anchorTo = (fillOnly and hFill) and hFill or hBar
    -- Both measurements come off the health BAR, never off the fill
    -- texture: the fill's width tracks a secret health value under 12.1,
    -- and a secret would poison the sig concat below. fillOnly still
    -- anchors to the fill edge — only the strip's extent is bar-relative.
    local extent
    if horizontal then extent = hBar:GetWidth() else extent = hBar:GetHeight() end
    if not extent or extent <= 0 then
        -- Not laid out yet (fx slots are created in :Create, ahead of the
        -- first frame:Layout). Use the health area's DESIGNED size -- the
        -- same arithmetic Container:Layout is about to anchor the bar by
        -- (border inset and power-bar strip taken off the header's frame
        -- size), so the strip comes out exactly as a measured bar would.
        -- initW/initH (the raw frame size a caller may pass) are the last
        -- resort only. Explicit branches, not and/or: a nil width must not
        -- fall through to the height (the wrong axis).
        local cw, ch
        if BF.ComputeFrameContentSize then cw, ch = BF.ComputeFrameContentSize(parent) end
        if horizontal then extent = cw or initW else extent = ch or initH end
    end
    local size = extent and extent * frac
    if not size or size <= 0 then return end  -- not laid out yet; next Layout
    local sig = (col.r or 0) .. "," .. (col.g or 1) .. "," .. (col.b or 0)
        .. "|" .. alpha .. "|" .. tostring(fillOnly) .. "|" .. size
        .. "|" .. tostring(dm) .. "|" .. dir .. "|" .. style
    if peek then return sig end
    if host._bf_fxSig == sig then return end
    if pcall(function()
        host:ClearAllPoints()
        if horizontal then
            local edge = (dir == "rightToLeft") and "RIGHT" or "LEFT"
            host:SetPoint("TOP" .. edge,    anchorTo, "TOP" .. edge,    0, 0)
            host:SetPoint("BOTTOM" .. edge, anchorTo, "BOTTOM" .. edge, 0, 0)
            host:SetWidth(size)
        else
            local edge = (dir == "bottomToTop") and "BOTTOM" or "TOP"
            host:SetPoint(edge .. "LEFT",  anchorTo, edge .. "LEFT",  0, 0)
            host:SetPoint(edge .. "RIGHT", anchorTo, edge .. "RIGHT", 0, 0)
            host:SetHeight(size)
        end
        local tex = host._bf_fxTex
        ApplyFxFill(tex, style, dir, col.r or 0, col.g or 1, col.b or 0, alpha)
        if dm then
            -- Drain orientation follows the Gradient Direction: the fill
            -- retreats toward the gradient's strong edge.
            --   topToBottom: vertical, hangs from the top (reverse fill)
            --   bottomToTop: vertical, sits on the bottom
            --   leftToRight: horizontal, anchored left
            --   rightToLeft: horizontal, anchored right (reverse fill)
            -- The statusbar fill is only the GEOMETRY driver (invisible):
            -- statusbars manage their fill texture's texcoords, so the
            -- gradient can't live on the fill itself. Our texture rides
            -- the fill REGION instead, compressing as the bar drains.
            local bar = host._bf_fxBar
            bar:SetOrientation(horizontal and "HORIZONTAL" or "VERTICAL")
            bar:SetReverseFill(dir == "topToBottom" or dir == "rightToLeft")
            bar:SetAllPoints(host)
            bar:SetStatusBarColor(0, 0, 0, 0)
            tex:ClearAllPoints()
            tex:SetAllPoints(bar:GetStatusBarTexture())
            bar:Show()
        else
            if host._bf_fxBar then host._bf_fxBar:Hide() end
            tex:ClearAllPoints()
            tex:SetAllPoints(host)
        end
        tex:Show()
    end) then host._bf_fxSig = sig end
end

-- ── v53: Swiftmendable name recolor (Resto Druid) ─────────────────
-- The frame's nameText can't be recolored conditionally on 12.1 (aura
-- presence is secret in Lua), so the slot button hosts a MIRROR
-- FontString positioned identically over it: the engine shows the
-- colored copy while a swiftmendable HoT is present, covering the
-- original. Text stays in sync via hooksecurefunc on the original
-- FontString (fires for every writer — NameText, status overlay
-- append, secret-name passthrough; name writes are roster/status
-- edges, not per-frame traffic).
-- v84 §9.8: the name mirror is built by InitFxMerged on the "nm" level host.

-- The three hooks below are hooksecurefunc and can NEVER be removed, so every
-- body early-outs on parent._bf_smNameActive: set when RestampFxName commits,
-- cleared when the "nm" kind is hidden or the fxSM slot parks. Without it a
-- frame that had the name recolor on ONCE kept syncing text into a hidden
-- mirror for the rest of the session -- after the toggle went off, after a spec
-- change, after Verdant Infusion was talented.
local function SyncSwiftmendName(parent)
    if not parent._bf_smNameActive then return end
    local fs = parent._bf_smNameFS
    local nt = parent.nameText
    if fs and nt then
        -- GetText may be a secret string (secret-name passthrough);
        -- pass it straight through, no truthiness/concat.
        pcall(fs.SetText, fs, nt:GetText())
    end
end

local function RestampFxName(parent, host, color, peek)
    if host and not peek then host._bf_fxHidden = nil end  -- see HideFxKind (peek: above RestampFxHealth)
    local nt = parent.nameText
    local fs = host and host._bf_fxFS
    if not (fs and nt) then return end
    local col = type(color) == "table" and color or nil
    local cr = col and col.r or 0.4
    local cg = col and col.g or 0.85
    local cb = col and col.b or 1.0
    local font, fsize, fflags = nt:GetFont()
    local point, _, relPoint, px, py = nt:GetPoint(1)
    local justH = nt:GetJustifyH()
    local sig = tostring(font) .. "|" .. tostring(fsize) .. "|"
        .. tostring(fflags) .. "|" .. tostring(point) .. "|"
        .. tostring(px) .. "|" .. tostring(py) .. "|" .. justH .. "|"
        .. cr .. "," .. cg .. "," .. cb
    if peek then return sig end
    if host._bf_fxSig == sig then
        -- Committed on an earlier pass and unchanged since: the mirror is
        -- stamped and live, so the hooks must stay armed. Without this the
        -- park -> unpark cycle (which clears the flag but NOT the sig) left
        -- the mirror visible with the hooks inert -- showing the previous
        -- unit's name after a roster change, and staying visible over a
        -- hidden nameText because the Hide hook had gone dead.
        parent._bf_smNameActive = true
        return
    end
    if pcall(function()
        -- The host takes the geometry of the nameText's anchor rect
        -- (nameClip = container/health bar rect); the mirror then
        -- reproduces the nameText's own point spec relative to it.
        local anchorHost = parent.nameClip or parent.textFrame or parent
        host:ClearAllPoints()
        host:SetAllPoints(anchorHost)
        fs:ClearAllPoints()
        if point then
            fs:SetPoint(point, host, relPoint or point, px or 0, py or 0)
        else
            fs:SetPoint("CENTER", host, "CENTER", 0, 0)
        end
        if font then fs:SetFont(font, fsize, fflags) end
        fs:SetJustifyH(justH)
        fs:SetWordWrap(false)
        fs:SetNonSpaceWrap(false)
        fs:SetShadowOffset(1, -1)
        fs:SetShadowColor(0, 0, 0, 1)
        fs:SetTextColor(cr, cg, cb)
        fs:SetText(nt:GetText())
        fs:SetShown(nt:IsShown())
    -- Armed only on COMMIT: a denied pcall leaves the mirror unfonted and
    -- unanchored, and the hooks must not write text into it until a stamp has
    -- actually landed.
    end) then
        host._bf_fxSig = sig
        parent._bf_smNameActive = true
    end
    if not parent._bf_smNameHooked then
        parent._bf_smNameHooked = true
        hooksecurefunc(nt, "SetText", function() SyncSwiftmendName(parent) end)
        hooksecurefunc(nt, "Hide", function()
            if not parent._bf_smNameActive then return end
            local m = parent._bf_smNameFS
            if m then m:Hide() end
        end)
        hooksecurefunc(nt, "Show", function()
            if not parent._bf_smNameActive then return end
            local m = parent._bf_smNameFS
            if m then m:Show() end
        end)
    end
end

-- sid: a single spell id, or a SET table { [sid]=true, ... } used as the
-- include set directly (v53 swiftmendable: the 4 HoT ids share one slot).
-- v53 Phase 2: every fx slot is one slot on the frame's SHARED slot
-- container (it used to be a container per spell PER EFFECT TYPE).
-- Returns the slot record; the include set lives on the record so
-- unparking restores it, and the frame level is now per button.
-- v84 (Stage 5 §9.8): ONE merged slot per spell (and one for the Swiftmendable
-- set). FxHostDefsFor names the level hosts this key bakes; the key encodes the
-- host set, so it is fixed for the button's life.
--
-- Hosts are BORN at the entry's Prioritise rung (field report 2026-09-10).
-- They used to be baked at the non-prioritised rung from two fixed tables and
-- re-levelled afterwards by ApplyFxKinds (SetSlotHostLevel) -- a post-creation
-- write, so inside a keystone (auras secret for the whole run) a /reload left
-- every prioritised effect UNDER the dispel visual it was meant to beat, until
-- the key ended. BuildLevelHosts stamps h._bf_levelOffset from these defs, so
-- the live SetSlotHostLevel sees the level already applied and no-ops; it stays
-- the live-edit path for a Prioritise toggle flipped later. The numbers are the
-- exact ones ApplyFxKinds passes. `fx` is the entry (nil when the slot carries
-- no hc/bd/ov config -- the name-only Swiftmendable slot); `withName` adds the
-- Swiftmendable name-mirror host. FRESH per call: read once, inside the init
-- window, and only on the creation branch.
local function FxHostDefsFor(fx, withName)
    local hc, ov, bd = fx and fx.hc, fx and fx.ov, fx and fx.bd
    local defs = {
        { key = "hc", level = (hc and hc.priority) and FX_LEVEL_HEALTH_PRIO
                                                   or FX_LEVEL_HEALTH },
        { key = "ov", level = (ov and ov.priority) and FX_LEVEL_OVERLAY_PRIO
                                                   or FX_LEVEL_OVERLAY },
        { key = "bd", level = (bd and bd.priority) and FX_LEVEL_BORDER_PRIO
                                                   or FX_LEVEL_BORDER },
    }
    if withName then defs[4] = { key = "nm", level = 218 } end
    return defs
end

-- ── v92: THE FX TOOLKIT, EXPORTED ─────────────────────────────────────────
-- Per-container debuff frame effects (DebuffIcons.lua) are the same machinery
-- on a different trigger: one merged slot, per-kind level hosts, the same
-- regions, the same restamps. These are thin aliases -- no behavior changes
-- here and no wrapper layer to drift -- so that consumer never reaches into
-- this file's locals.
--
-- CONTRACT for every one of them, and it is not optional:
--
--   * Regions live on the engine SLOT BUTTON and become FORBIDDEN objects
--     whenever aura data is secret (in combat, a combat /reload, or once
--     foreign taint reaches the frame). Every native call on them must be
--     pcall-guarded INDIVIDUALLY -- an unguarded region:Hide() throws
--     "calling 'Hide' on bad self ... forbidden object" out of the secure-frame
--     machinery, which is how a live restamp under a secret window took the
--     addon down. The restamps below already guard themselves; a caller adding
--     its own region work must do the same (see the notes on HideFxKind and
--     above RestampFxHealth).
--   * The restamps are SIG-GUARDED per host (host._bf_fxSig) and only commit
--     the sig when the guarded body SUCCEEDED, so a denied pass retries on the
--     next Layout. Do not stamp a sig around them and do not call them from the
--     Update hot path -- they are Layout-driven.
--   * InitFxMerged runs INSIDE the init window (AddAuraSlot's initializeFrame)
--     and nowhere else: CreateTexture/CreateFrame on an already-configured
--     pooled button is unproven in either direction, which is why it bakes the
--     regions for EVERY kind in the host set, configured or not. Pass it as the
--     slot spec's `initButton`; the signature is (button, parent, hosts).
--   * A kind with no config is HIDDEN (BF.HideFxKind), never parked -- park the
--     slot only when NO kind remains, or the kinds sharing the button go with it.
BF.InitFxMerged     = InitFxMerged
BF.HideFxKind       = HideFxKind
BF.RestampFxHealth  = RestampFxHealth
BF.RestampFxBorder  = RestampFxBorder
BF.RestampFxOverlay = RestampFxOverlay
-- Same function; the name marks the size-hinted entry point (initW, initH as
-- the 4th/5th args) for creation-time callers -- see RestampFxOverlay.
BF.RestampFxOverlaySized = RestampFxOverlay
-- (BF.FxFillTexture / BF.ApplyFxFill / BF.FxOverlayAlpha are exported at their
-- definitions -- the restamps above already call them internally, so a consumer
-- needs them only to paint something of its own.)

-- Fresh host-def list for a merged fx slot, in the order InitFxMerged bakes.
-- `levels` defaults to the per-container rungs; pass a table of the same shape
-- to place the hosts anywhere else in the map above.
--
-- FRESH per call by contract, even though sharing one is provably safe today
-- (the defs are read once, inside the init window, and never retained -- see
-- BuildLevelHosts in Auras/ContainerFactory.lua). Slot creation is rare;
-- the guarantee is worth more than the table.
function BF.MakeFxHostDefs(levels)
    levels = levels or BF.CONTAINER_FX_LEVEL
    return {
        { key = "hc", level = levels.hc },
        { key = "ov", level = levels.ov },
        { key = "bd", level = levels.bd },
    }
end

-- v85: the single-host (one slot per (spell, effect)) variants and the
-- BF:IsFxMergeEnabled() / "/bf fxmerge" gate that selected them are GONE --
-- owner ruling 2026-08-16: optimizations are not gated behind kill switches.
-- One merged slot per spell is now the only shape. ApplyFxKinds still tolerates
-- an absent host, which is what lets the per-spell slot omit the "nm" host the
-- Swiftmendable slot carries.

-- The visible state of a merged fx slot, stamped INSIDE the init window.
--
-- Field report 2026-09-10: after a /reload inside a Mythic+ keystone "only some
-- buff customizations are active, some reverted to default". Auras are secret
-- for the whole run there, in or out of combat, so every pcall'd write to a
-- slot button's regions AFTER creation is denied and never retried until the
-- key ends. InitFxMerged alone only builds HIDDEN regions; the color, texture,
-- anchors and Show all came from ApplyFxKinds after EnsureFxSlot returned --
-- i.e. never, for the whole key. Running the same restamps here makes the
-- effect complete at creation.
--
-- Same functions as the live path on purpose: RestampFx* commit
-- host._bf_fxSig (and RestampFxName arms parent._bf_smNameActive) only when
-- their guarded body lands, and HideFxKind latches host._bf_fxHidden, so the
-- ApplyFxKinds pass that follows creation finds everything already committed
-- and is a sig-match no-op until the user actually edits the effect.
-- (Unconfigured kinds go through HideFxKind rather than a hand-set latch: the
-- regions ARE hidden, and the hides are allowed here, so it latches honestly.)
--
-- pcall'd as a whole: the factory pcalls initButton and treats ANY error as a
-- failed init (the slot is discarded), so a surprise in a visual stamp must
-- never be allowed to cost the button its regions.
local function StampFxAtCreation(parent, hosts, e, smName)
    if not hosts then return end
    pcall(function()
        if e and e.hc then
            RestampFxHealth(parent, hosts.hc, e.hc)
        else
            HideFxKind(hosts.hc, "hc")
        end
        if e and e.bd then
            RestampFxBorder(parent, hosts.bd, e.bd)
        else
            HideFxKind(hosts.bd, "bd")
        end
        if e and e.ov then
            -- The bar can still measure 0 here (:Create runs before the
            -- frame's first Layout) -- hand the overlay the header's initial
            -- size (BuzzardFrame_GetInitialSize's source) as the stand-in.
            -- RestampFxOverlay prefers BF.ComputeFrameContentSize (the exact
            -- health-area size) over these; they are its last resort.
            local header = parent._bf_parentHeader or parent:GetParent()
            RestampFxOverlay(parent, hosts.ov, e.ov,
                header and header.frameWidth, header and header.frameHeight)
        else
            HideFxKind(hosts.ov, "ov")
        end
        if hosts.nm then
            if smName then
                RestampFxName(parent, hosts.nm, smName)
            else
                parent._bf_smNameActive = nil
                HideFxKind(hosts.nm, "nm")
            end
        end
    end)
end

-- `withName`: bake the Swiftmendable name-mirror host (the fxSM key).
-- `e` / `smName`: the entry (or nil) and the Swiftmendable name color (or nil)
-- the caller is about to hand ApplyFxKinds -- baked into the host levels
-- (FxHostDefsFor) and the creation stamp above. Only read on the creation
-- branch, which is also why the host defs are built THERE: it covers the v88
-- discard-and-recreate below, and steady state allocates nothing.
local function EnsureFxSlot(parent, key, sid, filter, withName, e, smName)
    local s = parent._bf_auraSlots and parent._bf_auraSlots[key]
    -- v88: an fx slot whose initButton was interrupted (the engine's late
    -- initializeFrame path, running on a stack that was tainted by then) is
    -- structurally present and visually dead. Retire it and fall into the
    -- creation branch below, which is already the every-pass retry this
    -- function has always had -- so fx slots need nothing else to recover.
    -- Guarded on the one-boolean health bit, so a working slot pays a single
    -- read and never reaches the state probe or the discard.
    if s and not s.healthy and BF.AuraSlotStylingState
       and BF:AuraSlotStylingState(parent, key) == "discard" then
        -- 2026-09-11 (restricted recreate, plan §3.1): inside a key, hand the
        -- retire-and-rebuild to the recreate executor (its own budget) rather
        -- than burn the v88 attempt budget here. The record stays until then.
        if BF:IsAuraRecreateWindow() then
            BF:RequestAuraRecreate(parent, "slot", key, "fxRepair")
        elseif BF:DiscardAuraSlotVisual(parent, key) then
            s = nil
        end
    end
    -- Allocated per branch, not up front: in steady state (slot exists and is
    -- not parked) neither consumer runs and the table was immediate garbage --
    -- two tables per fx spell per frame per Layout sweep.
    if not s then
        local cand = { includeSpellIDs =
            type(sid) == "table" and sid or { [sid] = true } }
        s = BF:EnsureAuraSlotVisual(parent, key, {
            -- The record's own level is the LOWEST kind's offset: an inert base.
            -- Every kind renders from its own absolute-level host, so moving the
            -- button can never cascade into another kind (the reason a merged
            -- slot can carry kinds that used to sit at different levels).
            frameLevelOffset = FX_LEVEL_HEALTH,
            filter = filter or "HELPFUL",
            -- Regions AND visible state inside the init window (see
            -- StampFxAtCreation). `p` is the unit frame the factory passes --
            -- the same object as `parent`.
            initButton = function(button, p, hosts)
                InitFxMerged(button, p, hosts)
                StampFxAtCreation(p, hosts, e, smName)
            end,
            levelHosts = FxHostDefsFor(e, withName),
            candidateFilters = cand,
        })
    else
        if s.parked then
            -- Re-stamp the include set first (the spell's id set can
            -- have changed while parked), then unpark — unparking
            -- pushes the record's set and forces the engine rebuild.
            local cand = { includeSpellIDs =
                type(sid) == "table" and sid or { [sid] = true } }
            BF:SetAuraSlotCandidates(parent, key, cand)
            BF:SetAuraSlotVisualDormant(parent, key, false)
        end
    end
    return s
end

-- Apply ONE spell's configured effects to its merged slot. Kinds the spell has
-- no config for are HIDDEN (visibility-only runtime — safe), never parked: the
-- slot parks only when NO effect remains, which is what makes the parking
-- granularity per SPELL rather than per (spell, effect).
-- 2026-09-11 (restricted recreate, plan §3.1 fx row; field report
-- 2026-09-10): the in-key half of ApplyFxKinds. Every host write there is
-- denied inside a key, so this compares what ApplyFxKinds WOULD do against
-- what is stamped on the hosts -- the level rung (_bf_levelOffset, the same
-- numbers FxHostDefsFor bakes), the restamp sig (peek), the hidden latch --
-- and writes nothing. True = the slot is stale and must be rebuilt.
-- A nil peek sig (bar not laid out, host absent) is "cannot tell", not stale.
local function FxKindStale(host, cfg, level, sig)
    if not host then return false end
    if not cfg then return not host._bf_fxHidden end
    if host._bf_levelOffset ~= level then return true end
    return sig ~= nil and host._bf_fxSig ~= sig
end

local function FxSlotStale(parent, hosts, e, smName)
    local hc, bd, ov = e and e.hc, e and e.bd, e and e.ov
    if FxKindStale(hosts.hc, hc,
            hc and (hc.priority and FX_LEVEL_HEALTH_PRIO or FX_LEVEL_HEALTH),
            hc and hosts.hc and RestampFxHealth(parent, hosts.hc, hc, true)) then
        return true
    end
    if FxKindStale(hosts.bd, bd,
            bd and (bd.priority and FX_LEVEL_BORDER_PRIO or FX_LEVEL_BORDER),
            bd and hosts.bd and RestampFxBorder(parent, hosts.bd, bd, true)) then
        return true
    end
    if FxKindStale(hosts.ov, ov,
            ov and (ov.priority and FX_LEVEL_OVERLAY_PRIO or FX_LEVEL_OVERLAY),
            ov and hosts.ov and RestampFxOverlay(parent, hosts.ov, ov, nil, nil, true)) then
        return true
    end
    local nm = hosts.nm
    if nm then
        if not smName then return not nm._bf_fxHidden end
        local sig = RestampFxName(parent, nm, smName, true)
        if sig ~= nil and nm._bf_fxSig ~= sig then return true end
    end
    return false
end

local function ApplyFxKinds(parent, s, e, smName)
    local hosts = s and s.hosts
    if not hosts then return end
    -- The FEATURE key: SetSlotHostLevel and the recreate queue both index
    -- _bf_auraSlots by it. s.key is the engine key, which carries a suffix
    -- once the slot has been rebuilt (v88 retry / plan §3.2 B).
    local key = s.featureKey or s.key
    if BF:IsAuraRecreateWindow() then
        if FxSlotStale(parent, hosts, e, smName) then
            BF:RequestAuraRecreate(parent, "slot", key, "fx")
        elseif hosts.nm then
            -- Lua-side state only, mirroring the live arms below: a stamped,
            -- current mirror keeps its nameText hooks armed; no mirror, inert.
            parent._bf_smNameActive = smName and true or nil
        end
        return
    end
    if e and e.hc then
        -- Prioritise re-levels ONLY this kind's host, across the dispel health
        -- tint (offset 3) and the container tint (2); mirrors the ov/bd
        -- Prioritise toggles. Default (off) is FX_LEVEL_HEALTH, the bottom rung
        -- of the tint lane -- v92 made that ordering explicit; it used to TIE
        -- with the dispel tint and be settled by draw order, same winner.
        -- (The prioritised rung ties the DISPEL OVERLAY at offset 4; cross-kind
        -- ties are policy, not oversight -- see the tie policy above.)
        BF:SetSlotHostLevel(parent, key, "hc",
            e.hc.priority and FX_LEVEL_HEALTH_PRIO or FX_LEVEL_HEALTH)
        RestampFxHealth(parent, hosts.hc, e.hc)
    else
        HideFxKind(hosts.hc, "hc")
    end
    if e and e.bd then
        -- Prioritise re-levels ONLY this kind's host (13 straddles the dispel
        -- border's 12 and the container border's 11); absolute host levels mean
        -- the other kinds never move.
        BF:SetSlotHostLevel(parent, key, "bd",
            e.bd.priority and FX_LEVEL_BORDER_PRIO or FX_LEVEL_BORDER)
        RestampFxBorder(parent, hosts.bd, e.bd)
    else
        HideFxKind(hosts.bd, "bd")
    end
    if e and e.ov then
        BF:SetSlotHostLevel(parent, key, "ov",
            e.ov.priority and FX_LEVEL_OVERLAY_PRIO or FX_LEVEL_OVERLAY)
        RestampFxOverlay(parent, hosts.ov, e.ov)
    else
        HideFxKind(hosts.ov, "ov")
    end
    if hosts.nm then
        if smName then
            RestampFxName(parent, hosts.nm, smName)
        else
            parent._bf_smNameActive = nil  -- the nameText hooks go inert
            HideFxKind(hosts.nm, "nm")
        end
    end
end

-- Every fx feature key a slot has EVER been created for on this frame. The
-- stale-park loop below used to walk parent._bf_auraSlots -- which also holds
-- the single-buff, dispel and container slots -- doing a :sub(1,2) per key per
-- frame per Layout just to find the fx ones, and did so even when no fx were
-- configured at all. This list is exactly the parking candidate set.
--
-- Safe against the v88 retry keys: _bf_auraSlots is indexed by FEATURE key
-- (the "~2" suffix lives on s.key only), and DiscardAuraSlotVisual removes the
-- entry outright -- so a tracked key either has a live slot or none, and
-- SetAuraSlotVisualDormant no-ops on the latter.
local function TrackFxKey(parent, key)
    local all = parent._bf_fxAllKeys
    if not all then all = {}; parent._bf_fxAllKeys = all end
    for i = 1, #all do
        if all[i] == key then return end
    end
    all[#all + 1] = key
end

local function ApplySpellFx(parent, cfg)
    local fxKeys = parent._bf_fxKeys
    if fxKeys then
        for i = #fxKeys, 1, -1 do fxKeys[i] = nil end
    end
    local fx = cfg.frameFx
    if fx and next(fx) and parent.healthBar then
        if not fxKeys then fxKeys = {}; parent._bf_fxKeys = fxKeys end
        for sid, e in pairs(fx) do
            -- One slot for the whole spell: the health tint, the border and the
            -- overlay all carry the SAME filter and the SAME includeSpellIDs
            -- set by construction, so nothing about them was ever per effect
            -- at the engine level.
            --
            -- The filter follows the owning entry's Applied By (e.scope,
            -- projected in the cfg build; same CASTER_SCOPE_FILTERS mapping
            -- the containers use, Grid2's mine/not-mine filter grammar). It
            -- used to be a hardcoded bare "HELPFUL", so every frame effect
            -- fired on ANY caster's aura regardless of the entry's setting —
            -- another Priest's Atonement recolored health bars through an
            -- "Applied by Me Only" entry. Re-stamped change-guarded below so
            -- an Applied By edit applies live (SetAuraSlotVisualFilter
            -- rebuilds on a real change; steady state is one string compare).
            if e.hc or e.bd or e.ov then
                local key = "fx" .. sid
                local filter = CASTER_SCOPE_FILTERS[e.scope] or "HELPFUL"
                local s = EnsureFxSlot(parent, key, sid, filter, false, e, nil)
                if s then
                    BF:SetAuraSlotVisualFilter(parent, key, filter)
                    ApplyFxKinds(parent, s, e, nil)
                    fxKeys[#fxKeys + 1] = key
                    TrackFxKey(parent, key)
                end
            end
        end
    end
    -- v53: Swiftmendable slot visuals (Resto Druid, spec-gated in the
    -- cfg build): one shared include set — the 4 swiftmendable HoT ids,
    -- player-cast only — driving the same fx restamps plus the name
    -- mirror. The key ends in "SM" so the parking loop below covers it.
    -- v84: all four of those visuals are now ONE slot (worst case 4 -> 1).
    local smFx, smName = cfg.swiftmendFx, cfg.swiftmendName
    if smFx or smName then
        if not fxKeys then fxKeys = {}; parent._bf_fxKeys = fxKeys end
        local ids = BF.SWIFTMENDABLE_IDS
        local wantFx = smFx and parent.healthBar
            and (smFx.hc or smFx.bd or smFx.ov) and true or false
        if wantFx or smName then
            local smE = wantFx and smFx or nil
            local s = EnsureFxSlot(parent, "fxSM", ids, "HELPFUL|PLAYER",
                true, smE, smName)
            if s then
                ApplyFxKinds(parent, s, smE, smName)
                fxKeys[#fxKeys + 1] = "fxSM"
                TrackFxKey(parent, "fxSM")
            end
        end
    end
    -- Park stale fx slots (effect removed / spell hidden / un-flagged).
    -- Walks the tracked fx key list (see TrackFxKey), so a frame that has
    -- never had an fx slot skips this entirely and one that has pays only its
    -- own key count -- no :sub per unrelated slot on the frame.
    local all = parent._bf_fxAllKeys
    if all then
        for i = 1, #all do
            local key = all[i]
            local active = false
            if fxKeys then
                for j = 1, #fxKeys do
                    if fxKeys[j] == key then active = true; break end
                end
            end
            if not active then
                if key == "fxSM" then
                    parent._bf_smNameActive = nil  -- nameText hooks go inert
                end
                BF:SetAuraSlotVisualDormant(parent, key, true)
            end
        end
    end
end

-- Re-stamp every frame's per-spell frame effects against the CURRENT
-- health bar texture.
--
-- The health tint (RestampFxHealth) is a copy of the health bar's own
-- texture file, tinted -- so the bar keeps its shading through the tint.
-- Which file that is goes into the tint's signature, and the tint is
-- re-stamped only when the containers are laid out. Changing the health
-- bar texture does not lay them out: it runs RefreshHealthBarLayout, which
-- re-textures the bar and nothing else, so the tint kept the file it was
-- stamped with (the solid one, for a profile that started plain) and drew
-- it over the new texture whenever the buff was up -- which read as the
-- texture "resetting" while the effect showed. ApplySpellFx is idempotent
-- and signature-guarded, so re-running it here costs one sig compare per
-- effect and re-stamps only the tints whose file changed.
--
-- Real frames only, and only ones in service: preview frames stamp their
-- effects from the live profile on every preview refresh already.
function BF:RestampFrameFx()
    -- Grid2 rule: config reaches every registered frame, spares included.
    for _, frame in next, self.registeredFrames or {} do
        if not frame._isPreviewFrame and frame.healthBar
           and not self:ShouldDeferFrameAuraContainers(frame) then
            local cfg = self:GetAuraCacheForFrame(frame)
            if cfg then ApplySpellFx(frame, cfg) end
        end
    end
end

-- ============================================================
-- v50: showRaidBuffs — OOC raid-buff display. A dedicated "raidbuffs"
-- group on the buffs container (all classes' raid buff ids, incl. the
-- Evoker per-class Bronze variants; the container auto-dedups against
-- the main group). Active only while the toggle is ON and OUT OF
-- combat; parked otherwise. Combat edges re-apply via
-- BF:ReapplyCombatConditionalAuraFilters (pcall'd — V12).
-- ============================================================
-- v50: showRaidBuffs — OOC raid-buff display group ("raidbuffs") on the
-- buffs container (CURRENT SPEC's raid buff, ANY CASTER; follower NPC
-- units carry id-less copies the include set can never match — known
-- data anomaly, unfixable addon-side).
--
-- v59 FIX: the filter was "HELPFUL|PLAYER|RAID". PLAYER restricts to
-- auras cast BY YOU, so the group only ever showed the buff where the
-- game credited you as caster — which is not what this feature is for
-- (it should show the spec's raid buff whoever applied it), and directly
-- contradicted the "any caster" claim this comment already made. RAID
-- went with it: it is also a caster/relevance restriction and no other
-- buff group in this file uses either flag — they are all plain
-- "HELPFUL", which is what this group now matches.
local function GetOwnRaidBuffIDs()
    local specId = BF.playerSpecID
    return specId and BF.SPEC_RAID_BUFF_IDS
        and BF.SPEC_RAID_BUFF_IDS[specId] or nil
end

local function ApplyRaidBuffGroupState(parent)
    local c = parent._bf_auraContainers and parent._bf_auraContainers.buffs
    if not c then return end
    local acp = BF.acDB and BF.acDB.profile
    local ids = GetOwnRaidBuffIDs()
    local want = (acp and acp.showRaidBuffs and ids and not BF._inCombat)
        and true or false
    local gk = "raidbuffs"
    if not (c._bf_groupSpecs and c._bf_groupSpecs[gk]) then
        if not want then return end  -- created lazily, out of combat only
        local ac = BF:GetAuraCacheForFrame(parent)
        BF:EnsureAuraGridSpellGroup(parent, "buffs", gk, {
            filter = "HELPFUL",  -- v59: was HELPFUL|PLAYER|RAID (see above)
            -- Bound at CREATION as well as post-creation below. With the
            -- filter widened to a bare "HELPFUL", a denied post-creation
            -- setter would leave this group matching every helpful aura on
            -- the unit from any caster — exactly the flood the include set
            -- exists to prevent.
            candidateFilters = { includeSpellIDs = ids },
            buttonSpec = BuffButtonSpec(parent, ac._roundedBuffSize or 12),
            layoutIndex = 2000,  -- flows AFTER the regular buffs
            maxFrameCount = 8,
            spacing = ac.buffSpacing, rowSpacing = ac.buffRowSpacing,
        })
        if c._bf_groupSpecs and c._bf_groupSpecs[gk] then
            pcall(c.SetAuraGroupCandidateFilters, c, gk,
                { includeSpellIDs = ids })
            pcall(c.UpdateAllAuras, c)
            c._bf_rbSpec = BF.playerSpecID
        end
        return
    end
    if want then
        local unparked = c._bf_dormantGroups and c._bf_dormantGroups[gk]
        if unparked then
            BF:SetAuraGridGroupDormant(parent, "buffs", gk, false)
        end
        -- Re-applied on every want-pass, so groups created by an older
        -- build pick the widened filter up without a rebuild.
        BF:SetAuraGridGroupFilter(parent, "buffs", gk, "HELPFUL")
        if unparked or c._bf_rbSpec ~= BF.playerSpecID then
            pcall(c.SetAuraGroupCandidateFilters, c, gk,
                { includeSpellIDs = ids })
            pcall(c.UpdateAllAuras, c)
            c._bf_rbSpec = BF.playerSpecID
        end
        local ac = BF:GetAuraCacheForFrame(parent)
        BF:ApplyAuraGridGroupButtonSpec(parent, "buffs", gk,
            BuffButtonSpec(parent, ac._roundedBuffSize or 12))
    else
        BF:SetAuraGridGroupDormant(parent, "buffs", gk, true)
    end
end
BF.ApplyRaidBuffGroupState = ApplyRaidBuffGroupState

-- ============================================================================
-- THE BUFFS ROW — read Docs/Buffs_Row_Architecture.md before changing anything
-- in this function or in ApplySingleBuffGroups. That file is authoritative and
-- supersedes every older plan doc where they disagree (they do: see its §0).
--
-- The rules, in short. [OWNER] = owner-stated, do not change without asking.
-- [OPEN] = undecided, DO NOT GUESS — ask.
--
--  1. [OWNER] `main` is LIVE. It is not parked. It is the ordinary buff row.
--  2. [OWNER] `main` is the WHITELIST BUCKET: a permissive filter plus an
--     includeSpellIDs set of exactly the spells that are whitelisted, set to
--     "Show (Default Buff)" and anchored to Buffs. The thing that RESPECTS THE
--     FILTER SETTING is the PRESET group (pre<pkey>); the CLAIM SET
--     (cfg.excludeSpellIDs, AuraCustomizations.lua:986-1037) rides on THAT --
--     already merged by _mergePresetCandidates (v66) -- so a whitelisted spell
--     never renders twice. `main`'s filter MUST stay permissive: a whitelisted
--     spell shows whether or not it satisfies the preset's tokens.
--  2b.[OWNER] Preset `none` = no filter preset; the row is just the whitelist.
--     Needs no special case -- `none` builds no preset group, so the row IS
--     `main`. "No Preset - Whitelist Only" is now literally true.
--  3. [OWNER] A single-buff entry gets its OWN GROUP only if it carries
--     something per-entry: per-entry VISUALS (Display Type = Customized), an
--     ORDER, or (v81, rule 3 of doc §3.2) a NON-DEFAULT APPLIED BY — `main`
--     expresses the default "Me Only" scope group-wide. An entry with none of
--     the three belongs in the shared row using the container's own settings
--     — see SingleBuffNeedsOwnGroup (which also promotes defensive-category
--     spells that `main`'s filter negations would suppress).
--  4. [OWNER] An ORDER PROMOTES an entry back to its own group. layoutIndex
--     orders GROUPS, not auras within one, and no sort comparator takes a
--     user-supplied rank, so a position in the row is only expressible as a
--     group. Same rule the sp<sid> groups run on.
--  5. A stale sweep must only park when the pass could actually DECIDE
--     membership (§4 of the doc) — the "all buff icons vanish until I toggle a
--     setting" bug.
--  6. The settings-time claim (_fbsSingleBuffSpell -> cfg.generalExclude) is
--     LEFT ALONE and needs no per-Layout rework: `main` is include-driven, so
--     being claimed costs a whitelisted spell nothing there, and `main`'s
--     include set is built PER FRAME at Layout time where anchoring is already
--     resolved. See doc §3.3.
--
-- STATUS (2026-08-15, v81): the ruled design is IMPLEMENTED. v78 shipped it
-- first and flooded (engine security carve-out: spell-ID candidate filters are
-- silently dropped for HELPFUL auras on non-assistable units — owner-observed
-- on cross-faction party members); v79 re-parked `main` as a safety revert and
-- shipped the assist gate (:Update renders nothing on non-assistable units);
-- v81 re-enabled `main` on the default-scope filter (HELPFUL|PLAYER|…) behind
-- that gate, with the Applied-By promotion ruling closing the last [OPEN].
-- `main`'s "permissive" in rule 2 means PRESET-INDEPENDENT, scoped to the
-- default Applied By — see the stamp site in ApplyBuffFilters.
--
-- HISTORY, because it caused real damage: `main` was parked in v65 ONLY because
-- the retired Filter Mode dropdowns were still live on 12.0.7, and the park was
-- gated on BF._useAuraContainers. v67 deleted those dropdowns, made the addon
-- 12.1-only, and rewrote the park as unconditional while carrying the old
-- justification forward verbatim — so a comment kept asserting a reason that no
-- longer existed. If you write a conditional decision here, WRITE WHAT MAKES IT
-- EXPIRE.
-- ============================================================================
--
-- Re-apply filters + candidateFilters (spec change, spell reassignment,
-- filter-mode change — all routed through cache invalidation → Layout).
local function ApplyBuffFilters(parent)
    local cfg = BF:GetContainerBuffConfig()
    local ac = BF:GetAuraCacheForFrame(parent)
    -- ── `main`: RULED DESIGN vs CURRENT STATE (v79) ─────────────────────────
    -- RULED DESIGN (Docs/Buffs_Row_Architecture.md §2, authoritative): `main`
    -- is the WHITELIST BUCKET / shared slot -- a permissive filter plus an
    -- includeSpellIDs set of exactly the entries that are whitelisted, set to
    -- "Show (Default Buff)" and anchored to Buffs, with no per-entry visuals
    -- and no Order (see SingleBuffNeedsOwnGroup). The thing that "respects the
    -- filter setting" is the PRESET group (pre<pkey>, layoutIndex 1500+i); the
    -- claim set (cfg.excludeSpellIDs) is merged into THAT by
    -- _mergePresetCandidates, so a whitelisted spell never renders twice.
    -- Under preset "none" no preset group is built at all, so the row IS the
    -- whitelist -- "No Preset - Whitelist Only", literally.
    --
    -- CURRENT STATE (v81): the ruled design is LIVE. `main` is unparked (with
    -- a non-empty include set) at the end of this function; the sharing gate
    -- in ApplySingleBuffGroups is back on. The v78 flood (engine drops
    -- spell-ID candidate sets for HELPFUL auras on non-assistable units,
    -- owner-observed cross-faction) is closed by the v79 assist gate in
    -- :Update — the whole row renders NOTHING on non-assistable units.
    --
    -- The filter stamped here is the ruling's DEFAULT SCOPE ("Me Only" —
    -- HELPFUL|PLAYER), which is what every default-scope sb* group carried, so
    -- sharing is behavior-preserving. It stays PRESET-INDEPENDENT: a
    -- whitelisted spell shows whether or not it satisfies the preset's token
    -- string (candidateFilters narrow WITHIN the filter's matches; a
    -- preset-derived filter here would silently drop whitelisted spells).
    -- Entries wanting a different scope, or in a category the negations below
    -- exclude, promote to their own sb* group via SingleBuffNeedsOwnGroup.
    --
    -- The include set is computed by ApplySingleBuffGroups; the unpark/stamp
    -- happens after that call, further down.
    BF:SetAuraGridGroupFilter(parent, "buffs", "main",
        "HELPFUL|PLAYER|!BIG_DEFENSIVE|!EXTERNAL_DEFENSIVE")
    -- v43: per-spell groups for customized spells routed to the general
    -- buffs container.
    -- v65: on 12.1 the per-spell groups get a NEUTRAL base filter rather than
    -- cfg.filter. cfg.filter is built from _fbsAuraFilter, i.e. from the Filter
    -- Mode dropdowns that are now 12.0.7-only -- so passing it here would leave
    -- those dropdowns quietly narrowing the per-spell groups on an engine where
    -- they are supposed to decide nothing. Each of these groups carries its own
    -- includeSpellIDs, so the filter string only has to be permissive; this is
    -- the exact string whitelist mode already uses, negations included.
    local buffSize0 = ac._roundedBuffSize or 12
    -- v67: 12.0.7 branch removed (addon is 12.1-only) — was a ternary that
    -- fell back to cfg.filter on the old engine.
    local spellGroupFilter = "HELPFUL|!BIG_DEFENSIVE|!EXTERNAL_DEFENSIVE"
    ApplySpellGroups(parent, "buffs", cfg.customized and cfg.customized.buffs,
        spellGroupFilter, buffSize0, ac.buffSpacing, ac.buffRowSpacing,
        BF.TooltipBelowFrameY(parent, ac.buffAnchor, ac.buffOffsetY, buffSize0))
    local containers = BF:GetActiveCustomBuffContainers() or {}
    -- v51/v73: per-container visibility -- showForGroupType under
    -- per-Layout Config (the frame-type Show Container toggles were
    -- removed in v73) -- the legacy GetActiveAuraGroups gate.
    -- Resolved HERE (settings-time) into a per-frame cache; the hot
    -- Update path only does one table lookup.
    local groupTypeKey = BF.ResolveGroupTypeKey and BF:ResolveGroupTypeKey(parent)
    local vis = parent._bf_bfcVisible
    if not vis then vis = {}; parent._bf_bfcVisible = vis end
    -- v65: a SECOND per-frame flag, deliberately not folded into vis[]. The two
    -- answer different questions and Update needs both: vis[ci] is "the user
    -- wants this entry visible", which ApplySingleBuffGroups reads to decide
    -- whether to build the sb<key> group -- so a flow-anchored entry must stay
    -- vis[ci] == true. anchored[ci] is "this entry has no container of its own",
    -- which is what Update's SyncAuraGridContainer loop must skip. Setting
    -- vis[ci] = false instead would have parked the sb group as well; leaving
    -- Update alone would have re-SetShown the container it just hid, once per
    -- Layout/Update cycle.
    --
    -- v92: the flag's meaning broadens from "renders in the buffs row" to
    -- "renders inside SOME host container" -- the name still fits (it is the
    -- absence of a bfc/slot of its own that Update cares about) and every
    -- consumer asks exactly that question. An entry anchored INTO another bfc
    -- container must have no bfc/slot of its own for the same reason a
    -- Buffs-anchored one must not: the engine container it used to own cannot
    -- be destroyed and would keep rendering a duplicate.
    local anchored = parent._bf_bfcAnchored
    if not anchored then anchored = {}; parent._bf_bfcAnchored = anchored end
    -- 2026-09-14 (owner ruling): the spells the Buff List anchors INTO each
    -- multi-icon container, per host index, resolved BEFORE the loop because
    -- a host is usually visited before the entries anchored to it. Handed to
    -- the host's preset groups as their exclude set: an anchored entry is
    -- already rendered by the host's `main` (shared) or its own sb group, and
    -- a preset in the same container that also matched it would be a second
    -- group over one aura with an unspecified winner -- the same reason the
    -- buffs row hands ITS presets cfg.excludeSpellIDs. Only entries the
    -- Layout would show (their Spec condition met, not blacklisted), so a
    -- preset still shows a spell the entry is not showing here.
    local bfcAnchoredSids
    for ci, c in ipairs(containers) do
        if c.singleBuff and BF:IsSingleBuffVisibleForSpec(c) then
            local h = BF:GetSingleBuffAnchorHost(c, groupTypeKey)
            if h and h.kind == "bfc" and h.ci then
                local sid = BF:GetSingleBuffSpellID(c)
                if sid then
                    bfcAnchoredSids = bfcAnchoredSids or {}
                    local set = bfcAnchoredSids[h.ci]
                    if not set then set = {}; bfcAnchoredSids[h.ci] = set end
                    set[sid] = true
                end
            end
        end
    end
    for ci, c in ipairs(containers) do
        local key = "bfc" .. ci
        local cc = parent._bf_auraContainers and parent._bf_auraContainers[key]
        -- v69: global Enabled gate (never set on single buffs). A disabled
        -- container is invisible everywhere; its spell claims are released in
        -- the spellToContainer build (AuraCustomizations.lua), so the spells
        -- reappear in the regular row rather than vanishing.
        local hidden = not c.singleBuff and c.enabled == false
        -- v65: per-Layout branch gated by the two-gate predicate
        -- (BF:IsContainerPerLayoutActive) -- THIS container's own
        -- perLayoutConfig flag, or the group's Buffs override flag on a CFG
        -- scope. The predicate is false for a nil key, so the old
        -- `groupTypeKey and` guard is folded into it. No hoist here: the answer
        -- is per container now, and this call already sits inside the loop.
        if c.groupSettings and BF:IsContainerPerLayoutActive(groupTypeKey, c) then
            local gs = c.groupSettings[groupTypeKey]
            if gs and gs.showForGroupType == false then hidden = true end
        end
        -- v73 (owner): the shared-tier per-frame-type gate (showOnParty /
        -- showOnRaid / showOnCustomFrames) is removed with its UI -- a shared
        -- container shows on every frame kind. Stale stored flags are
        -- deliberately IGNORED.
        -- v62: single buffs gate on their own Spec condition (plan 3.67). It
        -- lands HERE, in the settings-time visibility resolution, for the same
        -- reason the frame-type gate above does: Update only reads
        -- _bf_bfcVisible[ci]. The predicate is never consulted per frame or per
        -- UNIT_AURA. Belt over the parked include set below -- a spec-excluded
        -- single buff contributes no spells either, so the group is dormant
        -- anyway; this makes the container invisible rather than merely empty.
        if not hidden and not BF:IsSingleBuffVisibleForSpec(c) then
            hidden = true
        end
        vis[ci] = not hidden
        -- ── v65/v92: FLOW-ANCHORED ENTRIES ─────────────────────────────────
        -- These render as an sb<key> group inside their HOST's container
        -- (ApplySingleBuffGroups, below), not as a container of their own.
        --
        -- Nil-ing `cc` is NOT enough, and assuming it was is exactly the bug
        -- the orphan sweep at the end of this function exists to catch: an
        -- entry the user switches TO a flow anchor already HAS a live
        -- bfc<ci> from before the switch. EnsureBuffContainers stops creating
        -- it, but engine AuraContainers can never be destroyed -- so it would
        -- keep its candidate filters, unit binding and shown state and go on
        -- rendering, duplicating the icon the new sb<key> group now draws.
        -- Its index is <= #containers, so the orphan sweep never visits it.
        --
        -- Park every group and hide the frame, exactly as that sweep does.
        -- Both calls are change-guarded, so a steady-state anchored entry that
        -- never had a container pays nothing.
        --
        -- v92: resolved ONCE per container here and reused by the slot arm
        -- below -- the answer is identical and the resolver is not free. Kept
        -- as a BOOLEAN, never as the descriptor: host descriptors are shared
        -- and re-pointed on the next resolver call.
        local sbFlowed = BF:GetSingleBuffAnchorHost(c, groupTypeKey) ~= nil
        if sbFlowed then
            anchored[ci] = true
            if cc then
                for _, gk in ipairs(cc._bf_groupKeys) do
                    BF:SetAuraGridGroupDormant(parent, key, gk, true)
                end
                BF:SyncAuraGridContainer(parent, key, nil, false)
            end
            cc = nil
        else
            anchored[ci] = nil
        end
        -- v82: single-buff SLOT maintenance — the per-Layout mirror of the
        -- container arm below, for entries running in slot mode. Every
        -- re-stamp is change-guarded inside the slot helpers; geometry
        -- (anchor/offset/size incl. power-bar lift) is re-applied each pass,
        -- which is what makes position/size edits live in slot mode.
        if c.singleBuff and SingleBuffSlotMode() then
            local skey = "sbc" .. ci
            local s = parent._bf_auraSlots and parent._bf_auraSlots[skey]
            -- v88: before maintaining the slot, make sure it is WORTH
            -- maintaining. A button whose styling walk was interrupted (a
            -- denial on a tainted stack while auras were secret -- the raid
            -- combat-reload case) is invisible but structurally present, and
            -- every guard below reads it as healthy. Repair it, or retire and
            -- rebuild it, before any of them run.
            --
            -- `s.healthy` is derived once at creation, so the steady-state cost
            -- of this whole arm is ONE boolean read -- nothing is re-derived and
            -- nothing is called. Everything past the `not s.healthy` is
            -- unreachable on a working slot.
            if s and not s.healthy
               and RepairSingleBuffSlot(parent, ci, c, ac, groupTypeKey) then
                local rsid = BF:GetSingleBuffSpellID(c)
                if rsid then
                    EnsureSingleBuffSlot(parent, ci, c, rsid, ac, groupTypeKey)
                end
                s = parent._bf_auraSlots and parent._bf_auraSlots[skey]
            end
            if s then
                local sid = BF:GetSingleBuffSpellID(c)
                -- v92: any host, not just Buffs (sbFlowed above) -- a slot is
                -- the "positions itself" shape, and an entry flowing inside
                -- someone else's container does not position itself.
                local park = hidden or (not sid) or sbFlowed
                    or not BF:IsContainerCreationRelevant("buff", ci)
                -- v88d: the SECOND thing that can silence a slot that WAS
                -- created in the window. `main` on the buffs container is
                -- parked at creation and unparked again in this very same pass;
                -- a slot parked here is only unparked by a LATER Layout, and on
                -- a combat reload there is no later Layout. Recorded once per
                -- frame, first pass only.
                local pt = BF:IsSlotDiagEnabled() and parent._bf_sbParkTrace
                if BF:IsSlotDiagEnabled() and not pt then
                    pt = {}; parent._bf_sbParkTrace = pt
                end
                if pt and pt[ci] == nil then
                    pt[ci] = ("park=%s (hidden=%s sid=%s)"):format(
                        tostring(park and true or false), tostring(hidden),
                        tostring(sid))
                end
                if park then
                    BF:SetAuraSlotVisualDormant(parent, skey, true)
                else
                    BF:SetAuraSlotVisualFilter(parent, skey, ContainerAuraFilter(c))
                    if s._bf_sbSid ~= sid then
                        s._bf_sbSid = sid
                        BF:SetAuraSlotCandidates(parent, skey,
                            { includeSpellIDs = { [sid] = true } })
                    end
                    BF:SetAuraSlotVisualDormant(parent, skey, false)
                    -- v88h: the button's rect and visuals are FORBIDDEN to
                    -- tainted code while auras are secret (ledger-proven: 609
                    -- SetPoint + 609 SetSize + 279 restyle denials on one combat
                    -- reload). None of these can succeed in that window, so
                    -- skip them rather than burn a denied pcall per slot per
                    -- frame per Layout -- the creation path already anchored the
                    -- button inside the init window, and the v88b regen replay
                    -- re-runs this whole arm once the restriction lifts, which
                    -- is what makes live geometry/style edits land then.
                    if not BF:IsAuraCreationRestricted() then
                        local sgeo = ContainerGeo(c, ac, groupTypeKey)
                        local btn = s._bf_slotButton
                        local sized = false
                        if btn then
                            sized = BF:SlotCall("button:SetSize(layout)", btn.SetSize,
                                btn, sgeo.size, sgeo.size)
                            -- v83: LIVE restyle — border/duration/icon-type
                            -- edits apply this pass instead of on /reload.
                            -- Sig-guarded (BF.RestyleSlotButton), so a
                            -- steady-state Layout pays one sig computation.
                            BF.RestyleSlotButton(btn,
                                DeriveSingleBuffSlotSpec(parent, c, sgeo, ac, groupTypeKey))
                        end
                        -- Re-bake the geometry sig only when both writes LANDED
                        -- (plan §3.1): a denied write leaves the old sig, so a
                        -- later in-key compare still sees the button as stale.
                        if AnchorSingleBuffSlot(parent, s, sgeo) and sized then
                            s._bf_sbGeoSig = SingleBuffGeoSig(parent, sgeo)
                        end
                    elseif BF:IsAuraRecreateWindow() then
                        -- 2026-09-11 (restricted recreate, plan §3.1 sbc row;
                        -- field report 2026-09-10): inside a key the writes
                        -- above are all denied. Compare WITHOUT writing and ask
                        -- for a rebuilt slot on a mismatch -- the new button is
                        -- born with this spec and geometry in its init window.
                        local sgeo = ContainerGeo(c, ac, groupTypeKey)
                        local geoNow = SingleBuffGeoSig(parent, sgeo)
                        local miss
                        if s._bf_sbGeoSig ~= geoNow then miss = "sbc-geo" end
                        local btn = s._bf_slotButton
                        if not miss and btn and btn._bf_icon and BF.ButtonSpecSig then
                            -- The same sig RestyleSlotButton stamps, derived
                            -- without writing: this pass restyles nothing, so a
                            -- failed rebuild still leaves the key-end replay a
                            -- miss to act on.
                            if btn._bf_specSig ~= BF.ButtonSpecSig(
                                DeriveSingleBuffSlotSpec(parent, c, sgeo, ac, groupTypeKey)) then
                                miss = "sbc-spec"
                            end
                        end
                        if miss then
                            -- The two legs are named separately in the reason
                            -- (2026-09-11 first in-key run: three sbc slots
                            -- looped and "sbc" could not say which compare
                            -- disagreed). The sigs are kept on the record for
                            -- /bf sbdiag.
                            s._bf_sbMissWas, s._bf_sbMissNow = s._bf_sbGeoSig, geoNow
                            BF:RequestAuraRecreate(parent, "slot", skey, miss)
                        end
                    end
                end
            end
        end
        if cc then
            local spells = cfg.containerSpells[ci]
            local custList = cfg.customized and cfg.customized[ci]
            -- Main group runs only while it has NON-customized spells
            -- left (an emptied include set must never be passed — see
            -- the general-group guard above).
            if spells and next(spells) then
                BF:SetAuraGridGroupDormant(parent, key, "main", false)
                cc:SetAuraGroupCandidateFilters("main", { includeSpellIDs = spells })
                -- v59: player-cast only (see the creation site).
                -- v61: unless this container opted out (ContainerAuraFilter).
                BF:SetAuraGridGroupFilter(parent, key, "main", ContainerAuraFilter(c))
            else
                -- No spells assigned for this spec: park dormant via
                -- candidateFilters (a "parked" filter string is NOT safe —
                -- see SetAuraGridGroupDormant in ContainerFactory).
                BF:SetAuraGridGroupDormant(parent, key, "main", true)
            end
            -- v43: per-spell groups for this container's customized spells.
            -- v61: straight to the resolver's multiple returns — this site
            -- needs five scalars, not a geometry table (only
            -- ApplyAuraGridGeometry needs one, because it retains it).
            local cSize, _, cSpacing, cRowSpacing, _, cAnchor, _, cOffY
                = BF:ResolveContainerGeometry(c, groupTypeKey, ac)
            -- v59: player-cast only (see the creation site).
            -- v61: unless this container opted out (ContainerAuraFilter).
            ApplySpellGroups(parent, key, custList, ContainerAuraFilter(c),
                cSize, cSpacing, cRowSpacing,
                BF.TooltipBelowFrameY(parent, cAnchor, cOffY, cSize))
            -- v64: token-backed preset groups (Important / Big Defensive /
            -- External Defensive / Applied by Me). AFTER ApplySpellGroups on
            -- purpose -- that function parks every stale "sp*" group it did not
            -- see this pass, and preset keys are "pre*" precisely so they fall
            -- outside that sweep.
            -- With the container's anchored spells as the exclude set (see
            -- the pre-pass above); cfg.generation is the same edge the buffs
            -- row's presets key their re-push on.
            ApplyPresetGroups(parent, key, c, groupTypeKey, ac,
                cSize, cSpacing, cRowSpacing,
                BF.TooltipBelowFrameY(parent, cAnchor, cOffY, cSize),
                bfcAnchoredSids and bfcAnchoredSids[ci] or nil, cfg.generation)
            -- ── v62 (plan 3.67 slice 2): single-buff per-entry visuals ──────
            -- A single buff's icon lives in its container's MAIN group, not in
            -- a per-spell group, so ApplySpellGroups above never styles it --
            -- which is exactly why a migrated single buff rendered from
            -- container-level defaults. Re-derive that group's buttonSpec from
            -- the entry's OWN store (DeriveSpellButtonSpec's sbC branch).
            --
            -- Settings-time, like everything else in ApplyBuffFilters: this
            -- runs on Layout, never per aura, and only for containers that are
            -- single buffs in Customized mode with something configured.
            local sbSid = BF.GetSingleBuffSpellID and BF:GetSingleBuffSpellID(c)
            -- NOTE: GetSingleBuffVisualRoot is a PLAIN function (SBRoot in
            -- AuraCustomizationHelpers.lua), not a method. A colon call here
            -- passed BF as the container, so the root probe returned nil for
            -- every single buff and this whole block never ran -- the entry's
            -- Icon/Effects/Cooldown Text settings silently did nothing on the
            -- 12.1 live path.
            if sbSid and BF.GetSingleBuffVisualRoot and BF.GetSingleBuffVisualRoot(c) then
                -- Derived EXACTLY as the creation site in EnsureBuffContainers
                -- derives it (SingleBuffSpec + ApplyContainerBorder +
                -- ApplyContainerDuration). The two Apply* calls no-op for a
                -- single buff today, but a restamp that derives differently
                -- from creation re-walks every button to a different look on a
                -- plain load -- and inside a keystone that walk is denied, so
                -- whichever look creation baked is what stays (field report
                -- 2026-09-10). One derivation, two sites, no drift.
                -- (SingleBuffSpec's gate is this block's gate, so it is never nil here.)
                local sbSpec = SingleBuffSpec(parent, c, cSize)
                ApplyContainerBorder(sbSpec, c, groupTypeKey, ac)
                ApplyContainerDuration(sbSpec, c, groupTypeKey, ac)
                sbSpec.tooltipFrameY =
                    BF.TooltipBelowFrameY(parent, cAnchor, cOffY, cSize)
                -- v62 FIX: this used ApplyAuraGridGroupButtonSpec(..., "main", ...),
                -- which SILENTLY DID NOTHING. That function early-returns unless
                -- c._bf_groupSpecs[groupKey] exists, and only EnsureAuraGridSpellGroup
                -- populates that table -- for the per-spell "sp"<id> groups. A
                -- container's MAIN group keeps its spec in c._bf_buttonSpec (see the
                -- `(_bf_groupSpecs[gk]) or c._bf_buttonSpec` fallback in
                -- ContainerFactory's geometry pass), so the entry's own visuals never
                -- reached the icon and a single buff rendered the plain spell texture
                -- no matter what its Icon subtab said.
                --
                -- ApplyAuraGridButtonSpec is the container-level applier and targets
                -- exactly that spec.
                -- v99: the `cc._bf_styleGen = nil` fast-path defeat is GONE. It
                -- existed because the v53 cheap pre-guard keyed on ac._cacheGen,
                -- and this spec is derived from c.sbVisuals -- options storage,
                -- which never bumps it. There is no pre-guard left to defeat:
                -- ApplyAuraGridButtonSpec now compares the FULL spec census, so a
                -- sbVisuals edit moves the comparison by itself.
                BF:ApplyAuraGridButtonSpec(parent, key, sbSpec)
            end
            -- v45: candidate-filter changes don't re-evaluate EXISTING
            -- aura assignments (PTR-observed) — force the engine rebuild
            -- once per settings generation.
            if cc._bf_cfgGen ~= cfg.generation then
                cc._bf_cfgGen = cfg.generation
                pcall(cc.UpdateAllAuras, cc)
            end
        end
    end
    -- v65/v92: flow-anchored single buffs, as groups inside their HOST's
    -- container (the buffs row, a bfc container, or bigDef). AFTER the loop
    -- above for three reasons: it resolves _bf_bfcVisible -- the per-Layout
    -- Enabled flag and the Spec condition, read rather than re-derived; it
    -- stamps each bfc host's own containerSpells include set, which the shared
    -- arm re-stamps as a UNION (StampHostSharedInclude); and ApplySpellGroups'
    -- "sp*" stale sweep must not see these keys (they start "sb", as preset
    -- keys start "pre", for exactly that reason).
    --
    -- Returns the BUFFS host's shared sids only -- the other hosts' shared sets
    -- are consumed inside, against their own `main` groups.
    local sharedIDs = ApplySingleBuffGroups(parent, ac, groupTypeKey, cfg)
    -- ── v81: `main` RE-ENABLED as the whitelist bucket ─────────────────────
    -- Owner ruling 2026-08-15 (Docs/Buffs_Row_Architecture.md §2 + §3.2 rule 3,
    -- Docs/Buffs_Row_Target_Matrix.md row 1). Two things make this safe where
    -- v78 flooded (ValidateCandidateFilters silently DROPS spell-ID candidate
    -- sets for HELPFUL auras on non-assistable units — owner-observed on
    -- cross-faction party members, hence the v79 park):
    --   1. The assist gate in :Update (v79, UnitCanAssist — the engine's own
    --      predicate): the whole row renders NOTHING on non-assistable units,
    --      so the candidate-drop case can no longer paint anything.
    --   2. The filter string alone is sane if the candidate set is ever
    --      ignored anyway: HELPFUL|PLAYER|!BIG_DEFENSIVE|!EXTERNAL_DEFENSIVE
    --      — your own casts, minus the classes other displays own. That is
    --      also the ruling's DEFAULT SCOPE: `main` expresses Applied By =
    --      "Me Only", exactly what a default-scope sb* group carried, so
    --      sharing is behavior-preserving; non-default scopes promote in
    --      SingleBuffNeedsOwnGroup and never reach this set.
    --
    -- Unpark ONLY with a NON-EMPTY include set: the engine semantics of an
    -- empty includeSpellIDs map are unverified (it could mean "no candidate
    -- narrowing" = every player-cast buff), and an empty bucket has nothing
    -- to render anyway. Candidates are re-applied AFTER the unpark — the
    -- dormancy helper clears them to {} on the parked→live edge — and are
    -- stamped from a FRESH table each time (_sbShared is per-pass scratch and
    -- c0._bf_mainIncl is our own bookkeeping; the engine may retain whatever
    -- table it is handed). A DENIED stamp re-parks `main` so it never sits
    -- live without its include set; the flipped-back dormancy flag makes the
    -- next Layout pass retry (same retry contract as the sb path).
    --
    -- `local c0` also repairs a v79 casualty: the revert deleted the v78
    -- declaration but left the cfg.generation UpdateAllAuras kick at the
    -- bottom of this function reading `c0` — a nil global since, so that
    -- rebuild had been dead code.
    local c0 = parent._bf_auraContainers and parent._bf_auraContainers.buffs
    if c0 then
        local incl = c0._bf_mainIncl
        local changed = false
        if sharedIDs and next(sharedIDs) ~= nil then
            if not incl then incl = {}; c0._bf_mainIncl = incl end
            for sid in pairs(incl) do
                if not sharedIDs[sid] then incl[sid] = nil; changed = true end
            end
            for sid in pairs(sharedIDs) do
                if not incl[sid] then incl[sid] = true; changed = true end
            end
            local wasParked = c0._bf_dormantGroups and c0._bf_dormantGroups.main
            BF:SetAuraGridGroupDormant(parent, "buffs", "main", false)
            if wasParked or changed then
                local stamp = {}
                for sid in pairs(incl) do stamp[sid] = true end
                local ok = pcall(c0.SetAuraGroupCandidateFilters, c0, "main",
                    { includeSpellIDs = stamp })
                if ok then
                    -- Candidate changes don't re-evaluate existing aura
                    -- assignments (PTR-observed) — force the rebuild.
                    pcall(c0.UpdateAllAuras, c0)
                else
                    BF:SetAuraGridGroupDormant(parent, "buffs", "main", true)
                end
            end
        else
            BF:SetAuraGridGroupDormant(parent, "buffs", "main", true)
            if incl and next(incl) then wipe(incl) end
        end
    end
    -- v65: the Buffs display's own presets — they render ordinary buffs
    -- alongside the shared `main` whitelist bucket (v81).
    --
    -- ApplyPresetGroups reads c.presets off its container argument and nothing
    -- else, so the pseudo-container (BF:GetBuffsPresetContainer) works here
    -- with no change to that function. Passed as the container arg it also
    -- reaches ApplyContainerBorder, which resolves per-container border fields
    -- -- absent on the pseudo-container, so it falls through to the Buffs
    -- section's own border, which is what these icons should use.
    --
    -- Placed HERE, not next to the "buffs" ApplySpellGroups call above, because
    -- groupTypeKey is not resolved until the container loop. Order against the
    -- other group builders does not matter: preset keys are "pre*" and neither
    -- the "sp*" nor the "sb*" stale sweep can touch them.
    if BF.GetBuffsPresetContainer then
        local bpc = BF:GetBuffsPresetContainer()
        if bpc then
            local bs = ac._roundedBuffSize or 12
            -- v66: hand the preset group the exclude set. cfg.generalExclude
            -- already holds every claimed spell -- Blacklist entries
            -- (_fbsSingleBuffHidden), Whitelist entries claiming their spell
            -- (_fbsSingleBuffSpell), AC-untracked spells, customized spells
            -- routed to sp<sid> groups and the OOC raid-buff ids -- and it is
            -- exactly the set the `main` group was given before 12.1 parked it.
            ApplyPresetGroups(parent, "buffs", bpc, groupTypeKey, ac,
                bs, ac.buffSpacing, ac.buffRowSpacing,
                BF.TooltipBelowFrameY(parent, ac.buffAnchor, ac.buffOffsetY, bs),
                cfg.excludeSpellIDs, cfg.generation)
        end
    end
    -- ── v62: ORPHANED ENGINE CONTAINERS ─────────────────────────────────────
    -- Removing a custom container (e.g. deleting a single buff) shrinks the
    -- array, but engine AuraContainers cannot be destroyed and both this loop
    -- and Update's sync loop only visit 1..#containers. The highest-index
    -- "bfc" container therefore kept its last candidate filters, unit binding
    -- and shown state and RENDERED ON — a deleted single buff's icon stayed
    -- on frames, duplicated once the deletion lifted the spell's claim out of
    -- the regular buffs. Park every group and hide the frame. Both calls are
    -- change-guarded, so passes with no orphans pay one string.match per bfc
    -- key and steady-state orphans pay nothing. If a later "Add" grows the
    -- array back over an orphan, the main loop above unparks and re-stamps it.
    local pools = parent._bf_auraContainers
    if pools then
        local n = #containers
        for key, oc in pairs(pools) do
            local idx = key:match("^bfc(%d+)$")
            if idx and tonumber(idx) > n then
                for _, gk in ipairs(oc._bf_groupKeys) do
                    BF:SetAuraGridGroupDormant(parent, key, gk, true)
                end
                BF:SyncAuraGridContainer(parent, key, nil, false)
            end
        end
    end
    -- v82: orphaned single-buff SLOTS — same reasoning as the container
    -- sweep above (slots can't be removed either), same park idiom. A later
    -- "Add" that grows the array back over the index reuses the slot via the
    -- maintenance arm (sid change re-stamps the candidate set; note the
    -- baked BUTTON STYLING is spec-bound — a reused index wanting different
    -- visuals completes on /reload, the documented slot-mode contract).
    do
        local sl = parent._bf_auraSlots
        if sl then
            local n2 = #containers
            for skey in pairs(sl) do
                local idx = skey:match("^sbc(%d+)$")
                if idx and tonumber(idx) > n2 then
                    BF:SetAuraSlotVisualDormant(parent, skey, true)
                end
            end
        end
    end
    if c0 and c0._bf_cfgGen ~= cfg.generation then
        c0._bf_cfgGen = cfg.generation
        pcall(c0.UpdateAllAuras, c0)
    end
    -- v46: per-spell frame-effect slots.
    ApplySpellFx(parent, cfg)
    -- v50: OOC raid-buff group.
    ApplyRaidBuffGroupState(parent)
end

-- v67: 12.0.7 branch removed (addon is 12.1-only). The old arm pre-allocated
-- parent.buffFrames (BF.MAX_BUFFS icon frames) + tooltips; it was already
-- unreachable on 12.1 because the container arm returns unconditionally.
-- Preview/dummy pools are still built by Auras/DummyAuras.lua.
-- v72 PERF: nothing is built here for a frame that is not in service yet.
-- The "buffs" container plus every bfc<ci> custom container (20 of them on
-- the owner's profile, 360 styled aura buttons) used to be built for all 45
-- header children at login; 44 of them never showed a unit. The build now
-- runs from BF:EnsureFrameAuraContainers the moment the frame is assigned a
-- unit (see Auras/ContainerFactory.lua), which routes back into :Layout
-- below — a superset of this function.
function BuffsAndContainers:Create(parent)
    if BF:ShouldDeferFrameAuraContainers(parent) then return end
    -- v88b: same flag as :Layout — this is the other entry that builds and
    -- filters inside a possibly-restricted window.
    BF:NoteAuraLayoutRestricted(parent)
    -- v92: drop the per-host wrap-budget memo (see MaxSingleBuffSizeFor). One
    -- of the two entries that resolve container geometry after a settings edit.
    InvalidateSingleBuffHostSizes()
    EnsureBuffContainers(parent)
    ApplyBuffFilters(parent)
end

-- v67: BuffsAndContainers:UpdateFrameSettings removed (12.1-only). Tooltip
-- bindings are baked per container button, so this returned before touching
-- frame.buffFrames / frame.SF_CustomContainerIcons on every 12.1 call. Its
-- only dispatcher, BF:DispatchTooltipSettings, was deleted along with the
-- other three empty UpdateFrameSettings methods.

-- Per-scope cache write. Called from RebuildAuraCacheScope before
-- per-frame Layout/Update. Owns buff geometry + buffColorAuraBorder
-- (which lives in auraText behind the useGlobal switch).
function BuffsAndContainers:UpdateDB(cache, flat, grp)
    -- v60: resolved per aura sub-category. The Buffs and Debuffs
    -- per-layout toggles are independent, so a flat's auras table can
    -- carry stale rawkeys for whichever group is currently OFF --
    -- ResolveCFGSection(..., "auras") plus an index would read them.
    local buffsP = BF.ResolveCFGAurasSubcat(BF, flat, grp, "buffs") or {}
    cache.showBuffs    = buffsP.showBuffs ~= false
    cache.buffSize     = buffsP.buffSize or 12
    cache.buffAnchor   = buffsP.buffAnchorPoint or "BOTTOMRIGHT"
    cache.buffOffsetX  = buffsP.buffOffsetX or 0
    cache.buffOffsetY  = buffsP.buffOffsetY or 0
    cache.buffGrowDir  = BF.NormalizeGrowDirection(
        buffsP.buffGrowDirection or "LEFT", cache.buffAnchor)
    cache.maxBuffs     = buffsP.maxBuffs or 8
    cache.buffsPerRow  = buffsP.buffsPerRow or 3
    cache.buffSpacing  = buffsP.buffSpacing or 1
    cache.buffRowSpacing = buffsP.buffRowSpacing or 1
    cache._roundedBuffSize = BF:PixelRound(cache.buffSize)
    cache.buffBorderColor     = buffsP.buffBorderColor
    cache.buffBorderThickness = buffsP.buffBorderThickness or 1
    cache.buffBlizzardBorders = buffsP.buffBlizzardBorders == true
    -- nil = derive from the blizzard toggle (BorderStyleOf fallback).
    cache.buffBorderStyle     = buffsP.buffBorderStyle

    -- buffColorAuraBorder: setting REMOVED (12.1 cut: threshold-driven
    -- border color has no container expression; owner decision to drop
    -- the setting entirely). Forced false so stale DB values are inert.
    cache.buffColorAuraBorder = false

    -- Tooltips section.
    local ttp = BF.ResolveCFGSection(BF, flat, grp, "tooltips") or {}
    cache.showBuffTooltip         = ttp.showBuffTooltip or false
    cache.showBuffTooltipInCombat = ttp.showBuffTooltipInCombat or false
end

-- v67: 12.0.7 branch removed (addon is 12.1-only).
function BuffsAndContainers:Layout(parent)
    -- Container work is for real frames only: preview frames render
    -- with the retained dummy icon pools (plan: preview KEEP) and
    -- must not create containers.
    -- v72 PERF: nor does a real frame that has never been in service —
    -- every Layout dispatch (login build, resize, profile change) used to
    -- re-walk 20 containers on all 45 frames. The gate clears permanently
    -- the first time the frame carries a unit, so a frame that later loses
    -- it keeps having its existing containers maintained here.
    if not parent._isPreviewFrame and not BF:ShouldDeferFrameAuraContainers(parent) then
        -- v88b: if this Layout is running inside the restricted window (a
        -- combat /reload is the case that matters), every engine call it is
        -- about to make can be denied and swallowed by its own pcall. Flag the
        -- frame so the regen replay re-runs this whole function once the
        -- restriction lifts -- see BF:NoteAuraLayoutRestricted in
        -- Auras/ContainerFactory.lua. One boolean write, and only in that
        -- window; zero cost on every normal Layout.
        BF:NoteAuraLayoutRestricted(parent)
        -- v92: drop the per-host wrap-budget memo (see MaxSingleBuffSizeFor).
        -- Every settings edit arrives as a fresh Layout, so dropping it here
        -- and in :Create is what keeps the memo honest; within one frame's
        -- pass it then answers all three hosts from ONE container walk.
        InvalidateSingleBuffHostSizes()
        EnsureBuffContainers(parent)
        local geo = BuffGeneralGeo(parent)
        BF:ApplyAuraGridGeometry(parent, "buffs", geo)
        BF:ApplyAuraGridButtonSpec(parent, "buffs", BuffButtonSpec(parent, geo.size))
        local containers = BF:GetActiveCustomBuffContainers() or {}
        local ac = BF:GetAuraCacheForFrame(parent)
        -- v61: per-Layout scope key resolved once per frame, not per
        -- container — ContainerGeo now honors groupSettings geometry.
        local groupTypeKey = BF.ResolveGroupTypeKey and BF:ResolveGroupTypeKey(parent)
        for ci, c in ipairs(containers) do
            -- v65/v92: a FLOW-ANCHORED single buff has no bfc<ci> container.
            -- ContainerGeo would hand ApplyAuraGridGeometry an anchor of
            -- "BUFFS" / "BIGDEF" / "C:<key>", none of which is a frame point --
            -- SetPoint would throw (the v65 contract: a sentinel must never
            -- reach geometry). Its geometry and styling are the sb<key>
            -- group's instead, applied by ApplySingleBuffGroups from
            -- ApplyBuffFilters below.
            --
            -- v74: existence gate. A container skipped at creation (relevance
            -- gate in EnsureBuffContainers, or a combat-deferred build) has
            -- nothing to maintain -- without this, every Layout still paid
            -- ContainerGeo + SingleBuffSpec/BuffButtonSpec + border/duration
            -- resolution per skipped container per frame just to feed two
            -- nil-guarded no-ops. EnsureBuffContainers ran above, so anything
            -- creatable THIS pass already exists by this line.
            local cc = parent._bf_auraContainers and parent._bf_auraContainers["bfc" .. ci]
            if cc and not BF:GetSingleBuffAnchorHost(c, groupTypeKey) then
                local cgeo = ContainerGeo(c, ac, groupTypeKey, ci)
                BF:ApplyAuraGridGeometry(parent, "bfc" .. ci, cgeo)
                -- v62: a single buff with its own visuals is styled by the
                -- DERIVED spec restamp in ApplyBuffFilters (runs at the end
                -- of this Layout). Restamping the plain spec here first
                -- would walk its buttons to plain and then back to derived
                -- on every cache-gen bump -- including a denial-prone
                -- SetIcon rebind attempt per direction when the entry uses
                -- a solid icon type. When the entry has no visuals (or was
                -- reverted to "Show (Default Buff)"), the plain restamp
                -- here is what restores container-level styling.
                local cspec = SingleBuffSpec(parent, c, cgeo.size)
                    or BuffButtonSpec(parent, cgeo.size)
                -- v64: per-container Border. Must match the creation site in
                -- EnsureBuffContainers exactly.
                ApplyContainerBorder(cspec, c, groupTypeKey, ac)
                -- v68: per-container Duration. Must match the creation site too.
                ApplyContainerDuration(cspec, c, groupTypeKey, ac)
                cspec.tooltipFrameY = BF.TooltipBelowFrameY(parent, cgeo.anchor, cgeo.offsetY, cgeo.size)
                -- v92: the v64 fast-path defeat (`cc._bf_styleGen = nil`) is
                -- GONE -- v92 removed it here because AcSpecFieldsMatch covered
                -- the acDB border/duration fields this site stamps. v99 removed
                -- the pre-guard itself: ApplyAuraGridButtonSpec compares the full
                -- spec census, so there is no partial field list to be covered by
                -- any more, here or at the single-buff and dbc restamps (which
                -- both dropped their defeats for the same reason).
                BF:ApplyAuraGridButtonSpec(parent, "bfc" .. ci, cspec)
            end
        end
        ApplyBuffFilters(parent)
    end
    -- Fall through when the dummy icon pools exist (preview frames always;
    -- real frames while test/setup mode renders dummies): the dummy
    -- pipeline still needs the font/scale stamping below
    -- (_LayoutDefaultBuffGroup) — without it, auraText changes (e.g.
    -- auto-scale on resize) never reach the preview icons.
    if not parent.buffFrames then return end
    if not BF.GetActiveAuraGroups then return end
    local groups = BF:GetActiveAuraGroups(parent)
    for i = 1, #groups do
        BF:LayoutAuraGroup(parent, groups[i])
    end
end

-- ============================================================
-- Update: hot-path render entry.
--
-- The active-groups list is pre-computed at layout/cache-build time
-- by GetActiveAuraGroups. It already reflects all settings-derived
-- visibility decisions (showBuffs toggle, per-container visibility,
-- spec gates). If empty, nothing to render -- exit fast.
--
-- No preview-frame guard: preview frames never enter the dirty-
-- update pipeline (no unit assignment, not in registeredFrames /
-- activatedFrames). The check is structurally unreachable.
-- ============================================================
-- v67: 12.0.7 branch removed (addon is 12.1-only). The old arm carried the
-- legacy group render loop (GetActiveAuraGroups / RenderAuraGroup) plus the
-- Swiftmendable detection; both were already unreachable on 12.1 because the
-- container arm returned unconditionally.
function BuffsAndContainers:Update(frame, unit)
    if frame._isPreviewFrame then return end
    -- v72 PERF: first-render safety net for a frame whose containers were
    -- deferred — one that reached a render pass without going through
    -- OnUnitChanged (vehicle remaps that keep the same unit token), or one
    -- whose build was refused while combat-restricted and is now legal.
    -- ONE field read in steady state; the build itself is the Layout path
    -- (BF:EnsureFrameAuraContainers), never anything new in this hot path.
    if not frame._bf_auraContainersBuilt then
        BF:EnsureFrameAuraContainers(frame)
    end
    local ac2 = BF:GetAuraCacheForFrame(frame)
    local ph = frame._bf_parentHeader or frame:GetParent()
    local moduleOff = ph and ph.isCustomFrame and ph.moduleShowBuffs == false
    -- ── v79: NO BUFFS AT ALL on a unit we cannot assist. ──────────────────
    -- Owner requirement: show nothing rather than garbage.
    --
    -- Uses the SAME predicate the engine uses. Blizzard's
    -- ValidateCandidateFilters permits includeSpellIDs matching for helpful
    -- auras only on ASSISTABLE units; on anything else the candidate set is
    -- silently DROPPED and the group falls back to its filter string alone.
    -- Every group that renders buffs here (sb<key>, sp<sid>, bfc<ci>/main)
    -- narrows by include set over a permissive string, so losing the candidate
    -- set turns each of them into "every helpful aura on the unit" -- observed
    -- in the open world on cross-faction party members, which are partied but
    -- NOT assistable.
    --
    -- So the moment ID matching is unavailable there is nothing this display can
    -- render correctly, and it renders nothing. Plain boolean (UnitCanAssist is
    -- not a secret value); one call per Update.
    -- v99: the assist gate is OFF by default (build 69465 honors include
    -- sets on group members regardless of assistability); `/bf gates` can
    -- re-enable it for a session. See the gate block in ContainerFactory.lua.
    local canAssist = (not BF.GateOn("assist")) or BF.PlayerCanAssistUnit(unit)
    -- v93: the assist gate above is now the NARROW half of a wider rule.
    -- BF:IsUnitAuraSuppressed folds hostile and charmed in (see the
    -- suppression block near the top of Auras/ContainerFactory.lua for the
    -- engine reasoning and the owner ruling). Kept as two terms rather than
    -- one: canAssist is specifically what the include sets require, and it
    -- stays readable as that. One table read -- the predicate is cached and
    -- event-maintained.
    -- Suppression is a RENDER gate. Never a CREATION gate (see the twin note
    -- in DebuffIcons:Update) and never a PARK trigger -- the park arms refuse
    -- it by rule, because a hostile/charmed unit reverts in seconds; see
    -- "NEVER PARK A TRANSIENT STATE" in ContainerFactory.lua. All this term
    -- does is take the container to shown = false, which hides it. That is
    -- the whole intent. canAssist stays in the creation term exactly as v79
    -- shipped it; only the new term is lifted out.
    local suppressed = BF:IsUnitAuraSuppressed(unit)
    local wantBuffs  = (ac2.showBuffs ~= false) and not moduleOff and canAssist
    local showBuffs  = wantBuffs and not suppressed
    -- v77 CREATE-ON-FIRST-ENABLE (BigDefIcons.lua:105-112 pattern).
    -- EnsureBuffContainers skips the "buffs" container entirely while the
    -- display is off, so the first render pass that sees it back ON builds it.
    -- :Layout is the build path (a superset of :Create -- geometry, styling and
    -- filters all have to land, not just the container), and it is idempotent,
    -- so this runs exactly once per enable. Two field reads in steady state.
    -- Restriction-gated like every other creation site; a toggle flipped in
    -- combat lands when the next pass runs after regen.
    if wantBuffs and not (frame._bf_auraContainers and frame._bf_auraContainers.buffs)
       and not BF:IsAuraCreationRestricted() then
        BuffsAndContainers:Layout(frame)
    end
    -- v88 NOTE: single-buff SLOTS deliberately have no net here. A denied slot
    -- creation enqueues its frame on the regen replay in ContainerFactory
    -- (pendingSlotRebuilds -> FlushPendingAuraContainers), which is the same
    -- recovery guarantee pendingCreates and pendingFrameBuilds already give and
    -- costs this function -- the aura hot path -- exactly nothing.
    BF:SyncAuraGridContainer(frame, "buffs", unit, showBuffs)
    local containers = BF:GetActiveCustomBuffContainers() or {}
    local vis = frame._bf_bfcVisible
    -- v65/v92: entries whose Anchor Point is a HOST rather than a frame point
    -- have no bfc<ci> container to sync -- they render as a group inside that
    -- host (the buffs row, another container, or bigDef). Skipping them here
    -- is what makes ApplyBuffFilters' hide stick; without it this loop
    -- re-showed the container it had just hidden on every pass.
    --
    -- The flag is resolved at Layout, so this stays one table lookup: the
    -- broadened v92 meaning costs the hot path nothing. Note the sb group of an
    -- entry hosted by a bfc container is synced by THAT container's own line
    -- below (a group follows its container's shown state), and one hosted by
    -- bigDef by BigDefIcons:Update -- which is why that indicator needs its own
    -- assist gate for them (§A5).
    local anchored = frame._bf_bfcAnchored
    for ci in ipairs(containers) do
        -- Custom containers show independently of the regular-buffs
        -- toggle; per-spec dormancy is handled by the parked filter in
        -- ApplyBuffFilters. v51/v73: per-Layout visibility resolved at
        -- Layout into frame._bf_bfcVisible — one lookup here.
        if not (anchored and anchored[ci]) then
            -- v79: custom buff containers narrow by include set too, so they
            -- carry the same assistable gate as the general row above.
            local shown = canAssist and (not moduleOff) and (not suppressed)
                and (not vis or vis[ci] ~= false)
            BF:SyncAuraGridContainer(frame, "bfc" .. ci, unit, shown)
            -- v82: same shown term for the slot-mode twin. A cheap no-op
            -- (one table lookup) unless the entry actually runs as a slot.
            BF:SyncAuraSlotVisual(frame, "sbc" .. ci, unit, shown)
        end
    end
    -- v46: per-spell frame-effect slots (precomputed key list; nil
    -- on frames with no configured effects — zero cost then).
    local fxKeys = frame._bf_fxKeys
    if fxKeys then
        for i = 1, #fxKeys do
            -- v93: frame effects are aura-driven too (health tint, border,
            -- overlay), so they carry the same suppression term as the icons.
            BF:SyncAuraSlotVisual(frame, fxKeys[i], unit,
                (not moduleOff) and (not suppressed))
        end
    end
end

-- ============================================================
-- v88b: /bf sbdiag — SINGLE-BUFF SLOT STATE PROBE
--
-- Written because two fixes were shipped for this bug on a theory rather than
-- on evidence, and both were wrong. The failure is silent by construction (a
-- wall of pcalls) so it leaves no error and no trace; the only way to find out
-- WHERE it stops is to print every step of the chain and look.
--
-- Run it on a frame that is showing the bug. It reports, per single-buff entry
-- per in-service frame, the upstream gates first (they decide whether anything
-- is even attempted), then the slot record, then the button, then the engine
-- container. The first line that reads wrong is the failure point.
-- ============================================================
-- v88f: SECRET-SAFE. The first run of this probe threw
--   "attempt to compare local 'v' (a secret boolean value, while execution
--    tainted by 'BuzzardFrames')"
-- on `v == false`, from YN(btn:IsShown()) -- which proves AuraButton:IsShown()
-- returns a SECRET boolean, and that comparing one throws for ANY BF code,
-- because addon-registered handlers always run tainted by the addon.
--
-- This is the same class as the note at ContainerFactory.lua:143 ("button
-- dimensions are SECRET post-PEW; comparing threw and silently aborted every
-- restyle walk -- that was the 'all live settings dead' bug"). It is the single
-- most dangerous shape in this codebase: a secret comparison does not return a
-- wrong answer, it THROWS, and inside the surrounding pcall wall it aborts the
-- rest of the function with no trace.
--
-- So: test for secrecy BEFORE comparing, never after. issecretvalue is captured
-- with the same fallback idiom Core_ChatCommands.lua already uses for
-- pre-Midnight clients.
local issecretvalue = issecretvalue or function() return false end
local function YN(v)
    if issecretvalue(v) then return "|cffff00ff<secret>|r" end
    if v == nil then return "|cff888888nil|r" end
    if v == false then return "|cffff5555no|r" end
    if v == true then return "|cff55ff55yes|r" end
    local ok, str = pcall(tostring, v)
    return ok and str or "|cffff00ff<secret>|r"
end

-- Read a getter that may return a secret, without ever comparing the result.
local function SafeGet(obj, method)
    if not obj then return nil end
    local fn = obj[method]
    if not fn then return "|cff888888no-method|r" end
    local ok, v = pcall(fn, obj)
    if not ok then return "|cffff5555err|r" end
    return YN(v)
end

-- v88g: report to a COPYABLE WINDOW, not the chat frame -- BF:ShowTextWindow,
-- the same window as BF:PrintLoadReport (LoadTiming.lua), so there is one
-- house style for "diagnostic text the user needs to get out of the game".
-- Falls back to chat when no window can be shown.
--
-- Building into a table first also removes the truncation hazard entirely: the
-- report is assembled, THEN displayed, so a fault while gathering one entry can
-- never swallow the entries after it.

-- `/bf sbdiag`       -> copy window
-- `/bf sbdiag chat`  -> chat print (fallback / quick glance)
function BF:_DebugSingleBuffSlots(arg)
    local L = {}
    local function add(fmt, ...)
        L[#L + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
    end

    add("BuzzardFrames /bf sbdiag")
    add("restricted=%s  slotMode=%s  recoveryGen=%s  spec=%s",
        YN(self:IsAuraCreationRestricted()),
        YN(not (self.db and self.db.global and self.db.global.singleBuffSlotsDisabled)),
        tostring(self._auraRecoveryGen), tostring(self.playerSpecID))
    -- 2026-09-11 (restricted recreate, plan §7): in-key rebuild state.
    local rst = self.AuraRecreateStatus and self:AuraRecreateStatus()
    if rst then
        add("recreate window=%s  pending=%s  leakedButtons=%s",
            YN(rst.window), tostring(rst.pending), tostring(rst.leakedButtons))
    end

    if not self:IsSlotDiagEnabled() then
        add("|cffff5555instrumentation is OFF|r -- the denial ledger and the")
        add("creation-window traces below record nothing. Enable with")
        add("|cffffff00/bf slotdiag|r, then /reload and reproduce.")
    end
    if self._slotFails then
        add("denied calls:")
        for k, n in pairs(self._slotFails) do add("   %s x%d", k, n) end
        add("   first: %s", tostring(self._slotFailFirst))
    elseif self:IsSlotDiagEnabled() then
        add("denied calls: none recorded")
    end
    add("")

    local containers = self:GetActiveCustomBuffContainers() or {}
    local frames = self.activeFrames
    if not frames then
        add("no active frames")
    else
        -- v88g: every frame with a unit, not the first three. The bug reproduces
        -- on ONE entry of ONE frame and the old 3-frame cap could hide it.
        local shown = 0
        for frame in pairs(frames) do
            if frame.unit and not frame._isPreviewFrame then
                shown = shown + 1
                local gt = self.ResolveGroupTypeKey and self:ResolveGroupTypeKey(frame)
                add("frame %s   built=%s  restrictedLayout=%s  gt=%s",
                    tostring(frame.unit), YN(frame._bf_auraContainersBuilt),
                    YN(frame._bf_auraLayoutRestricted), tostring(gt))
                if rst then
                    -- Slots retired by a rebuild on this frame (recent log).
                    local nRet = 0
                    for _, r in ipairs(rst.last) do
                        if r.kind == "slot" and r.ok and r.unit == tostring(frame.unit) then
                            nRet = nRet + 1
                        end
                    end
                    add("   retiredSlots(recent)=%d", nRet)
                end
                for ci, c in ipairs(containers) do
                    if type(c) == "table" and c.singleBuff then
                        local okEntry, entryErr = pcall(function()
                            local sid = self:GetSingleBuffSpellID(c)
                            local skey = "sbc" .. ci
                            local s = frame._bf_auraSlots and frame._bf_auraSlots[skey]
                            local btn = s and s._bf_slotButton
                            -- v92: the WHICH, not just the whether. "no" =
                            -- positions itself (has a slot / bfc of its own);
                            -- anything else is the host it flows inside, named
                            -- by containerKey for a container host because that
                            -- is what the stored anchorPoint carries.
                            local h = self:GetSingleBuffAnchorHost(c, gt)
                            add("  [%d] sid=%s  host=%s relevant=%s  record=%s",
                                ci, tostring(sid),
                                h and (h.key or h.kind) or "no",
                                YN(self:IsContainerCreationRelevant("buff", ci)),
                                YN(s ~= nil))
                            add("      window:    %s", tostring(
                                frame._bf_sbTrace and frame._bf_sbTrace[ci] or "no trace"))
                            add("      firstpark: %s", tostring(
                                frame._bf_sbParkTrace and frame._bf_sbParkTrace[ci]
                                or "never reached"))
                            if s then
                                add("      key=%s active=%s parked=%s shown=%s dormApplied=%s healthy=%s initOK=%s",
                                    tostring(s.key), YN(s.active), YN(s.parked),
                                    YN(s.shown), YN(s.dormantApplied),
                                    YN(s.healthy), YN(s.initOK))
                                add("      button=%s icon=%s initDone=%s btnShown=%s points=%s anchored=%s",
                                    YN(btn ~= nil), YN(btn and btn._bf_icon ~= nil),
                                    YN(btn and btn._bf_initDone),
                                    SafeGet(btn, "IsShown"), SafeGet(btn, "GetNumPoints"),
                                    YN(s.anchored))
                                local cc = s.c
                                add("      host: shown=%s enabled=%s activeSlots=%s unit=%s hostShown=%s",
                                    YN(cc._bf_shown), YN(cc._bf_enabled),
                                    tostring(cc._bf_activeSlots),
                                    SafeGet(cc, "GetUnit"), SafeGet(cc, "IsShown"))
                                -- v88m: the geometry the maintenance arm would
                                -- push RIGHT NOW. Everything above is state BF
                                -- recorded at some point in the past; this is
                                -- re-resolved live from the frame's CURRENT
                                -- group-type key, which is the one thing a
                                -- group transition definitely changes. A slot
                                -- can be healthy by every field above and still
                                -- render nothing if size resolves to 0/nil or
                                -- the lift target moved. Not secret: every
                                -- value here is BF-side profile resolution.
                                local sac  = self:GetAuraCacheForFrame(frame)
                                local sgeo = ContainerGeo(c, sac, gt)
                                local sanc = (sgeo.anchor and sgeo.anchor ~= "")
                                    and sgeo.anchor or "CENTER"
                                local lift = BF.AuraLiftAnchorFrame(frame, sac, sanc)
                                add("      geo:  size=%s anchor=%s offX=%s offY=%s grow=%s",
                                    tostring(sgeo.size), tostring(sanc),
                                    tostring(sgeo.offsetX), tostring(sgeo.offsetY),
                                    tostring(sgeo.growDirection))
                                add("      lift: target=%s pwrShown=%s abovePwr=%s",
                                    lift and (lift:GetName() or "clipFrame")
                                        or "|cff888888none (parent)|r",
                                    frame.powerBar and SafeGet(frame.powerBar, "IsShown")
                                        or "|cff888888no bar|r",
                                    YN(sac and sac.aurasAbovePowerBar))
                            end
                        end)
                        if not okEntry then
                            add("  [%d] PROBE ERROR: %s", ci, tostring(entryErr))
                        end
                    end
                end
                add("")
            end
        end
        if shown == 0 then add("no in-service frames with a unit") end
    end

    local text = table.concat(L, "\n")
    if not (arg and arg:find("chat", 1, true)) then
        if BF:ShowTextWindow("BuzzardFrames single-buff slot diagnostic", text, {
            status = "Creation-window trace per single buff. Re-runnable at any time with /bf sbdiag.",
            width  = 820, height = 560,
        }) then
            return
        end
    end
    for i = 1, #L do print(L[i]) end
end

BF:RegisterIndicator(BuffsAndContainers)
BuffsAndContainers:EnableDeferredUpdates()
