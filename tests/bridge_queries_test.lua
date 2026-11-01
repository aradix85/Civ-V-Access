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
    }) do
        save(_G, name)
    end
    for _, k in ipairs({
        "GetActivePlayer",
        "GetGameTurn",
        "GetGameTurnYear",
        "GetResourceUsageType",
        "GetReligionName",
    }) do
        save(Game, k)
    end
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
        FoodDifference = opts.food,
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
        })
        local data = Rpc._queries.city_details()
        local rome, antium = data.cities[1], data.cities[2]
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
        T.eq(data.civilizations[1].openBordersFromThem, true)
        local geneva = data.cityStates[1]
        T.eq(geneva.trait, "religious")
        T.eq(geneva.ally, nil, "an unmet ally stays unnamed")
        T.eq(geneva.hasUnmetAlly, true)
        T.eq(geneva.quests, "Clear a barbarian camp")
    end)
end

return M
