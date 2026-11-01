-- MCP bridge query: the World Congress (United Nations later). Registers
-- world_congress on Rpc._queries; included from Boot after CivVAccess_Rpc
-- so it re-registers on every load-from-game.
--
-- What the World Congress screen shows: whether it is in session and
-- when the next session is, the members with their delegates, the
-- player's own delegates and proposals left, the proposals on the table
-- (each with the game's own description of what it would do), and the
-- resolutions in force. Members and proposers the player has not met stay
-- unnamed; a resolution's own name and details are the game's text, which
-- the World Congress screen shows as is (it can name a civilization the
-- player has not met, such as the target of sanctions). Each proposal
-- carries the id and direction the league_vote action takes, and for a
-- proposal that picks a civilization the choices on offer.

local queries = Rpc._queries

local NO_CHOICE = -1

local function details(league, me, resolutionType, id, choice)
    local text = league:GetResolutionDetails(resolutionType, me, id, choice)
    if text == nil or text == "" then
        return nil
    end
    return TextFilter.filter(text)
end

-- What a voter can pick on a proposal that chooses a civilization (the
-- league_vote action takes one of these); nil for a yes/no proposal.
local function voterChoices(league, resolutionType, me)
    local info = GameInfo.Resolutions[resolutionType]
    if info.VoterDecision == "RESOLUTION_DECISION_YES_OR_NO" then
        return nil
    end
    local decision = GameInfo.ResolutionDecisions[info.VoterDecision]
    local out = {}
    for _, choiceId in ipairs(league:GetChoicesForDecision(decision.ID, me)) do
        out[#out + 1] = TextFilter.filter(league:GetTextForChoice(decision.ID, choiceId))
    end
    return out
end

local function proposalEntry(league, me, raw, direction, onHold)
    local choice = raw.ProposerDecision or NO_CHOICE
    local entry = {
        id = raw.ID,
        name = TextFilter.filter(league:GetResolutionName(raw.Type, raw.ID, choice, false)),
        direction = direction,
        onHold = onHold or nil,
        details = details(league, me, raw.Type, raw.ID, choice),
        choices = voterChoices(league, raw.Type, me),
    }
    if raw.ProposalPlayer ~= nil and raw.ProposalPlayer >= 0 then
        entry.proposedBy = Rpc.civLabel(raw.ProposalPlayer)
    end
    return entry
end

function queries.world_congress()
    if Game.GetNumActiveLeagues() == 0 then
        return { active = false }
    end
    local league = Game.GetActiveLeague()
    local me = Game.GetActivePlayer()
    local out = {
        active = true,
        name = tostring(league:GetName()),
        inSession = league:IsInSession(),
        specialSession = league:IsInSpecialSession() or nil,
        unitedNations = Game.IsUnitedNationsActive() or nil,
    }
    if not out.inSession then
        out.turnsUntilSession = math.max(league:GetTurnsUntilSession(), 0)
    end
    if out.unitedNations then
        out.turnsUntilWorldLeaderVote = league:GetTurnsUntilVictorySession()
        out.votesNeededToWin = Game.GetVotesNeededForDiploVictory()
    end

    local host = league:GetHostMember()
    local members = {}
    for i = 0, GameDefines.MAX_MAJOR_CIVS - 1 do
        local p = Players[i]
        if p:IsAlive() and not p:IsMinorCiv() and league:IsMember(i) then
            members[#members + 1] = {
                civ = Rpc.civLabel(i),
                delegates = league:CalculateStartingVotesForMember(i),
                host = i == host or nil,
            }
        end
    end
    table.sort(members, function(a, b)
        return a.delegates > b.delegates
    end)
    out.members = members

    if out.inSession then
        out.yourVotesLeft = league:GetRemainingVotesForMember(me)
    else
        out.yourDelegates = league:CalculateStartingVotesForMember(me)
        if league:CanPropose(me) then
            out.yourProposalsLeft = league:GetRemainingProposalsForMember(me)
        end
    end

    local proposals = {}
    for _, src in ipairs({
        { league:GetEnactProposals(), "enact", false },
        { league:GetRepealProposals(), "repeal", false },
        { league:GetEnactProposalsOnHold(), "enact", true },
        { league:GetRepealProposalsOnHold(), "repeal", true },
    }) do
        for _, raw in ipairs(src[1]) do
            proposals[#proposals + 1] = proposalEntry(league, me, raw, src[2], src[3])
        end
    end
    out.proposals = proposals

    local inForce = {}
    for _, raw in ipairs(league:GetActiveResolutions()) do
        local choice = raw.ProposerDecision or NO_CHOICE
        inForce[#inForce + 1] = {
            name = TextFilter.filter(league:GetResolutionName(raw.Type, raw.ID, choice, false)),
            details = details(league, me, raw.Type, raw.ID, choice),
        }
    end
    out.resolutionsInForce = inForce
    return out
end
