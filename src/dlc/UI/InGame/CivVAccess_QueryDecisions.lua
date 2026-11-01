-- MCP bridge query: choices waiting on the player. Registers decisions on
-- Rpc._queries; included from Boot after CivVAccess_Rpc so it
-- re-registers on every load-from-game.
--
-- The things a sighted player sees as a flashing button or a popup that
-- will come back at the end of the turn: a policy or tenet to pick, a free
-- technology or great person, a pantheon that can be founded, research
-- that is not set, a city with nothing to build, units with a promotion
-- ready. The briefing turns these into reminders; each is read live, and
-- an empty field means there is nothing to decide.

local queries = Rpc._queries

function queries.decisions()
    local player = Players[Game.GetActivePlayer()]
    local out = {}
    local function count(key, n)
        if n > 0 then
            out[key] = n
        end
    end
    count("freePolicies", player:GetNumFreePolicies())
    count("freeTenets", player:GetNumFreeTenets())
    count("freeTechs", player:GetNumFreeTechs())
    count("freeGreatPeople", player:GetNumFreeGreatPeople())
    count("mayaBonusGreatPeople", player:GetNumMayaBoosts())
    if player:GetJONSCulture() >= player:GetNextPolicyCost() then
        out.policyAffordable = true
    end
    if not player:HasCreatedPantheon() and player:CanCreatePantheon(true) then
        out.pantheonAvailable = true
    end
    if player:GetCurrentResearch() == -1 then
        out.researchNotSet = true
    end

    local idleCities = {}
    for city in player:Cities() do
        if city:GetOrderQueueLength() == 0 and not city:IsPuppet() then
            idleCities[#idleCities + 1] = city:GetName()
        end
    end
    if #idleCities > 0 then
        out.citiesWithoutProduction = idleCities
    end

    local promotable = {}
    for unit in player:Units() do
        if EngineData.unitPromotionReady(unit) then
            promotable[#promotable + 1] = {
                id = unit:GetID(),
                unit = Text.key(GameInfo.Units[unit:GetUnitType()].Description),
            }
        end
    end
    if #promotable > 0 then
        out.promotionsReady = promotable
    end
    return out
end
