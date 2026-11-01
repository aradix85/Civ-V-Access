-- MCP bridge query: what something in the game does, from the game's own
-- rules text. Registers explain on Rpc._queries; included from Boot right
-- after CivVAccess_Rpc so it re-registers on every load-from-game.
--
-- Answers from the loaded game database, so Vox Populi's rewritten rules
-- are what comes back, not the base game's: the entry's Help text (its
-- rules summary), its Strategy text (the game's advice), and the key
-- numbers a tooltip leads with (cost, strength, moves, maintenance, the
-- tech that unlocks it and the one that obsoletes it). Text goes through
-- the mod's markup filter; a text key the database names but never
-- defines is dropped rather than returned as a raw key.

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

local function resolve(kindArg, name)
    for _, k in ipairs(KINDS) do
        if kindArg == nil or kindArg == "" or kindArg == k.kind then
            local row = Rpc.resolveRow(k.table, k.prefix, name)
            if row ~= nil then
                return k.kind, row
            end
        end
    end
    return nil, nil
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
        cost = positive(row.Cost),
        strength = positive(row.Combat),
        rangedStrength = positive(row.RangedCombat),
        moves = positive(row.Moves),
        maintenance = positive(row.GoldMaintenance),
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
    return out
end
