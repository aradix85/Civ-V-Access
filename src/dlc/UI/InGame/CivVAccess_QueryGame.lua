-- MCP bridge query: which game this is. Registers game_info on
-- Rpc._queries; included from Boot right after CivVAccess_Rpc so it
-- re-registers on every load-from-game.
--
-- The MCP server keeps per-game notes (the player's strategy, standing
-- orders, a decision log) outside the game, and needs a key that stays the
-- same for one game across saves, reloads and sessions but differs between
-- games. The setup fields here never change after the map is generated:
-- the player's civilization and leader, the map script and size, and the
-- player's starting tile. The current turn rides along so the server can
-- tell a reloaded earlier save from a game that moved on.

local queries = Rpc._queries

local function typeOf(tableName, id)
    local row = GameInfo[tableName][id]
    if row == nil then
        return nil
    end
    return row.Type
end

function queries.game_info()
    local me = Game.GetActivePlayer()
    local player = Players[me]
    local mapScript = PreGame.GetMapScript() or ""
    local out = {
        civilization = player:GetCivilizationShortDescription(),
        civilizationType = typeOf("Civilizations", player:GetCivilizationType()),
        leader = player:GetName(),
        leaderType = typeOf("Leaders", player:GetLeaderType()),
        mapScript = (mapScript:match("([^/\\]+)$") or mapScript):gsub("%.[^.]*$", ""),
        worldSize = typeOf("Worlds", PreGame.GetWorldSize()),
        gameSpeed = typeOf("GameSpeeds", PreGame.GetGameSpeed()),
        handicap = typeOf("HandicapInfos", PreGame.GetHandicap(me)),
        turn = Game.GetGameTurn(),
        startTurn = Game.GetStartTurn(),
    }
    local start = player:GetStartingPlot()
    if start ~= nil then
        out.startX = start:GetX()
        out.startY = start:GetY()
    end
    return out
end
