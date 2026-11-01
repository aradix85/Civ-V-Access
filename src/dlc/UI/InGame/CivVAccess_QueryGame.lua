-- MCP bridge queries: which game this is (game_info) and how it was set
-- up (game_settings). Registers on Rpc._queries; included from Boot right
-- after CivVAccess_Rpc so they re-register on every load-from-game.
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

local function rowName(tableName, id)
    local row = GameInfo[tableName][id]
    if row == nil then
        return nil
    end
    return Text.key(row.Description)
end

-- The setup the player chose, as the game menu's details tab lists it
-- (GameMenu.lua): starting era, map type and size, difficulty, pace, the
-- enabled victory types and the enabled visible game options -- Vox
-- Populi's own options included, since they live in the same table. Each
-- option carries its help text so an unfamiliar one needs no second call.
-- The civilization and city-state counts are what the game started with,
-- the numbers chosen on the setup screen; they name no one.
function queries.game_settings()
    local out = {
        startEra = rowName("Eras", PreGame.GetEra()),
        mapSize = rowName("Worlds", PreGame.GetWorldSize()),
        difficulty = rowName("HandicapInfos", PreGame.GetHandicap(Game.GetActivePlayer())),
        pace = rowName("GameSpeeds", PreGame.GetGameSpeed()),
        maxTurns = Game.GetMaxTurns(),
    }
    -- A world-builder map (.Civ5Map) has no MapScripts row; the file stem
    -- is the only name the game itself has for it outside the setup screen.
    local mapScript = PreGame.GetMapScript() or ""
    for row in GameInfo.MapScripts() do
        if row.FileName == mapScript then
            out.mapType = Text.key(row.Name)
            break
        end
    end
    if out.mapType == nil then
        out.mapType = (mapScript:match("([^/\\]+)$") or mapScript):gsub("%.[^.]*$", "")
    end

    local victories = {}
    for row in GameInfo.Victories() do
        if PreGame.IsVictory(row.ID) then
            victories[#victories + 1] = Text.key(row.Description)
        end
    end
    out.victoryTypes = victories

    local conditions = { Visible = 1 }
    if Game.IsNetworkMultiPlayer() then
        conditions.SupportsMultiplayer = 1
    else
        conditions.SupportsSinglePlayer = 1
    end
    local options = {}
    for row in GameInfo.GameOptions(conditions) do
        if PreGame.GetGameOption(row.Type) == 1 then
            local help = Text.keyOrNil(row.Help)
            options[#options + 1] = {
                name = Text.key(row.Description),
                help = help and help ~= "" and TextFilter.filter(help) or nil,
            }
        end
    end
    out.gameOptions = options

    local majors, cityStates = 0, 0
    for i = 0, GameDefines.MAX_MAJOR_CIVS - 1 do
        if Players[i]:IsEverAlive() then
            majors = majors + 1
        end
    end
    for i = GameDefines.MAX_MAJOR_CIVS, GameDefines.MAX_CIV_PLAYERS - 1 do
        local p = Players[i]
        if p:IsEverAlive() and p:IsMinorCiv() then
            cityStates = cityStates + 1
        end
    end
    out.civilizations = majors
    out.cityStates = cityStates
    return out
end
