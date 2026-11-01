-- MCP bridge actions on the player's cities: choose or queue production,
-- buy with gold or faith (or invest, under Vox Populi), and switch a
-- city's automated production on or off. Registers on Rpc._actions;
-- included from Boot after CivVAccess_BridgeCore.
--
-- Each command goes through the same engine call the production chooser
-- or the city screen sends, after the same checks, and speaks the same
-- confirmation, prefixed with the city name because the player is not
-- looking at that city when the assistant acts.

include("CivVAccess_BuildingInvest")

local actions = Rpc._actions

local QUEUE_MAX = 6

local function itemName(row)
    return Text.key(row.Description)
end

local function queueNames(city)
    local out = {}
    for _, entry in ipairs(Bridge.queueOf(city)) do
        local tableName = ({
            [OrderTypes.ORDER_TRAIN] = "Units",
            [OrderTypes.ORDER_CONSTRUCT] = "Buildings",
            [OrderTypes.ORDER_CREATE] = "Projects",
            [OrderTypes.ORDER_MAINTAIN] = "Processes",
        })[entry.orderType]
        local row = tableName and GameInfo[tableName][entry.id]
        out[#out + 1] = row and itemName(row) or tostring(entry.id)
    end
    return out
end

local function countInQueue(city, orderType, id)
    local n = 0
    for _, entry in ipairs(Bridge.queueOf(city)) do
        if entry.orderType == orderType and entry.id == id then
            n = n + 1
        end
    end
    return n
end

local function refusePuppet(city)
    if city:IsPuppet() then
        error(city:GetName() .. " is a puppet; it chooses its own production")
    end
end

-- set_production <city> <item> [replace|append|first]
--   replace: clear the queue and make this the only item (the production
--            chooser's normal commit)
--   append:  add to the end of the queue (the chooser's queue mode)
--   first:   put it in front, keeping the rest of the queue behind it
function actions.set_production(cityName, item, mode)
    mode = mode or "replace"
    if mode ~= "replace" and mode ~= "append" and mode ~= "first" then
        error("mode must be replace, append or first")
    end
    local city = Bridge.ownCity(cityName)
    refusePuppet(city)
    local orderType, row, kind = Bridge.resolveProducible(item)
    if not Bridge.canProduce(city, orderType, row.ID) then
        error(
            city:GetName() .. " cannot " .. (kind == "process" and "switch to " or "build ") .. itemName(row) .. " now"
        )
    end
    if mode ~= "replace" and city:GetOrderQueueLength() >= QUEUE_MAX then
        error(city:GetName() .. "'s production queue is full")
    end

    local lengthBefore = city:GetOrderQueueLength()
    local before = countInQueue(city, orderType, row.ID)
    if mode == "append" then
        Game.CityPushOrder(city, orderType, row.ID, false, false, true)
    elseif mode == "first" then
        Game.CityPushOrder(city, orderType, row.ID, false, false, false)
    else
        Game.CityPushOrder(city, orderType, row.ID, false, true, true)
    end
    Events.SpecificCityInfoDirty(city:GetOwner(), city:GetID(), CityUpdateTypes.CITY_UPDATE_TYPE_BANNER)
    Events.SpecificCityInfoDirty(city:GetOwner(), city:GetID(), CityUpdateTypes.CITY_UPDATE_TYPE_PRODUCTION)
    if mode == "append" and lengthBefore > 0 then
        Bridge.speak(
            city:GetName()
                .. ", "
                .. itemName(row)
                .. ", "
                .. Text.format("TXT_KEY_CIVVACCESS_CHOOSEPRODUCTION_ADDED_SLOT", lengthBefore + 1)
        )
    else
        Bridge.speak(
            city:GetName() .. ", " .. Text.format("TXT_KEY_CIVVACCESS_CHOOSEPRODUCTION_BUILDING", itemName(row))
        )
    end

    -- Landed means the queue now shows the order: one more copy of it than
    -- before (append, first), or it is the whole queue (replace, which
    -- clears everything else). A tick that still shows the old queue keeps
    -- the reply waiting.
    local ownerID, cityID = city:GetOwner(), city:GetID()
    local result = { city = city:GetName(), item = itemName(row), kind = kind, mode = mode }
    return result,
        function()
            local c = Players[ownerID]:GetCityByID(cityID)
            local landed
            if mode == "replace" then
                local headType, headId = c:GetOrderFromQueue(0)
                landed = c:GetOrderQueueLength() == 1 and headType == orderType and headId == row.ID
            else
                landed = countInQueue(c, orderType, row.ID) > before
            end
            if not landed then
                return nil
            end
            return { queue = queueNames(c) }
        end
end

local YIELDS = { gold = "YIELD_GOLD", faith = "YIELD_FAITH" }

local function purchaseCost(city, orderType, id, yield)
    if yield == YieldTypes.YIELD_FAITH then
        if orderType == OrderTypes.ORDER_TRAIN then
            return city:GetUnitFaithPurchaseCost(id, true)
        end
        return city:GetBuildingFaithPurchaseCost(id)
    end
    if orderType == OrderTypes.ORDER_TRAIN then
        return city:GetUnitPurchaseCost(id)
    elseif orderType == OrderTypes.ORDER_CONSTRUCT then
        return city:GetBuildingPurchaseCost(id)
    end
    return city:GetProjectPurchaseCost(id)
end

local function canPurchase(city, orderType, id, yield)
    if orderType == OrderTypes.ORDER_TRAIN then
        return city:IsCanPurchase(true, true, id, -1, -1, yield)
    elseif orderType == OrderTypes.ORDER_CONSTRUCT then
        return city:IsCanPurchase(true, true, -1, id, -1, yield)
    elseif orderType == OrderTypes.ORDER_CREATE then
        return city:IsCanPurchase(true, true, -1, -1, id, yield)
    end
    return false
end

-- purchase <city> <item> [gold|faith]. Under Vox Populi a gold "purchase"
-- of a building is an investment (it halves the remaining cost instead of
-- completing it); that case goes through the mod's own invest path.
function actions.purchase(cityName, item, currency)
    currency = currency or "gold"
    local yieldKey = YIELDS[currency]
    if yieldKey == nil then
        error("currency must be gold or faith")
    end
    local yield = YieldTypes[yieldKey]
    local city = Bridge.ownCity(cityName)
    refusePuppet(city)
    local orderType, row, kind = Bridge.resolveProducible(item)
    local player = Bridge.activePlayer()
    local ownerID, cityID = city:GetOwner(), city:GetID()

    if yield == YieldTypes.YIELD_GOLD and BuildingInvest.canInvest(city, orderType, row.ID) then
        local cost = city:GetBuildingPurchaseCost(row.ID)
        if not BuildingInvest.perform(city, row.ID) then
            error(city:GetName() .. " cannot invest in " .. itemName(row) .. " now")
        end
        return { city = city:GetName(), item = itemName(row), invested = true, cost = cost, currency = currency }, function()
            local c = Players[ownerID]:GetCityByID(cityID)
            if not EngineData.buildingInvested(c, row.ID) then
                return nil
            end
            return { productionStillNeeded = c:GetBuildingProductionNeeded(row.ID) }
        end
    end

    if not canPurchase(city, orderType, row.ID, yield) then
        error(city:GetName() .. " cannot buy " .. itemName(row) .. " with " .. currency .. " now")
    end
    local cost = purchaseCost(city, orderType, row.ID, yield)
    local before = yield == YieldTypes.YIELD_GOLD and player:GetGold() or player:GetFaith()
    if orderType == OrderTypes.ORDER_TRAIN then
        Game.CityPurchaseUnit(city, row.ID, yield)
    elseif orderType == OrderTypes.ORDER_CONSTRUCT then
        Game.CityPurchaseBuilding(city, row.ID, yield)
    else
        Game.CityPurchaseProject(city, row.ID, yield)
    end
    Events.SpecificCityInfoDirty(ownerID, cityID, CityUpdateTypes.CITY_UPDATE_TYPE_BANNER)
    Events.SpecificCityInfoDirty(ownerID, cityID, CityUpdateTypes.CITY_UPDATE_TYPE_PRODUCTION)
    Events.AudioPlay2DSound("AS2D_INTERFACE_CITY_SCREEN_PURCHASE")
    Bridge.speak(city:GetName() .. ", " .. Text.format("TXT_KEY_CIVVACCESS_CHOOSEPRODUCTION_PURCHASED", itemName(row)))

    return { city = city:GetName(), item = itemName(row), kind = kind, cost = cost, currency = currency }, function()
        local p = Players[ownerID]
        local now = yield == YieldTypes.YIELD_GOLD and p:GetGold() or p:GetFaith()
        if now >= before then
            return nil
        end
        return { [currency .. "Left"] = now }
    end
end

-- city_automation <city> on|off: hand the city's production choices to
-- the game's own city AI, or take them back. Same task the city screen's
-- "Automate production" checkbox sends.
function actions.city_automation(cityName, state)
    if state ~= "on" and state ~= "off" then
        error("state must be on or off")
    end
    local city = Bridge.ownCity(cityName)
    if not EngineData.productionAutomationAvailable() then
        error("automated production is not available in this game")
    end
    refusePuppet(city)
    local on = state == "on"
    Network.SendDoTask(city:GetID(), TaskTypes.TASK_SET_AUTOMATED_PRODUCTION, -1, -1, on, false, false, false)
    local label = Text.key(on and "TXT_KEY_CIVVACCESS_CHECK_ON" or "TXT_KEY_CIVVACCESS_CHECK_OFF")
    Bridge.speak(city:GetName() .. ", " .. Text.format("TXT_KEY_CIVVACCESS_CITYVIEW_PROD_AUTOMATE", label))

    local ownerID, cityID = city:GetOwner(), city:GetID()
    return { city = city:GetName(), automated = on }, function()
        local c = Players[ownerID]:GetCityByID(cityID)
        if EngineData.isProductionAutomated(c) ~= on then
            return nil
        end
        return { queue = queueNames(c) }
    end
end
