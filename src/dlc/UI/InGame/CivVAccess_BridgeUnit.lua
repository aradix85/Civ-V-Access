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
local function unitState(unit)
    return {
        x = unit:GetX(),
        y = unit:GetY(),
        moves = unit:MovesLeft(),
        status = UnitSpeech.statusToken(unit),
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

local function verifyUnitChange(playerID, unitID, plotX, plotY, before)
    return function()
        local unit = Players[playerID]:GetUnitByID(unitID)
        if unit == nil or unit:IsDead() then
            local plot = Map.GetPlot(plotX, plotY)
            if plot:IsCity() then
                return { foundedCity = plot:GetPlotCity():GetName() }
            end
            for i = 0, plot:GetNumUnits() - 1 do
                local u = plot:GetUnit(i)
                if u:GetOwner() == playerID then
                    return { replacedBy = unitTypeName(u), newUnitId = u:GetID() }
                end
            end
            return { unitGone = true }
        end
        local now = unitState(unit)
        if not changed(before, now) then
            return nil
        end
        return { x = now.x, y = now.y, movesLeft = movesOf(now.moves), status = now.status, queuedMissions = now.queued }
    end
end

local function moveUnit(unit, xs, ys)
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
    return result
end

-- unit_action <unit id> <action> [<arg> [<arg>]]
--   move <x> <y>, fortify, sleep, sentry, skip, heal, wake, stop,
--   explore, automate, found, upgrade, build <build>, promote <promotion>
function actions.unit_action(idArg, action, arg1, arg2)
    local unit = Bridge.ownUnit(idArg)

    local matchers = SIMPLE[action]
    local wantedLabel = action
    if action == "build" then
        local build = resolveBuild(arg1)
        matchers = { typeIs(build.Type) }
        wantedLabel = Text.key(build.Description)
    elseif action == "promote" then
        local promo = Rpc.resolveRow("UnitPromotions", "PROMOTION_", arg1)
        if promo == nil then
            error("no promotion called " .. tostring(arg1))
        end
        matchers = { typeIs(promo.Type) }
        wantedLabel = Text.key(promo.Description)
    elseif matchers == nil and action ~= "move" then
        error("unknown unit action: " .. tostring(action))
    end
    if action == "found" and not Bridge.activePlayer():CanFound(unit:GetX(), unit:GetY()) then
        error("a city cannot be founded on this tile")
    end

    Bridge.selectUnit(unit)
    local before = unitState(unit)
    local verify = verifyUnitChange(Game.GetActivePlayer(), unit:GetID(), unit:GetX(), unit:GetY(), before)

    if action == "move" then
        return moveUnit(unit, arg1, arg2), verify
    end
    for _, matches in ipairs(matchers) do
        local committed = UnitActionMenu.commitWhere(unit, matches)
        if committed ~= nil then
            return {
                unit = unitTypeName(unit),
                id = unit:GetID(),
                action = action,
                did = UnitActionMenu.actionLabel(committed),
            },
                verify
        end
    end
    local labels = availableLabels(unit)
    error(
        unitTypeName(unit)
            .. " cannot do "
            .. wantedLabel
            .. " now; available: "
            .. (#labels > 0 and table.concat(labels, ", ") or "nothing")
    )
end
