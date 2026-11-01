-- Tab unit action menu: the live result lines a mission entry carries,
-- mirroring the numbers UnitPanel.lua prints in the button tooltip (a Great
-- Scientist's science, a Great Writer's culture, a Great Merchant's gold and
-- influence). Driven through UnitActionMenu.open and the entry's announce,
-- the path the player hears. A missing line is silent: the player just never
-- learns what the great person would yield.

local T = require("support")
local Setup = require("menu_test_setup")
local M = {}

local STRINGS = {
    TXT_KEY_MISSION_DISCOVER_TECH = "Discover Technology",
    TXT_KEY_MISSION_DISCOVER_TECH_HELP = "This order will consume the Great Person and grant science.",
    TXT_KEY_MISSION_CONDUCT_TRADE_MISSION = "Conduct Trade Mission",
    TXT_KEY_MISSION_CONDUCT_TRADE_MISSION_HELP = "This order will consume the Great Person.",
    TXT_KEY_MISSION_START_GOLDENAGE = "Start Golden Age",
    TXT_KEY_MISSION_START_GOLDENAGE_HELP = "Starts a Golden Age for {1_Num} turns.",
    TXT_KEY_COMMAND_DELETE = "Delete Unit",
    TXT_KEY_COMMAND_DELETE_HELP = "Disband the unit.",
    TXT_KEY_SCRAP_HELP = "Performing this action within your territory will provide {1_Num} [ICON_GOLD] Gold.",
}

local function setup(actionRows)
    Setup.fresh()
    T.installLocaleStrings(STRINGS)
    UnitControl = {
        actionKeyLabel = function()
            return nil
        end,
    }
    local actions = {}
    for i, row in ipairs(actionRows) do
        row.Visible = true
        actions[i - 1] = row
    end
    _G.GameInfoActions = actions
    Game.CanHandleAction = function()
        return true
    end
    dofile("src/dlc/UI/InGame/CivVAccess_UnitActionMenu.lua")
end

local function makeUnit(overrides)
    local plot = {}
    local u = {
        MovesLeft = function()
            return 60
        end,
        GetPlot = function()
            return plot
        end,
    }
    for k, v in pairs(overrides) do
        u[k] = v
    end
    return u
end

-- Open the menu for `unit` and return what its first entry speaks.
local function firstEntrySpeech(unit)
    UnitActionMenu.open(unit)
    local menu = HandlerStack.active()
    T.truthy(menu ~= nil and menu._items ~= nil and menu._items[1] ~= nil, "menu opened with an entry")
    return menu._items[1]:announce(menu)
end

local function assertContains(text, needle)
    T.truthy(text:find(needle, 1, true) ~= nil, "expected '" .. needle .. "' in: " .. tostring(text))
end

local function assertLacks(text, needle)
    T.truthy(text:find(needle, 1, true) == nil, "did not expect '" .. needle .. "' in: " .. tostring(text))
end

function M.test_discover_entry_speaks_science_amount()
    setup({
        {
            Type = "MISSION_DISCOVER",
            TextKey = "TXT_KEY_MISSION_DISCOVER_TECH",
            Help = "TXT_KEY_MISSION_DISCOVER_TECH_HELP",
        },
    })
    local speech = firstEntrySpeech(makeUnit({
        GetDiscoverAmount = function()
            return 734
        end,
    }))
    assertContains(speech, "Discover Technology")
    assertContains(speech, "consume the Great Person")
    assertContains(speech, "+734 [ICON_RESEARCH]")
end

-- Vanilla trade mission: influence and gold both read off the unit's plot,
-- zero amounts dropped; VP's extra lines stay out on the vanilla seam.
function M.test_trade_entry_speaks_nonzero_influence_and_gold()
    setup({
        {
            Type = "MISSION_TRADE",
            TextKey = "TXT_KEY_MISSION_CONDUCT_TRADE_MISSION",
            Help = "TXT_KEY_MISSION_CONDUCT_TRADE_MISSION_HELP",
        },
    })
    local unit = makeUnit({})
    local plotSeen
    unit.GetTradeInfluence = function(_, plot)
        plotSeen = plot
        return 0
    end
    unit.GetTradeGold = function()
        return 420
    end
    local speech = firstEntrySpeech(unit)
    T.eq(plotSeen, unit:GetPlot(), "influence read at the unit's own plot")
    assertContains(speech, "+420 [ICON_GOLD]")
    assertLacks(speech, "ICON_INFLUENCE")
end

-- Missions.Help for the golden-age mission carries an unfilled {1_Num}; the
-- entry must fill it from the seam rather than read the static help.
function M.test_golden_age_entry_fills_turn_count()
    setup({
        {
            Type = "MISSION_GOLDEN_AGE",
            TextKey = "TXT_KEY_MISSION_START_GOLDENAGE",
            Help = "TXT_KEY_MISSION_START_GOLDENAGE_HELP",
        },
    })
    local speech = firstEntrySpeech(makeUnit({
        GetGoldenAgeTurns = function()
            return 9
        end,
    }))
    assertContains(speech, "Golden Age for 9 turns")
    assertLacks(speech, "{1_Num}")
end

function M.test_delete_entry_appends_scrap_gold_only_when_positive()
    local rows = {
        { Type = "COMMAND_DELETE", TextKey = "TXT_KEY_COMMAND_DELETE", Help = "TXT_KEY_COMMAND_DELETE_HELP" },
    }
    setup(rows)
    local speech = firstEntrySpeech(makeUnit({
        GetScrapGold = function()
            return 35
        end,
    }))
    assertContains(speech, "provide 35 [ICON_GOLD] Gold")

    setup(rows)
    speech = firstEntrySpeech(makeUnit({
        GetScrapGold = function()
            return 0
        end,
    }))
    assertContains(speech, "Disband the unit")
    assertLacks(speech, "provide")
end

-- commitWhere (the MCP bridge's commit): a command goes out as DO_COMMAND
-- with Alt off -- never through HandleAction, which would read a held Alt
-- key and apply an All-flagged command to every unit of the type -- and a
-- mission goes out as PUSH_MISSION directly, never through HandleAction's
-- unit-less confirmation popup. Its confirmation names the build.
function M.test_bridge_commit_sends_net_messages_with_alt_off()
    setup({
        { Type = "COMMAND_UPGRADE", TextKey = "TXT_KEY_COMMAND_DELETE", CommandType = 12, CommandData = -1 },
        {
            Type = "BUILD_FARM",
            TextKey = "TXT_KEY_MISSION_DISCOVER_TECH",
            CommandType = -1,
            MissionType = 30,
            MissionData = 4,
        },
    })
    local sent, handled = {}, 0
    local savedSend, savedHandle = Game.SelectionListGameNetMessage, Game.HandleAction
    Game.SelectionListGameNetMessage = function(...)
        sent[#sent + 1] = { ... }
    end
    Game.HandleAction = function()
        handled = handled + 1
    end
    local ok, err = pcall(function()
        local unit = makeUnit({})
        local row = UnitActionMenu.commitWhere(unit, function(a)
            return a.Type == "COMMAND_UPGRADE"
        end)
        T.eq(row.Type, "COMMAND_UPGRADE")
        T.eq(sent[1][1], GameMessageTypes.GAMEMESSAGE_DO_COMMAND)
        T.eq(sent[1][2], 12)
        T.eq(sent[1][6], false, "Alt flag off")
        local sentBeforeSpeech
        UnitActionMenu.commitWhere(unit, function(a)
            return a.Type == "BUILD_FARM"
        end, function()
            sentBeforeSpeech = #sent
        end)
        T.eq(sentBeforeSpeech, 2, "onSent runs once the net message is out")
        T.eq(sent[2][1], GameMessageTypes.GAMEMESSAGE_PUSH_MISSION)
        T.eq(sent[2][2], 30)
        T.eq(sent[2][3], 4, "build id as mission data")
        T.eq(handled, 0, "HandleAction is never used")
    end)
    Game.SelectionListGameNetMessage, Game.HandleAction = savedSend, savedHandle
    if not ok then
        error(err, 0)
    end
end

return M
