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
    -- The instance itself, whatever boss is known: entry decisions and "Not
    -- now" are about the INSTANCE, and must not change when a boss becomes
    -- known mid-raid (that would read as entering new content).
    ctx.baseKey = exact
    local diffText = (ns.IsPlain(difficultyName) and difficultyName ~= "") and difficultyName or nil
    ctx.labels = {
        [exact] = diffText and string.format("%s (%s)", name, diffText) or name,
        [instance] = string.format(L["%s (any difficulty)"], name),
        [kindKey] = KIND_LABELS[kind],
    }

    -- A raid boss we know is next (Reminder.boss, see "Which boss is next"
    -- below): its key goes FIRST, so a build chosen for that boss wins over
    -- one for the raid. Any difficulty -- a boss build rarely differs by it.
    local boss = Reminder.boss
    if kind == "raid" and boss and boss.instanceID == instanceID then
        local bossKey = "b:" .. boss.encounterID
        table.insert(ctx.keys, 1, bossKey)
        ctx.labels[bossKey] = string.format(L["Boss: %s"], boss.name)
        ctx.bossKey = bossKey
    end
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

    -- The boss trigger (targeting a boss, a wipe) only speaks up for a build
    -- chosen for THAT boss; the raid's own build was already offered on the
    -- way in and on ready checks.
    if trigger == "boss" and (not ctx.bossKey or mappedKey ~= ctx.bossKey) then
        return nil, "no build for this boss"
    end

    if suggestion then
        -- Annotate's match, so an own build identical to the active Blizzard
        -- loadout counts too. Not a raw string compare: see Apply.Signature.
        if suggestion.isActive then return nil, "already matching" end
    else
        if not ns.Store.Setting("remindUnmapped") then return nil, "unmapped" end
    end

    if trigger == "enter" and dismissed[ctx.baseKey] then return nil, "dismissed" end

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
    if ctx then dismissed[ctx.baseKey] = true end
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
    if ctx.baseKey == decidedKey then return true end
    decidedKey = ctx.baseKey
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

-- ---------------------------------------------------------------------------
-- Which boss is next (raids)
-- ---------------------------------------------------------------------------
-- A per-boss build needs to know the boss BEFORE the pull, with no combat
-- data (a hard rule of this addon). Two signals qualify:
--   * targeting the boss out of combat -- the target's name is matched
--     against the Encounter Journal's bosses (and their creatures) for this
--     raid;
--   * ENCOUNTER_END after a WIPE -- you are about to pull that boss again. A
--     kill clears it: the next boss is not knowable until it is targeted.
-- Reminder.boss = { instanceID, encounterID, name }; GetContext puts its key
-- first. encounterID is the DUNGEON encounter id, the one ENCOUNTER_END
-- gives and EJ_GetEncounterInfo returns 7th, so both signals agree.
Reminder.boss = nil

local bossCache = {} -- [instanceID] = { byName = {}, byEncounter = {} }

-- The raid's bosses from the Encounter Journal, or nil. Not cached while
-- empty: the journal can have nothing for a moment after login.
local function RaidBosses(instanceID)
    if bossCache[instanceID] then return bossCache[instanceID] end
    if not (C_EncounterJournal and C_EncounterJournal.GetInstanceForGameMap
        and EJ_GetEncounterInfoByIndex and EJ_GetEncounterInfo and EJ_GetCreatureInfo) then
        return nil
    end
    local journalInstanceID = C_EncounterJournal.GetInstanceForGameMap(instanceID)
    if not journalInstanceID or not ns.IsPlain(journalInstanceID) then return nil end

    local bosses = { byName = {}, byEncounter = {} }
    local i = 1
    while true do
        local name, _, journalEncounterID = EJ_GetEncounterInfoByIndex(i, journalInstanceID)
        if not name or not journalEncounterID then break end
        local _, _, _, _, _, _, encounterID = EJ_GetEncounterInfo(journalEncounterID)
        if encounterID and ns.IsPlain(encounterID) and ns.IsPlain(name) then
            local boss = { encounterID = encounterID, name = name }
            bosses.byEncounter[encounterID] = boss
            bosses.byName[name] = boss
            -- Council fights and bosses with a different unit name: each
            -- creature of the encounter names it too.
            local c = 1
            while true do
                local _, creatureName = EJ_GetCreatureInfo(c, journalEncounterID)
                if not creatureName then break end
                if ns.IsPlain(creatureName) then bosses.byName[creatureName] = boss end
                c = c + 1
            end
        end
        i = i + 1
    end
    if not next(bosses.byEncounter) then return nil end
    bossCache[instanceID] = bosses
    return bosses
end

local function SetBoss(instanceID, encounterID, name, label)
    local b = Reminder.boss
    if b and b.instanceID == instanceID and b.encounterID == encounterID then return end
    Reminder.boss = { instanceID = instanceID, encounterID = encounterID, name = name }
    if ns.Store.Setting("remindOnBoss") then Reminder.Check("boss", label) end
end

local function CurrentRaid()
    local _, instanceType, _, _, _, _, _, instanceID = GetInstanceInfo()
    if instanceType ~= "raid" or not ns.IsPlain(instanceID) then return nil end
    return instanceID
end

ns.On("PLAYER_TARGET_CHANGED", function()
    if InCombatLockdown() then return end
    local instanceID = CurrentRaid()
    if not instanceID or not UnitExists("target") or UnitIsPlayer("target") then return end
    local name = UnitName("target")
    -- canaccessvalue as well as IsPlain: the name becomes a table key below,
    -- and the static checker only recognises the former as a guard.
    if not ns.IsPlain(name) or (canaccessvalue and not canaccessvalue(name)) then return end
    local bosses = RaidBosses(instanceID)
    local boss = bosses and bosses.byName[name]
    if boss then SetBoss(instanceID, boss.encounterID, boss.name, "boss (target)") end
end)

ns.On("ENCOUNTER_END", function(encounterID, encounterName, _, _, success)
    local instanceID = CurrentRaid()
    if not instanceID or not ns.IsPlain(encounterID) or not ns.IsPlain(success) then return end
    if success == 1 then
        local b = Reminder.boss
        if b and b.encounterID == encounterID then Reminder.boss = nil end
        return
    end
    local bosses = RaidBosses(instanceID)
    local known = bosses and bosses.byEncounter[encounterID]
    local name = (known and known.name) or (ns.IsPlain(encounterName) and encounterName) or "?"
    -- Queued out of combat by Reminder.Check if the wipe is still settling.
    SetBoss(instanceID, encounterID, name, "boss (wipe)")
end)

ns.On("CHALLENGE_MODE_START", function()
    ns.UI.HideReminder()
end)
