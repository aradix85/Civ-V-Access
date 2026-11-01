-- MCP bridge planning queries (CivVAccess_Query*): city details, empire
-- overview, research planning, turn summary, diplomacy. Each case drives a
-- query function directly against fake engine objects and checks the
-- rule that query exists to get right -- what it omits as much as what it
-- reports. The dispatch envelope itself is covered by rpc_test.

local T = require("support")
local M = {}

local saved

local function save(tbl, key)
    saved[#saved + 1] = { tbl, key, tbl[key] }
end

local function restore()
    for i = #saved, 1, -1 do
        local s = saved[i]
        s[1][s[2]] = s[3]
    end
end

-- Engine object fake: every listed method returns its value (or calls it
-- with the method's arguments when it is a function). An unlisted method
-- is nil, so a query reaching for something the case did not expect fails
-- loudly instead of reading a default.
local function fake(methods)
    return setmetatable({}, {
        __index = function(_, name)
            local v = methods[name]
            if v == nil then
                return nil
            end
            if type(v) == "function" then
                return function(_self, ...)
                    return v(...)
                end
            end
            return function()
                return v
            end
        end,
    })
end

-- GameInfo table fake: iterable with an optional column filter, indexable
-- by ID and by Type.
local function infoTable(rows)
    local byKey = {}
    for i, r in ipairs(rows) do
        r.ID = r.ID or (i - 1)
        byKey[r.ID] = r
        if r.Type ~= nil then
            byKey[r.Type] = r
        end
    end
    return setmetatable({}, {
        __call = function(_, cond)
            local i = 0
            return function()
                while true do
                    i = i + 1
                    local r = rows[i]
                    if r == nil then
                        return nil
                    end
                    local match = true
                    for k, v in pairs(cond or {}) do
                        if r[k] ~= v then
                            match = false
                            break
                        end
                    end
                    if match then
                        return r
                    end
                end
            end
        end,
        __index = function(_, k)
            return byKey[k]
        end,
    })
end

local function iterate(list)
    return function()
        local i = 0
        return function()
            i = i + 1
            return list[i]
        end
    end
end

local GAMEINFO_TABLES = {
    "Buildings",
    "BuildingClasses",
    "Units",
    "UnitClasses",
    "Projects",
    "Processes",
    "Specialists",
    "Technologies",
    "Technology_PrereqTechs",
    "Civilizations",
    "Civilization_BuildingClassOverrides",
    "Civilization_UnitClassOverrides",
    "Builds",
    "Improvements",
    "Eras",
    "PolicyBranchTypes",
    "Policies",
    "Resources",
    "Beliefs",
    "Victories",
    "Project_VictoryThresholds",
    "UnitPromotions",
    "GameOptions",
    "MapScripts",
    "Worlds",
    "HandicapInfos",
    "GameSpeeds",
    "Leaders",
    "Traits",
    "Civilization_Leaders",
    "Leader_Traits",
    "Trait_NoTrain",
}

local function withEnv(fn)
    saved = {}
    for _, name in ipairs({
        "Players",
        "Teams",
        "EngineData",
        "Turn",
        "Rpc",
        "OrderTypes",
        "CityAIFocusTypes",
        "PolicyBranchTypes",
        "MajorCivApproachTypes",
        "MinorCivTraitTypes",
        "GetActiveQuestToolTip",
        "PreGame",
        "MapUtilities",
        "AdvisorTypes",
        "HandlerStack",
    }) do
        save(_G, name)
    end
    for _, k in ipairs({
        "GetActivePlayer",
        "GetGameTurn",
        "GetGameTurnYear",
        "GetResourceUsageType",
        "GetReligionName",
        "GetMaxTurns",
        "GetStartTurn",
        "IsNetworkMultiPlayer",
        "GetNumActiveLeagues",
        "GetActiveLeague",
        "IsUnitedNationsActive",
        "SetAdvisorRecommenderCity",
        "IsBuildingRecommended",
        "IsUnitRecommended",
        "IsProjectRecommended",
    }) do
        save(Game, k)
    end
    AdvisorTypes = { ADVISOR_ECONOMIC = 0, ADVISOR_MILITARY = 1, ADVISOR_SCIENCE = 2, ADVISOR_FOREIGN = 3 }
    local handlers = {}
    HandlerStack = {
        count = function()
            return #handlers
        end,
        at = function(i)
            return handlers[i]
        end,
        _handlers = handlers,
    }
    Game.SetAdvisorRecommenderCity = function() end
    local function never()
        return false
    end
    Game.IsBuildingRecommended, Game.IsUnitRecommended, Game.IsProjectRecommended = never, never, never
    for _, k in ipairs(GAMEINFO_TABLES) do
        save(GameInfo, k)
        GameInfo[k] = infoTable({})
    end
    for _, k in ipairs({ "messageBuffer", "combatLog", "unitMoveLog", "foreignUnitDelta", "foreignClearDelta" }) do
        save(civvaccess_shared, k)
        civvaccess_shared[k] = nil
    end
    save(GameDefines, "MAX_CIV_PLAYERS")
    save(GameDefines, "MAX_MAJOR_CIVS")
    GameDefines.MAX_CIV_PLAYERS = 24
    GameDefines.MAX_MAJOR_CIVS = 22

    Players, Teams = {}, {}
    OrderTypes = { ORDER_TRAIN = 0, ORDER_CONSTRUCT = 1, ORDER_CREATE = 2, ORDER_MAINTAIN = 3 }
    CityAIFocusTypes = { NO_CITY_AI_FOCUS_TYPE = -1, CITY_AI_FOCUS_TYPE_FOOD = 0 }
    PolicyBranchTypes = { NO_POLICY_BRANCH_TYPE = -1 }
    MajorCivApproachTypes = {
        MAJOR_CIV_APPROACH_WAR = 0,
        MAJOR_CIV_APPROACH_HOSTILE = 1,
        MAJOR_CIV_APPROACH_DECEPTIVE = 2,
        MAJOR_CIV_APPROACH_GUARDED = 3,
        MAJOR_CIV_APPROACH_AFRAID = 4,
        MAJOR_CIV_APPROACH_FRIENDLY = 5,
        MAJOR_CIV_APPROACH_NEUTRAL = 6,
    }
    MinorCivTraitTypes = {
        MINOR_CIV_TRAIT_CULTURED = 0,
        MINOR_CIV_TRAIT_MILITARISTIC = 1,
        MINOR_CIV_TRAIT_MARITIME = 2,
        MINOR_CIV_TRAIT_MERCANTILE = 3,
        MINOR_CIV_TRAIT_RELIGIOUS = 4,
    }
    Game.GetActivePlayer = function()
        return 0
    end
    Game.GetGameTurn = function()
        return 10
    end
    Game.GetGameTurnYear = function()
        return -3000
    end
    EngineData = {
        baseTourism = function()
            return 0
        end,
        tourism = function()
            return 0
        end,
        happinessSummary = function()
            return { mode = "surplus", value = 5, state = "happy" }
        end,
        unhappinessFromCity = function()
            return 300
        end,
        ownedReligion = function()
            return -1
        end,
        minorPersonalityTextKey = function()
            return nil
        end,
    }

    dofile("src/dlc/UI/Shared/CivVAccess_TextFilter.lua")
    dofile("src/dlc/UI/Shared/CivVAccess_Text.lua")
    dofile("src/dlc/UI/InGame/CivVAccess_Rpc.lua")
    dofile("src/dlc/UI/InGame/CivVAccess_QueryCities.lua")
    dofile("src/dlc/UI/InGame/CivVAccess_QueryEmpire.lua")
    dofile("src/dlc/UI/InGame/CivVAccess_QueryTech.lua")
    dofile("src/dlc/UI/InGame/CivVAccess_QueryTurn.lua")
    dofile("src/dlc/UI/InGame/CivVAccess_QueryDiplo.lua")
    dofile("src/dlc/UI/InGame/CivVAccess_QueryVictory.lua")
    dofile("src/dlc/UI/InGame/CivVAccess_QueryRules.lua")
    dofile("src/dlc/UI/InGame/CivVAccess_QueryGame.lua")
    dofile("src/dlc/UI/InGame/CivVAccess_QueryDecisions.lua")
    dofile("src/dlc/UI/InGame/CivVAccess_QueryGreatPeople.lua")
    dofile("src/dlc/UI/InGame/CivVAccess_QueryTrade.lua")
    dofile("src/dlc/UI/InGame/CivVAccess_QueryLeague.lua")

    local ok, err = pcall(fn)
    restore()
    if not ok then
        error(err, 0)
    end
end

-- cities --------------------------------------------------------------------

local function fakeCity(opts)
    local methods = {
        GetName = opts.name,
        GetX = 3,
        GetY = 4,
        IsCapital = opts.capital or false,
        GetPopulation = 4,
        FoodDifferenceTimes100 = (opts.food or 0) * 100,
        IsFoodProduction = opts.foodProduction or false,
        GetFood = 10,
        GrowthThreshold = 30,
        GetFoodTurnsLeft = opts.turnsToGrow or 0,
        GetCurrentProductionDifferenceTimes100 = opts.production or 300,
        GetYieldRate = 2,
        GetJONSCulturePerTurn = 1,
        GetFaithPerTurn = 0,
        GetMaxHitPoints = 200,
        GetDamage = 0,
        GetStrengthValue = 800,
        GetOrderQueueLength = #opts.queue,
        GetOrderFromQueue = function(idx)
            local o = opts.queue[idx + 1]
            return o[1], o[2]
        end,
        GetUnitProductionTurnsLeft = 4,
        GetBuildingProductionTurnsLeft = 6,
        GetProjectProductionTurnsLeft = 9,
        IsProductionProcess = opts.process or false,
        GetProduction = 12,
        GetProductionNeeded = 40,
        IsPuppet = false,
        IsOccupied = false,
        IsRazing = false,
        IsResistance = false,
    }
    for k, v in pairs(opts.extra or {}) do
        methods[k] = v
    end
    return fake(methods)
end

local function installCityPlayer(cities)
    Players[0] = fake({
        Cities = iterate(cities),
        IsCapitalConnectedToCity = true,
    })
end

function M.test_city_summary_growth_and_production_turns()
    withEnv(function()
        GameInfo.Units = infoTable({ { Type = "UNIT_WARRIOR", Description = "Warrior" } })
        GameInfo.Processes = infoTable({ { Type = "PROCESS_WEALTH", Description = "Wealth" } })
        installCityPlayer({
            fakeCity({ name = "Rome", capital = true, food = 3, turnsToGrow = 5, queue = { { 0, 0 } } }),
            fakeCity({ name = "Antium", food = -2, process = true, queue = { { 3, 0 } } }),
            fakeCity({ name = "Cumae", food = 0.5, turnsToGrow = 40, queue = {} }),
            fakeCity({ name = "Veii", food = 0, foodProduction = true, queue = {} }),
        })
        local data = Rpc._queries.city_details()
        local rome, antium, cumae, veii = data.cities[1], data.cities[2], data.cities[3], data.cities[4]
        T.eq(cumae.food.perTurn, 0.5, "half a food of surplus is not rounded away")
        T.eq(cumae.food.turnsToGrow, 40)
        T.eq(veii.food.intoProduction, true, "food turned into production is not stagnation")
        T.eq(veii.food.starving, nil)
        T.eq(rome.food.turnsToGrow, 5)
        T.eq(rome.food.starving, nil)
        T.eq(rome.production.current.name, "Warrior")
        T.eq(rome.production.current.turnsLeft, 4)
        T.eq(antium.food.starving, true)
        T.eq(antium.food.turnsToGrow, nil, "a starving city has no growth countdown")
        T.eq(antium.production.current.kind, "process")
        T.eq(antium.production.current.turnsLeft, nil, "a process never finishes")
        T.eq(antium.connectedToCapital, true)
        T.eq(rome.connectedToCapital, nil, "the capital is not asked about its own connection")
    end)
end

function M.test_city_happiness_under_vox_populi()
    withEnv(function()
        EngineData.happinessSummary = function()
            return { mode = "approval", value = 60, state = "happy" }
        end
        installCityPlayer({
            fakeCity({
                name = "Babylon",
                capital = true,
                food = 2,
                queue = {},
                extra = {
                    GetLocalHappiness = 4,
                    GetUnhappinessAggregated = 6.5,
                    GetCityHappinessBreakdown = "[ICON_HAPPINESS_1] +3 from buildings[NEWLINE]+1 from the palace",
                    GetCityUnhappinessBreakdown = function(withMedian)
                        return withMedian and "Median need: 2[NEWLINE][NEWLINE]+4 from boredom" or "+4 from boredom"
                    end,
                    IsHasBuilding = false,
                    CanConstruct = false,
                    CanTrain = false,
                    CanCreate = false,
                    CanMaintain = false,
                    GetSpecialistCount = 0,
                    GetFocusType = -1,
                    GetJONSCultureStored = 0,
                    GetJONSCultureThreshold = 10,
                    GetReligiousMajority = -1,
                },
            }),
        })
        local summary = Rpc._queries.city_details().cities[1]
        T.eq(summary.happiness, 4)
        T.eq(summary.unhappiness, 6, "whole points, as the banner shows")
        local data = Rpc._queries.city_details("Babylon")
        T.eq(#data.happinessSources, 2)
        T.falsy(data.happinessSources[1]:find("[ICON", 1, true), "markup filtered")
        T.eq(table.concat(data.unhappinessSources, "|"), "Median need: 2|+4 from boredom", "empty lines dropped")
    end)
end

function M.test_city_details_unknown_name_raises()
    withEnv(function()
        installCityPlayer({ fakeCity({ name = "Rome", food = 1, queue = {} }) })
        local ok, err = pcall(Rpc._queries.city_details, "Atlantis")
        T.falsy(ok)
        T.truthy(tostring(err):find("Atlantis", 1, true), err)
    end)
end

function M.test_city_details_lists_only_what_the_city_can_produce()
    withEnv(function()
        GameInfo.BuildingClasses = infoTable({
            { Type = "BUILDINGCLASS_GRANARY", MaxGlobalInstances = -1, MaxPlayerInstances = -1 },
            { Type = "BUILDINGCLASS_WALLS", MaxGlobalInstances = -1, MaxPlayerInstances = -1 },
            { Type = "BUILDINGCLASS_PYRAMID", MaxGlobalInstances = 1, MaxPlayerInstances = -1 },
            { Type = "BUILDINGCLASS_MONUMENT", MaxGlobalInstances = -1, MaxPlayerInstances = -1 },
        })
        GameInfo.Buildings = infoTable({
            { Type = "BUILDING_GRANARY", BuildingClass = "BUILDINGCLASS_GRANARY", Description = "Granary" },
            { Type = "BUILDING_WALLS", BuildingClass = "BUILDINGCLASS_WALLS", Description = "Walls" },
            { Type = "BUILDING_PYRAMID", BuildingClass = "BUILDINGCLASS_PYRAMID", Description = "Pyramids" },
            { Type = "BUILDING_MONUMENT", BuildingClass = "BUILDINGCLASS_MONUMENT", Description = "Monument" },
        })
        local canConstruct = { [0] = true, [1] = false, [2] = true, [3] = false }
        local recommenderCity
        Game.SetAdvisorRecommenderCity = function(c)
            recommenderCity = c
        end
        Game.IsBuildingRecommended = function(id, advisor)
            return recommenderCity ~= nil and id == 2 and advisor == AdvisorTypes.ADVISOR_SCIENCE
        end
        installCityPlayer({
            fakeCity({
                name = "Rome",
                food = 1,
                queue = {},
                extra = {
                    CanConstruct = function(id)
                        return canConstruct[id]
                    end,
                    IsHasBuilding = function(id)
                        return id == 3
                    end,
                    CanTrain = false,
                    CanCreate = false,
                    CanMaintain = false,
                    GetSpecialistCount = 0,
                    GetFocusType = -1,
                    GetJONSCultureStored = 5,
                    GetJONSCultureThreshold = 15,
                    GetReligiousMajority = -1,
                },
            }),
        })
        local data = Rpc._queries.city_details("rome")
        local names = {}
        for _, b in ipairs(data.canProduce.buildings) do
            names[#names + 1] = b.name .. ":" .. b.kind
        end
        T.eq(table.concat(names, ","), "Granary:building,Pyramids:worldWonder")
        T.eq(data.canProduce.buildings[1].advisors, nil, "no advisor, no field")
        T.eq(table.concat(data.canProduce.buildings[2].advisors, ","), "science", "after pointing the advisors at the city")
        T.eq(data.happinessSources, nil, "the Vox Populi breakdown only under its happiness model")
        recommenderCity = nil
        HandlerStack._handlers[1] = { name = "ChooseProductionPopup" }
        local open = Rpc._queries.city_details("rome")
        T.eq(recommenderCity, nil, "the open chooser's advisor city is left alone")
        T.eq(open.canProduce.buildings[2].advisors, nil)
        T.truthy(open.canProduce.advisorsUnavailable ~= nil)
        T.eq(#data.buildings, 1)
        T.eq(data.buildings[1].name, "Monument")
        T.eq(data.borderGrowth.turns, 10)
        T.eq(data.focus, "NO_CITY_AI_FOCUS_TYPE")
    end)
end

-- empire --------------------------------------------------------------------

function M.test_empire_policy_countdown_resources_and_no_ideology()
    withEnv(function()
        GameInfo.Eras = infoTable({ { Type = "ERA_ANCIENT", Description = "Ancient Era" } })
        GameInfo.Resources = infoTable({
            { Type = "RESOURCE_IRON", Description = "Iron" },
            { Type = "RESOURCE_WINE", Description = "Wine" },
            { Type = "RESOURCE_HORSE", Description = "Horses" },
            { Type = "RESOURCE_WHEAT", Description = "Wheat" },
        })
        local usage = {
            [0] = ResourceUsageTypes.RESOURCEUSAGE_STRATEGIC,
            [1] = ResourceUsageTypes.RESOURCEUSAGE_LUXURY,
            [2] = ResourceUsageTypes.RESOURCEUSAGE_STRATEGIC,
            [3] = ResourceUsageTypes.RESOURCEUSAGE_BONUS,
        }
        Game.GetResourceUsageType = function(id)
            return usage[id]
        end
        local available = { [0] = 0, [1] = 2, [2] = -1, [3] = 4 }
        Teams[0] = fake({ GetTeamTechs = fake({ GetNumTechsKnown = 3 }) })
        Players[0] = fake({
            GetTeam = 0,
            GetCivilizationShortDescription = "Rome",
            GetName = "Augustus",
            GetCurrentEra = 0,
            GetScore = 50,
            GetNumCities = 2,
            GetTotalPopulation = 7,
            GetNumUnits = 4,
            GetGold = 100,
            CalculateGoldRate = 5,
            GetScience = 8,
            GetFaith = 0,
            GetTotalFaithPerTurn = 1,
            GetNumInternationalTradeRoutesUsed = 0,
            GetNumInternationalTradeRoutesAvailable = 1,
            GetCurrentResearch = -1,
            GetJONSCulture = 30,
            GetTotalJONSCulturePerTurn = 10,
            GetNextPolicyCost = 75,
            GetNumFreePolicies = 0,
            GetGoldenAgeTurns = 0,
            GetGoldenAgeProgressMeter = 20,
            GetGoldenAgeProgressThreshold = 500,
            GetLateGamePolicyTree = -1,
            HasCreatedPantheon = false,
            GetNumResourceAvailable = function(id)
                return available[id]
            end,
        })
        local data = Rpc._queries.empire_overview()
        T.eq(data.culture.turnsToNextPolicy, 5)
        T.eq(data.ideology, nil)
        T.eq(data.science.researching, nil)
        local res = {}
        for _, r in ipairs(data.resources) do
            res[#res + 1] = r.name .. ":" .. r.kind .. ":" .. r.available
        end
        T.eq(table.concat(res, ","), "Wine:luxury:2,Horses:strategic:-1", "zero stock and bonus resources omitted")
        T.eq(data.pantheon, nil)
    end)
end

function M.test_empire_religion_without_a_pantheon_belief()
    withEnv(function()
        GameInfo.Eras = infoTable({ { Type = "ERA_ANCIENT", Description = "Ancient Era" } })
        Teams[0] = fake({ GetTeamTechs = fake({ GetNumTechsKnown = 3 }) })
        Players[0] = fake({
            GetTeam = 0,
            GetCivilizationShortDescription = "Rome",
            GetName = "Augustus",
            GetCurrentEra = 0,
            GetScore = 50,
            GetNumCities = 2,
            GetTotalPopulation = 7,
            GetNumUnits = 4,
            GetGold = 100,
            CalculateGoldRate = 5,
            GetScience = 8,
            GetFaith = 0,
            GetTotalFaithPerTurn = 1,
            GetNumInternationalTradeRoutesUsed = 0,
            GetNumInternationalTradeRoutesAvailable = 1,
            GetCurrentResearch = -1,
            GetJONSCulture = 30,
            GetTotalJONSCulturePerTurn = 10,
            GetNextPolicyCost = 75,
            GetNumFreePolicies = 0,
            GetGoldenAgeTurns = 0,
            GetGoldenAgeProgressMeter = 20,
            GetGoldenAgeProgressThreshold = 500,
            GetLateGamePolicyTree = -1,
            HasCreatedPantheon = true,
            GetBeliefInPantheon = -1,
            GetNumResourceAvailable = 0,
        })
        local data = Rpc._queries.empire_overview()
        T.eq(data.pantheon, nil, "a religion with no pantheon belief names no pantheon")
    end)
end

-- tech ----------------------------------------------------------------------

local function installTechWorld(known, science, researchable)
    GameInfo.Technologies = infoTable({
        { Type = "TECH_AGRICULTURE", Description = "Agriculture" },
        { Type = "TECH_POTTERY", Description = "Pottery" },
        { Type = "TECH_CALENDAR", Description = "Calendar" },
        { Type = "TECH_WRITING", Description = "Writing" },
        { Type = "TECH_PHILOSOPHY", Description = "Philosophy" },
        { Type = "TECH_IRON_WORKING", Description = "Iron Working" },
    })
    GameInfo.Technology_PrereqTechs = infoTable({
        { TechType = "TECH_POTTERY", PrereqTech = "TECH_AGRICULTURE" },
        { TechType = "TECH_CALENDAR", PrereqTech = "TECH_POTTERY" },
        { TechType = "TECH_WRITING", PrereqTech = "TECH_POTTERY" },
        { TechType = "TECH_PHILOSOPHY", PrereqTech = "TECH_WRITING" },
        { TechType = "TECH_PHILOSOPHY", PrereqTech = "TECH_CALENDAR" },
    })
    GameInfo.Civilizations = infoTable({ { Type = "CIVILIZATION_ROME" } })
    Teams[0] = fake({
        GetTeamTechs = fake({
            HasTech = function(id)
                return known[id] == true
            end,
        }),
    })
    Players[0] = fake({
        GetTeam = 0,
        GetCivilizationType = 0,
        GetScience = science,
        GetCurrentResearch = -1,
        GetResearchCost = 50,
        GetResearchProgress = 0,
        CanResearch = function(id)
            return researchable[id] == true
        end,
        GetResearchTurnsLeft = 5,
    })
end

function M.test_tech_path_puts_prereqs_first_and_skips_known()
    withEnv(function()
        installTechWorld({ [0] = true }, 10, { [1] = true })
        local data = Rpc._queries.tech_plan("Philosophy")
        local order = {}
        for i, step in ipairs(data.target.path) do
            order[step.name] = i
        end
        T.eq(#data.target.path, 4)
        T.eq(order.Agriculture, nil, "a known tech is not on the path")
        T.eq(order.Pottery, 1)
        T.eq(order.Philosophy, 4)
        T.truthy(order.Writing < order.Philosophy and order.Calendar < order.Philosophy)
        T.eq(data.target.scienceNeeded, 200)
        T.eq(data.target.estimatedTurns, 20)
    end)
end

function M.test_tech_unlocks_follow_the_players_own_uniques()
    withEnv(function()
        installTechWorld({ [0] = true, [1] = true }, 10, { [3] = true })
        GameInfo.BuildingClasses = infoTable({
            {
                Type = "BUILDINGCLASS_LIBRARY",
                DefaultBuilding = "BUILDING_LIBRARY",
                MaxGlobalInstances = -1,
                MaxPlayerInstances = -1,
            },
        })
        GameInfo.Buildings = infoTable({
            {
                Type = "BUILDING_LIBRARY",
                BuildingClass = "BUILDINGCLASS_LIBRARY",
                PrereqTech = "TECH_WRITING",
                Description = "Library",
            },
            {
                Type = "BUILDING_PAPER_MAKER",
                BuildingClass = "BUILDINGCLASS_LIBRARY",
                PrereqTech = "TECH_WRITING",
                Description = "Paper Maker",
            },
        })
        GameInfo.Civilization_BuildingClassOverrides = infoTable({
            {
                CivilizationType = "CIVILIZATION_CHINA",
                BuildingClassType = "BUILDINGCLASS_LIBRARY",
                BuildingType = "BUILDING_PAPER_MAKER",
            },
        })
        GameInfo.UnitClasses = infoTable({ { Type = "UNITCLASS_SWORDSMAN", DefaultUnit = "UNIT_SWORDSMAN" } })
        GameInfo.Units = infoTable({
            {
                Type = "UNIT_SWORDSMAN",
                Class = "UNITCLASS_SWORDSMAN",
                PrereqTech = "TECH_IRON_WORKING",
                Description = "Swordsman",
            },
            {
                Type = "UNIT_LEGION",
                Class = "UNITCLASS_SWORDSMAN",
                PrereqTech = "TECH_IRON_WORKING",
                Description = "Legion",
            },
        })
        GameInfo.Civilization_UnitClassOverrides = infoTable({
            { CivilizationType = "CIVILIZATION_ROME", UnitClassType = "UNITCLASS_SWORDSMAN", UnitType = "UNIT_LEGION" },
        })

        local available = Rpc._queries.tech_plan().available
        T.eq(#available, 1)
        T.eq(available[1].name, "Writing")
        T.eq(
            table.concat(available[1].unlocks.buildings, ","),
            "Library",
            "another civilization's unique building is left out"
        )

        local library = Rpc._queries.tech_plan("Library").target
        T.eq(library.kind, "building")
        T.eq(library.tech, "Writing")
        T.eq(library.alreadyKnown, false)
        T.eq(#library.path, 1, "Pottery is known, so only Writing remains")

        local iron = Rpc._queries.tech_plan("Iron Working").target
        T.eq(table.concat(iron.path[1].unlocks.units, ","), "Legion", "Rome trains the Legion, not the Swordsman")
    end)
end

-- turn summary --------------------------------------------------------------

function M.test_turn_summary_splits_notifications_and_caps_messages()
    withEnv(function()
        local notes = {
            [0] = { turn = 9, dismissed = true, text = "Old news" },
            [1] = { turn = 5, dismissed = true, text = "Ancient news" },
            [2] = { turn = 10, dismissed = false, text = "Pick research" },
        }
        Players[0] = fake({
            GetEndTurnBlockingType = EndTurnBlockingTypes.NO_ENDTURN_BLOCKING_TYPE,
            GetNumNotifications = 3,
            GetNotificationTurn = function(i)
                return notes[i].turn
            end,
            GetNotificationDismissed = function(i)
                return notes[i].dismissed
            end,
            GetNotificationStr = function(i)
                return notes[i].text
            end,
        })
        civvaccess_shared.messageBuffer = {
            entries = {
                { text = "a", category = "combat" },
                { text = "b", category = "reveal" },
                { text = "c", category = "notification" },
            },
        }
        civvaccess_shared.combatLog = { { text = "Warrior attacked", x = 1, y = 2 } }
        local data = Rpc._queries.turn_summary("2")
        T.eq(data.waitingOn, nil)
        T.eq(#data.notifications, 1)
        T.eq(data.notifications[1].text, "Pick research")
        T.eq(#data.dismissedRecently, 1, "dismissed before last turn is dropped")
        T.eq(data.dismissedRecently[1].text, "Old news")
        T.eq(#data.recentMessages, 2)
        T.eq(data.recentMessages[1].text, "b", "the newest entries are kept")
        T.eq(data.turnLog.combat[1].x, 1)
        T.eq(#data.turnLog.unitMoves, 0)
    end)
end

function M.test_turn_summary_names_the_end_turn_blocker()
    withEnv(function()
        Turn = {
            blockerText = function()
                return "Choose research"
            end,
        }
        Players[0] = fake({
            GetEndTurnBlockingType = EndTurnBlockingTypes.ENDTURN_BLOCKING_RESEARCH,
            GetNumNotifications = 0,
        })
        local data = Rpc._queries.turn_summary()
        T.eq(data.waitingOn.type, "ENDTURN_BLOCKING_RESEARCH")
        T.eq(data.waitingOn.text, "Choose research")
    end)
end

-- diplomacy -----------------------------------------------------------------

function M.test_diplomacy_hides_the_unmet_and_reads_mood_only_where_shown()
    withEnv(function()
        GameInfo.Eras = infoTable({ { Type = "ERA_ANCIENT", Description = "Ancient Era" } })
        local met = { [0] = true, [1] = true, [2] = true, [3] = false, [22] = true }
        local atWar = { [2] = true }
        Teams[0] = fake({
            IsHasMet = function(t)
                return met[t] == true
            end,
            IsAtWar = function(t)
                return atWar[t] == true
            end,
            IsDefensivePact = false,
            IsHasResearchAgreement = false,
            IsAllowsOpenBordersToTeam = false,
            HasEmbassyAtTeam = false,
        })
        local otherTeam = fake({ IsAllowsOpenBordersToTeam = true, HasEmbassyAtTeam = false })
        Teams[1], Teams[2], Teams[22] = otherTeam, otherTeam, otherTeam
        Players[0] = fake({
            GetTeam = 0,
            IsAlive = true,
            IsBarbarian = false,
            IsMinorCiv = false,
            IsDoF = false,
            IsDenouncedPlayer = false,
            GetApproachTowardsUsGuess = MajorCivApproachTypes.MAJOR_CIV_APPROACH_FRIENDLY,
        })
        local function major(team, civ)
            return fake({
                GetTeam = team,
                IsAlive = true,
                IsBarbarian = false,
                IsMinorCiv = false,
                IsHuman = false,
                GetCivilizationShortDescription = civ,
                GetName = civ .. " leader",
                GetScore = 10,
                GetCurrentEra = 0,
                GetNumCities = 1,
                IsDenouncingPlayer = false,
                GetOpinionTable = {
                    "[COLOR_NEGATIVE_TEXT]You settled too close to them.[ENDCOLOR]",
                    "[COLOR_FADING_POSITIVE_TEXT]You share a common enemy.[ENDCOLOR]",
                },
            })
        end
        Players[1] = major(1, "Greece")
        Players[2] = major(2, "Persia")
        Players[3] = major(3, "Siam")
        Players[22] = fake({
            GetTeam = 22,
            IsAlive = true,
            IsBarbarian = false,
            IsMinorCiv = true,
            GetCivilizationShortDescription = "Geneva",
            GetMinorCivTrait = MinorCivTraitTypes.MINOR_CIV_TRAIT_RELIGIOUS,
            GetMinorCivFriendshipWithMajor = 35,
            IsFriends = true,
            IsAllies = false,
            GetAlly = 3,
            GetMinorCivNumDisplayedQuestsForPlayer = 1,
            GetCapitalCity = function()
                return nil
            end,
        })
        GetActiveQuestToolTip = function()
            return "Clear a barbarian camp"
        end

        local data = Rpc._queries.diplomacy()
        T.eq(#data.civilizations, 2, "Siam is unmet")
        T.eq(data.civilizations[1].civ, "Greece")
        T.eq(data.civilizations[1].mood, "friendly")
        T.eq(data.civilizations[2].mood, nil, "no mood is shown for a civ at war")
        local opinions = data.civilizations[1].opinions
        T.eq(opinions[1].valence, -3, "a strong grievance")
        T.eq(opinions[1].text, "You settled too close to them.", "colour markup stripped")
        T.eq(opinions[2].valence, 1)
        T.eq(data.civilizations[2].opinions, nil, "no reasons for a civ at war")
        T.eq(data.civilizations[1].openBordersFromThem, true)
        local geneva = data.cityStates[1]
        T.eq(geneva.trait, "religious")
        T.eq(geneva.ally, nil, "an unmet ally stays unnamed")
        T.eq(geneva.hasUnmetAlly, true)
        T.eq(geneva.quests, "Clear a barbarian camp")
    end)
end

-- victory -------------------------------------------------------------------

function M.test_victory_progress_names_only_met_civs()
    withEnv(function()
        save(PreGame, "IsVictory")
        save(GameInfoTypes, "PROJECT_APOLLO_PROGRAM")
        save(Game, "GetActiveTeam")
        GameInfo.Victories = infoTable({ { Type = "VICTORY_DOMINATION" }, { Type = "VICTORY_SPACE_RACE" } })
        PreGame.IsVictory = function()
            return true
        end
        GameInfoTypes.PROJECT_APOLLO_PROGRAM = 50
        Game.GetActiveTeam = function()
            return 0
        end
        local met = { [0] = true, [1] = true, [2] = false }
        local function team(apollo)
            return fake({
                IsHasMet = function(t)
                    return met[t] == true
                end,
                GetProjectCount = function(proj)
                    return (proj == 50 and apollo) and 1 or 0
                end,
            })
        end
        Teams[0], Teams[1], Teams[2] = team(false), team(false), team(true)
        local function capital(originalOwner, holder)
            return fake({ IsOriginalMajorCapital = true, GetOriginalOwner = originalOwner, GetOwner = holder })
        end
        EngineData.dominationController = function(city)
            return city:GetOwner()
        end
        local function major(id, civ, cities)
            return fake({
                GetTeam = id,
                IsEverAlive = true,
                IsAlive = true,
                IsMinorCiv = false,
                GetCivilizationShortDescription = civ,
                Cities = iterate(cities),
            })
        end
        -- Siam (unmet) took Greece's capital.
        Players[0] = major(0, "Babylon", { capital(0, 0) })
        Players[1] = major(1, "Greece", {})
        Players[2] = major(2, "Siam", { capital(2, 2), capital(1, 2) })
        GameDefines.MAX_MAJOR_CIVS = 3
        GameDefines.MAX_CIV_PLAYERS = 3

        local data = Rpc._queries.victory_progress()
        local greece = data.domination.capitals[2]
        T.eq(greece.civ, "Greece")
        T.eq(greece.heldBy, "unmet civilization", "the unmet conqueror stays unnamed")
        T.eq(data.domination.capitals[3].civ, "unmet civilization")
        T.eq(data.domination.yourCapitalsHeld, 1)
        T.eq(data.science.teams[1].civ, "you")
        T.eq(data.science.teams[3].civ, "unmet civilization", "an unmet team's spaceship is listed unnamed")
        T.eq(data.science.teams[3].apollo, true)
        T.eq(data.science.civsWithApollo, 1)
        T.eq(data.time, nil, "a disabled victory type is left out")
    end)
end

-- rules ---------------------------------------------------------------------

function M.test_explain_reads_the_loaded_rules_and_drops_undefined_text()
    withEnv(function()
        GameInfo.Technologies = infoTable({ { Type = "TECH_POTTERY", Description = "Pottery" } })
        GameInfo.Buildings = infoTable({
            {
                Type = "BUILDING_GRANARY",
                Description = "Granary",
                Help = "[ICON_FOOD] +2 Food.",
                Strategy = "TXT_KEY_NEVER_DEFINED",
                Cost = 65,
                GoldMaintenance = 1,
                PrereqTech = "TECH_POTTERY",
            },
        })
        local data = Rpc._queries.explain("granary")
        T.eq(data.kind, "building")
        T.eq(data.baseCost, 65)
        T.eq(data.unlockedBy, "Pottery")
        T.truthy(data.help ~= nil and not data.help:find("[ICON", 1, true), "icon markup filtered")
        T.eq(data.strategy, nil, "an undefined key is not returned as raw text")
        T.eq(data.baseStrength, nil, "fields a building lacks are omitted")
        local ok, err = pcall(Rpc._queries.explain, "granary", "unit")
        T.falsy(ok, "a kind filter that excludes the match fails")
        T.truthy(tostring(err):find("of kind unit", 1, true))
    end)
end

function M.test_explain_civilization_by_leader_or_adjective_lists_traits_and_uniques()
    withEnv(function()
        GameInfo.Civilizations = infoTable({
            {
                Type = "CIVILIZATION_BABYLON",
                Description = "Babylonian Empire",
                ShortDescription = "Babylon",
                Adjective = "Babylonian",
            },
            { Type = "CIVILIZATION_BARBARIAN", Description = "Barbarians", ShortDescription = "Barbarians" },
        })
        GameInfo.Leaders = infoTable({
            { Type = "LEADER_NEBUCHADNEZZAR", Description = "Nebuchadnezzar II" },
            { Type = "LEADER_HAMMURABI", Description = "Hammurabi" },
        })
        GameInfo.Civilization_Leaders = infoTable({
            { CivilizationType = "CIVILIZATION_BABYLON", LeaderheadType = "LEADER_NEBUCHADNEZZAR" },
            { CivilizationType = "CIVILIZATION_BABYLON", LeaderheadType = "LEADER_HAMMURABI" },
        })
        GameInfo.Traits = infoTable({
            {
                Type = "TRAIT_INGENUITY",
                ShortDescription = "Ingenuity",
                Description = "[ICON_GREAT_PEOPLE] Free Great Scientist.",
            },
            { Type = "TRAIT_CODE", ShortDescription = "TXT_KEY_NEVER_DEFINED", Description = "Laws." },
            { Type = "TRAIT_UNNAMED", ShortDescription = "TXT_KEY_NEVER_DEFINED" },
        })
        GameInfo.Leader_Traits = infoTable({
            { LeaderType = "LEADER_NEBUCHADNEZZAR", TraitType = "TRAIT_INGENUITY" },
            { LeaderType = "LEADER_HAMMURABI", TraitType = "TRAIT_CODE" },
            { LeaderType = "LEADER_HAMMURABI", TraitType = "TRAIT_UNNAMED" },
        })
        GameInfo.Trait_NoTrain = infoTable({
            { TraitType = "TRAIT_INGENUITY", UnitClassType = "UNITCLASS_SETTLER" },
            { TraitType = "TRAIT_CODE", UnitClassType = "UNITCLASS_MISSIONARY" },
        })
        GameInfo.Units = infoTable({
            { Type = "UNIT_ARCHER", Description = "Archer" },
            { Type = "UNIT_BABYLONIAN_BOWMAN", Description = "Bowman" },
            { Type = "UNIT_SETTLER", Description = "Settler" },
            { Type = "UNIT_MISSIONARY", Description = "Missionary" },
            { Type = "UNIT_FUSTA", Description = "Fusta" },
        })
        GameInfo.UnitClasses = infoTable({
            { Type = "UNITCLASS_ARCHER", DefaultUnit = "UNIT_ARCHER" },
            { Type = "UNITCLASS_SETTLER", DefaultUnit = "UNIT_SETTLER" },
            { Type = "UNITCLASS_MISSIONARY", DefaultUnit = "UNIT_MISSIONARY" },
            { Type = "UNITCLASS_FUSTA" },
        })
        GameInfo.Civilization_UnitClassOverrides = infoTable({
            {
                CivilizationType = "CIVILIZATION_BABYLON",
                UnitClassType = "UNITCLASS_ARCHER",
                UnitType = "UNIT_BABYLONIAN_BOWMAN",
            },
            { CivilizationType = "CIVILIZATION_BABYLON", UnitClassType = "UNITCLASS_SETTLER" },
            { CivilizationType = "CIVILIZATION_BABYLON", UnitClassType = "UNITCLASS_FUSTA", UnitType = "UNIT_FUSTA" },
            { CivilizationType = "CIVILIZATION_OTHER", UnitClassType = "UNITCLASS_ARCHER", UnitType = "UNIT_ARCHER" },
        })
        GameInfo.Buildings = infoTable({
            { Type = "BUILDING_WALLS", Description = "Walls" },
            { Type = "BUILDING_WALLS_OF_BABYLON", Description = "Walls of Babylon" },
            { Type = "BUILDING_WELL", Description = "Well" },
        })
        GameInfo.BuildingClasses = infoTable({
            { Type = "BUILDINGCLASS_WALLS", DefaultBuilding = "BUILDING_WALLS" },
            { Type = "BUILDINGCLASS_WELL", DefaultBuilding = "BUILDING_WELL" },
        })
        GameInfo.Civilization_BuildingClassOverrides = infoTable({
            {
                CivilizationType = "CIVILIZATION_BABYLON",
                BuildingClassType = "BUILDINGCLASS_WALLS",
                BuildingType = "BUILDING_WALLS_OF_BABYLON",
            },
            { CivilizationType = "CIVILIZATION_BABYLON", BuildingClassType = "BUILDINGCLASS_WELL" },
        })
        GameInfo.Improvements = infoTable({
            { Type = "IMPROVEMENT_FARM", Description = "Farm" },
            {
                Type = "IMPROVEMENT_GARDEN_TERRACE",
                Description = "Garden Terrace",
                CivilizationType = "CIVILIZATION_BABYLON",
            },
        })
        local data = Rpc._queries.explain("Nebuchadnezzar II")
        T.eq(data.kind, "civilization")
        T.eq(data.name, "Babylon", "the short name, not the empire description")
        T.eq(#data.leaders, 2, "every leader of the civilization is listed")
        T.eq(data.leaders[1].traits[1].name, "Ingenuity")
        T.falsy(data.leaders[1].traits[1].effect:find("[ICON", 1, true), "trait markup filtered")
        T.eq(data.leaders[2].traits[1].name, nil, "an undefined trait name is dropped, not returned raw")
        T.eq(data.leaders[2].traits[1].effect, "Laws.")
        T.eq(#data.leaders[2].traits, 1, "a trait with no defined text at all is left out")
        T.eq(#data.uniqueUnits, 2, "another civilization's override is not listed")
        T.eq(data.uniqueUnits[1].name, "Bowman")
        T.eq(data.uniqueUnits[1].replaces, "Archer")
        T.eq(data.uniqueUnits[2].name, "Fusta")
        T.eq(data.uniqueUnits[2].replaces, nil, "a class without a standard unit replaces nothing")
        T.eq(table.concat(data.cannotTrain, ","), "Settler,Missionary", "override and trait bans, each named once")
        T.eq(data.uniqueBuildings[1].name, "Walls of Babylon")
        T.eq(data.uniqueBuildings[1].replaces, "Walls")
        T.eq(data.cannotBuild[1], "Well", "an override without a building means the class cannot be built")
        T.eq(#data.uniqueImprovements, 1)
        T.eq(Rpc._queries.explain("babylonian").name, "Babylon", "the adjective resolves too")
        T.eq(Rpc._queries.explain("babylon").name, "Babylon", "and so does the short name")
        T.falsy(pcall(Rpc._queries.explain, "barbarians"), "the barbarians are not a civilization to explain")
    end)
end

-- settings ------------------------------------------------------------------

function M.test_game_settings_lists_what_the_game_menu_shows()
    withEnv(function()
        GameInfo.Eras = infoTable({
            { Type = "ERA_ANCIENT", Description = "Ancient Era" },
            { Type = "ERA_CLASSICAL", Description = "Classical Era" },
        })
        GameInfo.Worlds = infoTable({
            { Type = "WORLDSIZE_SMALL", Description = "Small", DefaultMinorCivs = 8 },
            { Type = "WORLDSIZE_HUGE", Description = "Huge", DefaultMinorCivs = 24 },
        })
        GameInfo.HandicapInfos = infoTable({
            { Type = "HANDICAP_SETTLER", Description = "Settler" },
            { Type = "HANDICAP_WARLORD", Description = "Warlord" },
        })
        GameInfo.GameSpeeds = infoTable({
            { Type = "GAMESPEED_STANDARD", Description = "Standard" },
            { Type = "GAMESPEED_MARATHON", Description = "Marathon" },
        })
        GameInfo.Victories = infoTable({
            { Type = "VICTORY_TIME", Description = "Time" },
            { Type = "VICTORY_SPACE_RACE", Description = "Science" },
        })
        GameInfo.GameOptions = infoTable({
            {
                Type = "GAMEOPTION_CHILL_BARBARIANS",
                Description = "Chill Barbarians",
                Help = "[ICON_WAR] Fewer barbarians.",
                Visible = 1,
                SupportsSinglePlayer = 1,
                SupportsMultiplayer = 1,
            },
            { Type = "GAMEOPTION_NO_HELP", Description = "No help", Visible = 1, SupportsSinglePlayer = 1 },
            { Type = "GAMEOPTION_OFF", Description = "Off", Visible = 1, SupportsSinglePlayer = 1 },
            { Type = "GAMEOPTION_HIDDEN", Description = "Hidden", Visible = 0, SupportsSinglePlayer = 1 },
            { Type = "GAMEOPTION_MP_ONLY", Description = "Multiplayer only", Visible = 1, SupportsMultiplayer = 1 },
        })
        local minorCivs, maxTurns, network = 16, 1500, false
        PreGame = {
            GetEra = function()
                return 1
            end,
            GetWorldSize = function()
                return 1
            end,
            GetHandicap = function(player)
                return player == 0 and 1 or 0
            end,
            GetGameSpeed = function()
                return 1
            end,
            GetMapScript = function()
                return "Assets\\Maps\\Earth_Huge.Civ5Map"
            end,
            GetNumMinorCivs = function()
                return minorCivs
            end,
            IsVictory = function(id)
                return id == 1
            end,
            GetGameOption = function(optionType)
                if optionType == "GAMEOPTION_OFF" then
                    return 0
                end
                return 1
            end,
        }
        MapUtilities = {
            GetBasicInfo = function(fileName)
                return { Name = fileName == "Assets\\Maps\\Earth_Huge.Civ5Map" and "Earth" or "TXT_KEY_MISC_UNKNOWN" }
            end,
        }
        Game.GetMaxTurns = function()
            return maxTurns
        end
        Game.GetStartTurn = function()
            return 20
        end
        Game.IsNetworkMultiPlayer = function()
            return network
        end
        for i = 0, GameDefines.MAX_CIV_PLAYERS - 1 do
            Players[i] = fake({ IsEverAlive = i < 3 or i >= GameDefines.MAX_MAJOR_CIVS })
        end
        local data = Rpc._queries.game_settings()
        T.eq(data.startEra, "Classical Era")
        T.eq(data.mapSize, "Huge")
        T.eq(data.pace, "Marathon")
        T.eq(data.difficulty, "Warlord", "the active player's difficulty")
        T.eq(data.lastTurn, 1520, "the turn limit counts from the start turn")
        T.eq(data.mapType, "Earth", "the map is named as the game menu names it")
        T.eq(#data.victoryTypes, 1)
        T.eq(data.victoryTypes[1], "Science")
        T.eq(#data.gameOptions, 2, "disabled, hidden and multiplayer-only options are left out")
        T.eq(data.gameOptions[1].name, "Chill Barbarians")
        T.falsy(data.gameOptions[1].help:find("[ICON", 1, true), "help markup filtered")
        T.eq(data.gameOptions[2].help, nil, "an option without help text has none")
        T.eq(data.civilizations, 3)
        T.eq(data.cityStates, 16, "the setup value, not the city-state slots that ever lived")

        minorCivs, maxTurns, network = -1, 0, true
        data = Rpc._queries.game_settings()
        T.eq(data.cityStates, 24, "the setup default follows the map size")
        T.eq(data.lastTurn, nil, "no turn limit, no last turn")
        T.eq(#data.gameOptions, 2, "a network game lists the multiplayer options")
        T.eq(data.gameOptions[2].name, "Multiplayer only")
    end)
end

-- decisions, great people, trade, congress ----------------------------------

-- Player 0 has met player 1 and not player 2.
local function installMeeting()
    Teams[0] = fake({
        IsHasMet = function(team)
            return team ~= 2
        end,
    })
    for i = 1, 2 do
        Players[i] = fake({
            GetTeam = i,
            GetCivilizationShortDescription = i == 1 and "Egypt" or "Secret",
            IsMinorCiv = false,
            IsAlive = true,
        })
    end
end

function M.test_decisions_list_only_what_waits_on_the_player()
    withEnv(function()
        GameInfo.Units = infoTable({ { Type = "UNIT_WARRIOR", Description = "Warrior" } })
        local function unit(id, ready)
            return fake({ GetID = id, GetUnitType = 0, Ready = ready })
        end
        local units = { unit(7, true), unit(8, false) }
        EngineData.unitPromotionReady = function(u)
            return u:Ready()
        end
        GameInfo.PolicyBranchTypes = infoTable({ { Type = "POLICY_BRANCH_TRADITION" } })
        GameInfo.Policies = infoTable({ { Type = "POLICY_ARISTOCRACY" } })
        local culture, open = 40, false
        Players[0] = fake({
            CanUnlockPolicyBranch = false,
            CanAdoptPolicy = function()
                return open
            end,
            GetNumFreePolicies = 1,
            GetNumFreeTenets = 0,
            GetNumFreeTechs = 0,
            GetNumFreeGreatPeople = 0,
            GetNumMayaBoosts = 0,
            GetJONSCulture = function()
                return culture
            end,
            GetNextPolicyCost = 50,
            HasCreatedPantheon = false,
            CanCreatePantheon = function(checkFaith)
                return checkFaith == true
            end,
            GetCurrentResearch = -1,
            Cities = iterate({
                fake({ GetName = "Babylon", GetOrderQueueLength = 0, IsPuppet = false }),
                fake({ GetName = "Ur", GetOrderQueueLength = 1, IsPuppet = false }),
                fake({ GetName = "Kish", GetOrderQueueLength = 0, IsPuppet = true }),
            }),
            Units = iterate(units),
        })
        local data = Rpc._queries.decisions()
        T.eq(data.freePolicies, 1)
        T.eq(data.freeTenets, nil, "nothing to decide, no field")
        T.eq(data.policyAffordable, nil, "40 culture of 50 is not yet a policy")
        T.eq(data.pantheonAvailable, true, "checked against the faith the player has")
        T.eq(data.researchNotSet, true)
        T.eq(table.concat(data.citiesWithoutProduction, ","), "Babylon", "a puppet picks its own production")
        T.eq(#data.promotionsReady, 1)
        T.eq(data.promotionsReady[1].id, 7)
        culture = 60
        T.eq(Rpc._queries.decisions().policyAffordable, nil, "culture buys nothing once every policy is taken")
        open = true
        T.eq(Rpc._queries.decisions().policyAffordable, true)
    end)
end

function M.test_great_people_per_city_with_turns_where_the_rate_is_known()
    withEnv(function()
        GameInfo.Specialists = infoTable({
            { Type = "SPECIALIST_SCIENTIST", GreatPeopleUnitClass = "UNITCLASS_SCIENTIST" },
            { Type = "SPECIALIST_ENGINEER", GreatPeopleUnitClass = "UNITCLASS_ENGINEER" },
            { Type = "SPECIALIST_CITIZEN" },
        })
        GameInfo.UnitClasses = infoTable({
            { Type = "UNITCLASS_SCIENTIST", Description = "Great Scientist" },
            { Type = "UNITCLASS_ENGINEER", Description = "Great Engineer" },
        })
        local city = fake({
            GetName = "Babylon",
            GetSpecialistGreatPersonProgress = function(id)
                return id == 0 and 40 or 0
            end,
            GetSpecialistRate = function(id)
                return id == 0 and 450 or 0
            end,
            GetSpecialistUpgradeThreshold = 100,
        })
        Players[0] = fake({
            Cities = iterate({ city }),
            GetCombatExperience = 30,
            GreatGeneralThreshold = 200,
            GetNavalCombatExperience = 0,
            GreatAdmiralThreshold = 200,
            GetFaith = 50,
            GetMinimumFaithNextGreatProphet = 300,
        })
        local data = Rpc._queries.great_people()
        T.eq(#data.fromSpecialists, 1, "a type no city earns points for is left out")
        local sci = data.fromSpecialists[1]
        T.eq(sci.name, "Great Scientist")
        T.eq(sci.cities[1].perTurn, 4.5)
        T.eq(sci.cities[1].turns, 14, "60 points to go at 4.5 a turn")
        T.eq(data.general.threshold, 200)
        T.eq(data.prophet.faithNeeded, 300)
    end)
end

function M.test_trade_routes_name_both_ends_and_rank_candidates()
    withEnv(function()
        installMeeting()
        local function route(toID, gold, extra)
            local r = {
                FromID = 0,
                FromCityName = "Babylon",
                ToID = toID,
                ToCityName = "Thebes",
                Domain = DomainTypes.DOMAIN_LAND,
                FromGPT = gold,
                ToGPT = 150,
                FromScience = 0,
                ToScience = 0,
                ToFood = 0,
                ToProduction = 0,
                FromReligion = 0,
                FromPressure = 0,
                ToReligion = 0,
                ToPressure = 0,
            }
            for k, v in pairs(extra or {}) do
                r[k] = v
            end
            return r
        end
        local candidates = {}
        for i = 1, 12 do
            candidates[i] = route(1, i * 100)
        end
        candidates[13] = route(0, 0, { ToFood = 2000 })
        Players[0] = fake({
            GetTeam = 0,
            GetTradeRoutes = { route(1, 400, { TurnsLeft = 12 }) },
            GetTradeRoutesToYou = { route(2, 300) },
            GetTradeRoutesAvailable = candidates,
            GetNumInternationalTradeRoutesUsed = 1,
            GetNumInternationalTradeRoutesAvailable = 2,
        })
        local data = Rpc._queries.trade_routes()
        local mine = data.yourRoutes[1]
        T.eq(mine.from.city, "Babylon")
        T.eq(mine.from.civ, nil, "your own city needs no civilization")
        T.eq(mine.to.civ, "Egypt")
        T.eq(mine.originGets.gold, 4)
        T.eq(mine.originGets.science, nil, "zero yields are left out")
        T.eq(mine.turnsLeft, 12)
        T.eq(data.routesToYou[1].to.civ, "unmet civilization", "an unmet partner stays unnamed")
        T.eq(data.availableCount, 13)
        T.eq(#data.bestAvailable, 10)
        T.eq(data.bestAvailable[1].destinationGets.food, 20, "an internal route's food counts for you")
        T.eq(data.bestAvailable[2].originGets.gold, 12)
    end)
end

function M.test_world_congress_reads_the_session_and_hides_the_unmet()
    withEnv(function()
        Game.GetNumActiveLeagues = function()
            return 0
        end
        T.eq(Rpc._queries.world_congress().active, false)

        installMeeting()
        Players[0] = fake({ GetTeam = 0, IsAlive = true, IsMinorCiv = false })
        local votes = { [0] = 4, [1] = 6, [2] = 2 }
        local league = fake({
            GetName = "World Congress",
            IsInSession = true,
            IsInSpecialSession = false,
            GetHostMember = 1,
            IsMember = function(i)
                return votes[i] ~= nil
            end,
            CalculateStartingVotesForMember = function(i)
                return votes[i]
            end,
            GetRemainingVotesForMember = 3,
            GetEnactProposals = { { Type = 5, ID = 9, ProposalPlayer = 2 } },
            GetRepealProposals = {},
            GetEnactProposalsOnHold = {},
            GetRepealProposalsOnHold = {},
            GetActiveResolutions = { { Type = 6, ID = 2 } },
            GetResolutionName = function(t)
                return t == 5 and "Embargo" or "Arts Funding"
            end,
            GetResolutionDetails = function(t)
                return t == 5 and "[ICON_GOLD] No trade routes." or ""
            end,
        })
        Game.GetNumActiveLeagues = function()
            return 1
        end
        Game.GetActiveLeague = function()
            return league
        end
        Game.IsUnitedNationsActive = function()
            return false
        end
        for i = 3, GameDefines.MAX_MAJOR_CIVS - 1 do
            Players[i] = fake({ IsAlive = false })
        end
        local data = Rpc._queries.world_congress()
        T.eq(data.inSession, true)
        T.eq(data.yourVotesLeft, 3)
        T.eq(data.members[1].civ, "Egypt", "most delegates first")
        T.eq(data.members[1].host, true)
        T.eq(data.members[3].civ, "unmet civilization")
        T.eq(data.proposals[1].name, "Embargo")
        T.eq(data.proposals[1].proposedBy, "unmet civilization")
        T.falsy(data.proposals[1].details:find("[ICON", 1, true), "markup filtered")
        T.eq(data.resolutionsInForce[1].details, nil, "empty details are left out")
    end)
end

return M
