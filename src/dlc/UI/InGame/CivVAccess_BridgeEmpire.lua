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

-- Tenet slots per level, as the policy screen has them (7, 4, 3); the
-- Community Patch defines them, vanilla only has the screen's slots.
local TENET_SLOTS = { 7, 4, 3 }

local function tenetSlotsFull(player, policy, branch)
    local level = policy.Level or 0
    if level < 1 then
        return false
    end
    local slots = GameDefines["MAX_NUM_TENETS_LEVEL_" .. level] or TENET_SLOTS[level]
    local owned = 0
    for p in GameInfo.Policies({ PolicyBranchType = branch.Type, Level = level }) do
        if player:HasPolicy(p.ID) then
            owned = owned + 1
        end
    end
    return owned >= slots
end

local function openBranch(player, branch)
    local label = Text.key(branch.Description)
    if player:IsPolicyBranchUnlocked(branch.ID) then
        error(label .. " is already open")
    end
    -- A blocked branch takes the screen's switch-branch question instead.
    if player:IsPolicyBranchBlocked(branch.ID) then
        error(label .. " is blocked by a branch you have; switch on the policy screen")
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

local function adoptPolicy(player, policy)
    local label = Text.key(policy.Description)
    if player:HasPolicy(policy.ID) then
        error("you already have " .. label)
    end
    if player:IsPolicyBlocked(policy.ID) then
        error(label .. " is blocked by a branch you have; switch on the policy screen")
    end
    local branch = GameInfo.PolicyBranchTypes[policy.PolicyBranchType]
    local isTenet = branch.PurchaseByLevel == true or branch.PurchaseByLevel == 1
    if isTenet and tenetSlotsFull(player, policy, branch) then
        error("every level " .. policy.Level .. " tenet slot is taken")
    end
    if not player:CanAdoptPolicy(policy.ID) then
        error(label .. " cannot be adopted now")
    end
    Network.SendUpdatePolicies(policy.ID, true, true)
    Bridge.sent()
    Events.AudioPlay2DSound("AS2D_INTERFACE_POLICY")
    Bridge.speak(
        Text.format(isTenet and "TXT_KEY_CIVVACCESS_SOCIALPOLICY_ADOPTED_TENET" or "TXT_KEY_CIVVACCESS_SOCIALPOLICY_ADOPTED", label)
    )
    local playerID = player:GetID()
    return { policy = label, tenet = isTenet or nil }, function()
        if not Players[playerID]:HasPolicy(policy.ID) then
            return nil
        end
        return { adopted = true }
    end
end

-- adopt_policy <name>: a policy branch to open, a policy, or a tenet of
-- the player's ideology. Branches resolve first: each classic branch has
-- a free starting policy of the same name (POLICY_TRADITION) that comes
-- with opening it and can never be adopted on its own.
function actions.adopt_policy(name)
    if name == nil or name == "" then
        error("name a policy or policy branch")
    end
    local player = Bridge.activePlayer()
    local branch = Rpc.resolveRow("PolicyBranchTypes", "POLICY_BRANCH_", name)
    if branch ~= nil then
        return openBranch(player, branch)
    end
    local policy = Rpc.resolveRow("Policies", "POLICY_", name)
    if policy == nil or policy.PolicyBranchType == nil then
        error("no policy or policy branch called " .. name)
    end
    return adoptPolicy(player, policy)
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
    Bridge.speak(label)
    return { belief = label }, function()
        if not Players[playerID]:HasCreatedPantheon() then
            return nil
        end
        return { founded = true }
    end
end
