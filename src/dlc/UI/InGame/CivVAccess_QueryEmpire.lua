-- MCP bridge query: the player's empire at a glance. Registers
-- empire_overview on Rpc._queries; included from Boot right after
-- CivVAccess_Rpc so it re-registers on every load-from-game.
--
-- The numbers the top panel and the empire status keys (T/R/G/H/F/P/I)
-- speak, gathered into one reply: treasury, research, culture and the
-- next policy, faith, happiness, golden age, tourism, trade routes,
-- adopted policies by branch, ideology, religion, and the luxury and
-- strategic resources on hand. Engine-divergent reads (happiness,
-- tourism, religion ownership) go through the EngineData seam so the
-- same query answers correctly under Vox Populi. Every value is read
-- live at call time.

local queries = Rpc._queries

local function policyBranches(player)
    local out = {}
    for branch in GameInfo.PolicyBranchTypes() do
        local adopted = {}
        for policy in GameInfo.Policies({ PolicyBranchType = branch.Type }) do
            if player:HasPolicy(policy.ID) then
                adopted[#adopted + 1] = Text.key(policy.Description)
            end
        end
        local unlocked = player:IsPolicyBranchUnlocked(branch.ID)
        if unlocked or #adopted > 0 then
            out[#out + 1] = {
                name = Text.key(branch.Description),
                unlocked = unlocked,
                finished = player:IsPolicyBranchFinished(branch.ID),
                adopted = adopted,
            }
        end
    end
    return out
end

local function resourcesOnHand(player)
    local out = {}
    for res in GameInfo.Resources() do
        local usage = Game.GetResourceUsageType(res.ID)
        local kind
        if usage == ResourceUsageTypes.RESOURCEUSAGE_LUXURY then
            kind = "luxury"
        elseif usage == ResourceUsageTypes.RESOURCEUSAGE_STRATEGIC then
            kind = "strategic"
        end
        if kind ~= nil then
            local available = player:GetNumResourceAvailable(res.ID, true)
            if available ~= 0 then
                out[#out + 1] = { name = Text.key(res.Description), kind = kind, available = available }
            end
        end
    end
    return out
end

function queries.empire_overview()
    local player = Players[Game.GetActivePlayer()]
    local team = Teams[player:GetTeam()]

    local data = {
        civilization = player:GetCivilizationShortDescription(),
        leader = player:GetName(),
        era = Text.key(GameInfo.Eras[player:GetCurrentEra()].Description),
        score = player:GetScore(),
        cities = player:GetNumCities(),
        population = player:GetTotalPopulation(),
        units = player:GetNumUnits(),
        gold = { total = player:GetGold(), perTurn = player:CalculateGoldRate() },
        science = {
            perTurn = player:GetScience(),
            techsKnown = team:GetTeamTechs():GetNumTechsKnown(),
        },
        faith = { total = player:GetFaith(), perTurn = player:GetTotalFaithPerTurn() },
        happiness = EngineData.happinessSummary(player),
        tourism = EngineData.tourism(player),
        tradeRoutes = {
            used = player:GetNumInternationalTradeRoutesUsed(),
            available = player:GetNumInternationalTradeRoutesAvailable(),
        },
        policyBranches = policyBranches(player),
        resources = resourcesOnHand(player),
    }

    local research = player:GetCurrentResearch()
    if research ~= -1 then
        data.science.researching = {
            name = Text.key(GameInfo.Technologies[research].Description),
            turnsLeft = player:GetResearchTurnsLeft(research, true),
        }
    end

    local culture = player:GetJONSCulture()
    local culturePerTurn = player:GetTotalJONSCulturePerTurn()
    local policyCost = player:GetNextPolicyCost()
    data.culture = {
        total = culture,
        perTurn = culturePerTurn,
        nextPolicyCost = policyCost,
        freePolicies = player:GetNumFreePolicies(),
    }
    if culturePerTurn > 0 then
        data.culture.turnsToNextPolicy = math.max(0, math.ceil((policyCost - culture) / culturePerTurn))
    end

    local goldenTurns = player:GetGoldenAgeTurns()
    data.goldenAge = {
        active = goldenTurns > 0,
        turnsLeft = goldenTurns,
        progress = player:GetGoldenAgeProgressMeter(),
        threshold = player:GetGoldenAgeProgressThreshold(),
    }

    local ideology = player:GetLateGamePolicyTree()
    if ideology ~= PolicyBranchTypes.NO_POLICY_BRANCH_TYPE then
        data.ideology = Text.key(GameInfo.PolicyBranchTypes[ideology].Description)
    end

    if player:HasCreatedPantheon() then
        data.pantheon = Text.key(GameInfo.Beliefs[player:GetBeliefInPantheon()].ShortDescription)
    end
    local religion = EngineData.ownedReligion(player)
    if religion >= 0 then
        data.religion = Text.key(Game.GetReligionName(religion))
    end
    return data
end
