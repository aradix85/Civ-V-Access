-- MCP bridge actions (Rpc._actions and the CivVAccess_Bridge* files):
-- the dispatcher's gates and held-reply verification, and each action's
-- resolve / check / issue path against fake engine objects. Every case
-- asserts on the engine call that went out (or that none did), because a
-- wrong argument there is a silent wrong command in the player's game.

local T = require("support")
local M = {}

local saved
local calls -- engine commands issued, in order
local spoken
local sent -- rpc.respond payloads
local pending -- request line the next rpc.poll returns

local function save(tbl, key)
    saved[#saved + 1] = { tbl, key, tbl[key] }
end

local function restore()
    for i = #saved, 1, -1 do
        local s = saved[i]
        s[1][s[2]] = s[3]
    end
end

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

local function record(name)
    return function(...)
        calls[#calls + 1] = { name, ... }
    end
end

local TURN = 10

-- The stamp every action request carries after its name: turn, active
-- player, and the second it was issued.
local function stamp(turn, player, issued)
    return (turn or TURN) .. "\t" .. (player or 0) .. "\t" .. (issued or os.time())
end

local function withEnv(fn)
    saved, calls, spoken, sent, pending = {}, {}, {}, {}, nil
    for _, name in ipairs({
        "Players",
        "Teams",
        "EngineData",
        "Rpc",
        "Bridge",
        "BuildingInvest",
        "OrderTypes",
        "TaskTypes",
        "ActionSubTypes",
        "GameInfoActions",
        "UnitActionMenu",
        "UnitControl",
        "UnitSpeech",
        "PathDiagnostic",
        "SpeechPipeline",
        "rpc",
        "Network",
        "CityUpdateTypes",
        "HandlerStack",
    }) do
        save(_G, name)
    end
    for _, k in ipairs({
        "GetActivePlayer",
        "GetActiveTeam",
        "GetGameTurn",
        "IsProcessingMessages",
        "CityPushOrder",
        "CityPurchaseUnit",
        "CityPurchaseBuilding",
        "CityPurchaseProject",
        "SelectionListGameNetMessage",
        "GetAvailablePantheonBeliefs",
        "GetNumActiveLeagues",
        "GetActiveLeague",
        "GetNumLeaguesEverFounded",
        "GetLeague",
    }) do
        save(Game, k)
    end
    for _, k in ipairs({ "SelectUnit", "GetHeadSelectedUnit", "IsCityScreenUp", "GetInterfaceMode" }) do
        save(UI, k)
    end
    for _, k in ipairs({
        "Buildings",
        "Units",
        "Projects",
        "Processes",
        "Technologies",
        "Builds",
        "UnitPromotions",
        "Civilizations",
        "Civilization_UnitClassOverrides",
        "Civilization_BuildingClassOverrides",
        "Policies",
        "PolicyBranchTypes",
        "Beliefs",
        "Resolutions",
        "ResolutionDecisions",
    }) do
        save(GameInfo, k)
        GameInfo[k] = infoTable({})
    end
    for _, k in ipairs({ "SpecificCityInfoDirty", "AudioPlay2DSound" }) do
        save(Events, k)
        Events[k] = function() end
    end
    -- A reply left waiting by an earlier case would be answered as orphaned
    -- when this case installs the dispatcher.
    save(civvaccess_shared, "rpcPendingEnvelope")
    civvaccess_shared.rpcPendingEnvelope = nil
    save(GameInfoTypes, "MISSION_MOVE_TO")
    GameInfoTypes.MISSION_MOVE_TO = 77
    save(GameDefines, "MOVE_DENOMINATOR")
    GameDefines.MOVE_DENOMINATOR = 60
    -- The envelope's coordinate origin scans every player's cities; these
    -- cases are about actions, so there is no capital.
    save(HexGeom, "originCapital")
    HexGeom.originCapital = function()
        return nil
    end

    Players, Teams = {}, {}
    OrderTypes = { ORDER_TRAIN = 0, ORDER_CONSTRUCT = 1, ORDER_CREATE = 2, ORDER_MAINTAIN = 3 }
    TaskTypes = { TASK_SET_AUTOMATED_PRODUCTION = 9 }
    ActionSubTypes = { ACTIONSUBTYPE_BUILD = 5, ACTIONSUBTYPE_PROMOTION = 6 }
    CityUpdateTypes = { CITY_UPDATE_TYPE_BANNER = 0, CITY_UPDATE_TYPE_PRODUCTION = 1 }
    HandlerStack = {
        active = function()
            return { name = "Baseline" }
        end,
    }
    Game.GetActivePlayer = function()
        return 0
    end
    Game.GetActiveTeam = function()
        return 0
    end
    Game.GetGameTurn = function()
        return TURN
    end
    Game.IsProcessingMessages = function()
        return false
    end
    Game.CityPushOrder = record("CityPushOrder")
    Game.CityPurchaseUnit = record("CityPurchaseUnit")
    Game.CityPurchaseBuilding = record("CityPurchaseBuilding")
    Game.CityPurchaseProject = record("CityPurchaseProject")
    Game.SelectionListGameNetMessage = record("SelectionListGameNetMessage")
    Network = {
        SendResearch = record("SendResearch"),
        SendDoTask = record("SendDoTask"),
        SendUpdatePolicies = record("SendUpdatePolicies"),
        SendFoundPantheon = record("SendFoundPantheon"),
        SendLeagueVoteEnact = record("SendLeagueVoteEnact"),
        SendLeagueVoteRepeal = record("SendLeagueVoteRepeal"),
        SendMoveSpy = record("SendMoveSpy"),
    }
    SpeechPipeline = {
        speakQueued = function(s)
            spoken[#spoken + 1] = s
        end,
        speakInterrupt = function(s)
            spoken[#spoken + 1] = s
        end,
    }
    EngineData = {
        buildingInvestmentsEnabled = function()
            return false
        end,
        missionQueue = function()
            return {}
        end,
        unitPromotionReady = function()
            return false
        end,
        computePath = function()
            return {}, true, 2
        end,
        productionAutomationAvailable = function()
            return true
        end,
        isProductionAutomated = function(city)
            return city:IsProductionAutomated()
        end,
    }
    rpc = {
        poll = function()
            local line = pending
            pending = nil
            return line
        end,
        respond = function(s)
            sent[#sent + 1] = s
            return true
        end,
    }

    dofile("src/dlc/UI/Shared/CivVAccess_TextFilter.lua")
    dofile("src/dlc/UI/Shared/CivVAccess_Text.lua")
    dofile("src/dlc/UI/Shared/CivVAccess_TickPump.lua")
    TickPump._reset()
    dofile("src/dlc/UI/InGame/CivVAccess_Rpc.lua")
    dofile("src/dlc/UI/Shared/CivVAccess_BuildingInvest.lua")
    dofile("src/dlc/UI/InGame/CivVAccess_BridgeCore.lua")
    dofile("src/dlc/UI/InGame/CivVAccess_BridgeCity.lua")
    dofile("src/dlc/UI/InGame/CivVAccess_BridgeTech.lua")
    dofile("src/dlc/UI/InGame/CivVAccess_BridgeUnit.lua")
    dofile("src/dlc/UI/InGame/CivVAccess_BridgeEmpire.lua")
    dofile("src/dlc/UI/InGame/CivVAccess_BridgeLeague.lua")
    dofile("src/dlc/UI/InGame/CivVAccess_BridgeTrade.lua")
    dofile("src/dlc/UI/InGame/CivVAccess_BridgeSpy.lua")
    Rpc.installListeners()

    local ok, err = pcall(fn)
    restore()
    if not ok then
        error(err, 0)
    end
end

-- Runs one request line through the dispatcher and returns the decoded-ish
-- reply text once one is sent, ticking frames until it is.
local function request(line, maxFrames)
    for i = #sent, 1, -1 do
        sent[i] = nil
    end
    pending = line
    for _ = 1, maxFrames or 200 do
        TickPump.tick()
        if #sent > 0 then
            return sent[#sent]
        end
    end
    return nil
end

local function activePlayer(extra)
    GameInfo.Civilizations = infoTable({ { Type = "CIVILIZATION_BABYLON" } })
    local methods = { IsTurnActive = true, GetTeam = 0, GetCivilizationType = 0 }
    for k, v in pairs(extra or {}) do
        methods[k] = v
    end
    Players[0] = fake(methods)
    return Players[0]
end

-- dispatcher ----------------------------------------------------------------

function M.test_action_for_another_turn_is_refused_without_running()
    withEnv(function()
        activePlayer()
        local ran = false
        Rpc._actions.probe = function()
            ran = true
            return {}
        end
        local reply = request("id1\tprobe\t" .. stamp(9))
        T.truthy(reply:find('"ok":false', 1, true), reply)
        T.truthy(reply:find("turn 9", 1, true), "names the stale turn")
        T.falsy(ran, "a stale request must not act")
    end)
end

function M.test_action_outside_own_turn_is_refused()
    withEnv(function()
        activePlayer({ IsTurnActive = false })
        local ran = false
        Rpc._actions.probe = function()
            ran = true
            return {}
        end
        local reply = request("id1\tprobe\t" .. stamp())
        T.truthy(reply:find("not your turn", 1, true), reply)
        T.falsy(ran)
    end)
end

function M.test_reply_waits_for_verify_then_reports_confirmed()
    withEnv(function()
        activePlayer()
        local landed = false
        Rpc._actions.probe = function(arg)
            return { echoed = arg }, function()
                if landed then
                    return { seen = true }
                end
                return nil
            end
        end
        pending = "id1\tprobe\t" .. stamp() .. "\tx"
        TickPump.tick()
        TickPump.tick()
        T.eq(#sent, 0, "no reply before the effect is visible")
        pending = "id2\tping" -- a second request must wait its turn
        landed = true
        TickPump.tick()
        T.eq(#sent, 1)
        T.truthy(sent[1]:find('"id":"id1"', 1, true))
        T.truthy(sent[1]:find('"confirmed":true', 1, true), sent[1])
        T.truthy(sent[1]:find('"seen":true', 1, true))
        T.truthy(sent[1]:find('"echoed":"x"', 1, true), "action args start after the turn")
        T.eq(pending, "id2\tping", "the queued request was not consumed while waiting")
    end)
end

function M.test_unverified_action_replies_unconfirmed_after_timeout()
    withEnv(function()
        activePlayer()
        Rpc._actions.probe = function()
            return {}, function()
                return nil
            end
        end
        local now = 0
        Rpc._clock = function()
            now = now + 0.1
            return now
        end
        local reply = request("id1\tprobe\t" .. stamp(), 400)
        T.truthy(reply ~= nil, "a reply goes out even when the effect never shows")
        T.truthy(reply:find('"confirmed":false', 1, true), reply)
    end)
end

-- cities --------------------------------------------------------------------

local function installCity(opts)
    local queue = opts.queue or {}
    local city = fake({
        GetName = "Babylon",
        GetID = 1,
        GetOwner = 0,
        IsPuppet = opts.puppet or false,
        CanConstruct = opts.canBuild ~= false,
        CanTrain = opts.canBuild ~= false,
        GetOrderQueueLength = function()
            return #queue
        end,
        GetOrderFromQueue = function(i)
            local o = queue[i + 1]
            if o == nil then
                return -1, -1
            end
            return o[1], o[2]
        end,
        IsCanPurchase = opts.canPurchase or false,
        GetBuildingPurchaseCost = 120,
        GetUnitFaithPurchaseCost = 80,
        IsProductionAutomated = function()
            return opts.automated and opts.automated() or false
        end,
    })
    activePlayer({
        Cities = iterate({ city }),
        GetCityByID = city,
        GetGold = opts.gold or 500,
        GetFaith = opts.faith or 200,
    })
    return city, queue
end

function M.test_set_production_replace_sends_the_choosers_commit()
    withEnv(function()
        GameInfo.Buildings = infoTable({ { Type = "BUILDING_GRANARY", Description = "Granary" } })
        local _city, queue = installCity({})
        Game.CityPushOrder = function(c, orderType, id, bSave, bPop, bAppend)
            calls[#calls + 1] = { "CityPushOrder", orderType, id, bSave, bPop, bAppend }
            queue[1] = { orderType, id }
        end
        local reply = request("id1\tset_production\t" .. stamp() .. "\tbabylon\tgranary")
        T.eq(#calls, 1)
        local c = calls[1]
        T.eq(c[2], OrderTypes.ORDER_CONSTRUCT)
        T.eq(c[3], 0)
        T.eq(c[5], true, "replace pops the queue")
        T.eq(c[6], true)
        T.truthy(reply:find('"confirmed":true', 1, true), reply)
        T.truthy(spoken[1]:find("Babylon", 1, true) and spoken[1]:find("Granary", 1, true), spoken[1])
    end)
end

function M.test_set_production_refuses_what_the_city_cannot_build()
    withEnv(function()
        GameInfo.Buildings = infoTable({ { Type = "BUILDING_GRANARY", Description = "Granary" } })
        installCity({ canBuild = false })
        local reply = request("id1\tset_production\t" .. stamp() .. "\tBabylon\tGranary")
        T.truthy(reply:find("cannot build Granary", 1, true), reply)
        T.eq(#calls, 0, "nothing is issued after a failed check")
        T.eq(#spoken, 0)
    end)
end

function M.test_append_to_a_full_queue_is_refused()
    withEnv(function()
        GameInfo.Buildings = infoTable({ { Type = "BUILDING_GRANARY", Description = "Granary" } })
        installCity({ queue = { { 1, 0 }, { 1, 0 }, { 1, 0 }, { 1, 0 }, { 1, 0 }, { 1, 0 } } })
        local reply = request("id1\tset_production\t" .. stamp() .. "\tBabylon\tGranary\tappend")
        T.truthy(reply:find("queue is full", 1, true), reply)
        T.eq(#calls, 0)
    end)
end

function M.test_faith_purchase_uses_faith_and_confirms_on_spend()
    withEnv(function()
        GameInfo.Units = infoTable({ { Type = "UNIT_MISSIONARY", Description = "Missionary" } })
        local faith = 200
        installCity({
            canPurchase = true,
            faith = function()
                return faith
            end,
        })
        Game.CityPurchaseUnit = function(_c, id, yield)
            calls[#calls + 1] = { "CityPurchaseUnit", id, yield }
            faith = 120
        end
        local reply = request("id1\tpurchase\t" .. stamp() .. "\tBabylon\tmissionary\tfaith")
        T.eq(calls[1][1], "CityPurchaseUnit")
        T.eq(calls[1][3], YieldTypes.YIELD_FAITH)
        T.truthy(reply:find('"faithLeft":120', 1, true), reply)
    end)
end

function M.test_purchase_in_a_puppet_is_the_engines_call()
    withEnv(function()
        GameInfo.Units = infoTable({ { Type = "UNIT_MISSIONARY", Description = "Missionary" } })
        installCity({ puppet = true, canPurchase = true })
        Game.CityPurchaseUnit = function(_c, id, yield)
            calls[#calls + 1] = { "CityPurchaseUnit", id, yield }
        end
        request("id1\tpurchase\t" .. stamp() .. "\tBabylon\tmissionary\tfaith")
        T.eq(#calls, 1, "a puppet purchase the engine allows (Venice, Vox Populi) goes through")
    end)
end

function M.test_an_error_after_the_command_went_out_is_not_a_failure()
    withEnv(function()
        GameInfo.Buildings = infoTable({ { Type = "BUILDING_GRANARY", Description = "Granary" } })
        installCity({})
        Game.CityPushOrder = function()
            calls[#calls + 1] = { "CityPushOrder" }
        end
        Events.SpecificCityInfoDirty = function()
            error("banner refresh broke")
        end
        local reply = request("id1\tset_production\t" .. stamp() .. "\tBabylon\tGranary")
        T.eq(#calls, 1)
        T.truthy(reply:find('"ok":true', 1, true), "the command went out; the reply must not invite a retry")
        T.truthy(reply:find('"errorAfterSend":"banner refresh broke"', 1, true), reply)
        T.truthy(reply:find('"confirmed":false', 1, true), reply)
    end)
end

function M.test_city_automation_sends_the_city_screen_task()
    withEnv(function()
        local on = false
        installCity({
            automated = function()
                return on
            end,
        })
        Network.SendDoTask = function(...)
            calls[#calls + 1] = { "SendDoTask", ... }
            on = true
        end
        local reply = request("id1\tcity_automation\t" .. stamp() .. "\tBabylon\ton")
        local c = calls[1]
        T.eq(c[2], 1, "city id")
        T.eq(c[3], TaskTypes.TASK_SET_AUTOMATED_PRODUCTION)
        T.eq(c[6], true, "bOption carries the new state")
        T.eq(c[7], false, "no modifier keys: the queue is kept")
        T.truthy(reply:find('"confirmed":true', 1, true), reply)
    end)
end

-- research ------------------------------------------------------------------

function M.test_research_goal_named_by_its_unlock_resolves_to_the_tech()
    withEnv(function()
        GameInfo.Technologies = infoTable({ { Type = "TECH_WRITING", Description = "Writing" } })
        GameInfo.Buildings =
            infoTable({ { Type = "BUILDING_LIBRARY", Description = "Library", PrereqTech = "TECH_WRITING" } })
        Teams[0] = fake({ IsHasTech = false })
        local queued = false
        activePlayer({
            CanEverResearch = true,
            GetQueuePosition = function()
                return queued and 2 or -1
            end,
            GetCurrentResearch = 0,
            GetResearchTurnsLeft = 6,
        })
        Network.SendResearch = function(...)
            calls[#calls + 1] = { "SendResearch", ... }
            queued = true
        end
        local reply = request("id1\tset_research\t" .. stamp() .. "\tlibrary\tappend")
        T.eq(calls[1][1], "SendResearch")
        T.eq(calls[1][2], 0, "tech id of Writing")
        T.eq(calls[1][3], 0, "not a free tech")
        T.eq(calls[1][5], true, "append maps to the shift flag")
        T.truthy(reply:find('"unlocks":"Library"', 1, true), reply)
        T.truthy(reply:find('"turnsToGoal":6', 1, true), reply)
    end)
end

function M.test_research_of_a_known_tech_is_refused()
    withEnv(function()
        GameInfo.Technologies = infoTable({ { Type = "TECH_WRITING", Description = "Writing" } })
        Teams[0] = fake({ IsHasTech = true })
        activePlayer({ CanEverResearch = true })
        local reply = request("id1\tset_research\t" .. stamp() .. "\tWriting")
        T.truthy(reply:find("already know Writing", 1, true), reply)
        T.eq(#calls, 0)
    end)
end

-- units ---------------------------------------------------------------------

local function installUnit(opts)
    local unit = fake({
        GetID = 7,
        GetUnitType = 0,
        GetX = 5,
        GetY = 5,
        IsDead = false,
        MovesLeft = opts.moves or 120,
        MaxMoves = 120,
        GetDamage = opts.damage or 0,
        GetCurrHitPoints = 100 - (opts.damage or 0),
        GetMaxHitPoints = 100,
        GetDomainType = DomainTypes.DOMAIN_LAND,
        IsCombatUnit = true,
        IsReadyToMove = opts.idle or false,
        IsEmbarked = false,
        GetBaseCombatStrength = 8,
        GetBaseRangedCombatStrength = 0,
        CanUpgradeRightNow = false,
        GetBuildType = -1,
        GetActivityType = 0,
        GetUpgradeUnitType = -1,
        GetPlot = "plot",
    })
    GameInfo.Units = infoTable({ { Type = "UNIT_WARRIOR", Description = "Warrior" } })
    activePlayer({ GetUnitByID = unit, Units = iterate({ unit }) })
    UI.IsCityScreenUp = function()
        return false
    end
    UI.GetInterfaceMode = function()
        return InterfaceModeTypes.INTERFACEMODE_SELECTION
    end
    UI.SelectUnit = record("SelectUnit")
    UI.GetHeadSelectedUnit = function()
        return unit
    end
    UnitSpeech = {
        statusToken = function()
            return ""
        end,
    }
    return unit
end

function M.test_units_lists_idle_units_with_health_only_when_hurt()
    withEnv(function()
        installUnit({ idle = true, damage = 30 })
        local data = Rpc._queries.units("idle")
        T.eq(#data.units, 1)
        local u = data.units[1]
        T.eq(u.id, 7)
        T.eq(u.name, "Warrior")
        T.eq(u.hp, 70)
        T.eq(u.movesLeft, 2)
        installUnit({ idle = false })
        T.eq(#Rpc._queries.units("idle").units, 0, "a unit with orders is not idle")
        T.eq(Rpc._queries.units().units[1].hp, nil, "a healthy unit carries no hp field")
    end)
end

function M.test_unknown_unit_action_fails_before_selecting()
    withEnv(function()
        installUnit({})
        local reply = request("id1\tunit_action\t" .. stamp() .. "\t7\tdance")
        T.truthy(reply:find("unknown unit action", 1, true), reply)
        T.eq(#calls, 0, "the player's selection is left alone")
    end)
end

function M.test_move_onto_an_enemy_is_left_to_the_player()
    withEnv(function()
        installUnit({})
        save(Map, "GetPlot")
        Map.GetPlot = function()
            return fake({ IsRevealed = true })
        end
        UnitControl = {
            enemyAt = function()
                return "defender"
            end,
            enemyCityAt = function()
                return nil
            end,
        }
        local reply = request("id1\tunit_action\t" .. stamp() .. "\t7\tmove\t6\t5")
        T.truthy(reply:find("attacks stay with the player", 1, true), reply)
        for _, c in ipairs(calls) do
            T.truthy(c[1] ~= "SelectionListGameNetMessage", "no move was pushed")
        end
    end)
end

function M.test_move_pushes_move_to_and_registers_the_announcement()
    withEnv(function()
        installUnit({})
        save(Map, "GetPlot")
        Map.GetPlot = function()
            return fake({ IsRevealed = true, GetX = 6, GetY = 4 })
        end
        UnitControl = {
            enemyAt = function()
                return nil
            end,
            enemyCityAt = function()
                return nil
            end,
            registerPending = record("registerPending"),
        }
        PathDiagnostic = {
            discriminativePath = function()
                return { ok = "strict" }
            end,
        }
        request("id1\tunit_action\t" .. stamp() .. "\t7\tmove\t6\t4", 3)
        local names = {}
        for _, c in ipairs(calls) do
            names[#names + 1] = c[1]
        end
        T.eq(table.concat(names, ","), "SelectUnit,registerPending,SelectionListGameNetMessage")
        local push = calls[3]
        T.eq(push[2], GameMessageTypes.GAMEMESSAGE_PUSH_MISSION)
        T.eq(push[3], 77, "MISSION_MOVE_TO")
        T.eq(push[4], 6)
        T.eq(push[5], 4)
        T.eq(push[8], false, "not appended to an existing queue")
    end)
end

function M.test_fortify_falls_back_to_sleep_and_lists_options_on_failure()
    withEnv(function()
        installUnit({})
        local committedTypes = {}
        UnitActionMenu = {
            commitWhere = function(_unit, matches)
                for _, t in ipairs({ "MISSION_FORTIFY", "MISSION_SLEEP" }) do
                    local row = { Type = t }
                    if t == "MISSION_SLEEP" and matches(row) then
                        committedTypes[#committedTypes + 1] = t
                        return row
                    end
                end
                return nil
            end,
            actionLabel = function(row)
                return row.Type
            end,
            availableActions = function()
                return { { type = "MISSION_SKIP", label = "Skip Turn" } }
            end,
        }
        local reply = request("id1\tunit_action\t" .. stamp() .. "\t7\tfortify", 2)
        T.eq(committedTypes[1], "MISSION_SLEEP", "a unit that cannot fortify sleeps")
        T.eq(reply, nil, "the reply waits for the unit's state to change")

        sent = {}
        UnitActionMenu.commitWhere = function()
            return nil
        end
        TickPump._reset()
        dofile("src/dlc/UI/InGame/CivVAccess_Rpc.lua")
        dofile("src/dlc/UI/InGame/CivVAccess_BridgeUnit.lua")
        Rpc.installListeners()
        reply = request("id2\tunit_action\t" .. stamp() .. "\t7\theal")
        T.truthy(reply:find("available: Skip Turn", 1, true), reply)
    end)
end

function M.test_unit_command_puts_the_players_selection_back()
    withEnv(function()
        local unit = installUnit({})
        local theirs = fake({ GetID = 3, IsDead = false })
        local head = theirs
        UI.SelectUnit = function(u)
            calls[#calls + 1] = { "SelectUnit", u:GetID() }
            head = u
        end
        UI.GetHeadSelectedUnit = function()
            return head
        end
        UnitActionMenu = {
            commitWhere = function(u, matches)
                T.eq(head, u, "the command goes out while our unit is selected")
                if matches({ Type = "MISSION_SLEEP" }) then
                    return { Type = "MISSION_SLEEP" }
                end
                return nil
            end,
            actionLabel = function(row)
                return row.Type
            end,
        }
        request("id1\tunit_action\t" .. stamp() .. "\t7\tsleep", 2)
        T.eq(calls[1][2], unit:GetID())
        T.eq(calls[2][2], 3, "the player's own unit is selected again")
        T.eq(head, theirs)
    end)
end

function M.test_unit_command_waits_while_a_menu_is_open()
    withEnv(function()
        installUnit({})
        HandlerStack.active = function()
            return { name = "UnitActionMenu" }
        end
        local reply = request("id1\tunit_action\t" .. stamp() .. "\t7\tsleep")
        T.truthy(reply:find("a menu is open", 1, true), reply)
        T.eq(#calls, 0, "nothing selected, nothing sent")
    end)
end

function M.test_build_over_an_improvement_waits_for_the_players_yes()
    withEnv(function()
        local unit = installUnit({})
        GameInfo.Builds =
            infoTable({ { Type = "BUILD_FARM", Description = "Farm", ImprovementType = "IMPROVEMENT_FARM" } })
        save(GameInfo, "Improvements")
        GameInfo.Improvements = infoTable({
            { Type = "IMPROVEMENT_FARM", Description = "Farm" },
            { Type = "IMPROVEMENT_MINE", Description = "Mine" },
        })
        unit.GetPlot = function()
            return fake({ GetImprovementType = 1 })
        end
        local committed = 0
        UnitActionMenu = {
            commitWhere = function()
                committed = committed + 1
                return { Type = "BUILD_FARM" }
            end,
            actionLabel = function(row)
                return row.Type
            end,
        }
        local reply = request("id1\tunit_action\t" .. stamp() .. "\t7\tbuild\tfarm")
        T.truthy(reply:find("replaces the Mine", 1, true), reply)
        T.eq(committed, 0, "nothing built without the player's yes")
        request("id2\tunit_action\t" .. stamp() .. "\t7\tbuild\tfarm\tconfirm", 2)
        T.eq(committed, 1, "confirmed, it is built")
    end)
end

-- empire, congress, trade, spies ---------------------------------------------

function M.test_adopt_policy_sends_the_policy_screen_commit()
    withEnv(function()
        GameInfo.PolicyBranchTypes = infoTable({
            { Type = "POLICY_BRANCH_TRADITION", Description = "Tradition", PurchaseByLevel = false },
            { Type = "POLICY_BRANCH_FREEDOM", Description = "Freedom", PurchaseByLevel = true },
        })
        GameInfo.Policies = infoTable({
            { Type = "POLICY_ARISTOCRACY", Description = "Aristocracy", PolicyBranchType = "POLICY_BRANCH_TRADITION" },
            -- The branch's free starting policy, same name, no branch.
            { Type = "POLICY_TRADITION", Description = "Tradition" },
            { Type = "POLICY_SPACE_PROCUREMENTS", Description = "Space Procurements", PolicyBranchType = "POLICY_BRANCH_FREEDOM", Level = 3 },
            { Type = "POLICY_A", Description = "A", PolicyBranchType = "POLICY_BRANCH_FREEDOM", Level = 3 },
            { Type = "POLICY_B", Description = "B", PolicyBranchType = "POLICY_BRANCH_FREEDOM", Level = 3 },
            { Type = "POLICY_C", Description = "C", PolicyBranchType = "POLICY_BRANCH_FREEDOM", Level = 3 },
        })
        local adoptable, has, opened = false, false, false
        local ownedTenets = { [3] = true, [4] = true, [5] = true }
        activePlayer({
            GetID = 0,
            IsPolicyBlocked = false,
            IsPolicyBranchBlocked = false,
            HasPolicy = function(id)
                return ownedTenets[id] or (id == 0 and has)
            end,
            CanAdoptPolicy = function()
                return adoptable
            end,
            IsPolicyBranchUnlocked = function()
                return opened
            end,
            CanUnlockPolicyBranch = true,
        })
        local reply = request("id1\tadopt_policy\t" .. stamp() .. "\tAristocracy")
        T.truthy(reply:find("cannot be adopted now", 1, true), reply)
        T.eq(#calls, 0, "nothing is sent after a failed check")

        adoptable = true
        Network.SendUpdatePolicies = function(id, isPolicy, flag)
            calls[#calls + 1] = { "SendUpdatePolicies", id, isPolicy, flag }
            has, opened = isPolicy and true or has, (not isPolicy) or opened
        end
        reply = request("id2\tadopt_policy\t" .. stamp() .. "\taristocracy")
        T.eq(calls[1][2], 0)
        T.eq(calls[1][3], true, "a policy, not a branch")
        T.truthy(reply:find('"confirmed":true', 1, true), reply)

        reply = request("id3\tadopt_policy\t" .. stamp() .. "\tTradition")
        T.eq(calls[2][2], 0, "the branch, not its same-named free starting policy")
        T.eq(calls[2][3], false, "a branch is opened with the branch flag")
        T.truthy(reply:find('"opened":true', 1, true), reply)

        reply = request("id4\tadopt_policy\t" .. stamp() .. "\tSpace Procurements")
        T.truthy(reply:find("level 3 tenet slot is taken", 1, true), reply)
        T.eq(#calls, 2, "no tenet beyond the screen's slots")
    end)
end

function M.test_found_pantheon_only_with_a_belief_on_offer()
    withEnv(function()
        GameInfo.Beliefs = infoTable({
            { Type = "BELIEF_GOD_OF_THE_SEA", ShortDescription = "God of the Sea" },
            { Type = "BELIEF_GOD_OF_WAR", ShortDescription = "God of War" },
        })
        activePlayer({ GetID = 0, HasCreatedPantheon = false, CanCreatePantheon = true })
        Game.GetAvailablePantheonBeliefs = function()
            return { 1 }
        end
        local reply = request("id1\tfound_pantheon\t" .. stamp() .. "\tGod of the Sea")
        T.truthy(reply:find("not an available pantheon belief", 1, true), reply)
        T.eq(#calls, 0)
        request("id2\tfound_pantheon\t" .. stamp() .. "\tgod of war")
        T.eq(calls[1][1], "SendFoundPantheon")
        T.eq(calls[1][3], 1, "the belief the player named")
    end)
end

local function installLeague(opts)
    GameInfo.Resolutions = infoTable({
        { Type = "RESOLUTION_EMBARGO", VoterDecision = "RESOLUTION_DECISION_YES_OR_NO" },
        { Type = "RESOLUTION_HOST", VoterDecision = "RESOLUTION_DECISION_MAJOR_CIV_MEMBER" },
    })
    GameInfo.ResolutionDecisions = infoTable({
        { Type = "RESOLUTION_DECISION_YES_OR_NO" },
        { Type = "RESOLUTION_DECISION_MAJOR_CIV_MEMBER" },
    })
    local remaining = opts.remaining or 5
    local league = fake({
        IsInSession = true,
        GetRemainingVotesForMember = function()
            return remaining
        end,
        GetEnactProposals = { { ID = 3, Type = 0 }, { ID = 4, Type = 1 } },
        GetRepealProposals = {},
        GetEnactProposalsOnHold = { { ID = 8, Type = 0 } },
        GetRepealProposalsOnHold = {},
        GetResolutionName = function(t)
            return t == 0 and "Embargo" or "Choose Host"
        end,
        GetChoicesForDecision = { 1, 2 },
        GetTextForChoice = function(_d, c)
            return c == 1 and "Egypt" or "Rome"
        end,
    })
    Game.GetNumActiveLeagues = function()
        return 1
    end
    Game.GetActiveLeague = function()
        return league
    end
    Game.GetNumLeaguesEverFounded = function()
        return 1
    end
    Game.GetLeague = function()
        return league
    end
    activePlayer({ GetID = 0 })
    return function(n)
        remaining = n
    end
end

function M.test_league_vote_checks_delegates_and_maps_the_choice()
    withEnv(function()
        local setRemaining = installLeague({ remaining = 5 })
        local reply = request("id1\tleague_vote\t" .. stamp() .. "\t8\tenact\t1\tyes")
        T.truthy(reply:find("on hold", 1, true), reply)
        reply = request("id2\tleague_vote\t" .. stamp() .. "\t3\tenact\t6\tyes")
        T.truthy(reply:find("5 delegates left", 1, true), reply)
        T.eq(#calls, 0)
        Network.SendLeagueVoteEnact = function(...)
            calls[#calls + 1] = { "SendLeagueVoteEnact", ... }
            setRemaining(2)
        end
        reply = request("id3\tleague_vote\t" .. stamp() .. "\t3\tenact\t3\tno")
        local c = calls[1]
        T.eq(c[2], 0, "league id")
        T.eq(c[3], 3, "proposal id")
        T.eq(c[5], 3, "delegates")
        T.eq(c[6], 0, "no is choice 0")
        T.truthy(reply:find('"delegatesLeft":2', 1, true), reply)
        request("id4\tleague_vote\t" .. stamp() .. "\t4\tenact\t1\trome")
        T.eq(calls[2][6], 2, "a civilization choice sends that choice's id")
    end)
end

local function installTradeUnit(destinations)
    local unit = fake({ GetID = 7, GetUnitType = 0, IsDead = false })
    GameInfo.Units = infoTable({ { Type = "UNIT_CARAVAN", Description = "Caravan" } })
    local routes = {}
    activePlayer({
        GetID = 0,
        GetUnitByID = unit,
        GetPotentialInternationalTradeRouteDestinations = destinations,
        GetTradeRoutes = function()
            return routes
        end,
    })
    save(Map, "GetPlot")
    Map.GetPlot = function(x)
        return fake({
            GetPlotCity = fake({ GetName = x == 1 and "Ur" or "Thebes" }),
            GetPlotIndex = 100 + x,
        })
    end
    save(_G, "TradeConnectionTypes")
    TradeConnectionTypes =
        { TRADE_CONNECTION_INTERNATIONAL = 0, TRADE_CONNECTION_FOOD = 1, TRADE_CONNECTION_PRODUCTION = 2 }
    UI.IsCityScreenUp = function()
        return false
    end
    UI.GetInterfaceMode = function()
        return InterfaceModeTypes.INTERFACEMODE_SELECTION
    end
    UI.SelectUnit = function() end
    UI.GetHeadSelectedUnit = function()
        return unit
    end
    save(UI, "ClearSelectionList")
    UI.ClearSelectionList = function() end
    save(_G, "MissionTypes")
    MissionTypes = { MISSION_ESTABLISH_TRADE_ROUTE = 55 }
    return routes
end

function M.test_trade_route_asks_which_kind_when_a_city_takes_two()
    withEnv(function()
        local routes = installTradeUnit({
            { X = 1, Y = 0, TradeConnectionType = 1 },
            { X = 1, Y = 0, TradeConnectionType = 2 },
            { X = 2, Y = 0, TradeConnectionType = 0 },
        })
        local reply = request("id1\testablish_trade_route\t" .. stamp() .. "\t7\tUr")
        T.truthy(reply:find("more than one kind of route (food, production)", 1, true), reply)
        reply = request("id2\testablish_trade_route\t" .. stamp() .. "\t7\tBabylon")
        T.truthy(reply:find("possible: Ur (food), Ur (production), Thebes (international)", 1, true), reply)
        T.eq(#calls, 0)
        Game.SelectionListGameNetMessage = function(...)
            calls[#calls + 1] = { "SelectionListGameNetMessage", ... }
            routes[1] = {}
        end
        reply = request("id3\testablish_trade_route\t" .. stamp() .. "\t7\tur\tproduction")
        local c = calls[1]
        T.eq(c[3], 55)
        T.eq(c[4], 101, "the destination plot")
        T.eq(c[5], 2, "the production connection")
        T.truthy(reply:find('"confirmed":true', 1, true), reply)
    end)
end

function M.test_move_spy_sends_a_diplomat_only_to_a_peaceful_capital()
    withEnv(function()
        local capital = fake({ GetName = "Thebes", GetID = 4, IsCapital = true })
        local town = fake({ GetName = "Memphis", GetID = 5, IsCapital = false })
        Players[1] = fake({
            IsMinorCiv = false,
            GetTeam = 1,
            GetCityByID = function(id)
                return id == 4 and capital or town
            end,
        })
        Teams[0] = fake({ IsAtWar = false })
        activePlayer({
            GetID = 0,
            GetEspionageSpies = {
                { AgentID = 2, Name = "Ashur", State = "TXT_KEY_SPY_STATE_IDLE", CityX = -1, CityY = -1 },
            },
            GetAvailableSpyRelocationCities = { { PlayerID = 1, CityID = 4 }, { PlayerID = 1, CityID = 5 } },
        })
        local reply = request("id0\tmove_spy\t" .. stamp() .. "\tAshur\thideout")
        T.truthy(reply:find("already in the hideout", 1, true), reply)
        reply = request("id1\tmove_spy\t" .. stamp() .. "\tAshur\tMemphis\tdiplomat")
        T.truthy(reply:find("only go to the capital", 1, true), reply)
        reply = request("id2\tmove_spy\t" .. stamp() .. "\tAshur\tKarnak")
        T.truthy(reply:find("possible: Thebes, Memphis", 1, true), reply)
        T.eq(#calls, 0)
        request("id3\tmove_spy\t" .. stamp() .. "\t2\tthebes\tdiplomat", 50)
        local c = calls[1]
        T.eq(c[1], "SendMoveSpy")
        T.eq(c[4], 1, "target player")
        T.eq(c[5], 4, "target city")
        T.eq(c[6], true, "as a diplomat")
    end)
end

return M
