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

-- The player's own version of a unit or building: a generic name ("Swordsman")
-- resolves to the civilization's unique replacement ("Legion") when it has
-- one, so the request means what the player's production list shows. A
-- class the civilization cannot build at all keeps the generic row, which
-- the Can* check then refuses.
function Bridge.civVersion(tableName, row)
    local civType = GameInfo.Civilizations[Bridge.activePlayer():GetCivilizationType()].Type
    local override
    if tableName == "Units" then
        override = GameInfo.Civilization_UnitClassOverrides({ CivilizationType = civType, UnitClassType = row.Class })()
        override = override and override.UnitType
    elseif tableName == "Buildings" then
        override = GameInfo.Civilization_BuildingClassOverrides({
            CivilizationType = civType,
            BuildingClassType = row.BuildingClass,
        })()
        override = override and override.BuildingType
    end
    if override ~= nil and override ~= row.Type and GameInfo[tableName][override] ~= nil then
        return GameInfo[tableName][override]
    end
    return row
end

function Bridge.resolveProducible(itemName)
    for _, p in ipairs(PRODUCIBLE) do
        local row = Rpc.resolveRow(p.table, p.prefix, itemName)
        if row ~= nil then
            return OrderTypes[p.order], Bridge.civVersion(p.table, row), p.kind
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
-- selected unit). withUnitSelected selects the unit, runs fn, and puts the
-- player's previous selection back right away -- the net message already
-- carries the unit's id, so the command still goes to the right unit, and
-- the player's own next key acts on the unit they had, not on ours.
-- Refuses while something else owns the selection: the city screen (the
-- engine blocks unit actions while a city is selected), a targeting mode
-- (the mod's pickers hold an interface mode), or any menu or mode on top
-- of the map (the Tab menu commits to whatever unit is selected).
local MAP_HANDLERS = { Baseline = true, Scanner = true }

function Bridge.withUnitSelected(unit, fn)
    if UI.IsCityScreenUp() then
        error("the city screen is open; close it first")
    end
    if UI.GetInterfaceMode() ~= InterfaceModeTypes.INTERFACEMODE_SELECTION then
        error("a targeting mode is open; press Escape first")
    end
    local top = HandlerStack.active()
    if top ~= nil and not MAP_HANDLERS[top.name] then
        error("a menu is open in the game; close it first")
    end
    local previous = UI.GetHeadSelectedUnit()
    UI.SelectUnit(unit)
    local head = UI.GetHeadSelectedUnit()
    if head == nil or head:GetID() ~= unit:GetID() then
        error("could not select " .. Text.key(GameInfo.Units[unit:GetUnitType()].Description))
    end
    local results = { pcall(fn) }
    if previous ~= nil and previous:GetID() ~= unit:GetID() and not previous:IsDead() then
        UI.SelectUnit(previous)
    end
    if not results[1] then
        error(results[2], 0)
    end
    return unpack(results, 2)
end

-- Speech for what the assistant did, queued behind whatever the player is
-- hearing rather than cutting it off.
function Bridge.speak(text)
    if text ~= nil and text ~= "" then
        SpeechPipeline.speakQueued(text)
    end
end
