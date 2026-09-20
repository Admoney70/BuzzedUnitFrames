-- BuzzardFrames: Statuses/Level.lua
-- Status: unit level. Fires on UNIT_LEVEL (which covers the player's own
-- level-ups too — WoW dispatches UNIT_LEVEL with unit="player" alongside
-- PLAYER_LEVEL_UP, so we don't need to register both).
--
-- Lazy lifecycle (Grid2 pattern): events are only registered while at
-- least one indicator is bound to this status. The initial render on
-- unit-join is provided by the framework's frame:UpdateIndicators()
-- path (BFLayout.lua:OnUnitChanged), so this status only needs to drive
-- updates for actual level changes — which during normal raid play
-- happen approximately never.

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local UnitLevel          = UnitLevel
local UnitEffectiveLevel = UnitEffectiveLevel
local UnitExists         = UnitExists

local Level = BF.statusPrototype:new("level")

function Level:IsActive(unit)
    return unit and UnitExists(unit)
end

function Level:GetLevel(unit)
    if not unit or not UnitExists(unit) then return 0 end
    return UnitEffectiveLevel and UnitEffectiveLevel(unit) or UnitLevel(unit) or 0
end

function Level:OnEnable()
    BF:RegisterEvent("UNIT_LEVEL", function(_, unit)
        if self.enabled then self:UpdateIndicators(unit) end
    end)
end

function Level:OnDisable()
    BF:UnregisterEvent("UNIT_LEVEL")
end

BF:RegisterStatus(Level)

-- Perf plan §L5.1 load-time mark: opens BFLayout (.toc 108-112).
if BuzzardFrames then BuzzardFrames:LoadMark("chunk:preBFLayout") end
