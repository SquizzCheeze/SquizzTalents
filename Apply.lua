-- Applying a loadout.
--
--   Blizzard entry: C_ClassTalents.LoadConfig(configID, true), the same call
--                   Blizzard's own loadout dropdown makes.
--   Own entry:      decode the import string exactly as Blizzard's
--                   ClassTalentImportExportMixin does, stage it onto the ACTIVE
--                   config with C_Traits (ResetTree, SetSelection, PurchaseRank)
--                   and commit with C_ClassTalents.CommitConfig(nil). We avoid
--                   C_ClassTalents.ImportLoadout on purpose: it creates a new
--                   Blizzard loadout, which would eat the very cap own builds exist
--                   to get around.
--
-- Completion is confirmed by TRAIT_CONFIG_UPDATED for the active config, failure
-- by CONFIG_COMMIT_FAILED, and a timeout reports "unconfirmed" rather than lying.
local _, ns = ...
local L = ns.L

local Apply = {}
ns.Apply = Apply

local CONFIRM_TIMEOUT = 20
local MAX_STAGE_PASSES = 12

Apply.last = nil    -- last result, for /sqt debug
Apply.pending = nil -- { entry, configID, startedAt, result }

local function Finish(result)
    result.finishedAt = GetTime()
    Apply.last = result
    Apply.pending = nil
    if ns.UI and ns.UI.OnApplyFinished then ns.UI.OnApplyFinished(result) end
end

-- Why applying is impossible right now, or nil when it is possible.
function Apply.BlockReason()
    if InCombatLockdown() then return L["In combat"] end
    if C_ChallengeMode.IsChallengeModeActive() then return L["Mythic+ key is active"] end
    if Apply.pending then return L["Already applying a build"] end
    local canEdit, err = C_ClassTalents.CanEditTalents()
    if not canEdit then
        return (ns.IsPlain(err) and err ~= "") and err or L["Talents cannot be changed right now"]
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Import string decoding. Mirrors Blizzard_ClassTalentImportExport.lua
-- (ReadLoadoutHeader / ReadLoadoutContent / ConvertToImportLoadoutEntryInfo).
-- ---------------------------------------------------------------------------
local BITS_VERSION, BITS_SPEC, BITS_RANKS = 8, 16, 6

local function ReadHeader(stream)
    if stream:GetNumberOfBits() < BITS_VERSION + BITS_SPEC + 128 then return nil end
    local version = stream:ExtractValue(BITS_VERSION)
    local specID = stream:ExtractValue(BITS_SPEC)
    local hash = {}
    for i = 1, 16 do hash[i] = stream:ExtractValue(8) end
    return version, specID, hash
end

local function HashIsEmpty(hash)
    for _, v in ipairs(hash) do
        if v ~= 0 then return false end
    end
    return true
end

local function HashEquals(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

local function ReadContent(stream, treeNodes)
    local results = {}
    for i = 1, #treeNodes do
        local r = { selected = stream:ExtractValue(1) == 1 }
        if r.selected then
            r.purchased = stream:ExtractValue(1) == 1
            if r.purchased then
                if stream:ExtractValue(1) == 1 then
                    r.partialRanks = stream:ExtractValue(BITS_RANKS)
                end
                if stream:ExtractValue(1) == 1 then
                    r.choiceIndex = stream:ExtractValue(2) + 1 -- stored zero-based
                end
            end
        end
        results[i] = r
    end
    return results
end

-- Why a saved build can no longer be applied as saved, or nil if it still can.
-- Header only (26 bytes), cheap enough to run on every render. Catches a talent
-- format change and a changed talent tree -- the patch-day case. It cannot
-- catch "I would pick different talents now"; that is the player's call.
function Apply.StaleReason(importString, specID)
    if not importString then return L["No build string"] end
    local stream = ExportUtil.MakeImportDataStream(importString)
    local version, _, hash = ReadHeader(stream)
    if not version then return L["Import string is invalid"] end
    if version ~= C_Traits.GetLoadoutSerializationVersion() then
        return L["Saved in an older talent format"]
    end
    if HashIsEmpty(hash) then return nil end -- third-party strings skip the check
    local treeID = specID and C_ClassTalents.GetTraitTreeForSpec(specID)
    if treeID and not HashEquals(hash, C_Traits.GetTreeHash(treeID)) then
        return L["The talent tree has changed since this build was saved"]
    end
    return nil
end

-- Decode `importString` against the active config. Returns a list of
-- { nodeID, ranks, entryID, isChoice } for every node with PURCHASED ranks
-- (granted nodes are free and need nothing), or nil + reason.
function Apply.Decode(importString, configID, treeID)
    local stream = ExportUtil.MakeImportDataStream(importString)
    local version, specID, hash = ReadHeader(stream)
    if not version then return nil, L["Import string is invalid"] end
    if version ~= C_Traits.GetLoadoutSerializationVersion() then
        return nil, L["Saved in an older talent format; right-click it and choose Update to current talents"]
    end
    if specID ~= ns.Sources.GetCurrentSpecID() then
        return nil, L["Build is for a different specialization"]
    end
    if not HashIsEmpty(hash) and not HashEquals(hash, C_Traits.GetTreeHash(treeID)) then
        return nil, L["The talent tree has changed since this build was saved; "
            .. "right-click it and choose Update to current talents"]
    end

    local treeNodes = C_Traits.GetTreeNodes(treeID)
    local content = ReadContent(stream, treeNodes)
    local targets = {}
    for i, nodeID in ipairs(treeNodes) do
        local r = content[i]
        if r.selected and r.purchased then
            local node = C_Traits.GetNodeInfo(configID, nodeID)
            if node then
                local t = {
                    nodeID = nodeID,
                    ranks = r.partialRanks or node.maxRanks,
                    posY = node.posY,
                    posX = node.posX,
                }
                local isChoice = node.type == Enum.TraitNodeType.Selection
                    or node.type == Enum.TraitNodeType.SubTreeSelection
                if isChoice and r.choiceIndex then
                    t.entryID = node.entryIDs[r.choiceIndex]
                    t.isChoice = true
                end
                -- Tiered nodes spread ranks over several entries; Blizzard's
                -- converter also takes maxRanks as the node total, and
                -- PurchaseRank walks the entries in order.
                targets[#targets + 1] = t
            end
        end
    end
    return targets
end

-- ---------------------------------------------------------------------------
-- Staging
-- ---------------------------------------------------------------------------
local function TargetMet(configID, t)
    local node = C_Traits.GetNodeInfo(configID, t.nodeID)
    if not node then return false end
    if t.isChoice then
        if not node.activeEntry or node.activeEntry.entryID ~= t.entryID then return false end
        return node.ranksPurchased >= 1
    end
    return node.ranksPurchased >= t.ranks
end

-- Try to move one target forward. Returns true if anything changed.
local function StepTarget(configID, t)
    if t.isChoice then
        local node = C_Traits.GetNodeInfo(configID, t.nodeID)
        if node and (not node.activeEntry or node.activeEntry.entryID ~= t.entryID
                or node.ranksPurchased < 1) then
            return C_Traits.SetSelection(configID, t.nodeID, t.entryID, false) and true or false
        end
        return false
    end
    local progressed = false
    for _ = 1, t.ranks do
        local node = C_Traits.GetNodeInfo(configID, t.nodeID)
        if not node or node.ranksPurchased >= t.ranks then break end
        if not C_Traits.PurchaseRank(configID, t.nodeID) then break end
        progressed = true
    end
    return progressed
end

-- Stage targets onto configID. Returns the list of targets that could not be
-- met. Top-of-tree first, then repeated passes: gates and edges unlock as
-- earlier nodes land, so one ordered pass is not always enough.
local function Stage(configID, targets)
    table.sort(targets, function(a, b)
        if a.posY ~= b.posY then return a.posY < b.posY end
        return a.posX < b.posX
    end)
    local remaining = targets
    for _ = 1, MAX_STAGE_PASSES do
        local nextRemaining, progressed = {}, false
        for _, t in ipairs(remaining) do
            if StepTarget(configID, t) then progressed = true end
            if not TargetMet(configID, t) then nextRemaining[#nextRemaining + 1] = t end
        end
        remaining = nextRemaining
        if #remaining == 0 or not progressed then break end
    end
    return remaining
end

-- ---------------------------------------------------------------------------
-- Entry points
-- ---------------------------------------------------------------------------
-- Arm the confirmation BEFORE the call that commits: TRAIT_CONFIG_UPDATED is a
-- synchronous event and can fire inside that call. `configIDs` is a set; a
-- saved loadout can report under its own ID or the active one.
local function BeginWait(entry, configIDs, result)
    result.status = "committing"
    Apply.pending = { entry = entry, configIDs = configIDs, result = result }
    local token = result
    C_Timer.After(CONFIRM_TIMEOUT, function()
        if Apply.pending and Apply.pending.result == token then
            token.status = "unconfirmed"
            token.reason = L["No confirmation from the game (timed out)"]
            Finish(token)
        end
    end)
end

local function StillPending(result)
    return Apply.pending and Apply.pending.result == result
end

local function ApplyBlizz(entry, result)
    local specID = entry.specID
    local active = C_ClassTalents.GetActiveConfigID()
    BeginWait(entry, { [entry.configID] = true, [active or 0] = true }, result)
    local loadResult, changeError = C_ClassTalents.LoadConfig(entry.configID, true)
    result.loadResult = loadResult
    if loadResult ~= Enum.LoadConfigResult.Error then
        -- Blizzard's own dropdown records the selection so its UI shows this loadout.
        C_ClassTalents.UpdateLastSelectedSavedConfigID(specID, entry.configID)
    end
    if not StillPending(result) then return end -- confirmed synchronously
    if loadResult == Enum.LoadConfigResult.Error then
        result.status = "failed"
        result.reason = (ns.IsPlain(changeError) and changeError ~= "") and changeError
            or L["The game refused to load this loadout"]
        return Finish(result)
    end
    if loadResult == Enum.LoadConfigResult.NoChangesNecessary then
        result.status = "success"
        result.reason = L["Already active"]
        return Finish(result)
    end
    if loadResult == Enum.LoadConfigResult.Ready then
        -- UNVERIFIED: with autoApply the UI never commits on Ready; commit
        -- ourselves so the build actually lands.
        if not C_ClassTalents.CommitConfig(entry.configID) then
            result.status = "failed"
            result.reason = L["Commit was refused"]
            return Finish(result)
        end
    end
    -- LoadInProgress (or Ready + commit): the wait armed above carries on.
end

local function ApplyOwn(entry, result)
    local configID = C_ClassTalents.GetActiveConfigID()
    if not configID then
        result.status, result.reason = "failed", L["No active talent config (below level 10?)"]
        return Finish(result)
    end
    if C_ClassTalents.GetStarterBuildActive() then
        result.status = "failed"
        result.reason = L["Starter Build is active. Switch to a loadout in the talent window first."]
        return Finish(result)
    end
    local treeID = C_ClassTalents.GetTraitTreeForSpec(entry.specID)
    if not treeID then
        result.status, result.reason = "failed", L["Could not find the talent tree"]
        return Finish(result)
    end

    local targets, err = Apply.Decode(entry.importString, configID, treeID)
    if not targets then
        result.status, result.reason = "failed", err
        return Finish(result)
    end
    result.targets = #targets

    -- Start from a clean slate: discard staged edits, then refund everything.
    if C_Traits.ConfigHasStagedChanges(configID) then C_Traits.RollbackConfig(configID) end
    C_Traits.ResetTree(configID, treeID)

    local unmet = Stage(configID, targets)
    result.unmet = {}
    for _, t in ipairs(unmet) do result.unmet[#result.unmet + 1] = t.nodeID end

    if not C_Traits.ConfigHasStagedChanges(configID) then
        if #unmet == 0 then
            result.status, result.reason = "success", L["Already active"]
        else
            result.status = "partial"
            result.reason = string.format(L["%d of %d talents could not be applied"], #unmet, #targets)
        end
        return Finish(result)
    end

    BeginWait(entry, { [configID] = true }, result)
    if not C_ClassTalents.CommitConfig(nil) then
        if StillPending(result) then
            C_Traits.RollbackConfig(configID)
            result.status, result.reason = "failed", L["Commit was refused"]
            Finish(result)
        end
        return
    end
    -- The committed build is no longer any named Blizzard loadout; clear the
    -- selection so the talent window doesn't claim one it no longer matches.
    C_ClassTalents.UpdateLastSelectedSavedConfigID(entry.specID, nil)
end

function Apply.Run(entry)
    local result = {
        entryID = entry.id,
        entryName = entry.name,
        source = entry.source,
        startedAt = GetTime(),
    }
    local block = Apply.BlockReason()
    if block then
        result.status, result.reason = "blocked", block
        return Finish(result)
    end
    if entry.specID ~= ns.Sources.GetCurrentSpecID() then
        result.status, result.reason = "blocked", L["Build is for a different specialization"]
        return Finish(result)
    end
    local ok, err
    if entry.source == "blizz" then
        ok, err = pcall(ApplyBlizz, entry, result)
    else
        ok, err = pcall(ApplyOwn, entry, result)
    end
    if not ok then
        result.status, result.reason = "error", tostring(err)
        Finish(result)
    end
end

ns.On("TRAIT_CONFIG_UPDATED", function(configID)
    local p = Apply.pending
    if not p or not p.configIDs[configID] then return end
    if p.result.status ~= "committing" then return end
    local r = p.result
    if r.unmet and #r.unmet > 0 then
        r.status = "partial"
        r.reason = string.format(L["%d of %d talents could not be applied"], #r.unmet, r.targets or 0)
    else
        r.status = "success"
        r.reason = nil
    end
    Finish(r)
end)

ns.On("CONFIG_COMMIT_FAILED", function(configID)
    local p = Apply.pending
    if not p or not p.configIDs[configID] then return end
    p.result.status = "failed"
    p.result.reason = L["The game rejected the talent change"]
    Finish(p.result)
end)
