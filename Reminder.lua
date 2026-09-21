-- Content detection, mapping lookup, mismatch test and the three triggers
-- (entering an instance, slotting a keystone, a ready check).
--
-- Everything here is out-of-combat, non-secret data: GetInstanceInfo, the
-- player's own talent config and our saved tables. A trigger that fires in
-- combat is queued until PLAYER_REGEN_ENABLED.
local _, ns = ...
local L = ns.L

local Reminder = {}
ns.Reminder = Reminder

local DELVE_DIFFICULTY = 208 -- UNVERIFIED fallback; IsDelveInProgress is the primary test

local KIND_LABELS = {
    dungeon = L["All dungeons"],
    raid = L["All raids"],
    delve = L["All delves"],
    pvp = L["All battlegrounds"],
    arena = L["All arenas"],
}

-- Dismissed contexts this session (instance key -> true), so re-entering the
-- same instance after "Not now" does not nag. Keystone/ready-check still ask.
local dismissed = {}

-- The current content, or nil when it is not content we remind for.
-- {
--   kind, instanceID, difficultyID, name, difficultyName,
--   keys = { exact, instance, kind },    -- most specific first
--   labels = { [key] = text },
-- }
function Reminder.GetContext()
    local name, instanceType, difficultyID, difficultyName, _, _, _, instanceID = GetInstanceInfo()
    if not ns.IsPlain(instanceType) or not ns.IsPlain(instanceID) then return nil end

    local kind
    if instanceType == "party" then
        kind = "dungeon"
    elseif instanceType == "raid" then
        kind = "raid"
    elseif instanceType == "pvp" then
        kind = "pvp"
    elseif instanceType == "arena" then
        kind = "arena"
    elseif instanceType == "scenario" then
        local inDelve = C_PartyInfo.IsDelveInProgress and C_PartyInfo.IsDelveInProgress()
        if inDelve or difficultyID == DELVE_DIFFICULTY then kind = "delve" end
    end
    if not kind then return nil end

    local ctx = {
        kind = kind,
        instanceID = instanceID,
        difficultyID = difficultyID,
        name = name,
        difficultyName = difficultyName,
    }
    local exact = string.format("i:%d:d:%d", instanceID, difficultyID or 0)
    local instance = string.format("i:%d", instanceID)
    local kindKey = "t:" .. kind
    ctx.keys = { exact, instance, kindKey }
    local diffText = (ns.IsPlain(difficultyName) and difficultyName ~= "") and difficultyName or nil
    ctx.labels = {
        [exact] = diffText and string.format("%s (%s)", name, diffText) or name,
        [instance] = string.format(L["%s (any difficulty)"], name),
        [kindKey] = KIND_LABELS[kind],
    }
    return ctx
end

-- Mapped entry id for ctx on specID, plus the key that matched.
function Reminder.Resolve(ctx, specID)
    local mappings = ns.Store.GetMappings(specID)
    for _, key in ipairs(ctx.keys) do
        local m = mappings[key]
        if m then return m.entryID, key end
    end
    return nil
end

-- Build everything the popup needs, or nil + reason when no popup is due.
function Reminder.Evaluate(trigger)
    local ctx = Reminder.GetContext()
    if not ctx then return nil, "not relevant content" end
    if C_ChallengeMode.IsChallengeModeActive() then return nil, "key active" end
    local specID = ns.Sources.GetCurrentSpecID()
    if not specID then return nil, "no spec" end

    local list = ns.Sources.GetList(specID)
    if #list == 0 then return nil, "no entries" end
    local current = ns.Sources.Annotate(list)
    if not current then return nil, "cannot read active build" end

    local mappedID, mappedKey = Reminder.Resolve(ctx, specID)
    local suggestion
    for _, e in ipairs(list) do
        if e.id == mappedID then suggestion = e end
    end

    if suggestion then
        -- Compare export strings, so an own build identical to the active
        -- Blizzard loadout counts as a match too.
        if suggestion.importStringResolved == current then return nil, "already matching" end
    else
        if not ns.Store.Setting("remindUnmapped") then return nil, "unmapped" end
    end

    if trigger == "enter" and dismissed[ctx.keys[1]] then return nil, "dismissed" end

    return {
        trigger = trigger,
        ctx = ctx,
        specID = specID,
        list = list,
        suggestion = suggestion,
        mappedKey = mappedKey,
    }
end

Reminder.lastEvaluation = nil -- { trigger, reason, at } for /sqt debug

-- What GetInstanceInfo said at the time, for the debug dump: a miss is only
-- diagnosable if we know what the game was reporting when we looked.
local function InstanceSnapshot()
    local _, instanceType, difficultyID = GetInstanceInfo()
    local delve = C_PartyInfo.IsDelveInProgress and C_PartyInfo.IsDelveInProgress()
    return string.format("type=%s diff=%s delve=%s", tostring(instanceType), tostring(difficultyID),
        tostring(delve))
end

-- Returns the reason (nil when the popup was shown / queued). `label` only
-- names the attempt in /sqt debug; `trigger` drives behaviour ("enter" is the
-- one that honours Not now), so the two must stay separate.
function Reminder.Check(trigger, label)
    local data, reason = Reminder.Evaluate(trigger)
    Reminder.lastEvaluation = {
        trigger = label or trigger,
        reason = reason or "shown",
        at = GetTime(),
        snapshot = InstanceSnapshot(),
    }
    if not data then return reason end
    ns.RunOutOfCombat("reminder", function()
        -- Re-evaluate: the situation may have changed during combat.
        local fresh = Reminder.Evaluate(trigger)
        if fresh then ns.UI.ShowReminder(fresh) end
    end)
end

function Reminder.Dismiss(ctx)
    if ctx then dismissed[ctx.keys[1]] = true end
end

-- ---------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------
-- The entry reminder: one decision per piece of content per entry.
--
-- Instance info arrives late and by no fixed deadline. A delve read as open
-- world 3s in (fixed by retrying), then still read as open world at 15s -- the
-- game only reported it once the delve's scenario started. Timers alone
-- cannot win that race, so the check is ALSO driven by the events that fire
-- when the zone or scenario changes, and whichever sees the content first
-- decides. `decidedKey` is the content already decided for this entry, so
-- repeat events inside the same instance do nothing; a new load clears it,
-- so re-entering the same delve asks again.
local ENTER_DELAYS = { 3, 8, 15 }
local decidedKey = nil
local enterToken = 0

-- Returns true once the current content has been decided (or needs none).
local function CheckEntry(label)
    if not ns.Store.Setting("remindOnEnter") then return true end
    local ctx = Reminder.GetContext()
    if not ctx then
        -- Left relevant content: a later entry is a new decision.
        decidedKey = nil
        return false
    end
    if ctx.keys[1] == decidedKey then return true end
    decidedKey = ctx.keys[1]
    Reminder.Check("enter", label)
    return true
end

ns.On("PLAYER_ENTERING_WORLD", function()
    decidedKey = nil
    enterToken = enterToken + 1
    local token = enterToken
    local function Attempt(i)
        if token ~= enterToken then return end
        if CheckEntry(string.format("enter #%d", i)) then return end
        -- Nothing recognised yet: note what the game reported, for /sqt debug.
        Reminder.Check("enter", string.format("enter #%d", i))
        if ENTER_DELAYS[i + 1] then
            C_Timer.After(ENTER_DELAYS[i + 1] - ENTER_DELAYS[i], function() Attempt(i + 1) end)
        end
    end
    C_Timer.After(ENTER_DELAYS[1], function() Attempt(1) end)
end)

-- Zone and scenario changes: the late signal that a delve (or any instance)
-- is now known. Debounced, since these can arrive in bursts.
local eventQueued = false
local function OnContentEvent(event)
    if eventQueued then return end
    eventQueued = true
    C_Timer.After(1, function()
        eventQueued = false
        CheckEntry("enter (" .. event .. ")")
    end)
end
for _, event in ipairs({ "ZONE_CHANGED_NEW_AREA", "SCENARIO_UPDATE", "ACTIVE_DELVE_DATA_UPDATE" }) do
    ns.On(event, function() OnContentEvent(event) end)
end

ns.On("CHALLENGE_MODE_KEYSTONE_SLOTTED", function()
    if ns.Store.Setting("remindOnKeystone") then Reminder.Check("keystone") end
end)

ns.On("READY_CHECK", function()
    if ns.Store.Setting("remindOnReadyCheck") then Reminder.Check("readycheck") end
end)

ns.On("CHALLENGE_MODE_START", function()
    ns.UI.HideReminder()
end)
