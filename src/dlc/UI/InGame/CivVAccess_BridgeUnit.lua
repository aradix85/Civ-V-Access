-- MCP bridge: the player's units. Registers the units query on
-- Rpc._queries and the unit_action action on Rpc._actions; included from
-- Boot after CivVAccess_BridgeCore.
--
-- units lists every unit the player owns with what a sighted player reads
-- off the unit list: where it is, health, moves, what it is doing, and
-- whether it waits for orders, can be promoted or can be upgraded. Each
-- entry carries the unit id that unit_action takes.
--
-- unit_action selects the unit (every unit command acts on the selected
-- unit) and commits through the same paths the mod's own keys use: the
-- Tab menu's commit for actions at the unit's tile, the move-to message
-- with the mod's move-result announcement for moves. Attacks are not
-- offered: they stay with the player and the mod's target mode.

local queries = Rpc._queries
local actions = Rpc._actions

local function domainName(domain)
    if domain == DomainTypes.DOMAIN_LAND then
        return "land"
    elseif domain == DomainTypes.DOMAIN_SEA then
        return "sea"
    elseif domain == DomainTypes.DOMAIN_AIR then
        return "air"
    end
    return "other"
end

local function unitTypeName(unit)
    return Text.key(GameInfo.Units[unit:GetUnitType()].Description)
end

local function movesOf(n)
    return n / GameDefines.MOVE_DENOMINATOR
end

local function unitEntry(unit)
    local entry = {
        id = unit:GetID(),
        name = unitTypeName(unit),
        x = unit:GetX(),
        y = unit:GetY(),
        domain = domainName(unit:GetDomainType()),
        military = unit:IsCombatUnit(),
        movesLeft = movesOf(unit:MovesLeft()),
        maxMoves = movesOf(unit:MaxMoves()),
        status = UnitSpeech.statusToken(unit),
        needsOrders = unit:IsReadyToMove(),
    }
    if unit:GetDamage() > 0 then
        entry.hp = unit:GetCurrHitPoints()
        entry.maxHp = unit:GetMaxHitPoints()
    end
    if unit:IsEmbarked() then
        entry.embarked = true
    end
    if unit:GetBaseCombatStrength() > 0 then
        entry.strength = unit:GetBaseCombatStrength()
    end
    if unit:GetBaseRangedCombatStrength() > 0 then
        entry.rangedStrength = unit:GetBaseRangedCombatStrength()
    end
    if EngineData.unitPromotionReady(unit) then
        entry.promotionReady = true
    end
    if unit:CanUpgradeRightNow(1) then
        local upgradeType = unit:GetUpgradeUnitType()
        entry.upgrade = {
            to = Text.key(GameInfo.Units[upgradeType].Description),
            cost = unit:UpgradePrice(upgradeType),
            possibleNow = unit:CanUpgradeRightNow(0),
        }
    end
    return entry
end

-- units [idle|military|civilian|<unit type>]
function queries.units(filter)
    local wantType
    if filter ~= nil and filter ~= "idle" and filter ~= "military" and filter ~= "civilian" then
        wantType = Rpc.resolveRow("Units", "UNIT_", filter)
        if wantType == nil then
            error("filter must be idle, military, civilian or a unit type; got " .. filter)
        end
    end
    local out = {}
    for unit in Bridge.activePlayer():Units() do
        if not unit:IsDead() then
            local keep = true
            if filter == "idle" then
                keep = unit:IsReadyToMove()
            elseif filter == "military" then
                keep = unit:IsCombatUnit()
            elseif filter == "civilian" then
                keep = not unit:IsCombatUnit()
            elseif wantType ~= nil then
                keep = unit:GetUnitType() == wantType.ID
            end
            if keep then
                out[#out + 1] = unitEntry(unit)
            end
        end
    end
    return { units = out }
end

-- === unit_action ===

local function typeIs(...)
    local wanted = {}
    for _, t in ipairs({ ... }) do
        wanted[t] = true
    end
    return function(action)
        return wanted[action.Type] == true
    end
end

local function automateIs(kind)
    local key = "TXT_KEY_ACTION_AUTOMATE_" .. kind
    local types = { ["AUTOMATE_" .. kind] = true, ["COMMAND_AUTOMATE_" .. kind] = true }
    return function(action)
        return types[action.Type] == true or action.TextKey == key
    end
end

-- Self-plot actions, each an ordered list of matchers: the first one with
-- an available row commits (fortify falls back to sleep for units that
-- cannot fortify, as Alt+S does).
local SIMPLE = {
    fortify = { typeIs("MISSION_FORTIFY"), typeIs("MISSION_SLEEP") },
    sleep = { typeIs("MISSION_SLEEP") },
    sentry = { typeIs("MISSION_ALERT") },
    skip = { typeIs("MISSION_SKIP") },
    heal = { typeIs("MISSION_HEAL") },
    wake = { typeIs("COMMAND_WAKE", "MISSION_WAKE") },
    stop = { typeIs("COMMAND_CANCEL", "COMMAND_STOP_AUTOMATION") },
    explore = { automateIs("EXPLORE") },
    automate = { automateIs("BUILD") },
    found = { typeIs("MISSION_FOUND") },
    upgrade = { typeIs("COMMAND_UPGRADE") },
}

local function resolveBuild(name)
    local build = Rpc.resolveRow("Builds", "BUILD_", name)
    if build ~= nil then
        return build
    end
    -- The first build that makes the named improvement or route.
    local improvement = Rpc.resolveRow("Improvements", "IMPROVEMENT_", name)
    if improvement ~= nil then
        build = GameInfo.Builds({ ImprovementType = improvement.Type })()
    end
    local route = build == nil and Rpc.resolveRow("Routes", "ROUTE_", name) or nil
    if route ~= nil then
        build = GameInfo.Builds({ RouteType = route.Type })()
    end
    if build ~= nil then
        return build
    end
    error("no build, improvement or route called " .. tostring(name))
end

local function availableLabels(unit)
    local labels = {}
    for _, a in ipairs(UnitActionMenu.availableActions(unit)) do
        labels[#labels + 1] = a.label
    end
    return labels
end

-- A snapshot of what a unit command can change, for the verify step.
-- Activity and readiness catch the commands that move nothing (skip
-- turns a waiting unit into a holding one; sentry and sleep change the
-- activity before any status word does).
local function unitState(unit)
    return {
        x = unit:GetX(),
        y = unit:GetY(),
        moves = unit:MovesLeft(),
        status = UnitSpeech.statusToken(unit),
        activity = unit:GetActivityType(),
        ready = unit:IsReadyToMove(),
        build = unit:GetBuildType(),
        queued = #EngineData.missionQueue(unit),
    }
end

local function changed(a, b)
    for k, v in pairs(a) do
        if b[k] ~= v then
            return true
        end
    end
    return false
end

-- Verify for a unit command. A unit that is gone founded a city, was
-- upgraded (the replacement of the upgrade type stands on its tile) or was
-- consumed; one that is still there must show a change from `before`, or
-- pass `check` when the command has a precise test (a promotion).
local function verifyUnitChange(playerID, unit, before, check)
    local unitID, plotX, plotY = unit:GetID(), unit:GetX(), unit:GetY()
    local upgradeType = unit:GetUpgradeUnitType()
    return function()
        local u = Players[playerID]:GetUnitByID(unitID)
        if u == nil or u:IsDead() then
            local plot = Map.GetPlot(plotX, plotY)
            if plot:IsCity() and plot:GetPlotCity():GetOwner() == playerID then
                return { foundedCity = plot:GetPlotCity():GetName() }
            end
            for i = 0, plot:GetNumUnits() - 1 do
                local other = plot:GetUnit(i)
                if other:GetOwner() == playerID and other:GetUnitType() == upgradeType then
                    return { replacedBy = unitTypeName(other), newUnitId = other:GetID() }
                end
            end
            return { unitGone = true }
        end
        local now = unitState(u)
        if check ~= nil then
            if not check(u) then
                return nil
            end
        elseif not changed(before, now) then
            return nil
        end
        return { x = now.x, y = now.y, movesLeft = movesOf(now.moves), status = now.status, queuedMissions = now.queued }
    end
end

-- Every check a move needs, before anything is selected or sent. Returns
-- the target plot.
local function moveTarget(unit, xs, ys)
    local x, y = tonumber(xs), tonumber(ys)
    if x == nil or y == nil then
        error("move needs numeric x and y")
    end
    local plot = Map.GetPlot(x, y)
    if plot == nil then
        error("no tile at " .. tostring(xs) .. ", " .. tostring(ys))
    end
    if not plot:IsRevealed(Game.GetActiveTeam(), false) then
        error("that tile is unexplored")
    end
    if unit:MovesLeft() <= 0 then
        error(unitTypeName(unit) .. " has no moves left this turn")
    end
    if UnitControl.enemyAt(plot) ~= nil or UnitControl.enemyCityAt(plot) ~= nil then
        error("an enemy is on that tile; attacks stay with the player")
    end
    local diag = PathDiagnostic.discriminativePath(unit, plot)
    if diag.ok ~= "strict" then
        local reason = PathDiagnostic.formatFailure(diag, x, y)
        if diag.ok == "declareWar" then
            reason = "the route would declare war (closed borders): " .. reason
        end
        error(reason)
    end
    return plot
end

local function commitMove(unit, plot)
    local x, y = plot:GetX(), plot:GetY()
    -- Priced before the push: once the mission runs the unit is no longer
    -- at its start tile.
    local _nodes, ok, turns = EngineData.computePath(unit, unit:GetPlot(), plot)
    local result = { unit = unitTypeName(unit), id = unit:GetID(), action = "move", target = { x = x, y = y } }
    if ok and turns ~= nil then
        result.turns = turns
    end
    UnitControl.registerPending(unit, x, y)
    Game.SelectionListGameNetMessage(
        GameMessageTypes.GAMEMESSAGE_PUSH_MISSION,
        GameInfoTypes.MISSION_MOVE_TO,
        x,
        y,
        0,
        false,
        false
    )
    Bridge.sent()
    return result
end

-- The cases where the game itself would stop and ask "are you sure"
-- (CvGame::handleAction): a build that replaces the improvement already on
-- the tile, or a city founded on an antiquity site. Returns the question to
-- put to the player, or nil. Slightly more cautious than the engine, which
-- also skips the question for some resource combinations.
local function needsConfirmation(unit, action, build)
    local plot = unit:GetPlot()
    if action == "build" then
        if build.Repair or (build.RouteType ~= nil and build.RouteType ~= "NONE") then
            return nil
        end
        local makes = build.ImprovementType and GameInfo.Improvements[build.ImprovementType]
        if makes ~= nil and makes.RequiresImprovement then
            return nil
        end
        local existing = plot:GetImprovementType()
        if existing ~= nil and existing >= 0 then
            return "this replaces the " .. Text.key(GameInfo.Improvements[existing].Description) .. " on the tile"
        end
    elseif action == "found" then
        local resource = GameInfo.Resources[plot:GetResourceType(Game.GetActiveTeam())]
        if
            resource ~= nil and (resource.Type == "RESOURCE_ARTIFACTS" or resource.Type == "RESOURCE_HIDDEN_ARTIFACTS")
        then
            return "founding here destroys the antiquity site"
        end
    end
    return nil
end

-- unit_action <unit id> <action> [<arg> [<arg>]]
--   move <x> <y>, fortify, sleep, sentry, skip, heal, wake, stop,
--   explore, automate, found [confirm], upgrade, build <build> [confirm],
--   promote <promotion>
-- "confirm" answers the question the game would otherwise ask (see
-- needsConfirmation); without it such a command is refused with the
-- question.
function actions.unit_action(idArg, action, arg1, arg2)
    local unit = Bridge.ownUnit(idArg)
    local playerID = Game.GetActivePlayer()

    -- Resolve and check everything that needs no selection first, so a
    -- refusal leaves the player's selection alone.
    local matchers = SIMPLE[action]
    local wantedLabel = action
    local check
    local target
    if action == "move" then
        target = moveTarget(unit, arg1, arg2)
    elseif action == "build" then
        local build = resolveBuild(arg1)
        matchers = { typeIs(build.Type) }
        wantedLabel = Text.key(build.Description)
        local question = needsConfirmation(unit, action, build)
        if question ~= nil and arg2 ~= "confirm" then
            error("needs the player's confirmation: " .. question)
        end
    elseif action == "promote" then
        local promo = Rpc.resolveRow("UnitPromotions", "PROMOTION_", arg1)
        if promo == nil then
            error("no promotion called " .. tostring(arg1))
        end
        matchers = { typeIs(promo.Type) }
        wantedLabel = Text.key(promo.Description)
        check = function(u)
            return u:IsHasPromotion(promo.ID)
        end
    elseif matchers == nil then
        error("unknown unit action: " .. tostring(action))
    end
    if action == "found" then
        if not Bridge.activePlayer():CanFound(unit:GetX(), unit:GetY()) then
            error("a city cannot be founded on this tile")
        end
        local question = needsConfirmation(unit, action)
        if question ~= nil and arg1 ~= "confirm" then
            error("needs the player's confirmation: " .. question)
        end
    end

    local verify = verifyUnitChange(playerID, unit, unitState(unit), check)
    if target ~= nil then
        return Bridge.withUnitSelected(unit, function()
            return commitMove(unit, target)
        end), verify
    end
    local committed, labels = Bridge.withUnitSelected(unit, function()
        for _, matches in ipairs(matchers) do
            local row = UnitActionMenu.commitWhere(unit, matches, Bridge.sent)
            if row ~= nil then
                return row
            end
        end
        return nil, availableLabels(unit)
    end)
    if committed == nil then
        error(
            unitTypeName(unit)
                .. " cannot do "
                .. wantedLabel
                .. " now; available: "
                .. (#labels > 0 and table.concat(labels, ", ") or "nothing")
        )
    end
    return {
        unit = unitTypeName(unit),
        id = unit:GetID(),
        action = action,
        did = UnitActionMenu.actionLabel(committed),
    },
        verify
end
