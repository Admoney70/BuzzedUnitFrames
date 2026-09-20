--[[
Name: LibSharedMedia-3.0
Revision: $Revision: 130 $
Author: Elkano (elkano@gmx.de)
Website: http://www.wowace.com/projects/libsharedmedia-3-0/
SVN: svn://svn.wowace.com/wow/libsharedmedia-3-0/mainline/trunk
Description: Shared handling of media data (fonts, sounds, textures, ...) between addons.
Dependencies: LibStub, CallbackHandler-1.0
License: LGPL v2.1
]]

local MAJOR, MINOR = "LibSharedMedia-3.0", 8000002 -- 8.0.1
local lib = LibStub:NewLibrary(MAJOR, MINOR)

if not lib then return end

local _G = getfenv(0)

local pairs		= _G.pairs
local type		= _G.type

local band			= _G.bit.band

local table_insert	= _G.table.insert
local table_sort	= _G.table.sort

local locale = GetLocale()
local LOCALE_MASK = 0
if locale == "koKR" then
	LOCALE_MASK = 1
elseif locale == "frFR" then
	LOCALE_MASK = 2
elseif locale == "deDE" then
	LOCALE_MASK = 4
elseif locale == "zhCN" then
	LOCALE_MASK = 8
elseif locale == "zhTW" then
	LOCALE_MASK = 16
elseif locale == "esES" then
	LOCALE_MASK = 32
elseif locale == "esMX" then
	LOCALE_MASK = 64
elseif locale == "ruRU" then
	LOCALE_MASK = 128
elseif locale == "ptBR" then
	LOCALE_MASK = 256
elseif locale == "itIT" then
	LOCALE_MASK = 512
end

local CallbackHandler = LibStub:GetLibrary("CallbackHandler-1.0")

lib.callbacks	= lib.callbacks		or CallbackHandler:New(lib)

lib.DefaultMedia	= lib.DefaultMedia	or {}
lib.MediaList		= lib.MediaList		or {}
lib.MediaTable		= lib.MediaTable	or {}
lib.MediaType		= lib.MediaType		or {}
lib.OverrideMedia	= lib.OverrideMedia	or {}

local defaultMedia	= lib.DefaultMedia
local mediaList		= lib.MediaList
local mediaTable	= lib.MediaTable
local overrideMedia	= lib.OverrideMedia

-- create mediatype if it doesn't exist yet
-- set-up defaultMedia for each mediatype
local function createMediaType(mediaType)
	if not mediaTable[mediaType] then
		mediaTable[mediaType] = {}
	end
	if not mediaList[mediaType] then
		mediaList[mediaType] = {}
	end
	if not defaultMedia[mediaType] then
		local key = "Default"
		if mediaType == "font" then
			local font, height, flags = _G.GameFontNormal:GetFont()
			if font and height and flags then
				defaultMedia[mediaType] = {font, height, flags}
			end
		elseif mediaType == "sound" then
			-- no default sound
		else
			defaultMedia[mediaType] = {[[Interface\Buttons\WHITE8X8]]}
		end
	end
end

-- Register a new media
function lib:Register(mediaType, key, data, langmask)
	if type(mediaType) ~= "string" then
		error(MAJOR..":Register(mediaType, key, data, langmask) - mediaType must be string, got "..type(mediaType))
	end
	if type(key) ~= "string" then
		error(MAJOR..":Register(mediaType, key, data, langmask) - key must be string, got "..type(key))
	end
	if type(data) ~= "string" and type(data) ~= "table" then
		error(MAJOR..":Register(mediaType, key, data, langmask) - data must be string or table, got "..type(data))
	end
	mediaType = mediaType:lower()
	
	if langmask then
		if band(langmask, LOCALE_MASK) == 0 then
			return false
		end
	end
	
	createMediaType(mediaType)
	
	if type(data) == "table" then
		if mediaType == "font" and (#data == 1 or #data == 3) then
			if #data == 1 then
				data = {data[1], [[Fonts\FRIZQT__.TTF]], 12, ""}
			end
		end
	end
	
	if not mediaTable[mediaType][key] then
		mediaTable[mediaType][key] = data
		table_insert(mediaList[mediaType], key)
		table_sort(mediaList[mediaType])
		lib.callbacks:Fire("LibSharedMedia_Registered", mediaType, key)
		return true
	end
	return false
end

-- Return hash of all registered media of given type
function lib:HashTable(mediaType)
	mediaType = mediaType:lower()
	return mediaTable[mediaType]
end

-- Return a list of all registered media of given type
function lib:List(mediaType)
	mediaType = mediaType:lower()
	return mediaList[mediaType]
end

-- Check if a mediaType is registered
function lib:IsValid(mediaType, key)
	mediaType = mediaType:lower()
	return (mediaTable[mediaType] and mediaTable[mediaType][key]) and true or false
end

-- Fetch a media
function lib:Fetch(mediaType, key, noDefault)
	mediaType = mediaType:lower()
	
	local result = (mediaTable[mediaType] and mediaTable[mediaType][key]) or (not noDefault and defaultMedia[mediaType])
	
	if result and mediaType == "sound" then
		-- FIXME path or path+file?
	end
	
	return result
end

-- Set the default media for a type
function lib:SetDefault(mediaType, key)
	mediaType = mediaType:lower()
	if mediaTable[mediaType] and mediaTable[mediaType][key] and not overrideMedia[mediaType] then
		defaultMedia[mediaType] = mediaTable[mediaType][key]
		lib.callbacks:Fire("LibSharedMedia_SetGlobal", mediaType, key)
	end
end

function lib:GetGlobal(mediaType)
	mediaType = mediaType:lower()
	return overrideMedia[mediaType] or defaultMedia[mediaType]
end

function lib:SetGlobal(mediaType, key)
	mediaType = mediaType:lower()
	if mediaTable[mediaType] and mediaTable[mediaType][key] then
		overrideMedia[mediaType] = mediaTable[mediaType][key]
		lib.callbacks:Fire("LibSharedMedia_SetGlobal", mediaType, key)
	end
end

-- List of ready-made media types
lib.MediaType.background	= "background"		-- background textures
lib.MediaType.border		= "border"			-- border textures
lib.MediaType.font			= "font"			-- fonts
lib.MediaType.statusbar		= "statusbar"		-- statusbar textures
lib.MediaType.sound			= "sound"			-- sound files

-- DEPRECATED
lib.MediaType.BACKGROUND	= "background"
lib.MediaType.BORDER		= "border"
lib.MediaType.FONT			= "font"
lib.MediaType.STATUSBAR		= "statusbar"
lib.MediaType.SOUND			= "sound"

-- populate lib with default Blizzard data
-- BACKGROUND
lib:Register("background", "Blizzard Dialog Background", [[Interface\DialogFrame\UI-DialogBox-Background]])
lib:Register("background", "Blizzard Dialog Background Dark", [[Interface\DialogFrame\UI-DialogBox-Background-Dark]])
lib:Register("background", "Blizzard Dialog Background Gold", [[Interface\DialogFrame\UI-DialogBox-Gold-Background]])
lib:Register("background", "Blizzard Low Health", [[Interface\FullScreenTextures\LowHealth]])
lib:Register("background", "Blizzard Marble", [[Interface\FrameGeneral\UI-Background-Marble]])
lib:Register("background", "Blizzard Out of Control", [[Interface\FullScreenTextures\OutOfControl]])
lib:Register("background", "Blizzard Parchment", [[Interface\AchievementFrame\UI-Achievement-Parchment-Horizontal]])
lib:Register("background", "Blizzard Parchment 2", [[Interface\AchievementFrame\UI-GuildAchievement-Parchment-Horizontal]])
lib:Register("background", "Blizzard Rock", [[Interface\FrameGeneral\UI-Background-Rock]])
lib:Register("background", "Blizzard Tabard Background", [[Interface\TabardFrame\TabardFrameBackground]])
lib:Register("background", "Blizzard Tooltip", [[Interface\Tooltips\UI-Tooltip-Background]])
lib:Register("background", "Solid", [[Interface\Buttons\WHITE8X8]])

-- BORDER
-- added in 3.0.2
lib:Register("border", "Blizzard Achievement Wood", [[Interface\AchievementFrame\UI-Achievement-WoodBorder]])
lib:Register("border", "Blizzard Chat Bubble", [[Interface\Tooltips\ChatBubble-Backdrop]])
lib:Register("border", "Blizzard Dialog", [[Interface\DialogFrame\UI-DialogBox-Border]])
lib:Register("border", "Blizzard Dialog Gold", [[Interface\DialogFrame\UI-DialogBox-Gold-Border]])
lib:Register("border", "Blizzard Party", [[Interface\CHARACTERFRAME\UI-Party-Border]])
lib:Register("border", "Blizzard Tooltip", [[Interface\Tooltips\UI-Tooltip-Border]])
-- tooltip border texture didn't exist before 3.0
lib:SetDefault("border", "Blizzard Tooltip")

-- FONT
lib:Register("font", "Friz Quadrata TT", [[Fonts\FRIZQT__.TTF]])

if locale == "koKR" then
	lib:Register("font", "2002",			[[Fonts\2002.TTF]],			LOCALE_MASK)
	lib:Register("font", "2002 Bold",		[[Fonts\2002B.TTF]],		LOCALE_MASK)
	lib:Register("font", "AR CrystalzcuheiGBK",	[[Fonts\ARHei.ttf]],	LOCALE_MASK)
	lib:Register("font", "AR ZhongkaiGBK Medium (Combat)", [[Fonts\ARKai_C.ttf]],LOCALE_MASK)
	lib:Register("font", "AR ZhongkaiGBK Medium", [[Fonts\ARKai_T.ttf]],		LOCALE_MASK)
elseif locale == "zhCN" then
	lib:Register("font", "AR CrystalzcuheiGBK",		[[Fonts\ARHei.ttf]],		LOCALE_MASK)
	lib:Register("font", "AR ZhongkaiGBK Medium (Combat)", [[Fonts\ARKai_C.ttf]],	LOCALE_MASK)
	lib:Register("font", "AR ZhongkaiGBK Medium",	[[Fonts\ARKai_T.ttf]],		LOCALE_MASK)
elseif locale == "zhTW" then
	lib:Register("font", "AR CrystalzcuheiGBK",		[[Fonts\ARHei.ttf]],		LOCALE_MASK)
	lib:Register("font", "AR ZhongkaiGBK Medium (Combat)", [[Fonts\ARKai_C.ttf]],	LOCALE_MASK)
	lib:Register("font", "AR ZhongkaiGBK Medium",	[[Fonts\ARKai_T.ttf]],		LOCALE_MASK)
	lib:Register("font", "AR CrystalzcuheiGBK Bold",	[[Fonts\bHEI00M.ttf]],	LOCALE_MASK)
	lib:Register("font", "AR CrystalzcuheiGBK Bold (Combat)", [[Fonts\bHEI01B.ttf]], LOCALE_MASK)
	lib:Register("font", "AR ZhongkaiGBK (Combat)",		[[Fonts\bKAI00M.ttf]],	LOCALE_MASK)
	lib:Register("font", "AR ZhongkaiGBK Bold",		[[Fonts\bKAI01M.ttf]],	LOCALE_MASK)
elseif locale == "ruRU" then
	lib:Register("font", "AR CrystalzcuheiGBK",	[[Fonts\ARHei.ttf]],		LOCALE_MASK)
	lib:Register("font", "AR ZhongkaiGBK Medium (Combat)", [[Fonts\ARKai_C.ttf]],	LOCALE_MASK)
	lib:Register("font", "AR ZhongkaiGBK Medium",	[[Fonts\ARKai_T.ttf]],	LOCALE_MASK)
	lib:Register("font", "Nimrod MT",			[[Fonts\NIM_____.ttf]],		LOCALE_MASK)
else
	lib:Register("font", "Arial Narrow",		[[Fonts\ARIALN.TTF]])
	lib:Register("font", "Skurri",				[[Fonts\skurri.ttf]])
	lib:Register("font", "Morpheus",			[[Fonts\MORPHEUS.TTF]])
end

-- STATUSBAR
lib:Register("statusbar", "Blizzard", [[Interface\TargetingFrame\UI-StatusBar]])
lib:Register("statusbar", "Blizzard Character Skills Bar", [[Interface\PaperDollInfoFrame\UI-Character-Skills-Bar]])
lib:Register("statusbar", "Blizzard Raid Bar", [[Interface\RaidFrame\Raid-Bar-Hp-Fill]])
lib:Register("statusbar", "Solid", [[Interface\Buttons\WHITE8X8]])

-- SOUND
lib:Register("sound", "Rubber Ducky", [[Interface\AddOns\LibSharedMedia-3.0\sound\RubberDucky.ogg]])
lib:Register("sound", "Fel Nova", [[sound\doodad\fx_scourge_acherus_explosionfissurefx_01.ogg]])
lib:Register("sound", "Whisper Alert", [[sound\interface\iwhisperreceived.ogg]])
lib:Register("sound", "Achievement Alert", [[sound\interface\achievementcomplete.ogg]])

