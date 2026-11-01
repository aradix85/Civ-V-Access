-- MCP bridge query: what one of the player's units would do attacking a
-- tile. Registers combat_odds on Rpc._queries; included from Boot after
-- CivVAccess_Rpc so it re-registers on every load-from-game.
--
-- The combat preview the mod's own target mode speaks
-- (UnitTargetMode.previewAt: the engine's odds as EnemyUnitPanel shows
-- them, strengths, expected damage both ways, modifiers), for a ranged
-- attack when the unit is a ranged unit and a melee attack otherwise; a
-- ranged unit that cannot strike this turn says so instead. Nothing is
-- attacked; attacking stays with the player. A tile the player cannot see
-- answers nothing.

local queries = Rpc._queries

-- combat_odds <unit id> <x> <y> [melee]
function queries.combat_odds(unitArg, xs, ys, mode)
    local player = Players[Game.GetActivePlayer()]
    local unit = player:GetUnitByID(tonumber(unitArg) or -1)
    if unit == nil or unit:IsDead() then
        error("you have no unit with id " .. tostring(unitArg))
    end
    local x, y = tonumber(xs), tonumber(ys)
    local plot = x and y and Map.GetPlot(x, y)
    if plot == nil then
        error("no tile at " .. tostring(xs) .. ", " .. tostring(ys))
    end
    -- Ranged by what the unit is, not CanRangeStrike: that is false for
    -- an archer that already attacked or a ship in a city, which would
    -- otherwise get a melee preview it can never fight.
    local ranged = GameInfo.Units[unit:GetUnitType()].RangedCombat > 0 and mode ~= "melee"
    local out = {
        unit = Text.key(GameInfo.Units[unit:GetUnitType()].Description),
        attack = ranged and "ranged" or "melee",
        distance = Map.PlotDistance(unit:GetX(), unit:GetY(), x, y),
    }
    if not plot:IsVisible(Game.GetActiveTeam(), false) then
        out.visible = false
        return out
    end
    if ranged and not unit:CanRangeStrike() then
        out.cannotAttackNow = true
        return out
    end
    local preview = UnitTargetMode.previewAt(unit, plot, ranged)
    if preview == nil or preview == "" then
        out.noTarget = true
    else
        out.preview = preview
    end
    return out
end
