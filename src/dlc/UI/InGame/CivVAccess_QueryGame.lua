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
-- tell a reloaded earlier save from a game that moved on, and the pace's
-- growth scaling rides along for the briefing's growth warnings.

-- MapUtilities.GetBasicInfo is how the game menu names the map.
include("MapUtilities")

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
        -- The pace's growth scaling (100 at standard speed), so the
        -- server can judge "grows slowly" for this game speed.
        growthPercent = GameInfo.GameSpeeds[PreGame.GetGameSpeed()].GrowthPercent,
    }
    local start = player:GetStartingPlot()
    if start ~= nil then
        out.startX = start:GetX()
        out.startY = start:GetY()
    end
    return out
end

-- A text key's string, or nil when the row names no key or the key is
-- not defined, so a missing string is left out instead of returned raw.
local function text(key)
    if key == nil or key == "" then
        return nil
    end
    local s = Text.keyOrNil(key)
    if s == nil or s == "" then
        return nil
    end
    return TextFilter.filter(s)
end

local function rowName(tableName, id)
    local row = GameInfo[tableName][id]
    if row == nil then
        return nil
    end
    return text(row.Description)
end

-- The setup the player chose, as the game menu's details tab lists it
-- (GameMenu.lua): starting era, map type and size, difficulty, pace, the
-- enabled victory types and the enabled visible game options -- Vox
-- Populi's own options included, since they live in the same table. Each
-- option carries its help text so an unfamiliar one needs no second call.
-- The civilization and city-state counts are the numbers the game was set
-- up with; they name no one. The city-state count is the setup value, not
-- a count of city-state slots, because Vox Populi can turn a rebelling
-- city into a new city-state mid-game.
function queries.game_settings()
    local worldSize = PreGame.GetWorldSize()
    local out = {
        startEra = rowName("Eras", PreGame.GetEra()),
        mapSize = rowName("Worlds", worldSize),
        difficulty = rowName("HandicapInfos", PreGame.GetHandicap(Game.GetActivePlayer())),
        pace = rowName("GameSpeeds", PreGame.GetGameSpeed()),
        mapType = text(MapUtilities.GetBasicInfo(PreGame.GetMapScript() or "").Name),
    }
    -- GetMaxTurns counts turns played from the start turn; zero means no
    -- turn limit, and the field is left out.
    local maxTurns = Game.GetMaxTurns()
    if maxTurns > 0 then
        out.lastTurn = Game.GetStartTurn() + maxTurns
    end

    local victories = {}
    for row in GameInfo.Victories() do
        if PreGame.IsVictory(row.ID) then
            victories[#victories + 1] = text(row.Description)
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
            local name = text(row.Description)
            if name ~= nil then
                options[#options + 1] = { name = name, help = text(row.Help) }
            end
        end
    end
    out.gameOptions = options

    local majors = 0
    for i = 0, GameDefines.MAX_MAJOR_CIVS - 1 do
        if Players[i]:IsEverAlive() then
            majors = majors + 1
        end
    end
    out.civilizations = majors
    -- -1 is the setup screen's "default for this map size".
    local cityStates = PreGame.GetNumMinorCivs()
    if cityStates < 0 then
        cityStates = GameInfo.Worlds[worldSize].DefaultMinorCivs
    end
    out.cityStates = cityStates
    return out
end
