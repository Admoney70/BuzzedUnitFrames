-- ============================================================================
-- MenuModes.lua -- runtime switch for the right-click unit menu path
--
-- WHY THIS EXISTS
--
-- In 12.0.0 Blizzard rewrote SecureUnitButton_OnLoad. It used to do:
--
--     self:SetAttribute("*type2", "togglemenu")
--     self.menu = menufunc
--
-- and it now does:
--
--     self:SetAttribute("*type2", "menu")
--     self:SetAttribute("menu-function", menufunc)
--
-- Those two attribute values run COMPLETELY DIFFERENT menu-type selectors.
--
--   *type2 = "menu"        -> SECURE_ACTIONS.menu, which calls whatever
--                             function is stored in the "menu-function"
--                             attribute. Blizzard's own frames store
--                             CompactUnitFrame_OpenMenu there.
--
--   *type2 = "togglemenu"  -> SECURE_ACTIONS.togglemenu, which picks the
--                             menu type itself. Blizzard's comment on it in
--                             SecureTemplates.lua reads:
--                               "Unused by Blizzard code but retained because
--                                the type attribute can be set from addons."
--
-- The togglemenu ladder has two branches that CompactUnitFrame_OpenMenu does
-- not have, and it checks them BEFORE the player check:
--
--     elseif UnitIsOtherPlayersBattlePet(unit) then which = "OTHERBATTLEPET"
--     elseif UnitIsOtherPlayersPet(unit)       then which = "OTHERPET"
--     elseif UnitIsPlayer(unit)                then ... RAID_PLAYER / PARTY
--
-- It also has a "party" fast path but NO "raid" fast path, so a party1 token
-- short-circuits safely while a raid5 token falls all the way through into
-- those pet branches.
--
-- OTHERBATTLEPET is a 4-entry menu whose first entry is "Show in Pet Journal".
-- It is the only menu in the client that is both 4 options and has a Pet
-- Journal entry, and SECURE_ACTIONS.togglemenu is the only place in the entire
-- 12.1 client that can produce it.
--
-- This file does not pick a winner. It lets you switch the path at runtime and
-- try each one against a live repro.
--
-- USAGE:  /bfmenu
-- ============================================================================

local ADDON, ns = ...
local BF = _G.BuzzardFrames or ns.BF or BuzzardFrames
if not BF then return end

local InCombatLockdown       = InCombatLockdown
local UnitIsUnit             = UnitIsUnit
local UnitIsPlayer           = UnitIsPlayer
local UnitInRaid             = UnitInRaid
local UnitInParty            = UnitInParty
local UnitExists             = UnitExists

local PREFIX = "|cff11ace9Buzzard Frames|r |cffaaaaaa[menu]|r "

local function Print(fmt, ...)
	local msg = (select("#", ...) > 0) and fmt:format(...) or fmt
	print(PREFIX .. msg)
end

-- Any 12.x unit API can hand back a "secret value". Reading one is fine;
-- doing almost anything WITH one (tostring, compare, concat) raises an
-- immediate Lua error in tainted code. Everything below that touches a
-- return value goes through these two.
local function SafeStr(v)
	local ok, s = pcall(tostring, v)
	if not ok then return "|cffff7f00<secret>|r" end
	return s
end

-- Truthiness test that cannot blow up on a secret boolean.
local function SafeTruthy(v)
	local ok, res = pcall(function() return not not v end)
	if not ok then return nil end -- nil == "couldn't tell, it was secret"
	return res
end

-- ============================================================================
-- Saved state
-- ============================================================================

local DEFAULT_MODE    = "legacy"
local DEFAULT_VEHICLE = "default"

local function DB()
	if type(BuzzardFramesMenuModeDB) ~= "table" then
		BuzzardFramesMenuModeDB = {}
	end
	local db = BuzzardFramesMenuModeDB
	if db.mode    == nil then db.mode    = DEFAULT_MODE    end
	if db.vehicle == nil then db.vehicle = DEFAULT_VEHICLE end
	return db
end

-- ============================================================================
-- Mode 3 selector -- token-first
--
-- The premise of modes 1 and 2 is that the unit APIs answer correctly. This
-- one assumes they might not, for a unit the client has no local object for,
-- and trusts the unit TOKEN instead: a "raid5" token is a raid member by
-- definition, whatever UnitIsPlayer/UnitIsOtherPlayersBattlePet say about it.
--
-- Only UnitIsUnit(unit, "player"/"pet") is consulted, and only for units where
-- the comparison is documented as permitted.
-- ============================================================================

local function BF_OpenUnitMenu_Token(frame, unit, button, isKeyPress)
	if not unit then return end
	unit = unit:lower()

	local which

	if unit == "player" or SafeTruthy(UnitIsUnit(unit, "player")) then
		which = "SELF"
	elseif unit == "pet" or SafeTruthy(UnitIsUnit(unit, "pet")) then
		which = "PET"
	elseif unit:match("^raidpet%d+$") or unit:match("^partypet%d+$") then
		which = "OTHERPET"
	elseif unit:match("^raid%d+$") then
		which = "RAID_PLAYER"
	elseif unit == "party" or unit:match("^party%d+$") then
		which = "PARTY"
	elseif unit:match("^boss%d+$") then
		which = "BOSS"
	elseif unit == "focus" then
		which = "FOCUS"
	elseif unit:match("^arena%d+$") then
		which = "ARENAENEMY"
	elseif SafeTruthy(UnitIsPlayer(unit)) then
		which = "PLAYER"
	else
		which = "TARGET"
	end

	if which then
		UnitPopup_OpenMenu(which, { unit = unit })
	end
end

-- ============================================================================
-- Modes
--
-- apply(frame) runs on every secure unit button, both existing ones on a mode
-- switch and newly created header children.
-- ============================================================================

local MODES = {
	legacy = {
		order = 1,
		label = "legacy",
		desc  = "*type2 = \"togglemenu\"  (what the addon ships today)",
		apply = function(frame)
			frame:SetAttribute("menu-function", nil)
			frame:SetAttribute("*type2", "togglemenu")
		end,
	},

	blizzard = {
		order = 2,
		label = "blizzard",
		desc  = "*type2 = \"menu\" + CompactUnitFrame_OpenMenu  (identical to an untouched Blizzard raid frame)",
		apply = function(frame)
			frame:SetAttribute("menu-function", CompactUnitFrame_OpenMenu)
			frame:SetAttribute("*type2", "menu")
		end,
	},

	token = {
		order = 3,
		label = "token",
		desc  = "*type2 = \"menu\" + Buzzard token-first selector  (ignores the unit APIs, trusts the raidN/partyN token)",
		apply = function(frame)
			frame:SetAttribute("menu-function", BF_OpenUnitMenu_Token)
			frame:SetAttribute("*type2", "menu")
		end,
	},
}

local MODE_ORDER = { "legacy", "blizzard", "token" }

-- Numeric aliases so "/bfmenu 2" works.
local MODE_BY_NUMBER = {}
for i, key in ipairs(MODE_ORDER) do MODE_BY_NUMBER[tostring(i)] = key end

-- ----------------------------------------------------------------------------
-- Independent vehicle-swap override.
--
-- SecureButton_GetModifiedUnit rewrites raid5 -> raidpet5 when the frame
-- carries toggleForVehicle and UnitHasVehicleUI(unit) is true. That attribute
-- is set by essentially every unit-frame addon and by NO Blizzard code anywhere
-- in 12.1 -- it is the one other asymmetry between an addon frame and a default
-- one. A swapped token also defeats the togglemenu "party" fast path, because
-- "partypet1" no longer matches unitType == "party".
--
-- This is orthogonal to the mode, so it gets its own switch.
-- ----------------------------------------------------------------------------

local VEHICLE_MODES = {
	["default"] = function(frame)
		-- Hand control back to the header/SECURE_INIT values: useparent on,
		-- no local override, and the existing v91 per-button opt-out kept.
		frame:SetAttribute("useparent-toggleForVehicle", true)
		frame:SetAttribute("toggleForVehicle", nil)
		frame:SetAttribute("*toggleForVehicle2", false)
	end,
	["off"] = function(frame)
		frame:SetAttribute("useparent-toggleForVehicle", false)
		frame:SetAttribute("toggleForVehicle", false)
		frame:SetAttribute("*toggleForVehicle2", false)
	end,
	["on"] = function(frame)
		frame:SetAttribute("useparent-toggleForVehicle", true)
		frame:SetAttribute("toggleForVehicle", true)
		frame:SetAttribute("*toggleForVehicle2", nil)
	end,
}

-- ============================================================================
-- Frame collection
-- ============================================================================

local UNIT_FRAME_NAMES = {
	"BuzzardFrames_oUFPlayer",
	"BuzzardFrames_oUFTarget",
	"BuzzardFrames_oUFTargetOfTarget",
	"BuzzardFrames_oUFFocus",
	"BuzzardFrames_oUFFocusTarget",
	"BuzzardFrames_oUFPet",
}

local function IsSecureUnitButton(f)
	if type(f) ~= "table" or not f.GetAttribute or not f.SetAttribute then return false end
	local ok, t2 = pcall(f.GetAttribute, f, "*type2")
	if not ok then return false end
	return t2 == "togglemenu" or t2 == "menu"
end

-- Collect every frame that owns a right-click menu binding: header children,
-- the oUF unit frames, and the separate portrait-icon buttons those frames
-- parent (oUF_Shared.lua creates them as their own SecureUnitButtonTemplate).
local function CollectFrames()
	local out, seen = {}, {}

	local function add(f)
		if f and not seen[f] and IsSecureUnitButton(f) then
			seen[f] = true
			out[#out + 1] = f
		end
	end

	local function addWithChildren(f)
		if type(f) ~= "table" or not f.GetChildren then return end
		add(f)
		local ok, children = pcall(function() return { f:GetChildren() } end)
		if ok then
			for _, child in ipairs(children) do add(child) end
		end
	end

	for _, frame in pairs(BF.registeredFrames or {}) do
		addWithChildren(frame)
	end

	for _, name in ipairs(UNIT_FRAME_NAMES) do
		addWithChildren(_G[name])
	end

	for i = 1, 8 do
		addWithChildren(_G["BuzzardFrames_oUFBoss" .. i])
	end

	return out
end

-- ============================================================================
-- Apply
-- ============================================================================

local pendingApply = false

local function ApplyToFrame(frame)
	local db = DB()
	local mode = MODES[db.mode] or MODES[DEFAULT_MODE]
	local veh  = VEHICLE_MODES[db.vehicle] or VEHICLE_MODES[DEFAULT_VEHICLE]
	pcall(veh, frame)
	pcall(mode.apply, frame)
end

local function ApplyAll(quiet)
	if InCombatLockdown() then
		pendingApply = true
		if not quiet then
			Print("in combat -- will apply when combat ends.")
		end
		return false
	end

	local frames = CollectFrames()
	for _, frame in ipairs(frames) do
		ApplyToFrame(frame)
	end

	if not quiet then
		local db = DB()
		Print("mode |cffffff00%s|r, vehicle swap |cffffff00%s|r -- applied to %d frame%s.",
			db.mode, db.vehicle, #frames, #frames == 1 and "" or "s")
	end
	return true
end

-- New header children are created by SecureGroupHeader_Update and land in
-- BF:RegisterFrame via the header's initialConfigFunction CallMethod. Hook it
-- so a frame created after a mode switch does not silently keep the old path.
local origRegisterFrame = BF.RegisterFrame
if type(origRegisterFrame) == "function" then
	BF.RegisterFrame = function(self, frame, ...)
		local r = origRegisterFrame(self, frame, ...)
		if frame and not InCombatLockdown() then
			local db = DB()
			if db.mode ~= DEFAULT_MODE or db.vehicle ~= DEFAULT_VEHICLE then
				ApplyToFrame(frame)
				local ok, children = pcall(function() return { frame:GetChildren() } end)
				if ok then
					for _, child in ipairs(children) do
						if IsSecureUnitButton(child) then ApplyToFrame(child) end
					end
				end
			end
		elseif frame then
			pendingApply = true
		end
		return r
	end
end

local watcher = CreateFrame("Frame")
watcher:RegisterEvent("PLAYER_REGEN_ENABLED")
watcher:RegisterEvent("PLAYER_ENTERING_WORLD")
watcher:SetScript("OnEvent", function(_, event)
	local db = DB()
	if event == "PLAYER_ENTERING_WORLD" then
		if db.mode ~= DEFAULT_MODE or db.vehicle ~= DEFAULT_VEHICLE then
			C_Timer.After(2, function() ApplyAll(true) end)
		end
		return
	end
	if pendingApply then
		pendingApply = false
		ApplyAll()
	end
end)

-- ============================================================================
-- Diagnostic
-- ============================================================================

local function GetFrameUnderCursor()
	local f
	if GetMouseFoci then
		local foci = GetMouseFoci()
		for _, candidate in ipairs(foci or {}) do
			if IsSecureUnitButton(candidate) then f = candidate break end
			f = f or candidate
		end
	elseif GetMouseFocus then
		f = GetMouseFocus()
	end
	return f
end

local function Diagnose()
	local frame = GetFrameUnderCursor()
	if not frame then
		Print("no frame under the cursor. Hover a raid frame and run |cffffff00/bfmenu diag|r again.")
		return
	end

	local name = (frame.GetName and frame:GetName()) or "<unnamed>"
	local attrUnit = frame.GetAttribute and frame:GetAttribute("unit")
	local modUnit  = attrUnit and SecureButton_GetModifiedUnit(frame, "RightButton")

	Print("---- |cffffff00%s|r ----", name)
	Print("  *type2 ............. %s", SafeStr(frame:GetAttribute("*type2")))
	Print("  menu-function ...... %s", frame:GetAttribute("menu-function") and "|cff00ff00set|r" or "|cffff5555nil|r")
	Print("  unit attribute ..... %s", SafeStr(attrUnit))
	Print("  modified unit ...... %s%s", SafeStr(modUnit),
		(modUnit and attrUnit and modUnit ~= attrUnit) and "  |cffff5555<-- REWRITTEN|r" or "")
	Print("  toggleForVehicle ... %s   (*toggleForVehicle2: %s)",
		SafeStr(frame:GetAttribute("toggleForVehicle")),
		SafeStr(frame:GetAttribute("*toggleForVehicle2")))

	local u = modUnit or attrUnit
	if not u or not UnitExists(u) then
		Print("  |cffff5555no live unit on this frame.|r")
		return
	end

	Print("  ---- unit API answers for |cffffff00%s|r ----", SafeStr(u))
	Print("    UnitInOtherParty ............. %s", SafeStr(UnitInOtherParty and UnitInOtherParty(u)))
	Print("    UnitIsOtherPlayersBattlePet .. %s%s",
		SafeStr(UnitIsOtherPlayersBattlePet and UnitIsOtherPlayersBattlePet(u)),
		SafeTruthy(UnitIsOtherPlayersBattlePet and UnitIsOtherPlayersBattlePet(u))
			and "  |cffff5555<-- this is the culprit|r" or "")
	Print("    UnitIsOtherPlayersPet ........ %s", SafeStr(UnitIsOtherPlayersPet and UnitIsOtherPlayersPet(u)))
	Print("    UnitIsPlayer ................. %s", SafeStr(UnitIsPlayer(u)))
	Print("    UnitIsHumanPlayer ............ %s", SafeStr(UnitIsHumanPlayer and UnitIsHumanPlayer(u)))
	Print("    UnitInRaid ................... %s", SafeStr(UnitInRaid(u)))
	Print("    UnitInParty .................. %s", SafeStr(UnitInParty(u)))
	Print("    UnitHasVehicleUI ............. %s", SafeStr(UnitHasVehicleUI and UnitHasVehicleUI(u)))
	Print("    UnitIsUnit(unit,\"pet\") ........ %s", SafeStr(UnitIsUnit(u, "pet")))
	Print("    UnitIsUnit(unit,\"player\") ..... %s", SafeStr(UnitIsUnit(u, "player")))

	if C_Secrets then
		Print("  ---- secret restrictions ----")
		Print("    HasSecretRestrictions ........ %s", SafeStr(C_Secrets.HasSecretRestrictions and C_Secrets.HasSecretRestrictions()))
		local ok, v = pcall(C_Secrets.ShouldUnitIdentityBeSecret, u)
		Print("    ShouldUnitIdentityBeSecret ... %s", ok and SafeStr(v) or "|cffff7f00<blocked>|r")
		local ok2, v2 = pcall(C_Secrets.CanCompareUnitTokens, u, "player")
		Print("    CanCompareUnitTokens(u,player) %s", ok2 and SafeStr(v2) or "|cffff7f00<blocked>|r")
	end
end

-- ============================================================================
-- Slash command
-- ============================================================================

local function ShowStatus()
	local db = DB()
	Print("current mode: |cffffff00%s|r  --  %s", db.mode, (MODES[db.mode] or MODES[DEFAULT_MODE]).desc)
	Print("vehicle swap: |cffffff00%s|r", db.vehicle)
end

local function ShowHelp()
	Print("|cffffff00/bfmenu|r -- switch the right-click unit menu path")
	print(" ")
	for i, key in ipairs(MODE_ORDER) do
		local m = MODES[key]
		print(("   |cff11ace9/bfmenu %d|r  or  |cff11ace9/bfmenu %s|r"):format(i, key))
		print(("       %s"):format(m.desc))
	end
	print(" ")
	print("   |cff11ace9/bfmenu vehicle on|off|default|r")
	print("       force the raidN -> raidpetN vehicle swap on or off, independent of mode")
	print("   |cff11ace9/bfmenu diag|r")
	print("       dump every attribute and unit-API answer for the frame under the cursor")
	print("   |cff11ace9/bfmenu status|r    current settings")
	print("   |cff11ace9/bfmenu reset|r     back to shipping defaults")
	print(" ")
	print("|cffaaaaaaSettings persist across /reload. To test: get a group member into a")
	print("different instance to you, right-click their raid frame, switch mode, repeat.|r")
end

SLASH_BFMENU1 = "/bfmenu"
SlashCmdList.BFMENU = function(msg)
	local db = DB()
	msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	local cmd, rest = msg:match("^(%S*)%s*(.-)$")

	if cmd == "" or cmd == "help" or cmd == "?" then
		ShowHelp()
		print(" ")
		ShowStatus()
		return
	end

	if cmd == "status" then
		ShowStatus()
		return
	end

	if cmd == "diag" or cmd == "diagnose" then
		Diagnose()
		return
	end

	if cmd == "reset" then
		db.mode, db.vehicle = DEFAULT_MODE, DEFAULT_VEHICLE
		ApplyAll()
		return
	end

	if cmd == "vehicle" then
		if not VEHICLE_MODES[rest] then
			Print("usage: |cffffff00/bfmenu vehicle on|off|default|r  (currently: %s)", db.vehicle)
			return
		end
		db.vehicle = rest
		ApplyAll()
		return
	end

	local key = MODE_BY_NUMBER[cmd] or (MODES[cmd] and cmd)
	if key then
		db.mode = key
		ApplyAll()
		Print("%s", MODES[key].desc)
		return
	end

	Print("unknown option |cffff5555%s|r -- try |cffffff00/bfmenu|r", cmd)
end

-- Re-assert the saved mode once the frames exist.
C_Timer.After(5, function()
	local db = DB()
	if db.mode ~= DEFAULT_MODE or db.vehicle ~= DEFAULT_VEHICLE then
		ApplyAll(true)
	end
end)
