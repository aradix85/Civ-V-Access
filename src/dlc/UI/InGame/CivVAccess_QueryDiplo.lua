-- MCP bridge query: diplomatic standing with every met civilization and
-- city-state. Registers diplomacy on Rpc._queries; included from Boot
-- right after CivVAccess_Rpc so it re-registers on every
-- load-from-game.
--
-- Majors: war, declared friendship, denunciations both ways, defensive
-- pact, research agreement, open borders both ways, embassies both ways,
-- score, era, city count, and for an AI not at war the mood the game
-- shows (GetApproachTowardsUsGuess, the player-side guess the base UI and
-- the F4 relationships screen read -- never the AI's hidden approach).
-- City-states: trait, personality, influence, friend / ally status, who
-- their ally is (unnamed when unmet, as the game shows it), war, the
-- active quests text, and their capital's tile when revealed. Unmet
-- civilizations are left out entirely. Everything is read live.

-- Supplies GetActiveQuestToolTip, the same quest text the city-state
-- diplomacy popup and the F4 screen read.
include("CityStateStatusHelper")

local queries = Rpc._queries

local function moodName(approach)
    if approach == MajorCivApproachTypes.MAJOR_CIV_APPROACH_WAR then
        return "war"
    elseif approach == MajorCivApproachTypes.MAJOR_CIV_APPROACH_HOSTILE then
        return "hostile"
    elseif approach == MajorCivApproachTypes.MAJOR_CIV_APPROACH_GUARDED then
        return "guarded"
    elseif approach == MajorCivApproachTypes.MAJOR_CIV_APPROACH_AFRAID then
        return "afraid"
    elseif approach == MajorCivApproachTypes.MAJOR_CIV_APPROACH_FRIENDLY then
        return "friendly"
    elseif approach == MajorCivApproachTypes.MAJOR_CIV_APPROACH_NEUTRAL then
        return "neutral"
    end
    return nil
end

local function traitName(trait)
    if trait == MinorCivTraitTypes.MINOR_CIV_TRAIT_CULTURED then
        return "cultured"
    elseif trait == MinorCivTraitTypes.MINOR_CIV_TRAIT_MILITARISTIC then
        return "militaristic"
    elseif trait == MinorCivTraitTypes.MINOR_CIV_TRAIT_MARITIME then
        return "maritime"
    elseif trait == MinorCivTraitTypes.MINOR_CIV_TRAIT_MERCANTILE then
        return "mercantile"
    elseif trait == MinorCivTraitTypes.MINOR_CIV_TRAIT_RELIGIOUS then
        return "religious"
    end
    return nil
end

local function majorEntry(me, player, myTeamId, i)
    local other = Players[i]
    local otherTeamId = other:GetTeam()
    local myTeam, otherTeam = Teams[myTeamId], Teams[otherTeamId]
    local entry = {
        civ = other:GetCivilizationShortDescription(),
        leader = other:GetName(),
        human = other:IsHuman(),
        teammate = otherTeamId == myTeamId,
        atWar = myTeam:IsAtWar(otherTeamId),
        score = other:GetScore(),
        era = Text.key(GameInfo.Eras[other:GetCurrentEra()].Description),
        cities = other:GetNumCities(),
        declaredFriends = player:IsDoF(i),
        youDenounced = player:IsDenouncedPlayer(i),
        theyDenounceYou = other:IsDenouncingPlayer(me),
        defensivePact = myTeam:IsDefensivePact(otherTeamId),
        researchAgreement = myTeam:IsHasResearchAgreement(otherTeamId),
        openBordersFromThem = otherTeam:IsAllowsOpenBordersToTeam(myTeamId),
        openBordersToThem = myTeam:IsAllowsOpenBordersToTeam(otherTeamId),
        yourEmbassyWithThem = myTeam:HasEmbassyAtTeam(otherTeamId),
        theirEmbassyWithYou = otherTeam:HasEmbassyAtTeam(myTeamId),
    }
    if not entry.atWar and not entry.teammate and not entry.human then
        entry.mood = moodName(player:GetApproachTowardsUsGuess(i))
    end
    return entry
end

local function minorEntry(me, myTeamId, i, withQuests)
    local minor = Players[i]
    local myTeam = Teams[myTeamId]
    local entry = {
        name = minor:GetCivilizationShortDescription(),
        trait = traitName(minor:GetMinorCivTrait()),
        influence = minor:GetMinorCivFriendshipWithMajor(me),
        friends = minor:IsFriends(me),
        allied = minor:IsAllies(me),
        atWar = myTeam:IsAtWar(minor:GetTeam()),
    }
    local personalityKey = EngineData.minorPersonalityTextKey(i)
    if personalityKey ~= nil then
        entry.personality = Text.key(personalityKey)
    end

    local ally = minor:GetAlly()
    if ally ~= nil and ally >= 0 and ally ~= me then
        if myTeam:IsHasMet(Players[ally]:GetTeam()) then
            entry.ally = Players[ally]:GetCivilizationShortDescription()
        else
            entry.hasUnmetAlly = true
        end
    end

    if withQuests and minor:GetMinorCivNumDisplayedQuestsForPlayer(me) > 0 then
        local quests = GetActiveQuestToolTip(me, i)
        if quests ~= nil and quests ~= "" then
            entry.quests = TextFilter.filter(quests)
        end
    end

    local capital = minor:GetCapitalCity()
    if capital ~= nil and capital:Plot():IsRevealed(myTeamId, false) then
        entry.x, entry.y = capital:GetX(), capital:GetY()
    end
    return entry
end

function queries.diplomacy()
    local me = Game.GetActivePlayer()
    local player = Players[me]
    local myTeamId = player:GetTeam()
    local myTeam = Teams[myTeamId]

    local withQuests = GetActiveQuestToolTip ~= nil
    if not withQuests then
        Log.warn("QueryDiplo: GetActiveQuestToolTip missing; city-state quests omitted")
    end

    local majors, cityStates = {}, {}
    for i = 0, GameDefines.MAX_CIV_PLAYERS - 1 do
        local other = Players[i]
        if
            i ~= me
            and other ~= nil
            and other:IsAlive()
            and not other:IsBarbarian()
            and myTeam:IsHasMet(other:GetTeam())
        then
            if other:IsMinorCiv() then
                cityStates[#cityStates + 1] = minorEntry(me, myTeamId, i, withQuests)
            else
                majors[#majors + 1] = majorEntry(me, player, myTeamId, i)
            end
        end
    end
    return { civilizations = majors, cityStates = cityStates }
end
