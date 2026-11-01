-- MCP bridge query: the player's religion. Registers religion on
-- Rpc._queries; included from Boot after CivVAccess_Rpc so it
-- re-registers on every load-from-game.
--
-- Faith and its rate, the pantheon belief, the player's own religion with
-- its holy city and beliefs (name and effect, the game's own text), how
-- many of the player's cities follow which religion, how many religions
-- can still be founded, and while a pantheon can be founded the beliefs
-- on offer (what found_pantheon takes).

local queries = Rpc._queries

local function beliefEntry(id)
    local belief = GameInfo.Beliefs[id]
    local name = Text.keyOrNil(belief.ShortDescription)
    local effect = Text.keyOrNil(belief.Description)
    return { name = name, effect = effect and TextFilter.filter(effect) or nil }
end

function queries.religion()
    local player = Players[Game.GetActivePlayer()]
    local out = {
        faith = player:GetFaith(),
        faithPerTurn = player:GetTotalFaithPerTurn(),
        religionsStillToFound = Game.GetNumReligionsStillToFound(),
    }
    if player:HasCreatedPantheon() then
        -- NO_BELIEF under the Community Patch for a player with a religion
        -- but no pantheon of its own (see QueryEmpire).
        local id = player:GetBeliefInPantheon()
        if GameInfo.Beliefs[id] ~= nil then
            out.pantheon = beliefEntry(id)
        end
    elseif player:CanCreatePantheon(true) then
        local offer = {}
        for _, id in ipairs(Game.GetAvailablePantheonBeliefs()) do
            offer[#offer + 1] = beliefEntry(id)
        end
        out.pantheonBeliefsAvailable = offer
    end
    local religion = EngineData.ownedReligion(player)
    if religion > 0 then
        local beliefs = {}
        for _, id in ipairs(Game.GetBeliefsInReligion(religion)) do
            beliefs[#beliefs + 1] = beliefEntry(id)
        end
        local holy = EngineData.holyCityForReligion(religion, player)
        out.religion = {
            name = Text.key(Game.GetReligionName(religion)),
            holyCity = holy and holy:GetName() or nil,
            beliefs = beliefs,
        }
    end
    local following = {}
    for city in player:Cities() do
        local majority = city:GetReligiousMajority()
        if majority > 0 then
            local name = Text.key(Game.GetReligionName(majority))
            following[name] = (following[name] or 0) + 1
        end
    end
    local list = {}
    for name, n in pairs(following) do
        list[#list + 1] = { religion = name, cities = n }
    end
    table.sort(list, function(a, b)
        return a.cities > b.cities
    end)
    out.yourCitiesFollow = list
    return out
end
