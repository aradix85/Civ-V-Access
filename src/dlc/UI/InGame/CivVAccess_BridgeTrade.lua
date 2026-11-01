-- MCP bridge action: sending a trade unit (caravan or cargo ship) off on
-- a new trade route. Registers establish_trade_route on Rpc._actions;
-- included from Boot after CivVAccess_BridgeCore.
--
-- The destinations are the engine's own list for that unit
-- (GetPotentialInternationalTradeRouteDestinations, what the route picker
-- popup offers), and the order is the popup's own commit
-- (ChooseInternationalTradeRoutePopup.lua OnConfirmYes): a PUSH_MISSION of
-- MISSION_ESTABLISH_TRADE_ROUTE with the destination plot and the
-- connection type, sent with the unit selected.

local actions = Rpc._actions

-- Connection type by the word the server uses. TradeConnectionTypes is an
-- engine global on BNW and Vox Populi (not on LekMod); without it the
-- kind cannot be told apart and is not checked.
local function connectionKind(connectionType)
    if TradeConnectionTypes == nil then
        return nil
    end
    if connectionType == TradeConnectionTypes.TRADE_CONNECTION_FOOD then
        return "food"
    end
    if connectionType == TradeConnectionTypes.TRADE_CONNECTION_PRODUCTION then
        return "production"
    end
    if connectionType == TradeConnectionTypes.TRADE_CONNECTION_INTERNATIONAL then
        return "international"
    end
    return "other"
end

-- establish_trade_route <unit id> <city> [international|food|production]
function actions.establish_trade_route(unitArg, cityName, kind)
    if cityName == nil or cityName == "" then
        error("name the destination city")
    end
    local unit = Bridge.ownUnit(unitArg)
    local player = Bridge.activePlayer()
    local wanted = Locale.ToLower(cityName)
    local matches, names = {}, {}
    for _, v in ipairs(player:GetPotentialInternationalTradeRouteDestinations(unit)) do
        local city = Map.GetPlot(v.X, v.Y):GetPlotCity()
        local vKind = connectionKind(v.TradeConnectionType)
        names[#names + 1] = city:GetName() .. (vKind and (" (" .. vKind .. ")") or "")
        if
            Locale.ToLower(city:GetName()) == wanted and (kind == nil or kind == "" or vKind == nil or vKind == kind)
        then
            matches[#matches + 1] = { dest = v, city = city, kind = vKind }
        end
    end
    local unitName = Text.key(GameInfo.Units[unit:GetUnitType()].Description)
    if #names == 0 then
        error(unitName .. " has no trade route it can start from here")
    end
    if #matches == 0 then
        error(unitName .. " cannot start a route to " .. cityName .. "; possible: " .. table.concat(names, ", "))
    end
    if #matches > 1 then
        error(cityName .. " takes a food or a production route; say which")
    end
    local m = matches[1]
    local plotIndex = Map.GetPlot(m.dest.X, m.dest.Y):GetPlotIndex()
    local before = #player:GetTradeRoutes()
    Bridge.withUnitSelected(unit, function()
        Game.SelectionListGameNetMessage(
            GameMessageTypes.GAMEMESSAGE_PUSH_MISSION,
            MissionTypes.MISSION_ESTABLISH_TRADE_ROUTE,
            plotIndex,
            m.dest.TradeConnectionType,
            0,
            false,
            nil
        )
        Bridge.sent()
    end)
    Events.AudioPlay2DSound("AS2D_INTERFACE_CARAVAN_TRADE_ROUTE")
    Bridge.speak(unitName .. ", " .. m.city:GetName())
    local playerID = player:GetID()
    return { unit = unitName, id = unit:GetID(), destination = m.city:GetName(), kind = m.kind }, function()
        if #Players[playerID]:GetTradeRoutes() <= before then
            return nil
        end
        return { routes = #Players[playerID]:GetTradeRoutes() }
    end
end
