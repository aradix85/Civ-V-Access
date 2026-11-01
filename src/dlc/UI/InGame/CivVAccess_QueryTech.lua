-- MCP bridge query: research planning. Registers tech_plan on
-- Rpc._queries; included from Boot right after CivVAccess_Rpc so it
-- re-registers on every load-from-game.
--
-- Without an argument: the current research and every technology the
-- player can research right now, each with its turn count and what it
-- unlocks. With a target (a technology, building, wonder, unit or project
-- name): the technologies still missing on the way there, in a valid
-- research order, with the science each still needs and a whole-path turn
-- estimate at the current science rate. Unlocks are filtered to the
-- player's own civilization -- its unique units and buildings replace the
-- defaults, other civilizations' uniques are left out -- the same
-- substitution the tech tree shows. Everything is read live at call time.

local queries = Rpc._queries

-- The building (or unit) Type the player's civilization gets for a class:
-- its unique override when it has one (which may be nil, meaning the
-- civilization cannot build that class at all), else the class default.
local function civBuildingType(civType, classType)
    local found, override = false, nil
    for row in GameInfo.Civilization_BuildingClassOverrides({
        CivilizationType = civType,
        BuildingClassType = classType,
    }) do
        found, override = true, row.BuildingType
    end
    if found then
        return override
    end
    return GameInfo.BuildingClasses[classType].DefaultBuilding
end

local function civUnitType(civType, classType)
    local found, override = false, nil
    for row in GameInfo.Civilization_UnitClassOverrides({ CivilizationType = civType, UnitClassType = classType }) do
        found, override = true, row.UnitType
    end
    if found then
        return override
    end
    return GameInfo.UnitClasses[classType].DefaultUnit
end

local function unlocksOf(tech, civType)
    local buildings, wonders, units, projects, improvements = {}, {}, {}, {}, {}
    for row in GameInfo.Buildings({ PrereqTech = tech.Type }) do
        if civBuildingType(civType, row.BuildingClass) == row.Type then
            local class = GameInfo.BuildingClasses[row.BuildingClass]
            if class.MaxGlobalInstances > 0 or class.MaxPlayerInstances > 0 then
                wonders[#wonders + 1] = Text.key(row.Description)
            else
                buildings[#buildings + 1] = Text.key(row.Description)
            end
        end
    end
    for row in GameInfo.Units({ PrereqTech = tech.Type }) do
        if civUnitType(civType, row.Class) == row.Type then
            units[#units + 1] = Text.key(row.Description)
        end
    end
    for row in GameInfo.Projects({ TechPrereq = tech.Type }) do
        projects[#projects + 1] = Text.key(row.Description)
    end
    for row in GameInfo.Builds({ PrereqTech = tech.Type }) do
        if row.ImprovementType ~= nil then
            local improvement = GameInfo.Improvements[row.ImprovementType]
            if improvement.CivilizationType == nil or improvement.CivilizationType == civType then
                improvements[#improvements + 1] = Text.key(improvement.Description)
            end
        end
    end
    return {
        buildings = buildings,
        wonders = wonders,
        units = units,
        projects = projects,
        improvements = improvements,
    }
end

-- Resolve a GameInfo row from an exact Type, a bare name to prefix and
-- upcase, or a localized display name compared case-insensitively.
local function resolveRow(tableName, prefix, arg)
    local rows = GameInfo[tableName]
    local row = rows[arg]
    if row ~= nil then
        return row
    end
    row = rows[prefix .. arg:upper():gsub(" ", "_")]
    if row ~= nil then
        return row
    end
    local wanted = Locale.ToLower(arg)
    for candidate in rows() do
        if Locale.ToLower(Text.key(candidate.Description)) == wanted then
            return candidate
        end
    end
    return nil
end

-- Target kinds, tried in this order; column is where the row names the
-- technology that unlocks it.
local TARGETS = {
    { tableName = "Technologies", prefix = "TECH_", kind = "tech" },
    { tableName = "Buildings", prefix = "BUILDING_", kind = "building", column = "PrereqTech" },
    { tableName = "Units", prefix = "UNIT_", kind = "unit", column = "PrereqTech" },
    { tableName = "Projects", prefix = "PROJECT_", kind = "project", column = "TechPrereq" },
}

local function resolveTarget(arg)
    for _, spec in ipairs(TARGETS) do
        local row = resolveRow(spec.tableName, spec.prefix, arg)
        if row ~= nil then
            if spec.column == nil then
                return row, spec.kind, Text.key(row.Description)
            end
            local techType = row[spec.column]
            if techType == nil then
                error(Text.key(row.Description) .. " needs no technology")
            end
            return GameInfo.Technologies[techType], spec.kind, Text.key(row.Description)
        end
    end
    error("no technology, building, wonder, unit or project named " .. arg)
end

-- Every technology still missing on the way to `tech`, prerequisites
-- before the technologies that need them (depth-first post-order).
local function missingPath(teamTechs, tech)
    local seen, order = {}, {}
    local function visit(t)
        if seen[t.ID] or teamTechs:HasTech(t.ID) then
            return
        end
        seen[t.ID] = true
        for row in GameInfo.Technology_PrereqTechs({ TechType = t.Type }) do
            visit(GameInfo.Technologies[row.PrereqTech])
        end
        order[#order + 1] = t
    end
    visit(tech)
    return order
end

function queries.tech_plan(target)
    local player = Players[Game.GetActivePlayer()]
    local teamTechs = Teams[player:GetTeam()]:GetTeamTechs()
    local civType = GameInfo.Civilizations[player:GetCivilizationType()].Type
    local science = player:GetScience()

    local data = { sciencePerTurn = science }
    local current = player:GetCurrentResearch()
    if current ~= -1 then
        data.researching = {
            name = Text.key(GameInfo.Technologies[current].Description),
            turnsLeft = player:GetResearchTurnsLeft(current, true),
        }
    end

    if target == nil or target == "" then
        local available = {}
        for tech in GameInfo.Technologies() do
            if not teamTechs:HasTech(tech.ID) and player:CanResearch(tech.ID) then
                available[#available + 1] = {
                    name = Text.key(tech.Description),
                    turns = player:GetResearchTurnsLeft(tech.ID, true),
                    unlocks = unlocksOf(tech, civType),
                }
            end
        end
        data.available = available
        return data
    end

    local tech, kind, label = resolveTarget(target)
    local path, totalScience = {}, 0
    for _, t in ipairs(missingPath(teamTechs, tech)) do
        local remaining = math.max(0, player:GetResearchCost(t.ID) - player:GetResearchProgress(t.ID))
        totalScience = totalScience + remaining
        path[#path + 1] = {
            name = Text.key(t.Description),
            scienceNeeded = remaining,
            researchableNow = player:CanResearch(t.ID),
            unlocks = unlocksOf(t, civType),
        }
    end
    data.target = {
        name = label,
        kind = kind,
        tech = Text.key(tech.Description),
        alreadyKnown = #path == 0,
        path = path,
        scienceNeeded = totalScience,
    }
    if science > 0 and #path > 0 then
        data.target.estimatedTurns = math.ceil(totalScience / science)
    end
    return data
end
