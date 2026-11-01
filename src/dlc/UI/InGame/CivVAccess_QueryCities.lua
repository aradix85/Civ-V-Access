-- MCP bridge query: the inside of the player's own cities. Registers
-- city_details on Rpc._queries; included from Boot right after
-- CivVAccess_Rpc so it re-registers on every load-from-game.
--
-- Without an argument every own city comes back as a compact summary
-- (growth, production, yields, health, status). With a city name the one
-- city comes back in full: the production queue, the buildings it has,
-- everything it can produce right now with turn counts, specialists,
-- border growth, religion and focus. Only the player's own cities are
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

local function citySummary(player, city)
    local foodPerTurn = city:FoodDifference()
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
    if foodPerTurn > 0 then
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
    -- Per-city unhappiness exists only under the vanilla surplus model;
    -- Vox Populi tracks happiness through citizen needs instead.
    if EngineData.happinessSummary(player).mode == "surplus" then
        entry.unhappiness = EngineData.unhappinessFromCity(player, city) / 100
    end
    return entry
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
    for row in GameInfo.Buildings() do
        if city:CanConstruct(row.ID) then
            buildings[#buildings + 1] = {
                name = Text.key(row.Description),
                kind = buildingKind(row),
                turns = city:GetBuildingProductionTurnsLeft(row.ID),
            }
        end
    end
    for row in GameInfo.Units() do
        if city:CanTrain(row.ID, 0) then
            units[#units + 1] = { name = Text.key(row.Description), turns = city:GetUnitProductionTurnsLeft(row.ID) }
        end
    end
    for row in GameInfo.Projects() do
        if city:CanCreate(row.ID) then
            projects[#projects + 1] =
                { name = Text.key(row.Description), turns = city:GetProjectProductionTurnsLeft(row.ID) }
        end
    end
    for row in GameInfo.Processes() do
        if city:CanMaintain(row.ID) then
            processes[#processes + 1] = Text.key(row.Description)
        end
    end
    return { buildings = buildings, units = units, projects = projects, processes = processes }
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
    local culturePerTurn = city:GetJONSCulturePerTurn()
    if culturePerTurn > 0 then
        data.borderGrowth.turns = math.max(0, math.ceil((cultureNeeded - cultureStored) / culturePerTurn))
    end

    local religion = city:GetReligiousMajority()
    if religion >= 0 then
        data.religion = Text.key(Game.GetReligionName(religion))
    end
    return data
end
