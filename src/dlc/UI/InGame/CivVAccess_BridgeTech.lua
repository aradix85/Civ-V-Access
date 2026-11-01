-- MCP bridge action: choose what to research. Registers on Rpc._actions;
-- included from Boot after CivVAccess_BridgeCore.
--
-- Sends the same research message the tech chooser and the tech tree
-- send. A goal more than one step away is fine: the engine queues the
-- missing prerequisites itself, exactly as when the player picks a distant
-- tech in the tech tree. The goal may also be named by what it unlocks
-- ("library", "Swordsman"), which resolves to the tech that unlocks it.

local actions = Rpc._actions

local UNLOCKERS = {
    { table = "Buildings", prefix = "BUILDING_", column = "PrereqTech" },
    { table = "Units", prefix = "UNIT_", column = "PrereqTech" },
    { table = "Projects", prefix = "PROJECT_", column = "TechPrereq" },
}

local function resolveTech(goal)
    local tech = Rpc.resolveRow("Technologies", "TECH_", goal)
    if tech ~= nil then
        return tech, nil
    end
    for _, u in ipairs(UNLOCKERS) do
        local row = Rpc.resolveRow(u.table, u.prefix, goal)
        if row ~= nil then
            local prereq = row[u.column]
            if prereq == nil or GameInfo.Technologies[prereq] == nil then
                error(Text.key(row.Description) .. " needs no technology")
            end
            return GameInfo.Technologies[prereq], Text.key(row.Description)
        end
    end
    error("no technology, building, unit or project called " .. tostring(goal))
end

-- set_research <goal> [replace|append|free]
--   replace: research this now (its missing prerequisites first)
--   append:  add it to the end of the research queue
--   free:    take it as the free technology the game is offering
function actions.set_research(goal, mode)
    mode = mode or "replace"
    if mode ~= "replace" and mode ~= "append" and mode ~= "free" then
        error("mode must be replace, append or free")
    end
    local player = Bridge.activePlayer()
    local tech, unlocks = resolveTech(goal)
    local name = Text.key(tech.Description)
    if Teams[player:GetTeam()]:IsHasTech(tech.ID) then
        error("you already know " .. name)
    end
    if not player:CanEverResearch(tech.ID) then
        error("you can never research " .. name)
    end

    if mode == "free" then
        local free = player:GetNumFreeTechs()
        if free <= 0 then
            error("you have no free technology to choose")
        end
        if not (player:CanResearch(tech.ID) and player:CanResearchForFree(tech.ID)) then
            error(name .. " cannot be taken as a free technology now")
        end
        Network.SendResearch(tech.ID, free, -1, false)
        Bridge.sent()
        Bridge.speak(Text.format("TXT_KEY_CIVVACCESS_CHOOSETECH_COMMIT_FREE", name))
        local teamID = player:GetTeam()
        return { tech = name, mode = mode }, function()
            if not Teams[teamID]:IsHasTech(tech.ID) then
                return nil
            end
            return { known = true }
        end
    end

    local positionBefore = player:GetQueuePosition(tech.ID)
    local currentBefore = player:GetCurrentResearch()
    Network.SendResearch(tech.ID, 0, -1, mode == "append")
    Bridge.sent()
    if mode == "append" then
        Bridge.speak(Text.format("TXT_KEY_CIVVACCESS_TECHTREE_QUEUED_COMMIT", name))
    else
        Bridge.speak(Text.format("TXT_KEY_CIVVACCESS_CHOOSETECH_COMMIT", name))
    end

    local playerID = Game.GetActivePlayer()
    local result = { tech = name, mode = mode }
    if unlocks ~= nil then
        result.unlocks = unlocks
    end
    if positionBefore ~= nil and positionBefore >= 0 then
        -- Re-choosing a goal that is already queued may leave nothing to
        -- observe; the reply then goes out unconfirmed with this flag.
        result.wasAlreadyQueued = true
    end
    -- Landed means the goal is queued and the research queue visibly moved:
    -- its position or the current research differs from before the send.
    return result,
        function()
            local p = Players[playerID]
            local position = p:GetQueuePosition(tech.ID)
            local current = p:GetCurrentResearch()
            if position == nil or position < 0 then
                return nil
            end
            if position == positionBefore and current == currentBefore then
                return nil
            end
            local currentRow = current ~= nil and GameInfo.Technologies[current] or nil
            return {
                queuePosition = position,
                researchingNow = currentRow and Text.key(currentRow.Description) or nil,
                turnsToGoal = p:GetResearchTurnsLeft(tech.ID, true),
            }
        end
end
