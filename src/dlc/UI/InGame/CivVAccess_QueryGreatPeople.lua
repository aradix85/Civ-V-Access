-- MCP bridge query: where the player's next great people come from.
-- Registers great_people on Rpc._queries; included from Boot after
-- CivVAccess_Rpc so it re-registers on every load-from-game.
--
-- Per great person type, every city earning points toward one: points
-- banked, the cost of the next one, and under Vox Populi the points per
-- turn and turns to go (vanilla has no per-city rate binding; the Military
-- Overview recomputes it from GPList.lua's formula, which this does not
-- duplicate). Plus great general and admiral progress from combat
-- experience, and the faith a great prophet needs. The same numbers the
-- city screen and the Military Overview's great people tab show.

local queries = Rpc._queries

local function cityProgress(city, specialist, unitClass)
    local progress = city:GetSpecialistGreatPersonProgress(specialist.ID)
    local perTurn
    if city.GetSpecialistRate ~= nil then
        perTurn = city:GetSpecialistRate(specialist.ID) / 100
    end
    if progress <= 0 and (perTurn or 0) <= 0 then
        return nil
    end
    local threshold = city:GetSpecialistUpgradeThreshold(unitClass.ID)
    local entry = { city = city:GetName(), progress = progress, threshold = threshold, perTurn = perTurn }
    if perTurn ~= nil and perTurn > 0 then
        entry.turns = math.max(1, math.ceil((threshold - progress) / perTurn))
    end
    return entry
end

function queries.great_people()
    local player = Players[Game.GetActivePlayer()]
    local types = {}
    for specialist in GameInfo.Specialists() do
        local unitClass = specialist.GreatPeopleUnitClass and GameInfo.UnitClasses[specialist.GreatPeopleUnitClass]
        if unitClass ~= nil then
            local cities = {}
            for city in player:Cities() do
                cities[#cities + 1] = cityProgress(city, specialist, unitClass)
            end
            if #cities > 0 then
                table.sort(cities, function(a, b)
                    return (a.turns or math.huge) < (b.turns or math.huge)
                end)
                types[#types + 1] = { name = Text.key(unitClass.Description), cities = cities }
            end
        end
    end
    return {
        fromSpecialists = types,
        general = { progress = player:GetCombatExperience(), threshold = player:GreatGeneralThreshold() },
        admiral = { progress = player:GetNavalCombatExperience(), threshold = player:GreatAdmiralThreshold() },
        prophet = { faith = player:GetFaith(), faithNeeded = player:GetMinimumFaithNextGreatProphet() },
    }
end
