-- ============================================================
-- BuzzardFrames: LoadTiming.lua
-- Login / reload load-time harness  (perf plan §L5.1) plus the
-- layout-switch harness (§L5.2).
--
--   /bf loadreport         — print the login phase breakdown
--   /bf loadreport marks   — same, with every recorded mark listed
--
-- TWO collectors, both cold-path only:
--
--   * COARSE marks (BF:LoadMark) are recorded UNCONDITIONALLY. There are
--     ~45 of them, one small table each, and they have to be unconditional
--     because the first ones are stamped at file-parse time -- before
--     AceDB exists, so before db.global.debugTiming can be read at all.
--     This is what makes `/bf loadreport` useful on a run where no debug
--     flag was ever set.
--   * DETAIL marks (BF:LoadMarkD) record only when db.global.debugTiming
--     or db.global.debugLoadReport is on. These are the per-Build*,
--     per-migration-step marks, so a shipped install collects nothing
--     beyond the phase boundaries.
--
-- Every collector SELF-SEALS a few seconds after the first
-- PLAYER_ENTERING_WORLD (BF:SealLoadReport swaps each one for a no-op),
-- so nothing here costs anything during play. There is deliberately NO
-- OnUpdate hook anywhere in this file, and no event registration that
-- outlives login.
--
-- The zero point is stamped at the TOP of Defaults.lua (the first BF core
-- file), NOT here -- otherwise Defaults.lua's own 34 KB of parse+execute
-- would be unattributed. The only BF chunks that run before the origin are
-- the two vendored-verbatim salvaged oUF elements (19 KB); see the comment
-- on the origin stamp in Defaults.lua.
-- ============================================================

local BF = _G["BuzzardFrames"]
if not BF then return end

local debugprofilestop = debugprofilestop
local format = string.format
local ipairs, pairs = ipairs, pairs

-- Adopt the pre-DB bootstrap table. Recreated defensively if the seeding
-- chunk was ever removed, so the harness still works (just with a later
-- zero point) rather than erroring.
local LT = _G.BuzzardFrames_LoadTiming
if not LT then
    LT = { t0 = debugprofilestop(), marks = {} }
    _G.BuzzardFrames_LoadTiming = LT
end

BF._loadT0        = LT.t0
BF._loadMarks     = LT.marks   -- ordered { label, ms, isDetail } tuples
BF._loadUASC      = {}         -- callsite tag -> { n = calls, ms = total }
BF._loadUASCOrder = {}         -- tags in first-seen order

-- ============================================================
-- COLLECTORS
-- ============================================================

-- Coarse phase boundary. Always recorded until the harness seals.
function BF:LoadMark(label)
    local m = self._loadMarks
    m[#m + 1] = { label, debugprofilestop() - self._loadT0 }
end

-- Is fine-grained collection enabled? Nil-safe before RegisterDB runs.
function BF:LoadDetailOn()
    local g = self.db and self.db.global
    if g and (g.debugTiming or g.debugLoadReport) then return true end
    return false
end

-- Fine-grained sub-step. Recorded only behind the flag.
function BF:LoadMarkD(label)
    if not self:LoadDetailOn() then return end
    local m = self._loadMarks
    m[#m + 1] = { label, debugprofilestop() - self._loadT0, true }
end

-- Same, with a value appended to the label (counts, booleans...).
function BF:LoadMarkDv(label, value)
    if not self:LoadDetailOn() then return end
    local m = self._loadMarks
    m[#m + 1] = { label .. " = " .. tostring(value),
                  debugprofilestop() - self._loadT0, true }
end

-- ── UpdateAuraSizeCache accounting ──────────────────────────
-- Call-site tag is set immediately before a call (or before a wrapper
-- that makes one, e.g. RefreshProfileCache) and consumed by the pass
-- itself, so the report can say WHICH of the seven login passes cost
-- what. Counting is unconditional until seal: seven calls, two
-- debugprofilestop() each.
function BF:LoadUASCTag(tag)
    self._loadUASCTag = tag
end

function BF:LoadUASCBegin()
    return debugprofilestop()
end

function BF:LoadUASCEnd(t0)
    local tag = self._loadUASCTag or "other"
    self._loadUASCTag = nil
    local e = self._loadUASC[tag]
    if not e then
        e = { n = 0, ms = 0 }
        self._loadUASC[tag] = e
        local o = self._loadUASCOrder
        o[#o + 1] = tag
    end
    e.n  = e.n + 1
    e.ms = e.ms + (debugprofilestop() - t0)
end

-- ── oUF spawn / relayout counting (§L5.1 row `pew:oufVisibility`) ──
-- Counts existing oUF frames after ApplyOUFVisibility returns; the delta
-- against the previous call is the number this call SPAWNED, the rest it
-- re-laid-out. Kept here so ApplyOUFVisibility needs a single line.
local OUF_KEYS = {
    "oufPlayer", "oufTarget", "oufFocus", "oufTargetOfTarget",
    "oufFocusTarget", "oufPet", "oufBoss", "oufResourceBar",
}
function BF:LoadOUFCounts()
    local n = 0
    for i = 1, #OUF_KEYS do
        if self[OUF_KEYS[i]] then n = n + 1 end
    end
    local prev = self._loadOUFPrev or 0
    self._loadOUFPrev = n
    self:LoadMarkDv("pew:oufVisibility spawned/relaid",
        (n - prev) .. "/" .. prev)
end

-- ── headersBuilt drill-down (§L5.1 span `load:enter` -> `load:headersBuilt`) ──
-- That one span is ~73% of login, so it gets its own accumulator instead of
-- more marks: a mark per frame would be tens of thousands of table allocations
-- inside the very thing being measured.
--
-- The whole collector is ONE table hung off BF._loadHB. It exists only while
-- the span is open AND only when detail collection is on, so every call site
-- in the hot path (BuzzardFrame_Init, InitAuraButton, ...) is a single
-- `if BF._loadHB` nil test the rest of the session -- the same price the fine
-- marks pay, and it needs no seal of its own (LoadHBEnd nils it; the seal
-- no-ops the entry points anyway).
--
-- The stage rows are additive and provably close:
--
--   span            = sum(header rows) + other
--   sum(header rows)= create            + frameInit
--   frameInit       = secure + indicators + prealloc + layout + residue
--
-- `create` is the engine's own child CreateFrame + SecureGroupHeader_Update
-- work (header wall time minus everything our initialConfigFunction did),
-- `other` is everything in the span outside header creation (ResetHeaders,
-- UpdateAuraSizeCache, attribute writes). Nothing can hide in either.
function BF:LoadHBBegin()
    if not self:LoadDetailOn() then self._loadHB = nil; return end
    self._loadHB = {
        headers = {},        -- ordered { label, frames, ms }
        byFrame = {},        -- header object -> row (repeat calls fold in)
        t0      = debugprofilestop(),
        headerMs = 0, frameInit = 0,
        secure = 0, indicators = 0, prealloc = 0, layout = 0,
        buttonMs = 0,
        frames = 0, indCreates = 0, buttons = 0, containers = 0, slots = 0,
        -- v77: pooled buttons the engine created that we deliberately did NOT
        -- style (the skip block in Auras/ContainerFactory.lua). `buttons`
        -- counts InitAuraButton calls, so without this the report would read
        -- the win as buttons vanishing rather than as work avoided.
        skipped = 0,
        -- v77b: per-group-class attribution, keyed by normalized
        -- "<container>/<group>" (see HBKey in Auras/ContainerFactory.lua).
        byKey = {},
        -- v85: per-SLOT-KEY census, keyed by BF.HBSlotKey (dispel keys kept
        -- whole, fx*/sbc* collapsed to a class). `slots` alone could not say
        -- WHICH slots a frame ended up with, which is exactly what the
        -- dispel-visual merge made worth knowing.
        slotKeys = {},
    }
end

function BF:LoadHBEnd()
    local hb = self._loadHB
    if not hb then return end
    self._loadHB = nil
    hb.span = debugprofilestop() - hb.t0
    hb.create  = hb.headerMs - hb.frameInit
    hb.other   = hb.span - hb.headerMs
    hb.residue = hb.frameInit
        - (hb.secure + hb.indicators + hb.prealloc + hb.layout)
    -- First completed span only, matching FirstAt()'s first-mark semantics.
    if not self._loadHBDone then self._loadHBDone = hb end
end

-- Readable identity for a header. Resolved here (not at the call site) so
-- BFLayout keeps a one-line diff, and only ever on the instrumented path.
local function HBHeaderLabel(header)
    if header.isPetFrame then
        return "pet:" .. tostring(header.petFlatID or "?")
    end
    if header.isCustomFrame or header._bf_isCFGHeader then
        return "cfg:" .. tostring(header.customGroupIndex or "?")
    end
    local ok, gf = pcall(header.GetAttribute, header, "groupFilter")
    return "main:" .. tostring((ok and gf) or "?")
end

function BF:LoadHBHeader(header, created, ms)
    local hb = self._loadHB
    if not hb then return end
    hb.headerMs = hb.headerMs + ms
    local row = hb.byFrame[header]
    if not row then
        row = { HBHeaderLabel(header), 0, 0 }
        hb.byFrame[header] = row
        hb.headers[#hb.headers + 1] = row
    end
    row[2] = row[2] + created
    row[3] = row[3] + ms
end

-- One completed BuzzardFrame_Init. Timestamps in call order; see the stage
-- comment above for what each gap owns.
function BF:LoadHBFrame(t0, t1, t2, t3, t4, t5)
    local hb = self._loadHB
    if not hb then return end
    hb.frames     = hb.frames + 1
    hb.frameInit  = hb.frameInit  + (t5 - t0)
    hb.secure     = hb.secure     + (t1 - t0)
    hb.indicators = hb.indicators + (t2 - t1)
    hb.prealloc   = hb.prealloc   + (t3 - t2)
    hb.layout     = hb.layout     + (t4 - t3)
end

-- ============================================================
-- SEAL — steady state reached, stop paying for anything
-- ============================================================
local function _noop() end

-- Sealing stops COLLECTION only. _loadMarks, _loadUASC/_loadUASCOrder and
-- _loadHBDone are deliberately left intact so `/bf loadreport` stays
-- re-openable for the whole session; nothing in the addon wipes them.
function BF:SealLoadReport()
    if self._loadSealed then return end
    self._loadSealed = true
    self._loadEndMs  = debugprofilestop() - self._loadT0
    -- v85: what the frames ACTUALLY hold now, vs what was created INSIDE the
    -- headersBuilt span. A slot present here but absent from hb.slotKeys was
    -- created after the span closed -- the distinction that separates "the
    -- feature never built" from "the feature builds late".
    if self._loadHBDone and BF.HBSlotSnapshot then
        local ok, snap = pcall(BF.HBSlotSnapshot)
        if ok then self._loadHBDone.slotKeysAtSeal = snap end
    end
    self.LoadMark      = _noop
    self.LoadMarkD     = _noop
    self.LoadMarkDv    = _noop
    self.LoadUASCTag   = _noop
    self.LoadUASCBegin = _noop   -- returns nil -> callers skip LoadUASCEnd
    self.LoadUASCEnd   = _noop
    self.LoadOUFCounts = _noop
    self._loadHB       = nil     -- the counters' own gate; see LoadHBBegin
    self.LoadHBBegin   = _noop
    self.LoadHBEnd     = _noop
    self.LoadHBHeader  = _noop
    self.LoadHBFrame   = _noop
end

-- Armed once, from the first PLAYER_ENTERING_WORLD. The delay covers the
-- deferred login tails the plan wants attributed (the 0.1 s role timer and
-- the 0.2 s spec timer, §L1.0 rows 30-31) and nothing more.
function BF:ArmLoadReportSeal()
    if self._loadSealArmed or self._loadSealed then return end
    self._loadSealArmed = true
    C_Timer.After(3, function() BF:SealLoadReport() end)
end

-- ============================================================
-- §L5.2 LAYOUT-SWITCH HARNESS
-- Separate buffer, auto-printed once per switch when debugTiming is on
-- (a layout switch is a discrete user-visible event, so an auto-print
-- beats a command). Every entry point is a single boolean test when off.
-- ============================================================
BF._swMarks = {}

function BF:SwitchBegin(reason)
    local g = self.db and self.db.global
    if not (g and g.debugTiming and self:IsDebugOutputEnabled()) then
        self._swActive = nil
        return
    end
    self._swActive      = true
    self._swReason      = reason
    self._swT0          = debugprofilestop()
    self._swLast        = self._swT0
    self._swPendingTail = nil
    self._swHeaders     = 0
    self._swFrames      = 0
    self._swForcedOnly  = 0
    self._swLayoutMs    = 0
    local m = self._swMarks
    for i = #m, 1, -1 do m[i] = nil end
end

function BF:SwitchMark(label, extra)
    if not self._swActive then return end
    local now = debugprofilestop()
    local m = self._swMarks
    m[#m + 1] = { label, now - self._swT0, now - self._swLast, extra }
    self._swLast = now
end

-- The decisive §L3 6a counter: how many frames were re-Layout'd, and how
-- many of those had unchanged w/h/scale and were dispatched only because
-- _forceReload was set.
function BF:SwitchCountLayouts(nFrames, sizeChanged, ms)
    if not self._swActive then return end
    self._swHeaders = self._swHeaders + 1
    self._swFrames  = self._swFrames + nFrames
    if not sizeChanged then
        self._swForcedOnly = self._swForcedOnly + nFrames
    end
    self._swLayoutMs = self._swLayoutMs + ms
end

function BF:SwitchPendingTail()
    if not self._swActive then return end
    self._swPendingTail = true
end

-- Flush unless the deferred tail still owes us marks; the tail calls this
-- itself when it finishes.
function BF:SwitchFlush(force)
    if not self._swActive then return end
    if self._swPendingTail and not force then return end
    self._swActive = nil
    local m = self._swMarks
    local total = m[#m] and m[#m][2] or 0
    print(format("|cff11ace9BF switch|r  %s  total %.1f ms",
        tostring(self._swReason or "ReloadLayout"), total))
    for i = 1, #m do
        local e = m[i]
        print(format("|cff11ace9BF|r   %-22s %8.1f %8.1f  %s",
            e[1], e[2], e[3], e[4] and tostring(e[4]) or ""))
    end
    print(format("|cff11ace9BF|r   %-22s %d frames in %d headers, %d size-unchanged (force-only), %.1f ms",
        "sw:frameLayouts", self._swFrames, self._swHeaders,
        self._swForcedOnly, self._swLayoutMs))
end

-- §L5.2 tail: make the combat swallow observable rather than theoretical.
function BF:SwitchSecureSwallow(priority, method, displaced)
    local g = self.db and self.db.global
    if not (g and g.debugTiming and self:IsDebugOutputEnabled()) then return end
    print(format("|cff11ace9BF secure|r  swallowed %s (priority %s)%s",
        tostring(method), tostring(priority),
        displaced and "  [displaced a pending entry]" or ""))
end

-- ============================================================
-- REPORT  (/bf loadreport)
-- ============================================================

-- Consecutive boundary spans. Every millisecond between the first and the
-- last boundary lands in exactly one row, so the rows provably sum to the
-- total and nothing can hide between them -- a dominator outside BF's own
-- functions surfaces as a fat `gap` row instead of silently vanishing.
local BOUNDARIES = {
    "chunk:origin", "chunk:end", "init:enter", "init:exit",
    "enable:enter", "enable:exit", "pew:enter", "pew:exit",
    "tail:enter", "tail:exit",
}

local SPAN_NAME = {
    ["chunk:origin>chunk:end"]   = "PARSE + execute of every .toc chunk",
    ["chunk:end>init:enter"]     = "SavedVariables load -> ADDON_LOADED",
    ["init:enter>init:exit"]     = "OnInitialize (RegisterDB)",
    ["init:exit>enable:enter"]   = "gap: ADDON_LOADED -> PLAYER_LOGIN (client + other addons)",
    ["enable:enter>enable:exit"] = "OnEnable",
    ["enable:exit>pew:enter"]    = "gap: PLAYER_LOGIN -> first PEW (client world load)",
    ["pew:enter>pew:exit"]       = "first PLAYER_ENTERING_WORLD (synchronous)",
    ["pew:exit>tail:enter"]      = "gap: PEW -> deferred LoadLayout tail",
    ["tail:enter>tail:exit"]     = "LoadLayout deferred tail",
}

-- Rows that are NOT BuzzardFrames Lua. Kept in the table (so the sum still
-- closes) but subtotalled separately.
local SPAN_IS_GAP = {
    ["init:exit>enable:enter"] = true,
    ["enable:exit>pew:enter"]  = true,
    ["pew:exit>tail:enter"]    = true,
}

-- The derived lines §L3's ordering is decided on (§L5.1). Overlapping by
-- design, so they are printed apart from the additive table above.
local DERIVED = {
    { "PARSE (total)",                    "chunk:origin",         "chunk:end" },
    { "  Defaults.lua (toc 43)",          "chunk:origin",         "chunk:Defaults" },
    { "  defaults block (toc 50-54)",     "chunk:Defaults",       "chunk:defaultsDone" },
    { "  core files (toc 55-69)",         "chunk:defaultsDone",   "chunk:postCore" },
    { "    ..Core_ProfileAPI (56)",       "chunk:defaultsDone",   "chunk:coreProfileAPI" },
    { "    ..Core_Migrations (58)",       "chunk:coreProfileAPI", "chunk:coreMigrations" },
    { "    Core_DB (59)",                 "chunk:coreMigrations", "chunk:coreDB" },
    { "  SpellData_Buffs",                "chunk:postCore",       "chunk:spellData" },
    { "  Preview engine",                 "chunk:spellData",      "chunk:postPreview" },
    { "  runtime block",                  "chunk:postPreview",    "chunk:preOptions2" },
    { "    ..SetupMode",                  "chunk:postPreview",    "chunk:setupMode" },
    { "    ..BFStatus",                   "chunk:setupMode",      "chunk:bfStatus" },
    { "    ..Statuses",                   "chunk:bfStatus",       "chunk:preBFLayout" },
    { "    BFLayout",                     "chunk:preBFLayout",    "chunk:bfLayout" },
    { "    ..Initialization",             "chunk:bfLayout",       "chunk:initialization" },
    { "    ..PreviewIconEff",             "chunk:initialization", "chunk:preOptions2" },
    { "  Themes+SingleBuffAPI",           "chunk:preOptions2",    "chunk:postSingleBuffAPI" },
    { "  ..CustomFrames",                 "chunk:postSingleBuffAPI", "chunk:preUF" },
    { "  PARSE (UnitFrames rt)",          "chunk:preUF",          "chunk:postUF" },
    { "  ..FrameSort+Profiler",           "chunk:postUF",         "chunk:end" },
    { "OnInitialize",              "init:enter",         "init:exit" },
    { "  of which RegisterDB",     "init:enter",         "init:dbDone" },
    { "    AceDB:New x6",          "init:enter",         "init:dbCreated" },
    { "    every-login purges",    "init:dbCreated",     "init:preDispatcher" },
    { "    migration dispatcher",  "init:preDispatcher", "init:postDispatcher" },
    { "    post purges",           "init:postDispatcher", "init:postPurges" },
    { "    Rehydrate*Flats",       "init:postPurges",    "init:postRehydrate" },
    { "OnEnable",                  "enable:enter",       "enable:exit" },
    { "first PEW",                 "pew:enter",          "pew:exit" },
    { "  of which oUF visibility", "pew:enter",          "pew:oufVisibility" },
    { "  of which GroupChanged",   "pew:preGroupChanged", "pew:postGroupChanged" },
    { "    of which headersBuilt", "load:enter",         "load:headersBuilt" },
    { "LOGIN -> PLAYABLE",         "chunk:origin",       "tail:exit" },
}

-- First absolute ms recorded for `label`, or nil.
local function FirstAt(marks, label)
    for i = 1, #marks do
        if marks[i][1] == label then return marks[i][2], i end
    end
end

-- Builds the ENTIRE report as plain-text lines -- no |cff color codes, no
-- printing. One producer, two consumers: the copy window (concat) and the
-- chat frame (prefix each line). The chat frame truncates a report this long
-- and the owner captures by screenshot, so the window is the default.
function BF:BuildLoadReport(wantMarks)
    local L = {}
    local function add(s) L[#L + 1] = s end

    local marks = self._loadMarks
    if not marks or #marks == 0 then
        add("   no marks recorded. LoadTiming.lua may be missing from the .toc.")
        return L
    end
    local detail = self:LoadDetailOn()
    local last   = marks[#marks][2]

    add(format("BuzzardFrames Load Report -- %d marks, detail=%s, %s.",
        #marks, detail and "ON" or "OFF",
        self._loadSealed and format("sealed at %.1f ms", self._loadEndMs or last)
                          or "NOT yet sealed"))
    add("   All ms are from the first BF chunk executed.")
    if not detail then
        add("   Fine-grained steps were NOT collected. For those:")
        add("      /run BuzzardFrames.db.global.debugLoadReport = true    then /reload.")
    end

    -- ── the mark table ──
    if wantMarks or detail then
        add(format("   %10s %9s  %s", "abs ms", "+delta", "mark"))
        local prev = 0
        for i = 1, #marks do
            local e = marks[i]
            add(format("   %10.1f %9.1f  %s%s",
                e[2], e[2] - prev, e[3] and "   " or "", e[1]))
            prev = e[2]
        end
    else
        add("   (add `marks` to list every recorded mark)")
    end

    -- ── additive phase table ──
    add("   --- PHASES (these rows sum to TOTAL) ---")
    local prevLabel, prevAt = nil, nil
    local bfSum, gapSum = 0, 0
    for i = 1, #BOUNDARIES do
        local label = BOUNDARIES[i]
        local at = FirstAt(marks, label)
        if at then
            if prevLabel then
                local key  = prevLabel .. ">" .. label
                local name = SPAN_NAME[key] or ("unmarked: " .. key)
                local span = at - prevAt
                if SPAN_IS_GAP[key] or not SPAN_NAME[key] then
                    gapSum = gapSum + span
                else
                    bfSum = bfSum + span
                end
                add(format("   %10.1f  %s", span, name))
            end
            prevLabel, prevAt = label, at
        end
    end
    -- Anything recorded after the last phase boundary (deferred spec/role
    -- timers) is a row of its own so the arithmetic still closes.
    local trailing = prevAt and (last - prevAt) or 0
    if trailing > 0 then
        add(format("   %10.1f  after last boundary (deferred timers)", trailing))
        gapSum = gapSum + trailing
    end
    add(format("   %10s  %s", "--------", "----------------------------------------"))
    add(format("   %10.1f  BF-attributed subtotal", bfSum))
    add(format("   %10.1f  UNATTRIBUTED (gaps + trailing; not BF Lua)", gapSum))
    add(format("   %10.1f  TOTAL (first mark -> last mark)", last))

    -- ── derived, overlapping ──
    add("   --- DERIVED (overlapping; the §L3 ranking numbers) ---")
    for i = 1, #DERIVED do
        local row = DERIVED[i]
        local a = FirstAt(marks, row[2])
        local b = FirstAt(marks, row[3])
        if a and b then
            add(format("   %10.1f  %s", b - a, row[1]))
        end
    end

    -- ── UpdateAuraSizeCache passes ──
    local order = self._loadUASCOrder
    if order and #order > 0 then
        add("   --- UpdateAuraSizeCache passes during startup ---")
        local n, ms = 0, 0
        for i = 1, #order do
            local tag = order[i]
            local e   = self._loadUASC[tag]
            add(format("   %10.1f  %-28s x%d", e.ms, tag, e.n))
            n, ms = n + e.n, ms + e.ms
        end
        add(format("   %10.1f  %-28s x%d", ms, "TOTAL", n))
    end

    -- ── headersBuilt drill-down ──
    local hb = self._loadHBDone
    if hb then
        local nf = hb.frames > 0 and hb.frames or 1
        add("   --- headersBuilt drill-down (load:enter -> load:headersBuilt) ---")
        add(format("   %10.1f  span total", hb.span))
        add(format("   %10.1f    header child creation (%d headers, %d frames)",
            hb.headerMs, #hb.headers, hb.frames))
        add(format("   %10.1f      CreateFrame level (engine children + SecureGroupHeader_Update)",
            hb.create))
        add(format("   %10.1f      BuzzardFrame_Init total", hb.frameInit))
        add(format("   %10.1f        secure-attribute setup (mixin + hooks + attrs + clicks)",
            hb.secure))
        add(format("   %10.1f        CreateIndicators (%d indicator :Create calls)",
            hb.indicators, hb.indCreates))
        add(format("   %10.1f          of which InitAuraButton (%d styled, %d skipped of %d pooled)",
            hb.buttonMs, hb.buttons, hb.skipped or 0,
            hb.buttons + (hb.skipped or 0)))
        add(format("   %10.1f        PreallocateContainerPools", hb.prealloc))
        add(format("   %10.1f        initial frame:Layout", hb.layout))
        add(format("   %10.1f        residue (SendMessage + stamps)", hb.residue))
        add(format("   %10.1f    other in span (ResetHeaders, caches, attributes)",
            hb.other))
        add(format("   %10s  %d aura containers, %d aura slots created",
            "", hb.containers, hb.slots))
        add(format("   %10.2f  PER FRAME ms  (%.1f styled + %.1f skipped buttons, %.1f containers, %.1f indicators)",
            hb.frameInit / nf, hb.buttons / nf, (hb.skipped or 0) / nf,
            hb.containers / nf, hb.indCreates / nf))
        add("   --- per header ---")
        for i = 1, #hb.headers do
            local r = hb.headers[i]
            add(format("   %10.1f    %-16s %3d frames", r[3], r[1], r[2]))
        end
        -- v77b: where the pooled buttons actually come from. `pool` is the
        -- MEASURED pool size for that class (init calls / groups) -- if it is
        -- not 10 everywhere, that is the answer to "the totals don't add up".
        -- `/frame` divides groups by the frame count, so a class present on
        -- every frame shows a whole number and one that is not shows a
        -- fraction.
        if hb.byKey and next(hb.byKey) then
            local rows = {}
            for _, r in pairs(hb.byKey) do rows[#rows + 1] = r end
            table.sort(rows, function(a, b)
                if a.pooled ~= b.pooled then return a.pooled > b.pooled end
                return a.key < b.key
            end)
            add("   --- pooled buttons by group class ---")
            add(format("   %-18s %7s %8s %7s %8s %6s %8s",
                "container/group", "groups", "pooled", "styled", "skipped",
                "pool", "grp/frm"))
            local tg, tp, ts, tk = 0, 0, 0, 0
            for i = 1, #rows do
                local r = rows[i]
                tg, tp = tg + r.groups, tp + r.pooled
                ts, tk = ts + r.styled, tk + r.skipped
                add(format("   %-18s %7d %8d %7d %8d %6.1f %8.2f",
                    r.key, r.groups, r.pooled, r.styled, r.skipped,
                    r.groups > 0 and (r.pooled / r.groups) or 0,
                    r.groups / nf))
            end
            add(format("   %-18s %7d %8d %7d %8d %6.1f %8.2f",
                "TOTAL", tg, tp, ts, tk,
                tg > 0 and (tp / tg) or 0, tg / nf))
        end

        -- v85: slots by KEY. Slots are 1 button each (no 10-pool), so the
        -- interesting number is how many of each kind exist and WHEN they were
        -- built.
        --
        --   `in span`  what EnsureAuraSlotVisual counted inside the
        --              headersBuilt window (hb.slotKeys).
        --   `at seal`  what the frames were actually holding 3 s after
        --              PLAYER_ENTERING_WORLD (BF.HBSlotSnapshot).
        --
        -- BOTH COLUMNS COVER THE SAME POPULATION -- every frame BF:RegisterFrame
        -- created, via BF.registeredFrames. (They did not in the first cut of
        -- this table: the snapshot walked BF.activeFrames, i.e. only frames
        -- currently holding a unit, so at-seal read ~2 for every key while
        -- in-span covered all 45 created frames.) Reading the comparison:
        --
        --   at seal == in span   the normal case -- built in the build pass.
        --   at seal >  in span   the feature builds LATE, after the census
        --                        closes (what v84's dispel path did before
        --                        creation moved back into :Create).
        --   at seal <  in span   slot RECORDS were lost after the build, which
        --                        should be impossible: nothing in the addon
        --                        nils frame._bf_auraSlots, header :Reset()
        --                        deliberately preserves per-frame indicator
        --                        state, and SuspendFrameAuraContainers only
        --                        hides. Treat it as a real defect.
        --   absent from both     never built at all.
        local atSeal = hb.slotKeysAtSeal
        if (hb.slotKeys and next(hb.slotKeys)) or (atSeal and next(atSeal)) then
            local keys, seen = {}, {}
            for k in pairs(hb.slotKeys or {}) do
                if not seen[k] then seen[k] = true; keys[#keys + 1] = k end
            end
            for k in pairs(atSeal or {}) do
                if not seen[k] then seen[k] = true; keys[#keys + 1] = k end
            end
            table.sort(keys)
            add("   --- slots by key (1 button each, no pool) ---")
            add(format("   %-18s %8s %8s %9s",
                "slot key", "in span", "at seal", "seal/frm"))
            local tin, tat = 0, 0
            for i = 1, #keys do
                local k = keys[i]
                local a = (hb.slotKeys and hb.slotKeys[k]) or 0
                local b = (atSeal and atSeal[k]) or 0
                tin, tat = tin + a, tat + b
                add(format("   %-18s %8d %8d %9.2f", k, a, b, b / nf))
            end
            add(format("   %-18s %8d %8d %9.2f", "TOTAL", tin, tat, tat / nf))
            if not atSeal then
                add("   (at-seal column is 0 until the report is sealed)")
            end
        end
    end

    return L
end

-- Copy window (BF:ShowTextWindow, Core_OptionsBridge.lua).

-- `/bf loadreport`        -> copy window
-- `/bf loadreport marks`  -> copy window, mark dump included
-- `/bf loadreport chat`   -> the old chat print (also accepts `chat marks`)
function BF:PrintLoadReport(arg)
    arg = arg or ""
    local wantMarks = arg:find("marks", 1, true) ~= nil
    local wantChat  = arg:find("chat",  1, true) ~= nil
    local L = self:BuildLoadReport(wantMarks)

    if not wantChat then
        if BF:ShowTextWindow("BuzzardFrames Load Report", table.concat(L, "\n"), {
            status = "Login phase breakdown (perf plan §L5.1). Marks survive the harness seal, so this can be reopened at any time with /bf loadreport.",
            width  = 760, height = 560,
        }) then
            return
        end
        -- No window could be shown: chat it is.
    end
    for i = 1, #L do
        -- Body rows already carry the 3-space indent the old chat rows had;
        -- the unindented title row gets its own separator.
        local l = L[i]
        print(l:sub(1, 1) == " " and ("|cff11ace9BF|r" .. l)
                                  or ("|cff11ace9BF|r  " .. l))
    end
end

-- Perf plan §L5.1 load-time mark: Defaults.lua's own chunk is now closed (.toc 43-49).
if BuzzardFrames then BuzzardFrames:LoadMark("chunk:Defaults") end
