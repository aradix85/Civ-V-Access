-- MCP bridge actions on the empire as a whole: adopting a social policy
-- (or opening a branch, or taking an ideology tenet) and founding a
-- pantheon. Registers on Rpc._actions; included from Boot after
-- CivVAccess_BridgeCore.
--
-- Each goes through the engine's own Can* check first and then the same
-- net message the policy screen or the pantheon popup sends
-- (SocialPolicyPopup.lua OnYes / OnTenetConfirmYes,
-- ChoosePantheonPopup.lua OnYes). Both are permanent choices; the server
-- only sends them when the player named the choice.

local actions = Rpc._actions

-- adopt_policy <name>: a policy, a tenet of the player's ideology, or a
-- policy branch to open.
function actions.adopt_policy(name)
    if name == nil or name == "" then
        error("name a policy or policy branch")
    end
    local player = Bridge.activePlayer()
    local policy = Rpc.resolveRow("Policies", "POLICY_", name)
    if policy ~= nil then
        local label = Text.key(policy.Description)
        if player:HasPolicy(policy.ID) then
            error("you already have " .. label)
        end
        if not player:CanAdoptPolicy(policy.ID) then
            error(label .. " cannot be adopted now")
        end
        Network.SendUpdatePolicies(policy.ID, true, true)
        Bridge.sent()
        Events.AudioPlay2DSound("AS2D_INTERFACE_POLICY")
        local branch = policy.PolicyBranchType and GameInfo.PolicyBranchTypes[policy.PolicyBranchType]
        local isTenet = branch ~= nil and (branch.PurchaseByLevel == true or branch.PurchaseByLevel == 1)
        Bridge.speak(
            Text.format(
                isTenet and "TXT_KEY_CIVVACCESS_SOCIALPOLICY_ADOPTED_TENET" or "TXT_KEY_CIVVACCESS_SOCIALPOLICY_ADOPTED",
                label
            )
        )
        local playerID = player:GetID()
        return { policy = label, tenet = isTenet or nil }, function()
            if not Players[playerID]:HasPolicy(policy.ID) then
                return nil
            end
            return { adopted = true }
        end
    end
    local branch = Rpc.resolveRow("PolicyBranchTypes", "POLICY_BRANCH_", name)
    if branch == nil then
        error("no policy or policy branch called " .. name)
    end
    local label = Text.key(branch.Description)
    if player:IsPolicyBranchUnlocked(branch.ID) then
        error(label .. " is already open")
    end
    if not player:CanUnlockPolicyBranch(branch.ID) then
        error(label .. " cannot be opened now")
    end
    Network.SendUpdatePolicies(branch.ID, false, true)
    Bridge.sent()
    Events.AudioPlay2DSound("AS2D_INTERFACE_POLICY")
    Bridge.speak(Text.format("TXT_KEY_CIVVACCESS_SOCIALPOLICY_ADOPTED", label))
    local playerID = player:GetID()
    return { branch = label }, function()
        if not Players[playerID]:IsPolicyBranchUnlocked(branch.ID) then
            return nil
        end
        return { opened = true }
    end
end

-- A belief by its name (ShortDescription; a belief's Description is its
-- effect), its Type, or a bare type name.
local function resolveBelief(name)
    local row = GameInfo.Beliefs[name] or GameInfo.Beliefs["BELIEF_" .. name:upper():gsub(" ", "_")]
    if row ~= nil then
        return row
    end
    local wanted = Locale.ToLower(name)
    for belief in GameInfo.Beliefs() do
        local short = Text.keyOrNil(belief.ShortDescription)
        if short ~= nil and Locale.ToLower(short) == wanted then
            return belief
        end
    end
    return nil
end

-- found_pantheon <belief>
function actions.found_pantheon(name)
    if name == nil or name == "" then
        error("name a pantheon belief")
    end
    local player = Bridge.activePlayer()
    if player:HasCreatedPantheon() then
        error("you already have a pantheon")
    end
    if not player:CanCreatePantheon(true) then
        error("you cannot found a pantheon yet")
    end
    local belief = resolveBelief(name)
    if belief == nil then
        error("no belief called " .. name)
    end
    local label = Text.key(belief.ShortDescription)
    local available = false
    for _, id in ipairs(Game.GetAvailablePantheonBeliefs()) do
        if id == belief.ID then
            available = true
            break
        end
    end
    if not available then
        error(label .. " is not an available pantheon belief")
    end
    local playerID = player:GetID()
    Network.SendFoundPantheon(playerID, belief.ID)
    Bridge.sent()
    Bridge.speak(Text.format("TXT_KEY_CIVVACCESS_SOCIALPOLICY_ADOPTED", label))
    return { belief = label }, function()
        if not Players[playerID]:HasCreatedPantheon() then
            return nil
        end
        return { founded = true }
    end
end
