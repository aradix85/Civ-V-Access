-- MCP bridge action: moving a spy. Registers move_spy on Rpc._actions;
-- included from Boot after CivVAccess_BridgeCore.
--
-- The target must be in the engine's own list of places that spy may go
-- (GetAvailableSpyRelocationCities, what the Espionage Overview's move
-- list offers), or the hideout. The order is the screen's own commit:
-- Network.SendMoveSpy, as a diplomat only when asked and only to the
-- capital of a major civilization the player is at peace with (the
-- screen's diplomat-or-spy question).

local actions = Rpc._actions

local function findSpy(player, spyArg)
    local id = tonumber(spyArg)
    local wanted = Locale.ToLower(spyArg or "")
    local names = {}
    for _, agent in ipairs(player:GetEspionageSpies()) do
        local name = Text.key(agent.Name)
        if agent.AgentID == id or Locale.ToLower(name) == wanted then
            return agent, name
        end
        names[#names + 1] = name
    end
    error("no spy called " .. tostring(spyArg) .. "; your spies: " .. table.concat(names, ", "))
end

local function spyState(player, agentID)
    for _, agent in ipairs(player:GetEspionageSpies()) do
        if agent.AgentID == agentID then
            return agent.State .. "@" .. agent.CityX .. "," .. agent.CityY
        end
    end
    return nil
end

-- move_spy <spy name or id> <city|hideout> [spy|diplomat]
function actions.move_spy(spyArg, target, role)
    if target == nil or target == "" then
        error("name a city or the hideout")
    end
    if role ~= nil and role ~= "" and role ~= "spy" and role ~= "diplomat" then
        error("role must be spy or diplomat")
    end
    local player = Bridge.activePlayer()
    local me = player:GetID()
    local agent, spyName = findSpy(player, spyArg)
    if agent.State == "TXT_KEY_SPY_STATE_DEAD" then
        error(spyName .. " is dead")
    end
    local before = spyState(player, agent.AgentID)
    local movedAs

    if Locale.ToLower(target) == "hideout" then
        Network.SendMoveSpy(me, agent.AgentID, -1, -1, false)
        Bridge.sent()
        Bridge.speak(spyName .. ", " .. Text.key("TXT_KEY_MOVE_SPY_HIDEOUT_BUTTON"))
    else
        local wanted = Locale.ToLower(target)
        local chosen, names = nil, {}
        for _, v in ipairs(player:GetAvailableSpyRelocationCities(agent.AgentID) or {}) do
            local city = Players[v.PlayerID]:GetCityByID(v.CityID)
            names[#names + 1] = city:GetName()
            if Locale.ToLower(city:GetName()) == wanted then
                chosen = { playerID = v.PlayerID, city = city }
            end
        end
        if chosen == nil then
            error(spyName .. " cannot go to " .. target .. "; possible: " .. table.concat(names, ", "))
        end
        local owner = Players[chosen.playerID]
        local mayBeDiplomat = chosen.city:IsCapital()
            and chosen.playerID ~= me
            and not owner:IsMinorCiv()
            and not Teams[player:GetTeam()]:IsAtWar(owner:GetTeam())
        local asDiplomat = role == "diplomat"
        if asDiplomat and not mayBeDiplomat then
            error("a diplomat can only go to the capital of a civilization you are at peace with")
        end
        Network.SendMoveSpy(me, agent.AgentID, chosen.playerID, chosen.city:GetID(), asDiplomat)
        Bridge.sent()
        Bridge.speak(spyName .. ", " .. chosen.city:GetName())
        target = chosen.city:GetName()
        movedAs = asDiplomat and "diplomat" or "spy"
    end
    return { spy = spyName, target = target, role = movedAs }, function()
        if spyState(Players[me], agent.AgentID) == before then
            return nil
        end
        return { moving = true }
    end
end
