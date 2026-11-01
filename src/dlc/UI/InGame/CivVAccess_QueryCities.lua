-- MCP bridge query: the inside of the player's own cities. Registers
-- city_details on Rpc._queries; included from Boot right after
-- CivVAccess_Rpc so it re-registers on every load-from-game.
--
-- Without an argument every own city comes back as a compact summary
-- (growth, production, yields, health, status). With a city name the one
-- city comes back in full: the production queue, the buildings it has,
-- everything it can produce right now with turn counts and which of the
-- game's advisors recommend it, specialists, border growth, religion,
-- focus, and under Vox Populi where its happiness and unhappiness come
-- from. Only the player's own cities are
-- read, so nothing here goes beyond what the city screen shows.
-- Every value is read live at call time.

local queries = Rpc._queries

-- Name of an engine enum value, for fields the agent reads as words.
local function enumName(enum, value)
    for k, v in pairs(enum) do
        if v == value then
            return k
        end
    end
    return tostring(value)
end

local function buildingKind(row)
    local class = GameInfo.BuildingClasses[row.BuildingClass]
    if class.MaxGlobalInstances > 0 then
        return "worldWonder"
    end
    if class.MaxPlayerInstances > 0 then
        return "nationalWonder"
    end
    return "building"
end

local function orderEntry(city, orderType, data1, idx)
    local entry
    if orderType == OrderTypes.ORDER_TRAIN then
        entry = { kind = "unit", name = Text.key(GameInfo.Units[data1].Description) }
        entry.turnsLeft = city:GetUnitProductionTurnsLeft(data1, idx)
    elseif orderType == OrderTypes.ORDER_CONSTRUCT then
        local row = GameInfo.Buildings[data1]
        entry = { kind = buildingKind(row), name = Text.key(row.Description) }
        entry.turnsLeft = city:GetBuildingProductionTurnsLeft(data1, idx)
    elseif orderType == OrderTypes.ORDER_CREATE then
        entry = { kind = "project", name = Text.key(GameInfo.Projects[data1].Description) }
        entry.turnsLeft = city:GetProjectProductionTurnsLeft(data1, idx)
    elseif orderType == OrderTypes.ORDER_MAINTAIN then
        entry = { kind = "process", name = Text.key(GameInfo.Processes[data1].Description) }
    else
        entry = { kind = enumName(OrderTypes, orderType) }
    end
    return entry
end

local function productionQueue(city)
    local queue = {}
    for idx = 0, city:GetOrderQueueLength() - 1 do
        local orderType, data1 = city:GetOrderFromQueue(idx)
        queue[#queue + 1] = orderEntry(city, orderType, data1, idx)
    end
    return queue
end

-- The culture that grows a city's borders. The Community Patch gives
-- border growth its own yield (CULTURE_LOCAL); GetJONSCulturePerTurn is
-- the city's whole culture output there. Same rule as
-- CitySpeech.borderGrowthToken.
local function borderCulturePerTurn(city)
    if YieldTypes.YIELD_CULTURE_LOCAL ~= nil then
        return city:GetYieldRateTimes100(YieldTypes.YIELD_CULTURE_LOCAL) / 100
    end
    return city:GetJONSCulturePerTurn()
end

local function citySummary(player, city)
    -- Hundredths, so half a food of surplus is not read as zero.
    local foodPerTurn = city:FoodDifferenceTimes100() / 100
    local productionPerTurn = city:GetCurrentProductionDifferenceTimes100(false, false) / 100
    local entry = {
        name = city:GetName(),
        x = city:GetX(),
        y = city:GetY(),
        capital = city:IsCapital(),
        population = city:GetPopulation(),
        food = {
            perTurn = foodPerTurn,
            stored = city:GetFood(),
            growthThreshold = city:GrowthThreshold(),
        },
        production = { perTurn = productionPerTurn },
        gold = city:GetYieldRate(YieldTypes.YIELD_GOLD),
        science = city:GetYieldRate(YieldTypes.YIELD_SCIENCE),
        culture = city:GetJONSCulturePerTurn(),
        faith = city:GetFaithPerTurn(),
        tourism = EngineData.baseTourism(city),
        health = city:GetMaxHitPoints() - city:GetDamage(),
        maxHealth = city:GetMaxHitPoints(),
        defense = math.floor(city:GetStrengthValue() / 100),
    }
    -- A city turning its food into production (building a settler) does
    -- not grow by design; that is neither stagnation nor starvation.
    if city:IsFoodProduction() then
        entry.food.intoProduction = true
    elseif foodPerTurn > 0 then
        entry.food.turnsToGrow = city:GetFoodTurnsLeft()
    elseif foodPerTurn < 0 then
        entry.food.starving = true
    end

    if city:GetOrderQueueLength() > 0 then
        local orderType, data1 = city:GetOrderFromQueue(0)
        local current = orderEntry(city, orderType, data1, 0)
        if city:IsProductionProcess() or productionPerTurn <= 0 then
            current.turnsLeft = nil
        else
            current.progress = city:GetProduction()
            current.needed = city:GetProductionNeeded()
        end
        entry.production.current = current
    end

    if city:IsPuppet() then
        entry.puppet = true
    end
    if city:IsOccupied() then
        entry.occupied = true
    end
    if city:IsRazing() then
        entry.razingTurns = city:GetRazingTurns()
    end
    if city:IsResistance() then
        entry.resistanceTurns = city:GetResistanceTurns()
    end
    if not city:IsCapital() then
        entry.connectedToCapital = player:IsCapitalConnectedToCity(city)
    end
    -- Vanilla: the city's share of empire unhappiness. Vox Populi: the
    -- city's own happiness against its unhappiness from citizen needs, the
    -- two numbers the city banner and city screen show.
    local mode = EngineData.happinessSummary(player).mode
    if mode == "surplus" then
        entry.unhappiness = EngineData.unhappinessFromCity(player, city) / 100
    elseif mode == "approval" then
        entry.happiness = city:GetLocalHappiness()
        entry.unhappiness = math.floor(city:GetUnhappinessAggregated())
    end
    return entry
end

-- The engine's prebuilt per-source breakdown, one line per source.
local function breakdownLines(text)
    local out = {}
    for line in ((text or "") .. "[NEWLINE]"):gmatch("(.-)%[NEWLINE%]") do
        local clean = TextFilter.filter(line)
        if clean ~= nil and clean:match("%S") then
            out[#out + 1] = clean
        end
    end
    return out
end

-- Which of the game's advisors recommend an item, as the production
-- chooser marks it (ChooseProductionLogic.advisorSuffix); nil when none.
-- Needs Game.SetAdvisorRecommenderCity(city) first. That city is one
-- shared engine setting the open production chooser reads its labels
-- from, and there is no getter to put it back, so while the chooser is
-- open the recommendations are left out.
local function productionChooserOpen()
    for i = 1, HandlerStack.count() do
        if HandlerStack.at(i).name == "ChooseProductionPopup" then
            return true
        end
    end
    return false
end

local ADVISORS = { "ECONOMIC", "MILITARY", "SCIENCE", "FOREIGN" }
local function recommendedBy(isRecommended, id)
    local out = {}
    for _, name in ipairs(ADVISORS) do
        local advisor = AdvisorTypes["ADVISOR_" .. name]
        if advisor ~= nil and isRecommended(id, advisor) then
            out[#out + 1] = Locale.ToLower(name)
        end
    end
    if #out == 0 then
        return nil
    end
    return out
end

local function ownedBuildings(city)
    local out = {}
    for row in GameInfo.Buildings() do
        if city:IsHasBuilding(row.ID) then
            out[#out + 1] = { name = Text.key(row.Description), kind = buildingKind(row) }
        end
    end
    return out
end

-- Everything the city can start producing this turn, with the turn count
-- the production chooser shows. Processes (wealth, research) have none.
local function producible(city)
    local buildings, units, projects, processes = {}, {}, {}, {}
    local advise = not productionChooserOpen()
    if advise then
        Game.SetAdvisorRecommenderCity(city)
    end
    local function advisors(isRecommended, id)
        if advise then
            return recommendedBy(isRecommended, id)
        end
        return nil
    end
    for row in GameInfo.Buildings() do
        if city:CanConstruct(row.ID) then
            buildings[#buildings + 1] = {
                name = Text.key(row.Description),
                kind = buildingKind(row),
                turns = city:GetBuildingProductionTurnsLeft(row.ID),
                advisors = advisors(Game.IsBuildingRecommended, row.ID),
            }
        end
    end
    for row in GameInfo.Units() do
        if city:CanTrain(row.ID, 0) then
            units[#units + 1] = {
                name = Text.key(row.Description),
                turns = city:GetUnitProductionTurnsLeft(row.ID),
                advisors = advisors(Game.IsUnitRecommended, row.ID),
            }
        end
    end
    for row in GameInfo.Projects() do
        if city:CanCreate(row.ID) then
            projects[#projects + 1] = {
                name = Text.key(row.Description),
                turns = city:GetProjectProductionTurnsLeft(row.ID),
                advisors = advisors(Game.IsProjectRecommended, row.ID),
            }
        end
    end
    for row in GameInfo.Processes() do
        if city:CanMaintain(row.ID) then
            processes[#processes + 1] = Text.key(row.Description)
        end
    end
    local out = { buildings = buildings, units = units, projects = projects, processes = processes }
    if not advise then
        out.advisorsUnavailable = "the production chooser is open; ask again after it closes"
    end
    return out
end

local function specialists(city)
    local out = {}
    for row in GameInfo.Specialists() do
        local count = city:GetSpecialistCount(row.ID)
        if count > 0 then
            out[#out + 1] = { name = Text.key(row.Description), count = count }
        end
    end
    return out
end

local function findOwnCity(player, name)
    local wanted = Locale.ToLower(name)
    for city in player:Cities() do
        if Locale.ToLower(city:GetName()) == wanted then
            return city
        end
    end
    return nil
end

function queries.city_details(name)
    local player = Players[Game.GetActivePlayer()]
    if name == nil or name == "" then
        local cities = {}
        for city in player:Cities() do
            cities[#cities + 1] = citySummary(player, city)
        end
        return { cities = cities }
    end

    local city = findOwnCity(player, name)
    if city == nil then
        error("you have no city named " .. name)
    end
    local data = citySummary(player, city)
    data.queue = productionQueue(city)
    data.buildings = ownedBuildings(city)
    data.canProduce = producible(city)
    data.specialists = specialists(city)
    data.focus = enumName(CityAIFocusTypes, city:GetFocusType())

    local cultureStored = city:GetJONSCultureStored()
    local cultureNeeded = city:GetJONSCultureThreshold()
    data.borderGrowth = { stored = cultureStored, threshold = cultureNeeded }
    local culturePerTurn = borderCulturePerTurn(city)
    if culturePerTurn > 0 then
        data.borderGrowth.turns = math.max(0, math.ceil((cultureNeeded - cultureStored) / culturePerTurn))
    end

    local religion = city:GetReligiousMajority()
    if religion >= 0 then
        data.religion = Text.key(Game.GetReligionName(religion))
    end
    if EngineData.happinessSummary(player).mode == "approval" then
        data.happinessSources = breakdownLines(city:GetCityHappinessBreakdown())
        -- With the median need context, as the city screen tooltip shows it.
        data.unhappinessSources = breakdownLines(city:GetCityUnhappinessBreakdown(true))
    end
    return data
end
