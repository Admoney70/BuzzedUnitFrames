-- ============================================================
-- BuzzardFrames: Core_ChatCommands.lua
-- /bf chat command dispatcher. Handles real user commands
-- (lock/unlock/reset/resetptf) as well as the /bf debug* suite
-- used during development.
-- Extracted from Core.lua in the Core split refactor.
-- ============================================================
local BF = _G["BuzzardFrames"]

-- Safe fallback for pre-Midnight clients where issecretvalue doesn't exist.
local issecretvalue = issecretvalue or function() return false end

function BF:OnChatCommand(input)
    input = input and input:lower():trim() or ""
    -- Debug/diagnostic subcommands are gated behind the two Experimental
    -- toggles (see Core.lua DEBUG OUTPUT GATE). With debug output off they
    -- produce NOTHING except a one-line pointer to the toggle, so a normal
    -- user typing them by accident gets no wall of diagnostic text.
    do
        local cmd = input:match("^(%S+)") or ""
        local DEBUG_CMDS = {
            debugreg = true, debugvis = true, debugcf = true, debugcolor = true,
            debugauras = true, debugreducedmax = true, debugpowercolor = true,
            debuglabels = true, debugspacing = true, petdebug = true,
            debugflags = true, oufauras = true, ufrects = true,
            loadreport = true, prof = true, pingtest = true, gates = true,
            menudiag = true,
            exportaudit = true, exportsizes = true,
        }
        if DEBUG_CMDS[cmd] and not self:IsDebugOutputEnabled() then
            print("|cffd3ff7dBuzzardFrames:|r debug output is off. Turn on"
                .. " |cffffff00Enable Experimental Options|r then"
                .. " |cffffff00Show Debug Outputs in chat|r (Preview & Special"
                .. " Options) to use debug commands.")
            return
        end
    end
    if input == "lock" then
        self:SetLocked(true)
    elseif input:match("^dev%s") or input == "dev" then
        -- Developer switches. `/bf dev panelconfig [on|off]` shows or
        -- hides the Panel Config section in the options panel; bare, it
        -- toggles. Persisted in db.global (BF:IsDevPanelConfigEnabled).
        local what, arg = input:match("^dev%s+(%S+)%s*(%S*)")
        if what == "panelconfig" then
            local on
            if arg == "on" then on = true
            elseif arg == "off" then on = false
            else on = not self:IsDevPanelConfigEnabled() end
            self:SetDevPanelConfigEnabled(on)
            print("|cffd3ff7dBuzzardFrames:|r Panel Config is now "
                .. (on and "|cff00ff00shown|r" or "|cffff8800hidden|r") .. ".")
            -- The section is a route, so an open panel re-declares its
            -- tree.
            local BFO = _G.BuzzardFramesOptions
            local P   = LibStub and LibStub("BuzzardPanel-1.0", true)
            local app = P and P.GetApp and P:GetApp("BuzzardFrames")
            if BFO and BFO.RebuildRoutes and app then BFO:RebuildRoutes(app) end
        else
            print("|cffd3ff7dBuzzardFrames:|r /bf dev panelconfig [on|off]")
        end
    elseif input == "unlock" then
        self:SetLocked(false)
    -- Perf plan §L5.1: the login phase breakdown collected by LoadTiming.lua.
    -- Works with every debug flag off (the phase boundaries are always
    -- collected). The report is far too long for the chat frame, so it opens
    -- in a copyable window by default:
    --   /bf loadreport         window
    --   /bf loadreport marks   window, every recorded mark listed
    --   /bf loadreport chat    the old chat print (accepts `chat marks`)
    -- Re-openable for the whole session -- sealing stops collection, it does
    -- not discard what was collected.
    elseif input:match("^loadreport") then
        if self.PrintLoadReport then
            self:PrintLoadReport(input:sub(11))
        else
            print("|cffd3ff7dBuzzardFrames:|r LoadTiming.lua is not loaded.")
        end
    -- v82/v83: single-buff slot mode (Target Matrix rows 3/6) — each
    -- non-Buffs-anchored single buff is ONE slot button on the shared slot
    -- host instead of a bfc container + 10-button group pool. DEFAULT ON
    -- since v83; this command is its KILL SWITCH, flipping
    -- db.global.singleBuffSlotsDisabled. Off + /reload restores the pre-v83
    -- shape and changes nothing else. (The v82 opt-in key singleBuffSlots is
    -- obsolete, read by nothing.)
    --
    -- v85: the LAST such switch. auraskip (v77 styling skip), dvmerge and
    -- fxmerge (v84 merged slots) were REMOVED — owner ruling 2026-08-16:
    -- optimizations are not gated, they are the code path. Do not add a new
    -- one without asking.
    elseif input == "sbslots" then
        local g = self.db and self.db.global
        if not g then
            print("|cffd3ff7dBuzzardFrames:|r database not ready yet.")
        else
            g.singleBuffSlotsDisabled = not g.singleBuffSlotsDisabled
            print(string.format(
                "|cffd3ff7dBuzzardFrames:|r single-buff slot mode (1-button"
                .. " slots instead of per-buff containers) is now %s."
                .. " |cffffff00/reload|r to apply (it changes what is created"
                .. " at frame build).",
                g.singleBuffSlotsDisabled and "|cffff5555OFF|r" or "|cff55ff55ON|r"))
        end
    -- Live aura rebuilds inside a keystone (see BF:IsAuraRecreateWindow in
    -- Auras/ContainerFactory.lua). Not debug-gated: the kill switch and its
    -- status must work mid-key.
    --   /bf recreate on|off    flip db.global.auraRecreateInKey
    --   /bf recreate [status]  window, queue, caps, leaks, last 10 rebuilds
    elseif input:match("^recreate") then
        local arg = input:sub(9):gsub("^%s+", "")
        local g = self.db and self.db.global
        if not g then
            print("|cffd3ff7dBuzzardFrames:|r database not ready yet.")
        elseif arg == "on" or arg == "off" then
            g.auraRecreateInKey = (arg == "on")
            print(string.format("|cffd3ff7dBuzzardFrames:|r live aura rebuilds"
                .. " inside a keystone are now %s.",
                g.auraRecreateInKey and "|cff55ff55ON|r" or "|cffff5555OFF|r"))
        elseif arg ~= "" and arg ~= "status" and arg ~= "chat" then
            print("|cffd3ff7dBuzzardFrames:|r usage: /bf recreate on||off||status||chat")
        elseif not self.AuraRecreateStatus then
            print("|cffd3ff7dBuzzardFrames:|r recreate status is unavailable.")
        else
            -- Same copyable-window pattern as /bf loadreport and /bf sbdiag
            -- (owner 2026-09-11: the chat print was far too long to read or
            -- paste). `/bf recreate chat` keeps the plain chat print.
            local st = self:AuraRecreateStatus()
            -- Same checks, same order, as BF:IsAuraRecreateWindow.
            local why = ""
            if not st.window then
                if not st.enabled then
                    why = " (switch off)"
                elseif not self:IsAuraCreationRestricted() then
                    why = " (not restricted)"
                elseif InCombatLockdown() then
                    why = " (in combat)"
                else
                    why = " (not a keystone)"
                end
            end
            local L = {}
            L[#L + 1] = string.format("recreate %s, window %s%s",
                st.enabled and "ON" or "OFF", st.window and "open" or "closed", why)
            local kinds = {}
            for kind, n in pairs(st.byKind or {}) do
                kinds[#kinds + 1] = kind .. "=" .. n
            end
            table.sort(kinds)
            L[#L + 1] = string.format("pending %d%s", st.pending or 0,
                #kinds > 0 and (" (" .. table.concat(kinds, ", ") .. ")") or "")
            L[#L + 1] = string.format("runs %d session, %d this key; leaked buttons %d",
                st.runs or 0, st.keyRuns or 0, st.leakedButtons or 0)
            local caps = st.capsUsed or {}
            L[#L + 1] = string.format("rebuilt objects: %d", #caps)
            for i = 1, #caps do
                local c = caps[i]
                L[#L + 1] = string.format("  %s %s:%s x%d%s", tostring(c.unit),
                    tostring(c.kind), tostring(c.key), c.used or 0,
                    c.reasons and ("  [" .. c.reasons .. "]") or "")
            end
            local drift = st.drift or {}
            L[#L + 1] = "loop-stopped (drift): " .. (#drift > 0 and table.concat(drift, ", ") or "none")
            local last = st.last or {}
            L[#L + 1] = string.format("last %d rebuild(s), oldest first:", #last)
            for i = 1, #last do
                local r = last[i]
                L[#L + 1] = string.format("  %s %s:%s %s %.1fms %s",
                    tostring(r.unit), tostring(r.kind), tostring(r.key),
                    tostring(r.reason), tonumber(r.ms) or 0, r.ok and "ok" or "FAIL")
            end
            local shown = false
            if arg ~= "chat" and self.ShowTextWindow then
                shown = self:ShowTextWindow("BuzzardFrames Recreate Status",
                    table.concat(L, "\n"), {
                        status = "Live aura rebuilds inside a keystone. /bf recreate chat prints this to chat instead.",
                        width = 640, height = 480,
                    })
            end
            if not shown then
                for i = 1, #L do
                    print("|cffd3ff7dBuzzardFrames:|r " .. L[i])
                end
            end
        end
    -- (Removed in v85: "/bf auraskip", "/bf dvmerge" and "/bf fxmerge".
    --  Owner ruling 2026-08-16: optimizations are not gated behind kill
    --  switches — the optimized path IS the code path. The three saved flags
    --  they wrote (db.global.auraSkipDisabled / dispelMergeDisabled /
    --  fxMergeDisabled) are cleaned once by the dbVersion-68 block in
    --  Core_DB.lua. The behavior each switch used to reveal is unchanged:
    --  the styling skip is unconditional, and the dispel/fx merges still
    --  resolve merge-vs-split from the SETTINGS, which is behavior and not a
    --  gate.)
    -- (Removed in dbVersion 17: "/bf reset" and "/bf resetptf" commands.
    --  The old reset commands operated on the monolithic parent profile,
    --  which no longer makes sense under the modular profiles model.
    --  A per-module "/bf reset <module>" replacement is deferred to the
    --  follow-up per-module management UI project.)
    -- v88b: single-buff slot state probe. Deliberately NOT in the DEBUG_CMDS
    -- gate above -- this exists to diagnose a bug that only reproduces in a
    -- raid, and requiring the two Experimental toggles first would make it
    -- useless at the moment it is needed. See BF:_DebugSingleBuffSlots in
    -- Indicators/BuffsAndContainers.lua.
    -- v88g: `/bf sbdiag` opens a copyable window (same as loadreport);
    -- `/bf sbdiag chat` keeps the plain chat print.
    -- v88j: instrumentation toggle for the single-buff slot path (the denial
    -- ledger + the creation-window traces read by /bf sbdiag). OFF by default;
    -- saved, because the evidence has to be captured during a combat /reload.
    elseif input == "slotdiag" then
        local g = self.db and self.db.global
        if not g then
            print("|cffd3ff7dBuzzardFrames:|r database not ready yet.")
        else
            g.slotDiagEnabled = not g.slotDiagEnabled
            self._slotDiag = g.slotDiagEnabled and true or false
            self._slotFails, self._slotFailFirst = nil, nil
            self._slotFailReported = nil
            print(string.format(
                "|cffd3ff7dBuzzardFrames:|r aura-slot instrumentation is now %s."
                .. " Read it with |cffffff00/bf sbdiag|r."
                .. " Creation-window traces are stamped at frame build, so"
                .. " |cffffff00/reload|r before reproducing.",
                g.slotDiagEnabled and "|cff55ff55ON|r" or "|cffff5555OFF|r"))
        end
    -- v86 DIAG (temporary — remove with the bisect): A/B for the two v86
    -- geometry change-guards. See BF:_WipeLayoutGuardCaches.
    --   /bf guardtest          refresh only, guards left in place
    --   /bf guardtest wipe     drop the guard caches, then refresh
    -- Run the plain form FIRST. Both arms end in the same RefreshAllAuras, so
    -- if the plain one already fixes the display the guards are innocent and
    -- something else needed the refresh; only a difference between the two
    -- arms implicates them.
    elseif input:match("^guardtest") then
        local arg = input:sub(10):gsub("^%s+", "")
        if arg == "wipe" then
            local n = self._WipeLayoutGuardCaches
                and self:_WipeLayoutGuardCaches() or 0
            print(string.format("|cffd3ff7dBuzzardFrames:|r dropped %d guard"
                .. " cache(s), refreshing.", n))
        else
            print("|cffd3ff7dBuzzardFrames:|r refreshing, guards left in"
                .. " place. Follow with |cffffff00/bf guardtest wipe|r.")
        end
        self:RefreshAllAuras()
    -- v88k DIAG (temporary — remove with the bisect): force every aura slot's
    -- filter string, candidate set and container unit back onto the engine,
    -- bypassing the change-guards that assume BF's cache still describes what
    -- the engine holds. See BF:_ForceSlotRepush.
    elseif input == "slotpush" then
        if not self._ForceSlotRepush then
            print("|cffd3ff7dBuzzardFrames:|r slotpush is unavailable.")
        else
            local n, fails = self:_ForceSlotRepush()
            print(string.format("|cffd3ff7dBuzzardFrames:|r re-pushed %d slot(s);"
                .. " %d denied.", n, #fails))
            for i = 1, #fails do print("   " .. fails[i]) end
        end
    -- v88l DIAG (temporary — remove with the bisect): drop the three restyle
    -- signature guards, then refresh so the walks actually re-run. See
    -- BF:_WipeStyleGuards.
    elseif input == "stylewipe" then
        if not self._WipeStyleGuards then
            print("|cffd3ff7dBuzzardFrames:|r stylewipe is unavailable.")
        else
            local nC, nB = self:_WipeStyleGuards()
            print(string.format("|cffd3ff7dBuzzardFrames:|r cleared %d container"
                .. " signature(s) and %d slot button signature(s); refreshing.",
                nC, nB))
            self:RefreshAllAuras()
        end
    -- v88n DIAG: every slot on every shared container, with its candidate set.
    -- Reads competition for an aura between siblings, which the per-slot
    -- sbdiag view cannot see. See BF:_DebugSlotRoster.
    -- v88o DIAG: add one inert slot to the live shared slot container, to test
    -- whether slot creation on a live container disturbs its existing slots.
    -- Leaks one engine button per run (slots cannot be removed) — diagnostic
    -- only. See BF:_DebugAddLiveSlot.
    -- v88r DIAG: break and remake the slot container's unit binding, which a
    -- same-unit SetUnit cannot do. See BF:_ForceSlotRebind.
    -- v88t DIAG: draw visible markers at the slot button's anchor, one
    -- frame-parented and one container-parented. `/bf slotmark [featureKey]`,
    -- default sbc4. Re-run to clear. See BF:_DebugSlotMarkers.
    elseif input:match("^slotmark") then
        if self._DebugSlotMarkers then
            self:_DebugSlotMarkers((input:match("^slotmark%s+(%S+)")))
        else
            print("|cffd3ff7dBuzzardFrames:|r slotmark is unavailable.")
        end
    -- v88s DIAG: raise the slot container above the frame's own art.
    -- `/bf slotlift [n]` — n defaults to 5. See BF:_ForceSlotLevel.
    elseif input:match("^slotlift") then
        if self._ForceSlotLevel then
            self:_ForceSlotLevel((input:match("^slotlift%s+(%d+)")))
        else
            print("|cffd3ff7dBuzzardFrames:|r slotlift is unavailable.")
        end
    elseif input == "slotkick" then
        if self._ForceSlotRebind then
            self:_ForceSlotRebind()
        else
            print("|cffd3ff7dBuzzardFrames:|r slotkick is unavailable.")
        end
    elseif input == "slottest" then
        if self._DebugAddLiveSlot then
            self:_DebugAddLiveSlot()
        else
            print("|cffd3ff7dBuzzardFrames:|r slottest is unavailable.")
        end
    -- Copy window by default, `/bf slotroster chat` for a plain print.
    elseif input:match("^slotroster") then
        if self._DebugSlotRoster then
            self:_DebugSlotRoster(input:sub(11))
        else
            print("|cffd3ff7dBuzzardFrames:|r slotroster is unavailable.")
        end
    elseif input:match("^sbdiag") then
        if self.AuraRecreateStatus then
            local st = self:AuraRecreateStatus()
            print(string.format("|cffd3ff7dBuzzardFrames:|r live aura rebuilds:"
                .. " %d this session (%d this key), %d/%d leaked buttons.",
                st.runs or 0, st.keyRuns or 0, st.leakedButtons or 0,
                st.leakBudget or 0))
        end
        if self._DebugSingleBuffSlots then
            self:_DebugSingleBuffSlots(input:sub(7))
        else
            print("|cffd3ff7dBuzzardFrames:|r sbdiag is unavailable.")
        end
    elseif input == "ufrects" then
        -- v86: bar/border rect probe (BF:_DebugUFRects, oUF_Shared.lua).
        if self._DebugUFRects then self:_DebugUFRects() end
    elseif input == "oufauras" then
        -- v85: aura-container state probe for the oUF frames (see
        -- BF:_DebugOUFAuraState in UnitFrames/oUF_Shared.lua).
        if self._DebugOUFAuraState then self:_DebugOUFAuraState() end
    elseif input == "debugreg" then
        -- Dump per-unit event frame registration state
        print("=== BuzzardFrames Registration Debug ===")
        print("IsInRaid:", IsInRaid(), "IsInGroup:", IsInGroup(), "NumMembers:", GetNumGroupMembers())
        print("mainHeader:", tostring(self.mainHeader), "shown:", self.mainHeader and tostring(self.mainHeader:IsShown()))
        local activeCount, noUnit = 0, 0
        for frame in pairs(self.activeFrames or {}) do
            if frame.unit then activeCount = activeCount + 1
            else noUnit = noUnit + 1 end
        end
        print("activeFrames with unit:", activeCount, "without unit:", noUnit)
        for i = 1, math.min(GetNumGroupMembers(), 10) do
            local unit = IsInRaid() and ("raid"..i) or (i < GetNumGroupMembers() and "party"..i or "player")
            local frame = self.unitToFrameCache and self.unitToFrameCache[unit]
            local hasPerUnit = BF._debugPerUnitFrames and BF._debugPerUnitFrames[unit] ~= nil
            print(string.format("  %s: inCache=%s frameUnit=%s perUnitReg=%s",
                unit, tostring(frame ~= nil),
                frame and tostring(frame.unit) or "nil",
                tostring(hasPerUnit)))
        end
        print("========================================")
    elseif input == "debugvis" then
        -- Print UnitIsVisible and UnitIsConnected for every current group member.
        -- Also shows seconds since last zone change so you can judge data freshness.
        print(string.format("|cffffff00BF debugvis|r  members: %d", GetNumGroupMembers()))
        local prefix = IsInRaid() and "raid" or "party"
        for i = 1, GetNumGroupMembers() do
            local unit = prefix .. i
            if UnitExists(unit) then
                local vis     = UnitIsVisible(unit)
                local conn    = UnitIsConnected(unit)
                local dead    = UnitIsDeadOrGhost(unit)
                local name    = UnitName(unit) or "?"
                local visCol  = vis  and "|cff00ff00" or "|cffff4444"
                local connCol = conn and "|cff00ff00" or "|cffff4444"
                local deadCol = dead and "|cffff4444" or "|cff888888"
                print(string.format("  %-10s %-16s  visible=%s%-5s|r  connected=%s%-5s|r  dead=%s%-5s|r",
                    unit, name,
                    visCol,  tostring(vis),
                    connCol, tostring(conn),
                    deadCol, tostring(dead)))
            end
        end
        if GetNumGroupMembers() == 0 then
            print("  (not in a group)")
        end
    elseif input == "debugcf" then
        for _, header in ipairs(self.groupsUsed or {}) do
            if header.isCustomFrame then
                local upc  = header:GetAttribute("unitsPerColumn")
                local mc   = header:GetAttribute("maxColumns")
                local pt   = header:GetAttribute("point")
                local grp  = self:GetCustomFrameGroups()[header.customGroupIndex]
                local sorting = grp and grp.flat and grp.flat.sorting
                print(string.format("|cffffff00[BF CF Debug]|r '%s' upc=%s maxCol=%s point=%s | flat.sorting.maxColumns=%s flat.sorting.unitsPerColumn=%s",
                    tostring(header.customGroupName),
                    tostring(upc), tostring(mc), tostring(pt),
                    tostring(sorting and sorting.maxColumns), tostring(sorting and sorting.unitsPerColumn)))
            end
        end
    elseif input == "debugcolor" then
        for frame in pairs(self.activeFrames) do
            if frame and frame.unit and frame.healthBar then
                local r, g, b = frame.healthBar:GetStatusBarColor()
                print(string.format("|cffffff00[BF debugcolor]|r unit=%s writer=%s tracked=%.2f,%.2f,%.2f actual=%.2f,%.2f,%.2f",
                    tostring(frame.unit),
                    tostring(frame._dbg_lastColorWriter),
                    frame._dbg_lastColorR or 0, frame._dbg_lastColorG or 0, frame._dbg_lastColorB or 0,
                    r, g, b))
            end
        end
    -- v67: the "/bf debugric" command was removed (12.1-only). It dumped the
    -- resolved RAID_IN_COMBAT secret-detection sentinel and what
    -- BF:FetchBuffData routed each aura to; both the per-unit scan and the
    -- sentinel resolution it inspected are gone from
    -- AuraCustomizations/AuraCustomizations.lua, so the command had nothing
    -- left to report. "/bf debugauras" below still dumps raw aura secrecy.
    elseif input == "debugauras" then
        -- Dump all debuffs on the player and every group member,
        -- showing spellId, name, and whether the spellId is secret.
        local _GetUnitAuras = C_UnitAuras and C_UnitAuras.GetUnitAuras
        local function dumpUnit(unit)
            if not UnitExists(unit) then return end
            local uname = UnitName(unit) or "?"
            print(string.format("|cffffff00[BF debugauras]|r %s (%s):", tostring(uname), unit))
            if not _GetUnitAuras then
                print("  (C_UnitAuras.GetUnitAuras not available)")
                return
            end
            local ok, debuffs = pcall(_GetUnitAuras, unit, "HARMFUL", 40, 0, 0)
            if not ok then
                print("  (GetUnitAuras errored: " .. tostring(debuffs) .. ")")
                return
            end
            if not debuffs or #debuffs == 0 then
                print("  (no HARMFUL auras)")
                return
            end
            for i, aura in ipairs(debuffs) do
                local sid = aura.spellId
                local aName = aura.name
                local sidSecret = issecretvalue(sid)
                local nameSecret = issecretvalue(aName)
                local canSid = canaccessvalue(sid)
                local durStr = "?"
                if aura.duration and not issecretvalue(aura.duration) then
                    durStr = string.format("%.1f", aura.duration)
                end
                print(string.format("  [%d] spellId=%s (secret=%s, access=%s) name=%s (secret=%s) dur=%s",
                    i,
                    tostring(sid), tostring(sidSecret), tostring(canSid),
                    tostring(aName), tostring(nameSecret),
                    durStr
                ))
            end
        end
        dumpUnit("player")
        local prefix = IsInRaid() and "raid" or "party"
        for i = 1, GetNumGroupMembers() do
            dumpUnit(prefix .. i)
        end
    elseif input:match("^debugflags") then
        -- Dump the CLASSIFICATION flags Blizzard's AuraUtil.ProcessAura keys on
        -- (isBossAura / IsRoleAura / IsPriorityDebuff / isRaid / isNameplateOnly)
        -- for every debuff on a unit. Uses the permissive
        -- HARMFUL|INCLUDE_NAME_PLATE_ONLY filter so nameplate-only auras -- which
        -- the "Blizzard" base filter drops -- still appear, which is exactly the
        -- set we are trying to explain. Optional unit arg:
        --   /bf debugflags            player + every group member
        --   /bf debugflags target     just the target
        --   /bf debugflags mouseover  just the mouseover unit
        --   /bf debugflags raid3      an explicit unit token
        local _GetUnitAuras = C_UnitAuras and C_UnitAuras.GetUnitAuras
        local unitArg = input:match("^debugflags%s+(%S+)")
        local function tf(v)
            if issecretvalue(v) then return "|cffaaaaaa?|r" end
            if v == true then return "|cff55ff55Y|r" end
            if v == nil or v == false then return "|cffff5555n|r" end
            return tostring(v)
        end
        local function sv(v)
            if issecretvalue(v) then return "|cffaaaaaasecret|r" end
            return tostring(v)
        end
        local function dumpUnit(unit)
            if not UnitExists(unit) then return end
            print(string.format("|cffffff00[BF debugflags]|r %s (%s):",
                tostring(UnitName(unit) or "?"), unit))
            if not _GetUnitAuras then
                print("  (C_UnitAuras.GetUnitAuras not available)"); return
            end
            local ok, auras = pcall(_GetUnitAuras, unit,
                "HARMFUL|INCLUDE_NAME_PLATE_ONLY", 40, 0, 0)
            if not ok then
                print("  (GetUnitAuras errored: " .. tostring(auras) .. ")"); return
            end
            if not auras or #auras == 0 then print("  (no debuffs)"); return end
            for i, a in ipairs(auras) do
                local role, prio
                if AuraUtil then
                    if AuraUtil.IsRoleAura then
                        local o, r = pcall(AuraUtil.IsRoleAura, a); role = o and r
                    end
                    if AuraUtil.IsPriorityDebuff then
                        local o, p = pcall(AuraUtil.IsPriorityDebuff, a.spellId); prio = o and p
                    end
                end
                print(string.format(
                    "  [%d] id=%s %s | boss=%s role=%s prio=%s raid=%s npOnly=%s",
                    i, sv(a.spellId), sv(a.name),
                    tf(a.isBossAura), tf(role), tf(prio),
                    tf(a.isRaid), tf(a.isNameplateOnly)))
            end
        end
        if unitArg then
            dumpUnit(unitArg)
        else
            dumpUnit("player")
            local prefix = IsInRaid() and "raid" or "party"
            for i = 1, GetNumGroupMembers() do dumpUnit(prefix .. i) end
        end
    -- v64: "/bf debugimportant" removed with the Important feature.
    elseif input == "debugreducedmax" then
        BF._debugReducedMax = not BF._debugReducedMax
        print("|cffffff00[BF]|r _debugReducedMax = " .. tostring(BF._debugReducedMax))
    elseif input == "debugpowercolor" then
        print("|cffffff00[BF]|r Power color debug for all active frames:")
        for frame in pairs(self.activeFrames or {}) do
            local u = frame.unit
            if u and UnitExists(u) then
                local pt, tok = UnitPowerType(u)
                local name = UnitName(u) or "?"
                local shouldShow = self.ShouldShowPowerBar and self:ShouldShowPowerBar(u, frame)
                local barObj = frame.powerBar
                local barShown = barObj and barObj:IsShown()
                local r, g, b = 0, 0, 0
                if barObj and barShown then
                    r, g, b = barObj:GetStatusBarColor()
                end
                local c = self.PowerTypeColors and tok and self.PowerTypeColors[tok]
                local matched = c and true or false
                print(string.format("  |cff00ffff%s|r (%s) pt=%s tok=%s matched=%s shouldShow=%s barShown=%s color=%.2f,%.2f,%.2f",
                    name, u, tostring(pt), tostring(tok), tostring(matched), tostring(shouldShow), tostring(barShown), r, g, b))
            end
        end
    -- Ping indicator visual test (the real ping-pin events are SecureOnly,
    -- so this fakes the indicator on an oUF unit frame):
    --   /bf pingtest                 Attack pin on the player frame
    --   /bf pingtest target assist   named unit + ping type
    --   /bf pingtest player all      cycle every ping type, 1.5s apart
    --   /bf pingtest target off      clear the pin on that unit
    --   /bf pingtest status          receiver/template diagnostics
    -- Types: attack warning assist onmyway alertthreat alertnotthreat
    -- v99: aura gate switches (see Auras/ContainerFactory.lua gate block).
    -- SESSION ONLY -- nothing is persisted; defaults are code constants.
    --   /bf gates                    status
    --   /bf gates on|off             every gate (assist4 untouched)
    --   /bf gates <name> on|off      one gate: assist suppress vehicle
    --                                cinematic visibility assist4
    elseif input:match("^gates") then
        local a, b = input:match("^gates%s+(%S+)%s*(%S*)")
        local valid = {}
        for _, k in ipairs(self.AURA_GATE_NAMES or {}) do valid[k] = true end
        if not a then
            print("|cffd3ff7dBuzzardFrames gates:|r " .. self:AuraGateStatus())
        elseif a == "on" or a == "off" then
            self:SetAuraGate("all", a == "on")
            print("|cffd3ff7dBuzzardFrames gates:|r all " .. a .. " -> " .. self:AuraGateStatus())
        elseif valid[a] and (b == "on" or b == "off") then
            self:SetAuraGate(a, b == "on")
            print("|cffd3ff7dBuzzardFrames gates:|r " .. self:AuraGateStatus())
        else
            print("|cffd3ff7dBuzzardFrames:|r usage: /bf gates [on|off] | /bf gates <assist|suppress|vehicle|cinematic|visibility|assist4> on|off")
        end
    -- v97: /bf menudiag while hovering a raid/party frame -- prints the
    -- right-click unit resolution and the unit predicates the secure menu
    -- classifier reads (debug-gated).
    elseif input == "menudiag" then
        local f = GetMouseFoci and GetMouseFoci()[1] or GetMouseFocus and GetMouseFocus()
        if not f or not f.GetAttribute or not f:GetAttribute("unit") then
            print("|cffd3ff7dBuzzardFrames:|r menudiag -- hover a unit frame first")
            return
        end
        local raw = f:GetAttribute("unit")
        local u = SecureButton_GetModifiedUnit(f, "RightButton")
        local function S(v) return issecretvalue and issecretvalue(v) and "SECRET" or tostring(v) end
        print(("|cffd3ff7dmenudiag:|r %s raw=%s rclick=%s type2=%s *type2=%s tfv2=%s")
            :format(tostring(f:GetName()), S(raw), S(u), S(f:GetAttribute("type2")),
                S(f:GetAttribute("*type2")), S(f:GetAttribute("*toggleForVehicle2"))))
        print(("|cffd3ff7dmenudiag:|r otherPet=%s vehicleUI=%s isPlayer=%s isPet=%s human=%s")
            :format(S(UnitIsOtherPlayersPet(u)), S(UnitHasVehicleUI(u)), S(UnitIsPlayer(u)),
                S(UnitIsUnit(u, "pet")), S(UnitIsHumanPlayer and UnitIsHumanPlayer(u))))
        print(("|cffd3ff7dmenudiag:|r inRaid=%s inParty=%s isSelf=%s isVehicle=%s battlePet=%s")
            :format(S(UnitInRaid(u)), S(UnitInParty(u)), S(UnitIsUnit(u, "player")),
                S(UnitIsUnit(u, "vehicle")), S(UnitIsOtherPlayersBattlePet(u))))
        print(("|cffd3ff7dmenudiag:|r canAssist=%s canAttack=%s isVisible=%s inRange=%s connected=%s")
            :format(S(UnitCanAssist("player", u)), S(UnitCanAttack("player", u)),
                S(UnitIsVisible(u)), S(UnitInRange(u)), S(UnitIsConnected(u))))
    -- /bf ufhealth: dumps the player frame's health-bar chain. Owner report
    -- 2026-09-06: after a disconnect/relog the whole health rect -- fill AND
    -- background -- was gone while the rest of the frame was fine, until a
    -- /reload. Run it BEFORE reloading next time: every line is plain frame
    -- state read back, nothing is changed. Deliberately not debug-gated so
    -- it is usable the moment the bug shows.
    elseif input == "ufhealth" then
        local f = self.oufPlayer
        if not f or not f.Health then
            print("|cffd3ff7dBuzzardFrames:|r ufhealth -- no player frame built")
            return
        end
        local function S(v) return issecretvalue and issecretvalue(v) and "SECRET" or tostring(v) end
        local function R(v) return type(v) == "number" and string.format("%.2f", v) or tostring(v) end
        local function frameLine(tag, fr)
            if not fr then
                print("|cffd3ff7dufhealth:|r " .. tag .. " = nil")
                return
            end
            local w, h = fr:GetSize()
            local pt, rel, relPt, x, y = fr:GetPoint(1)
            local relName = rel and (rel.GetName and rel:GetName() or "?") or "nil"
            print(("|cffd3ff7dufhealth:|r %s shown=%s vis=%s alpha=%s eff=%s size=%sx%s pts=%d anchor=%s->%s.%s (%s,%s) scale=%s")
                :format(tag, tostring(fr:IsShown()), tostring(fr:IsVisible()), R(fr:GetAlpha()),
                    R(fr:GetEffectiveAlpha()), R(w), R(h), fr:GetNumPoints(),
                    tostring(pt), relName, tostring(relPt), R(x), R(y), R(fr:GetEffectiveScale())))
        end
        frameLine("frame",     f)
        frameLine("container", f._oufHealthContainer)
        frameLine("clip",      f._oufHealthClipFrame)
        frameLine("Health",    f.Health)
        local hb = f.Health
        local mn, mx = hb:GetMinMaxValues()
        local r, g, b, a = hb:GetStatusBarColor()
        local fill = hb:GetStatusBarTexture()
        print(("|cffd3ff7dufhealth:|r bar min=%s max=%s value=%s color=%s,%s,%s a=%s cachedA=%s grad=%s tex=%s")
            :format(S(mn), S(mx), S(hb:GetValue()), R(r), R(g), R(b), R(a), R(f._bf_healthA),
                tostring(f._bf_healthGradient), tostring(fill and fill:GetTexture())))
        if fill then
            local fw, fh = fill:GetSize()
            local vr, vg, vb, va = fill:GetVertexColor()
            print(("|cffd3ff7dufhealth:|r fill shown=%s size=%sx%s vertex=%s,%s,%s,%s masks=%d layer=%s")
                :format(tostring(fill:IsShown()), R(fw), R(fh), R(vr), R(vg), R(vb), R(va),
                    fill:GetNumMaskTextures(), tostring(fill:GetDrawLayer())))
        end
        local bg = f._oufHealthBg
        if bg then
            local bw, bh = bg:GetSize()
            local br, bgg, bb, ba = bg:GetVertexColor()
            print(("|cffd3ff7dufhealth:|r bg shown=%s size=%sx%s alpha=%s vertex=%s,%s,%s,%s masks=%d")
                :format(tostring(bg:IsShown()), R(bw), R(bh), R(bg:GetAlpha()),
                    R(br), R(bgg), R(bb), R(ba), bg:GetNumMaskTextures()))
        end
        local m = f._oufIconCutoutMask
        if m then
            local mw, mh = m:GetSize()
            print(("|cffd3ff7dufhealth:|r iconCutoutMask shown=%s size=%sx%s tex=%s")
                :format(tostring(m:IsShown()), R(mw), R(mh), tostring(m:GetTexture())))
        end
        print(("|cffd3ff7dufhealth:|r alt eligible=%s active=%s band=%s drawn=%s powerH=%s spec=%s ptype=%s class=%s")
            :format(tostring(self.IsAltPowerBarEligible and self:IsAltPowerBarEligible()),
                tostring(self.IsAltPowerBarActive and self:IsAltPowerBarActive()),
                tostring(self.GetOUFPlayerHealthBandHeight and self:GetOUFPlayerHealthBandHeight()),
                tostring(self.GetOUFPlayerHealthDrawnHeight and self:GetOUFPlayerHealthDrawnHeight()),
                tostring(self.GetPowerBarEffectiveHeight and self:GetPowerBarEffectiveHeight()),
                tostring(GetSpecialization and GetSpecialization()), S(UnitPowerType("player")),
                tostring(select(2, UnitClass("player")))))
    elseif input:match("^pingtest") then
        local unit, typ = input:match("^pingtest%s+(%S+)%s*(%S*)")
        unit = (unit or "player"):lower()
        typ  = (typ ~= "" and typ or "attack"):lower()
        local TYPES = {
            { "attack", "Attack" }, { "warning", "Warning" },
            { "assist", "Assist" }, { "onmyway", "OnMyWay" },
            { "alertthreat", "AlertThreat" }, { "alertnotthreat", "AlertNotThreat" },
        }
        local function kitFor(enumName)
            -- Prefer the client's own texture kit mapping; fall back to the
            -- enum name, which is what the kits are named on 12.x.
            local ok, kit
            if C_Ping and C_Ping.GetTextureKitForType and Enum.PingSubjectType then
                ok, kit = pcall(C_Ping.GetTextureKitForType, Enum.PingSubjectType[enumName])
            end
            return (ok and type(kit) == "string" and kit ~= "") and kit or enumName
        end
        local function fire(kit)
            local ok, err = self:DebugFakePing(unit, kit)
            if not ok then
                print("|cffd3ff7dBuzzardFrames:|r pingtest -- " .. tostring(err))
            elseif kit then
                print("|cffd3ff7dBuzzardFrames:|r pingtest " .. unit
                    .. " -> Ping_Frame_" .. kit)
            else
                print("|cffd3ff7dBuzzardFrames:|r pingtest " .. unit .. " cleared")
            end
            return ok
        end
        if unit == "status" or typ == "status" then
            if unit == "status" then unit = "player" end
            local ok, info = self:DebugFakePing(unit, "status")
            print("|cffd3ff7dBuzzardFrames:|r pingtest " .. tostring(info))
        elseif typ == "off" or typ == "clear" then
            fire(nil)
        elseif typ == "all" then
            local i = 0
            local function step()
                i = i + 1
                local t = TYPES[i]
                if not t then fire(nil); return end
                if fire(kitFor(t[2])) then C_Timer.After(1.5, step) end
            end
            step()
        else
            local enumName
            for _, t in ipairs(TYPES) do
                if t[1] == typ then enumName = t[2] break end
            end
            if not enumName then
                print("|cffd3ff7dBuzzardFrames:|r pingtest -- unknown type '" .. typ
                    .. "'. Use: attack warning assist onmyway alertthreat"
                    .. " alertnotthreat all off")
            else
                fire(kitFor(enumName))
            end
        end
    elseif input == "debugspacing" then
        self:DebugSpacing()
    elseif input == "petdebug" then
        self:DebugPetHeader()
    elseif input == "debuglabels" then
        local p = self.db.profile
        print("showGroupLabels:", p.showGroupLabels)
        print("IsInRaid:", IsInRaid())
        if not self.mainHeader and not self.groupHeaders then print("NO HEADER"); return end
        local count = 0
        self:IterateHeaderChildren(function(frame)
            local top = frame:GetTop()
            local shown = frame:IsVisible()
            local unit = frame.unit
            local raidIndex = unit and UnitInRaid(unit)
            local subgroup = raidIndex and select(2, GetRaidRosterInfo(raidIndex))
            if unit then
                count = count + 1
                print(string.format("  unit=%s shown=%s top=%s raidIdx=%s sg=%s",
                    tostring(unit), tostring(shown), tostring(top),
                    tostring(raidIndex), tostring(subgroup)))
            end
        end)
        print("Total frames with unit:", count)
    elseif input == "exportaudit" then
        -- Phase E (ProfileExport.lua): classify every top-level profile key
        -- of every module against the export registry's whitelists. WARN
        -- lines are unregistered keys that would silently not export.
        if self.AuditExportCompleteness then self:AuditExportCompleteness(true) end
    elseif input == "exportsizes" then
        -- Phase 0 / Phase E measurement: per-module serialized bytes,
        -- raw profile vs the registry's sparse build.
        if self.ReportModuleExportSizes then self:ReportModuleExportSizes() end
    else
        -- `/bf panel` and bare `/bf` land here too.
        -- The options panel: BuzzardFramesOptions, loaded on demand by the
        -- bridge (Core_OptionsBridge.lua), which is the one place that
        -- knows which panel is behind this call.
        self:OpenOptions()
    end
end

