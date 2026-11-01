-- Shared helpers for the MCP bridge's actions (Rpc._actions). Included
-- from Boot after CivVAccess_Rpc and before the CivVAccess_Bridge* action
-- files that use it.
--
-- An action is a command the player asked the assistant to carry out. It
-- resolves the player's words to game objects, checks with the engine's
-- own Can* calls that the command is legal right now, issues it through
-- the same net message the mod's own screen would send, speaks what was
-- done in the same words that screen speaks, and hands the dispatcher a
-- verify function that reads the result back once the net message lands.
-- Failures raise with a reason the assistant can pass on; nothing is
-- issued after a failed check.

Bridge = {}

function Bridge.activePlayer()
    return Players[Game.GetActivePlayer()]
end

-- The player's city with this name (case-insensitive), or an error that
-- lists the names the player does have.
function Bridge.ownCity(name)
    if name == nil or name == "" then
        error("name a city")
    end
    local wanted = Locale.ToLower(name)
    local names = {}
    for city in Bridge.activePlayer():Cities() do
        if Locale.ToLower(city:GetName()) == wanted then
            return city
        end
        names[#names + 1] = city:GetName()
    end
    error("you have no city named " .. name .. "; your cities: " .. table.concat(names, ", "))
end

-- The player's unit with this id, alive, or an error.
function Bridge.ownUnit(idArg)
    local id = tonumber(idArg)
    if id == nil then
        error("unit id must be a number, got " .. tostring(idArg))
    end
    local unit = Bridge.activePlayer():GetUnitByID(id)
    if unit == nil or unit:IsDead() then
        error("you have no unit with id " .. tostring(idArg))
    end
    return unit
end

-- Things a city can make, by the player's word for them: an exact Type, a
-- bare name to prefix ("granary"), or the localized name ("Granary").
-- Returns the order type, the row and a short kind label.
local PRODUCIBLE = {
    { table = "Units", prefix = "UNIT_", order = "ORDER_TRAIN", kind = "unit" },
    { table = "Buildings", prefix = "BUILDING_", order = "ORDER_CONSTRUCT", kind = "building" },
    { table = "Projects", prefix = "PROJECT_", order = "ORDER_CREATE", kind = "project" },
    { table = "Processes", prefix = "PROCESS_", order = "ORDER_MAINTAIN", kind = "process" },
}

function Bridge.resolveProducible(itemName)
    for _, p in ipairs(PRODUCIBLE) do
        local row = Rpc.resolveRow(p.table, p.prefix, itemName)
        if row ~= nil then
            return OrderTypes[p.order], row, p.kind
        end
    end
    error("no unit, building, project or process called " .. tostring(itemName))
end

-- Whether the city can make this right now: the same checks the
-- production chooser applies before it commits.
function Bridge.canProduce(city, orderType, id)
    if orderType == OrderTypes.ORDER_TRAIN then
        return city:CanTrain(id, 0)
    elseif orderType == OrderTypes.ORDER_CONSTRUCT then
        return city:CanConstruct(id)
    elseif orderType == OrderTypes.ORDER_CREATE then
        return city:CanCreate(id)
    end
    return city:CanMaintain(id)
end

-- The city's production queue as {orderType, id} pairs, read live.
function Bridge.queueOf(city)
    local out = {}
    for i = 0, city:GetOrderQueueLength() - 1 do
        local orderType, id = city:GetOrderFromQueue(i)
        out[#out + 1] = { orderType = orderType, id = id }
    end
    return out
end

-- Selecting a unit is how every unit command reaches the engine
-- (HandleAction and the selection-list net messages act on the head
-- selected unit). Refuses while something else owns the selection: the
-- city screen (the engine blocks unit actions while a city is selected)
-- or a targeting mode (the mod's pickers hold an interface mode, and a
-- selection change would tear them down under the player).
function Bridge.selectUnit(unit)
    if UI.IsCityScreenUp() then
        error("the city screen is open; close it first")
    end
    if UI.GetInterfaceMode() ~= InterfaceModeTypes.INTERFACEMODE_SELECTION then
        error("a targeting mode is open; press Escape first")
    end
    UI.SelectUnit(unit)
    local head = UI.GetHeadSelectedUnit()
    if head == nil or head:GetID() ~= unit:GetID() then
        error("could not select " .. Text.key(GameInfo.Units[unit:GetUnitType()].Description))
    end
end

-- Speech for what the assistant did, queued behind whatever the player is
-- hearing rather than cutting it off.
function Bridge.speak(text)
    if text ~= nil and text ~= "" then
        SpeechPipeline.speakQueued(text)
    end
end
