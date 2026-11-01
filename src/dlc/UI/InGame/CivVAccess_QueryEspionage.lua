-- MCP bridge query: the player's spies and the cities they could work in.
-- Registers espionage on Rpc._queries; included from Boot after
-- CivVAccess_Rpc so it re-registers on every load-from-game.
--
-- What the Espionage Overview lists: each spy with rank, state, turns
-- left and where it is, and the cities the game reports on (only those
-- the player knows) with their potential where the engine gives one.
-- Civilizations the player has not met stay unnamed.

local queries = Rpc._queries

local function cityAt(x, y)
    if x == nil or x < 0 then
        return nil
    end
    local plot = Map.GetPlot(x, y)
    return plot and plot:GetPlotCity() or nil
end

function queries.espionage()
    local player = Players[Game.GetActivePlayer()]
    if player:GetNumSpies() == 0 then
        return { spies = {}, cities = {} }
    end
    local spies, spyIn = {}, {}
    for _, agent in ipairs(player:GetEspionageSpies()) do
        local entry = {
            id = agent.AgentID,
            name = Text.key(agent.Name),
            rank = agent.Rank and Text.key(agent.Rank) or nil,
            state = Text.key(agent.State),
            diplomat = agent.IsDiplomat or nil,
        }
        if agent.TurnsLeft ~= nil and agent.TurnsLeft >= 0 then
            entry.turnsLeft = agent.TurnsLeft
        end
        local city = cityAt(agent.CityX, agent.CityY)
        if city ~= nil then
            entry.city = city:GetName()
            entry.civ = Rpc.civLabel(city:GetOwner())
            spyIn[city:GetOwner() .. ":" .. city:GetID()] = entry.name
        end
        spies[#spies + 1] = entry
    end
    local cities = {}
    for _, v in ipairs(player:GetEspionageCityStatus()) do
        cities[#cities + 1] = {
            city = Text.key(v.Name),
            civ = Rpc.civLabel(v.PlayerID),
            cityState = Players[v.PlayerID]:IsMinorCiv() or nil,
            potential = v.Potential,
            yourSpy = spyIn[v.PlayerID .. ":" .. v.CityID],
        }
    end
    return { spies = spies, cities = cities }
end
