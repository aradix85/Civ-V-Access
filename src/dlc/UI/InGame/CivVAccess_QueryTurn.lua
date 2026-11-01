-- MCP bridge query: what happened since the player's last turn. Registers
-- turn_summary on Rpc._queries; included from Boot right after
-- CivVAccess_Rpc so it re-registers on every load-from-game.
--
-- Gathers what the player would otherwise piece together from F7 and the
-- message buffer: what is blocking the end of the turn, the active
-- notifications (plus any dismissed this turn or last), the F7 Turn Log
-- groups (combat, unit moves, foreign units appearing and leaving view),
-- and the most recent message-buffer entries. All of it is text the mod
-- or the game already showed or spoke to the player; nothing is cached
-- here, the shared lists are read at call time.

local queries = Rpc._queries

local DEFAULT_MESSAGE_LIMIT = 30

local function enumName(enum, value)
    for k, v in pairs(enum) do
        if v == value then
            return k
        end
    end
    return tostring(value)
end

local function notifications(player, sinceTurn)
    local active, recent = {}, {}
    for i = player:GetNumNotifications() - 1, 0, -1 do
        local entry = {
            turn = player:GetNotificationTurn(i),
            text = TextFilter.filter(player:GetNotificationStr(i)),
        }
        if not player:GetNotificationDismissed(i) then
            active[#active + 1] = entry
        elseif entry.turn >= sinceTurn then
            recent[#recent + 1] = entry
        end
    end
    return active, recent
end

-- Turn Log entries carry text plus the tile they happened on (combat
-- target, last seen position); the watcher deltas are plain strings.
local function plotEntries(list)
    local out = {}
    for _, e in ipairs(list or {}) do
        out[#out + 1] = { text = e.text, x = e.x, y = e.y }
    end
    return out
end

local function lines(list)
    local out = {}
    for _, line in ipairs(list or {}) do
        out[#out + 1] = line
    end
    return out
end

local function recentMessages(limit)
    local out = {}
    local buffer = civvaccess_shared.messageBuffer
    if buffer == nil then
        return out
    end
    local entries = buffer.entries
    for i = math.max(1, #entries - limit + 1), #entries do
        out[#out + 1] = { text = entries[i].text, category = entries[i].category }
    end
    return out
end

function queries.turn_summary(limitArg)
    local player = Players[Game.GetActivePlayer()]
    local turn = Game.GetGameTurn()
    local limit = tonumber(limitArg) or DEFAULT_MESSAGE_LIMIT

    local data = { turn = turn, year = Game.GetGameTurnYear() }

    local blocker = player:GetEndTurnBlockingType()
    if blocker ~= EndTurnBlockingTypes.NO_ENDTURN_BLOCKING_TYPE then
        data.waitingOn = { type = enumName(EndTurnBlockingTypes, blocker) }
        local text = Turn.blockerText(player, blocker)
        if text ~= nil then
            data.waitingOn.text = TextFilter.filter(text)
        end
    end

    data.notifications, data.dismissedRecently = notifications(player, turn - 1)
    data.turnLog = {
        combat = plotEntries(civvaccess_shared.combatLog),
        unitMoves = plotEntries(civvaccess_shared.unitMoveLog),
        foreignUnitsSeen = lines(civvaccess_shared.foreignUnitDelta),
        foreignUnitsGone = lines(civvaccess_shared.foreignClearDelta),
    }
    data.recentMessages = recentMessages(limit)
    return data
end
