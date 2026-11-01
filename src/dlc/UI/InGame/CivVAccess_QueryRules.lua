-- MCP bridge query: what something in the game does, from the game's own
-- rules text. Registers explain on Rpc._queries; included from Boot right
-- after CivVAccess_Rpc so it re-registers on every load-from-game.
--
-- Answers from the loaded game database, so Vox Populi's rewritten rules
-- are what comes back, not the base game's: the entry's Help text (its
-- rules summary), its Strategy text (the game's advice), and the key
-- numbers a tooltip leads with (cost, strength, moves, maintenance, the
-- tech that unlocks it and the one that obsoletes it). The numbers are the
-- database's base values, before game speed, difficulty and other
-- modifiers; the field names say so. A city's real cost and turns come
-- from city_details. Text goes through
-- the mod's markup filter; a text key the database names but never
-- defines is dropped rather than returned as a raw key.
--
-- A civilization (named as the game names it, by its adjective, or by its
-- leader) answers with what sets it apart: its leader's traits and the
-- units, buildings and improvements only it has, each unique with the
-- standard one it replaces, plus any standard unit or building it cannot
-- make at all.

local queries = Rpc._queries

-- Kind name, GameInfo table, Type prefix for bare names. The order breaks
-- ties when a name exists in several tables (a unit and a promotion
-- rarely share a name; a tech and a building can).
local KINDS = {
    { kind = "unit", table = "Units", prefix = "UNIT_" },
    { kind = "building", table = "Buildings", prefix = "BUILDING_" },
    { kind = "tech", table = "Technologies", prefix = "TECH_" },
    { kind = "policy", table = "Policies", prefix = "POLICY_" },
    { kind = "promotion", table = "UnitPromotions", prefix = "PROMOTION_" },
    { kind = "belief", table = "Beliefs", prefix = "BELIEF_" },
    { kind = "improvement", table = "Improvements", prefix = "IMPROVEMENT_" },
    { kind = "resource", table = "Resources", prefix = "RESOURCE_" },
    { kind = "project", table = "Projects", prefix = "PROJECT_" },
    { kind = "specialist", table = "Specialists", prefix = "SPECIALIST_" },
    { kind = "civilization", table = "Civilizations", prefix = "CIVILIZATION_" },
}

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

local function techName(techType)
    if techType == nil then
        return nil
    end
    local tech = GameInfo.Technologies[techType]
    return tech and Text.key(tech.Description) or nil
end

local function positive(n)
    if n ~= nil and n > 0 then
        return n
    end
    return nil
end

-- Beyond Rpc.resolveRow's Type and Description matches: the short name
-- ("Babylon", where Description is "Babylonian Empire"), the adjective,
-- or one of the civilization's leaders.
local function resolveCivilization(name)
    local row = Rpc.resolveRow("Civilizations", "CIVILIZATION_", name)
    if row ~= nil then
        return row
    end
    local wanted = Locale.ToLower(name)
    local function matches(key)
        if key == nil then
            return false
        end
        local s = Text.keyOrNil(key)
        return s ~= nil and Locale.ToLower(s) == wanted
    end
    for civ in GameInfo.Civilizations() do
        if matches(civ.ShortDescription) or matches(civ.Adjective) then
            return civ
        end
    end
    for leader in GameInfo.Leaders() do
        if matches(leader.Description) then
            local link = GameInfo.Civilization_Leaders({ LeaderheadType = leader.Type })()
            if link ~= nil then
                return GameInfo.Civilizations[link.CivilizationType]
            end
        end
    end
    return nil
end

local function resolve(kindArg, name)
    for _, k in ipairs(KINDS) do
        if kindArg == nil or kindArg == "" or kindArg == k.kind then
            local row
            if k.kind == "civilization" then
                row = resolveCivilization(name)
            else
                row = Rpc.resolveRow(k.table, k.prefix, name)
            end
            if row ~= nil then
                return k.kind, row
            end
        end
    end
    return nil, nil
end

local UNIT_OVERRIDES = {
    overrides = "Civilization_UnitClassOverrides",
    item = "UnitType",
    class = "UnitClassType",
    classes = "UnitClasses",
    default = "DefaultUnit",
    items = "Units",
}
local BUILDING_OVERRIDES = {
    overrides = "Civilization_BuildingClassOverrides",
    item = "BuildingType",
    class = "BuildingClassType",
    classes = "BuildingClasses",
    default = "DefaultBuilding",
    items = "Buildings",
}

-- The civilization's overrides of one class table: uniques with the
-- standard entry they replace, and classes it cannot make (an override
-- whose unit or building is NULL).
local function overrides(spec, civType)
    local unique, cannot = {}, {}
    for r in GameInfo[spec.overrides]({ CivilizationType = civType }) do
        local class = GameInfo[spec.classes][r[spec.class]]
        local default = class and GameInfo[spec.items][class[spec.default]]
        if r[spec.item] == nil then
            if default ~= nil then
                cannot[#cannot + 1] = Text.key(default.Description)
            end
        else
            local item = GameInfo[spec.items][r[spec.item]]
            if item ~= nil then
                local entry = { name = Text.key(item.Description) }
                if default ~= nil and default.Type ~= item.Type then
                    entry.replaces = Text.key(default.Description)
                end
                unique[#unique + 1] = entry
            end
        end
    end
    return unique, cannot
end

local function describeCivilization(out, row)
    out.name = Text.key(row.ShortDescription)
    local leaders = {}
    for link in GameInfo.Civilization_Leaders({ CivilizationType = row.Type }) do
        local leader = GameInfo.Leaders[link.LeaderheadType]
        if leader ~= nil then
            local traits = {}
            for lt in GameInfo.Leader_Traits({ LeaderType = leader.Type }) do
                local trait = GameInfo.Traits[lt.TraitType]
                if trait ~= nil then
                    traits[#traits + 1] = { name = text(trait.ShortDescription), effect = text(trait.Description) }
                end
            end
            leaders[#leaders + 1] = { name = Text.key(leader.Description), traits = traits }
        end
    end
    out.leaders = leaders
    local units, noUnits = overrides(UNIT_OVERRIDES, row.Type)
    local buildings, noBuildings = overrides(BUILDING_OVERRIDES, row.Type)
    local improvements = {}
    for imp in GameInfo.Improvements({ CivilizationType = row.Type }) do
        improvements[#improvements + 1] = Text.key(imp.Description)
    end
    out.uniqueUnits = units
    out.uniqueBuildings = buildings
    out.uniqueImprovements = improvements
    if #noUnits > 0 then
        out.cannotTrain = noUnits
    end
    if #noBuildings > 0 then
        out.cannotBuild = noBuildings
    end
end

-- explain <name> [kind]
function queries.explain(name, kindArg)
    if name == nil or name == "" then
        error("explain needs a name")
    end
    local kind, row = resolve(kindArg, name)
    if row == nil then
        error("nothing called " .. name .. (kindArg and (" of kind " .. kindArg) or "") .. " in this game")
    end
    -- A belief's Description is its effect; its ShortDescription is its name.
    local nameKey = row.Description
    if kind == "belief" then
        nameKey = row.ShortDescription
    end
    local out = {
        kind = kind,
        name = Text.key(nameKey),
        help = text(row.Help),
        strategy = text(row.Strategy),
        baseCost = positive(row.Cost),
        baseStrength = positive(row.Combat),
        baseRangedStrength = positive(row.RangedCombat),
        baseMoves = positive(row.Moves),
        baseMaintenance = positive(row.GoldMaintenance),
        unlockedBy = techName(row.PrereqTech or row.TechPrereq),
        obsoleteWith = techName(row.ObsoleteTech),
    }
    if kind == "belief" then
        out.help = out.help or text(row.Description)
    end
    if kind == "policy" and row.PolicyBranchType ~= nil then
        local branch = GameInfo.PolicyBranchTypes[row.PolicyBranchType]
        out.branch = branch and Text.key(branch.Description) or nil
    end
    if kind == "tech" then
        out.era = GameInfo.Eras[row.Era] and Text.key(GameInfo.Eras[row.Era].Description) or nil
    end
    if kind == "civilization" then
        describeCivilization(out, row)
    end
    return out
end
