-- ============================================================
-- BuzzardFrames: FrameSortIntegration.lua
-- Integration with the FrameSort addon via its v3 external API.
--
-- BuzzardFrames registers as a SELF-MANAGED provider. FrameSort
-- calls our Sort() method whenever any provider triggers a sort,
-- and we apply the sorted order to our SecureGroupHeader via the
-- nameList attribute.
--
-- This file is a no-op if FrameSort is not installed/enabled.
-- ============================================================

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local GetUnitName = GetUnitName
local UnitExists = UnitExists
local InCombatLockdown = InCombatLockdown
local IsInInstance = IsInInstance
local GetNumGroupMembers = GetNumGroupMembers
local ipairs, table_concat = ipairs, table.concat
local wipe = wipe
local strfind = string.find
local issecretvalue = issecretvalue or function() return false end

-- ============================================================
-- State
-- ============================================================
local frameSortEnabled = false   -- true once we successfully register
local api = nil                  -- FrameSortApi.v3 reference

-- Reusable table for building name lists (avoid per-sort alloc)
local nameBuffer = {}

-- ============================================================
-- Context → FrameSort area mapping
-- ============================================================
-- Based on FrameSort's Comparer:FriendlySortMode(), but treats open-world
-- raid groups as "Raid" so FrameSort's Raid settings (sort order, player
-- position, etc.) apply regardless of location. FrameSort's "World"
-- setting only affects party-sized groups.
local function GetFrameSortArea()
    local inInstance, instanceType = IsInInstance()
    if inInstance and instanceType == "arena" then
        local size = GetNumGroupMembers()
        if size == 2 then
            return "Arena - 2v2"
        else
            return "Arena - Default"
        end
    elseif inInstance and (instanceType == "party" or instanceType == "scenario") then
        return "Dungeon"
    elseif inInstance and (instanceType == "raid" or instanceType == "pvp") then
        return "Raid"
    elseif BF._contextIsRaid then
        -- Open-world raid group: use Raid settings, not World.
        return "Raid"
    else
        return "World"
    end
end

-- Returns true if FrameSort has sorting enabled for the current context.
local function IsFrameSortEnabledForContext()
    if not api then return false end
    local area = GetFrameSortArea()
    if not area then return false end
    local enabled = api.Options:GetEnabled(area)
    return enabled == true
end

-- ============================================================
-- Public queries for other BF modules
-- ============================================================

-- Returns true if FrameSort is overriding party-style frames.
function BF:IsFrameSortOverridingParty()
    if not frameSortEnabled or not api then return false end
    if not BF._contextIsParty then return false end
    local inInstance, instanceType = IsInInstance()
    if inInstance and instanceType == "arena" then
        local size = GetNumGroupMembers()
        local area = (size == 2) and "Arena - 2v2" or "Arena - Default"
        return api.Options:GetEnabled(area) == true
    elseif inInstance and (instanceType == "party" or instanceType == "scenario") then
        return api.Options:GetEnabled("Dungeon") == true
    elseif inInstance and (instanceType == "raid" or instanceType == "pvp") then
        return false
    else
        return api.Options:GetEnabled("World") == true
    end
end

-- Returns true if FrameSort is overriding raid-style frames.
function BF:IsFrameSortOverridingRaid()
    if not frameSortEnabled or not api then return false end
    if not BF._contextIsRaid then return false end
    local inInstance, instanceType = IsInInstance()
    if inInstance and (instanceType == "raid" or instanceType == "pvp") then
        return api.Options:GetEnabled("Raid") == true
    elseif not inInstance then
        -- Open world raid group: use the Raid setting. FrameSort's "World"
        -- setting only affects party-sized groups; raid frames always follow
        -- the Raid toggle regardless of location.
        return api.Options:GetEnabled("Raid") == true
    end
    return false
end

-- Settings-based queries: return true if FrameSort has ANY party-
-- or raid-affecting area enabled, regardless of the current context.
-- Used by the options panel to show the red override warning text
-- in the correct section at all times.

-- Returns true if any FrameSort area that affects party-style frames
-- is enabled (Dungeon, World, Arena - 2v2, Arena - Default).
function BF:IsFrameSortEnabledForParty()
    if not frameSortEnabled or not api then return false end
    return api.Options:GetEnabled("Dungeon") == true
        or api.Options:GetEnabled("World") == true
        or api.Options:GetEnabled("Arena - 2v2") == true
        or api.Options:GetEnabled("Arena - Default") == true
end

-- Returns true if FrameSort's Raid area is enabled.
function BF:IsFrameSortEnabledForRaid()
    if not frameSortEnabled or not api then return false end
    return api.Options:GetEnabled("Raid") == true
end

-- Returns a list of FrameSort area names that affect party-style frames
-- and are currently enabled. Used by the options panel for the warning text.
function BF:GetFrameSortEnabledPartyAreas()
    if not frameSortEnabled or not api then return nil end
    local areas = {}
    if api.Options:GetEnabled("Dungeon") == true then areas[#areas+1] = "Dungeon" end
    if api.Options:GetEnabled("World") == true then areas[#areas+1] = "World" end
    if api.Options:GetEnabled("Arena - 2v2") == true then areas[#areas+1] = "Arena 2v2" end
    if api.Options:GetEnabled("Arena - Default") == true then areas[#areas+1] = "Arena" end
    return #areas > 0 and areas or nil
end

-- Context-aware: returns true when FrameSort should override BF's
-- current frame context (party or raid).
function BF:IsFrameSortActive()
    if not frameSortEnabled then return false end
    if BF._contextIsParty then
        return BF:IsFrameSortOverridingParty()
    elseif BF._contextIsRaid then
        return BF:IsFrameSortOverridingRaid()
    end
    return false
end

-- ============================================================
-- Provider contract (self-managed)
-- ============================================================
local provider = {}
provider.IsSelfManaged = true

function provider:Name()
    return "BuzzardFrames"
end

function provider:Enabled()
    return frameSortEnabled and BF.groupsUsed and #BF.groupsUsed > 0
end

function provider:IsVisible()
    if not BF.groupsUsed then return false end
    for _, header in ipairs(BF.groupsUsed) do
        if header:IsShown() then
            return true
        end
    end
    return false
end

function provider:Init()
    -- Nothing extra needed; BuzzardFrames initializes its own headers.
end

-- Self-managed providers don't need these (only non-self-managed do).
function provider:RegisterRequestSortCallback() end
function provider:RegisterContainersChangedCallback() end

-- ============================================================
-- Sort implementation
-- ============================================================
-- Converts an array of unit tokens (from FrameSort's GetFriendlyUnits)
-- into a comma-separated nameList string suitable for
-- SecureGroupHeaderTemplate's nameList attribute.
local function UnitsToNameList(units)
    wipe(nameBuffer)
    for i = 1, #units do
        local unit = units[i]
        -- Skip pet units — GetUnitName on pets can return Midnight-protected
        -- secret values that crash table.concat.
        if unit and not strfind(unit, "pet") and UnitExists(unit) then
            local name = GetUnitName(unit, true)
            if name and not issecretvalue(name) then
                nameBuffer[#nameBuffer + 1] = name
            end
        end
    end
    if #nameBuffer == 0 then return nil end
    return table_concat(nameBuffer, ",")
end

function provider:Sort()
    if InCombatLockdown() then return false end
    if not api then return false end
    if not BF.groupsUsed or #BF.groupsUsed == 0 then return false end

    -- Only sort when FrameSort is active for the current frame context.
    if not BF:IsFrameSortActive() then return false end

    local units = api.Sorting:GetFriendlyUnits()
    if not units or #units == 0 then return false end

    -- Check if FrameSort wants the player frame hidden.
    local area = GetFrameSortArea()
    local playerMode = area and api.Options:GetPlayerSortMode(area)
    local hidePlayer = (playerMode == "Hidden")

    local nameList = UnitsToNameList(units)
    if not nameList then return false end

    -- Apply nameList to the first non-custom, non-pet header.
    -- Layout guarantees a single header when FrameSort is active
    -- (overrides "By Group" to "By Group Flowing").
    -- Do NOT set showPlayer=true — SecureGroupHeaderTemplate overrides
    -- nameList ordering when showPlayer is explicitly set.
    for _, header in ipairs(BF.groupsUsed) do
        if not header.isCustomFrame and not header.isPetFrame then
            -- Clear groupFilter if still set.
            if header:GetAttribute("groupFilter") then
                header:SetAttribute("groupFilter", nil)
                header:SetAttribute("groupBy", nil)
                header:SetAttribute("groupingOrder", nil)
            end

            header:SetAttribute("sortMethod", "NAMELIST")
            header:SetAttribute("nameList", nameList)

            if hidePlayer then
                header:SetAttribute("showPlayer", false)
                header:SetAttribute("showSolo", false)
            end

            return true
        end
    end

    return false
end

-- ============================================================
-- Post-layout hook: after BF reloads its layout (which resets
-- all header attributes), re-apply FrameSort's ordering so the
-- fresh headers get the correct nameList immediately.
-- Deferred by one frame: BF's ReloadLayout may fire before
-- FrameSort processes the same GROUP_ROSTER_UPDATE, so its
-- unit cache can still hold stale data. Deferring ensures
-- FrameSort has invalidated its cache and GetFriendlyUnits()
-- returns the full roster.
-- ============================================================
function BF:FrameSortOnLayoutReloaded()
    if not frameSortEnabled then return end
    if InCombatLockdown() then return end
    C_Timer.After(0, function()
        if InCombatLockdown() then return end
        provider:Sort()
    end)
end

-- ============================================================
-- Initialization — called from BF's OnEnable
-- ============================================================
function BF:InitFrameSort()
    -- Guard: FrameSort must be loaded and expose its API global
    if not FrameSortApi or not FrameSortApi.v3 then return end

    api = FrameSortApi.v3

    -- Validate the API surface we need
    if not api.Sorting or not api.Sorting.RegisterFrameProvider or not api.Sorting.GetFriendlyUnits then
        return
    end

    local ok = api.Sorting:RegisterFrameProvider(provider)
    if ok then
        frameSortEnabled = true
        -- Expose provider so GROUP_ROSTER_UPDATE can trigger a re-sort.
        self._frameSortProvider = provider

        -- Listen for FrameSort config changes (e.g. toggling an area on/off).
        -- Deferred by one frame: FrameSort invalidates its unit cache during
        -- NotifyChanged (before our callback) but doesn't rebuild until
        -- fsRun:Run() which fires AFTER NotifyChanged returns. Deferring
        -- ensures GetFriendlyUnits() has full data when we rebuild layout.
        api.Options:RegisterConfigurationChangedCallback(function()
            if InCombatLockdown() then return end
            C_Timer.After(0, function()
                if InCombatLockdown() then return end
                BF:ReloadLayout(true)
            end)
        end)
    end
end
