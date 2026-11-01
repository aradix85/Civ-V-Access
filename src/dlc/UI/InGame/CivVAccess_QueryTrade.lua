-- MCP bridge query: the player's trade routes. Registers trade_routes on
-- Rpc._queries; included from Boot after CivVAccess_Rpc so it
-- re-registers on every load-from-game.
--
-- The three lists of the Trade Route Overview: routes the player runs,
-- routes others run into the player's cities, and the routes that could
-- be started from the player's cities (the best few by yield, since a
-- large map offers hundreds; whether a trade unit is free to run one is
-- in the units query). Each route names both ends and what each end gets per
-- turn, in the engine's own GetTradeRoutes* records; Vox Populi adds
-- culture to the same records, vanilla leaves it out.

local queries = Rpc._queries

local AVAILABLE_LIMIT = 10

local function endpoint(playerID, cityName)
    if playerID == Game.GetActivePlayer() then
        return { city = cityName }
    end
    local p = Players[playerID]
    return { city = cityName, civ = Rpc.civLabel(playerID), cityState = p:IsMinorCiv() or nil }
end

local function yields(gold, science, culture, food, production)
    local out = {}
    local function put(key, times100)
        if times100 ~= nil and times100 ~= 0 then
            out[key] = times100 / 100
        end
    end
    put("gold", gold)
    put("science", science)
    put("culture", culture)
    put("food", food)
    put("production", production)
    return out
end

-- Religion one end of the route pushes into the other. From* is the
-- religion the destination pushes toward the origin, To* the origin's
-- toward the destination (see CivVAccess_TradeRouteRow). NO_RELIGION and
-- the pantheon exert none.
local function pressure(religion, amount)
    if religion == nil or religion <= 0 or amount == nil or amount == 0 then
        return nil
    end
    return { religion = Text.key(Game.GetReligionName(religion)), amount = amount }
end

-- International, or an internal route carrying food or production (the
-- same two cities can appear once for each).
local function routeKind(r)
    if r.ToID ~= Game.GetActivePlayer() then
        return "international"
    end
    if (r.ToFood or 0) > 0 then
        return "food"
    end
    if (r.ToProduction or 0) > 0 then
        return "production"
    end
    return "internal"
end

local function routeEntry(r)
    return {
        kind = routeKind(r),
        from = endpoint(r.FromID, r.FromCityName),
        to = endpoint(r.ToID, r.ToCityName),
        domain = r.Domain == DomainTypes.DOMAIN_SEA and "sea" or "land",
        turnsLeft = r.TurnsLeft,
        originGets = yields(r.FromGPT, r.FromScience, r.FromCulture),
        destinationGets = yields(r.ToGPT, r.ToScience, r.ToCulture, r.ToFood, r.ToProduction),
        religionIntoOrigin = pressure(r.FromReligion, r.FromPressure),
        religionIntoDestination = pressure(r.ToReligion, r.ToPressure),
    }
end

-- What a candidate route is worth to the player: everything the origin
-- gets, plus food and production when the destination is the player's
-- own city (an internal route).
local function valueToPlayer(r)
    local v = (r.FromGPT or 0) + (r.FromScience or 0) + (r.FromCulture or 0)
    if r.ToID == Game.GetActivePlayer() then
        v = v + (r.ToFood or 0) + (r.ToProduction or 0)
    end
    return v
end

function queries.trade_routes()
    local player = Players[Game.GetActivePlayer()]
    local yours, toYou = {}, {}
    for _, r in ipairs(player:GetTradeRoutes()) do
        yours[#yours + 1] = routeEntry(r)
    end
    for _, r in ipairs(player:GetTradeRoutesToYou()) do
        toYou[#toYou + 1] = routeEntry(r)
    end
    local candidates = player:GetTradeRoutesAvailable()
    table.sort(candidates, function(a, b)
        return valueToPlayer(a) > valueToPlayer(b)
    end)
    local available = {}
    for i = 1, math.min(AVAILABLE_LIMIT, #candidates) do
        available[i] = routeEntry(candidates[i])
    end
    return {
        slotsUsed = player:GetNumInternationalTradeRoutesUsed(),
        slots = player:GetNumInternationalTradeRoutesAvailable(),
        yourRoutes = yours,
        routesToYou = toYou,
        bestAvailable = available,
        availableCount = #candidates,
    }
end
