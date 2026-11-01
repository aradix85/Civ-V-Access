-- MCP bridge action: casting delegates on a World Congress proposal.
-- Registers league_vote on Rpc._actions; included from Boot after
-- CivVAccess_BridgeCore.
--
-- The same net messages the World Congress screen's vote commit sends
-- (CivVAccess_LeagueOverviewVote, after the engine's VoteController):
-- SendLeagueVoteEnact / SendLeagueVoteRepeal with the proposal id, the
-- number of delegates and the choice. A yes/no proposal takes 1 (yes) or
-- 0 (no); a proposal that picks a civilization takes that choice's id.
-- Delegates not cast stay with the player for this session; votes are
-- final once sent.

local actions = Rpc._actions

local CHOICE_NO, CHOICE_YES = 0, 1

-- The league's id for the Network calls; the handle has no getter, so
-- walk the founded leagues for the active one (as LeagueOverviewAccess).
local function leagueId(league)
    for i = 0, math.max(Game.GetNumLeaguesEverFounded() - 1, 0) do
        if Game.GetLeague(i) == league then
            return i
        end
    end
    error("the World Congress could not be identified")
end

local function findProposal(league, id, direction)
    local enact = direction ~= "repeal"
    local live = enact and league:GetEnactProposals() or league:GetRepealProposals()
    for _, raw in ipairs(live) do
        if raw.ID == id then
            return raw, false
        end
    end
    local held = enact and league:GetEnactProposalsOnHold() or league:GetRepealProposalsOnHold()
    for _, raw in ipairs(held) do
        if raw.ID == id then
            return raw, true
        end
    end
    return nil
end

-- The voter's choices for a proposal that picks a civilization, or nil
-- for a yes/no proposal (LeagueOverviewVote.buildVoterChoices).
local function voterChoices(league, resolutionType, me)
    local info = GameInfo.Resolutions[resolutionType]
    if info.VoterDecision == "RESOLUTION_DECISION_YES_OR_NO" then
        return nil
    end
    local decision = GameInfo.ResolutionDecisions[info.VoterDecision]
    local out = {}
    for _, choiceId in ipairs(league:GetChoicesForDecision(decision.ID, me)) do
        out[#out + 1] = { id = choiceId, text = league:GetTextForChoice(decision.ID, choiceId) }
    end
    return out
end

-- league_vote <proposal id> <enact|repeal> <delegates> <choice>
function actions.league_vote(idArg, direction, votesArg, choiceArg)
    if Game.GetNumActiveLeagues() == 0 then
        error("there is no World Congress yet")
    end
    local league = Game.GetActiveLeague()
    local me = Game.GetActivePlayer()
    if not league:IsInSession() then
        error("the World Congress is not in session")
    end
    if direction ~= "enact" and direction ~= "repeal" then
        error("direction must be enact or repeal")
    end
    local id, votes = tonumber(idArg), tonumber(votesArg)
    if id == nil or votes == nil or votes < 1 or votes ~= math.floor(votes) then
        error("proposal id and a whole number of delegates are needed")
    end
    local raw, onHold = findProposal(league, id, direction)
    if raw == nil then
        error("no " .. direction .. " proposal with id " .. tostring(idArg) .. " this session")
    end
    if onHold then
        error("that proposal is on hold and cannot be voted on")
    end
    local remaining = league:GetRemainingVotesForMember(me)
    if votes > remaining then
        error("you have " .. remaining .. " delegates left")
    end
    local name = TextFilter.filter(league:GetResolutionName(raw.Type, raw.ID, raw.ProposerDecision or -1, false))
    local choices = voterChoices(league, raw.Type, me)
    local choice, choiceLabel
    local wanted = Locale.ToLower(choiceArg or "")
    if choices == nil then
        if wanted == "yes" then
            choice, choiceLabel = CHOICE_YES, "yes"
        elseif wanted == "no" then
            choice, choiceLabel = CHOICE_NO, "no"
        else
            error("this proposal takes yes or no")
        end
    else
        local names = {}
        for _, c in ipairs(choices) do
            local text = TextFilter.filter(c.text)
            if Locale.ToLower(text) == wanted then
                choice, choiceLabel = c.id, text
            end
            names[#names + 1] = text
        end
        if choice == nil then
            error("choose one of: " .. table.concat(names, ", "))
        end
    end

    local lid = leagueId(league)
    if direction == "enact" then
        Network.SendLeagueVoteEnact(lid, raw.ID, me, votes, choice)
    else
        Network.SendLeagueVoteRepeal(lid, raw.ID, me, votes, choice)
    end
    Bridge.sent()
    Bridge.speak(name .. ", " .. choiceLabel .. ", " .. votes)
    return { proposal = name, choice = choiceLabel, delegates = votes, delegatesLeft = remaining - votes }, function()
        local left = Game.GetActiveLeague():GetRemainingVotesForMember(me)
        if left > remaining - votes then
            return nil
        end
        return { delegatesLeft = left }
    end
end
