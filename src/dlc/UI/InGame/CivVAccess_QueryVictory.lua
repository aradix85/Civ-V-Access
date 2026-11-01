-- MCP bridge query: how close anyone is to winning. Registers
-- victory_progress on Rpc._queries; included from Boot right after
-- CivVAccess_Rpc so it re-registers on every load-from-game.
--
-- The facts the Victory Progress screen shows, per enabled victory type,
-- with the same disclosure: a civilization the player has not met is never
-- named ("unmet civilization", as the screen's unmet icon).
--   time:        turns left before the game ends on score
--   domination:  who is credited with each original capital and how many
--                are needed; credit goes through the EngineData seam (the
--                holder on vanilla, the master or city-state ally under VP),
--                the same count the accessible screen speaks
--   science:     Apollo and spaceship parts per team
--   diplomatic:  delegates needed and held, United Nations, next session
--   cultural:    the player's influence on each other civilization as a
--                percentage of that civ's lifetime culture
-- Every value is read live at call time.

local queries = Rpc._queries

local SPACESHIP_PARTS = { "PROJECT_SS_BOOSTER", "PROJECT_SS_COCKPIT", "PROJECT_SS_STASIS_CHAMBER", "PROJECT_SS_ENGINE" }

local function enabled(victoryType)
    local row = GameInfo.Victories[victoryType]
    return row ~= nil and PreGame.IsVictory(row.ID)
end

-- What the player may call this civ: "you", its name once met, or nil.
local function civLabel(playerID, me, myTeam)
    if playerID == me then
        return "you"
    end
    local p = Players[playerID]
    if Teams[myTeam]:IsHasMet(p:GetTeam()) then
        return p:GetCivilizationShortDescription()
    end
    return nil
end

local function majors()
    local out = {}
    for i = 0, GameDefines.MAX_MAJOR_CIVS - 1 do
        local p = Players[i]
        if p ~= nil and p:IsEverAlive() and not p:IsMinorCiv() then
            out[#out + 1] = i
        end
    end
    return out
end

local function domination(me, myTeam)
    local creditedFor, held = {}, {}
    for i = 0, GameDefines.MAX_CIV_PLAYERS - 1 do
        local holder = Players[i]
        if holder ~= nil and holder:IsAlive() then
            for city in holder:Cities() do
                if city:IsOriginalMajorCapital() then
                    local credited = EngineData.dominationController(city)
                    creditedFor[city:GetOriginalOwner()] = credited
                    held[credited] = (held[credited] or 0) + 1
                end
            end
        end
    end
    local capitals = {}
    for _, i in ipairs(majors()) do
        local entry = { civ = civLabel(i, me, myTeam) or "unmet civilization" }
        local credited = creditedFor[i]
        if credited ~= nil and credited ~= i then
            entry.heldBy = civLabel(credited, me, myTeam) or "unmet civilization"
        end
        capitals[#capitals + 1] = entry
    end
    -- Capitals needed to win: all of them on vanilla; under the Community
    -- Patch a share of them (VICTORY_DOMINATION_CONTROL_PERCENT, at least
    -- two), the same rule the accessible Victory Progress screen applies.
    local total = #majors()
    local needed = total
    if Game.IsCustomModOption ~= nil then
        local pct = GameDefines.VICTORY_DOMINATION_CONTROL_PERCENT or 100
        needed = math.max(2, math.min(total, math.floor(total * pct / 100)))
    end
    return { capitals = capitals, yourCapitalsHeld = held[me] or 0, capitalsNeeded = needed }
end

local function partsOf(team)
    local built, needed = 0, 0
    for _, typeKey in ipairs(SPACESHIP_PARTS) do
        local proj = GameInfoTypes[typeKey]
        local row = GameInfo.Project_VictoryThresholds({ ProjectType = typeKey })()
        local threshold = row ~= nil and row.Threshold or 0
        if proj ~= nil and proj ~= -1 then
            built = built + math.min(team:GetProjectCount(proj), threshold)
        end
        needed = needed + threshold
    end
    return built, needed
end

local function science(me, myTeam)
    local apollo = GameInfoTypes.PROJECT_APOLLO_PROGRAM
    local teams, apolloCount, seen = {}, 0, {}
    for _, i in ipairs(majors()) do
        local teamID = Players[i]:GetTeam()
        if not seen[teamID] then
            seen[teamID] = true
            local team = Teams[teamID]
            local hasApollo = apollo ~= nil and apollo ~= -1 and team:GetProjectCount(apollo) >= 1
            if hasApollo then
                apolloCount = apolloCount + 1
            end
            local label
            if teamID == myTeam then
                label = "you"
            else
                label = civLabel(i, me, myTeam) or "unmet civilization"
            end
            local built, needed = partsOf(team)
            teams[#teams + 1] = { civ = label, apollo = hasApollo, partsBuilt = built, partsNeeded = needed }
        end
    end
    return { teams = teams, civsWithApollo = apolloCount }
end

local function diplomatic(me)
    local out = { votesNeeded = Game.GetVotesNeededForDiploVictory(), unitedNations = false }
    if Game.GetNumActiveLeagues() > 0 then
        local league = Game.GetActiveLeague()
        if league ~= nil then
            out.yourVotes = league:CalculateStartingVotesForMember(me)
            if Game.IsUnitedNationsActive() then
                out.unitedNations = true
                out.turnsUntilVictorySession = league:GetTurnsUntilVictorySession()
            end
        end
    end
    return out
end

local function cultural(me, myTeam)
    local influence = {}
    local active = Players[me]
    for _, i in ipairs(majors()) do
        local p = Players[i]
        if i ~= me and p:IsAlive() then
            local label = civLabel(i, me, myTeam)
            local lifetime = p:GetJONSCultureEverGenerated()
            local percent = 0
            if lifetime > 0 then
                percent = math.floor(active:GetInfluenceOn(i) / lifetime * 100)
            end
            influence[#influence + 1] = { civ = label or "unmet civilization", percent = percent }
        end
    end
    return { yourInfluence = influence }
end

function queries.victory_progress()
    local me = Game.GetActivePlayer()
    local myTeam = Game.GetActiveTeam()
    local out = {}
    if enabled("VICTORY_TIME") then
        out.time = { turnsLeft = Game.GetMaxTurns() - Game.GetElapsedGameTurns() }
    end
    if enabled("VICTORY_DOMINATION") then
        out.domination = domination(me, myTeam)
    end
    if enabled("VICTORY_SPACE_RACE") then
        out.science = science(me, myTeam)
    end
    if enabled("VICTORY_DIPLOMATIC") then
        out.diplomatic = diplomatic(me)
    end
    if enabled("VICTORY_CULTURAL") then
        out.cultural = cultural(me, myTeam)
    end
    return out
end
