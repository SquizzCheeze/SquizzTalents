-- SavedVariables: schema, migrations and the accessors every other file uses.
--
-- Layout (schema 1):
--   SquizzTalentsDB = {
--       schema   = 1,
--       nextOwnID = 1,
--       own      = { [ownID] = { name, icon, specID, tags = {}, importString, created } },
--       chars    = { ["Name-Realm"] = {
--           blizzMeta = { [configID] = { tags = {}, icon } },
--           mappings  = { [specID] = { [contextKey] = { entryID, label } } },
--       } },
--       settings = { remindOnEnter, remindOnKeystone, remindOnReadyCheck, remindUnmapped,
--                    attachToTalents, mainPos = { point, relPoint, x, y } },
--   }
-- Mappings are per character AND spec: they point at entry ids, and a
-- "blizz:<configID>" id only means something to the character that owns it.
-- Own builds are account-wide (a specID already pins them to one class).
-- Blizzard metadata is per character: configIDs belong to one character, and
-- pruning "orphans" against an account-wide table would wipe every alt's tags.
local _, ns = ...

local Store = {}
ns.Store = Store

Store.SCHEMA = 1

-- Each entry upgrades a db from version (index - 1) to index.
local MIGRATIONS = {
    -- [2] = function(db) ... end,
}

local function Migrate(db)
    local from = db.schema or 0
    for v = from + 1, Store.SCHEMA do
        local step = MIGRATIONS[v]
        if step then step(db) end
        db.schema = v
    end
end

local function CharKey()
    local name, realm = UnitFullName("player")
    if not ns.IsPlain(name) then return nil end
    if not ns.IsPlain(realm) or realm == "" then realm = GetNormalizedRealmName() end
    return name .. "-" .. (realm or "?")
end

Store.DEFAULT_SETTINGS = {
    remindOnEnter = true,
    remindOnKeystone = true,
    remindOnReadyCheck = true,
    remindUnmapped = false, -- also prompt in content with no mapping yet
    attachToTalents = true, -- open the loadout window beside Blizzard's talent tab
}

function Store.Init()
    -- Taken before the table is created: the only way Welcome.lua can tell a
    -- new install from an upgrade out of a version that predates it.
    ns.hadSavedVariables = SquizzTalentsDB ~= nil
    local db = SquizzTalentsDB or {}
    SquizzTalentsDB = db
    db.own = db.own or {}
    db.chars = db.chars or {}
    db.settings = db.settings or {}
    db.nextOwnID = db.nextOwnID or 1
    for k, v in pairs(Store.DEFAULT_SETTINGS) do
        if db.settings[k] == nil then db.settings[k] = v end
    end
    Migrate(db)
    Store.db = db
end

function Store.Setting(key)
    return Store.db and Store.db.settings[key]
end

function Store.SetSetting(key, value)
    if Store.db then Store.db.settings[key] = value end
end

function Store.Char()
    local key = CharKey()
    if not key or not Store.db then return nil end
    local c = Store.db.chars[key]
    if not c then
        c = {}
        Store.db.chars[key] = c
    end
    c.blizzMeta = c.blizzMeta or {}
    c.mappings = c.mappings or {}
    return c
end

-- ---------------------------------------------------------------------------
-- Content mappings
-- ---------------------------------------------------------------------------
function Store.GetMappings(specID)
    local c = Store.Char()
    if not c or not specID then return {} end
    c.mappings[specID] = c.mappings[specID] or {}
    return c.mappings[specID]
end

function Store.SetMapping(specID, key, entryID, label)
    local m = Store.GetMappings(specID)
    m[key] = entryID and { entryID = entryID, label = label } or nil
end

-- Remove every mapping that points at entryID (entry deleted).
function Store.ForgetEntry(entryID)
    local c = Store.Char()
    if not c then return end
    for _, m in pairs(c.mappings) do
        for key, v in pairs(m) do
            if v.entryID == entryID then m[key] = nil end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Own builds
-- ---------------------------------------------------------------------------
function Store.AddOwn(fields)
    local db = Store.db
    local id = db.nextOwnID
    db.nextOwnID = id + 1
    db.own[id] = {
        name = fields.name,
        icon = fields.icon,
        specID = fields.specID,
        tags = fields.tags or {},
        importString = fields.importString,
        created = time(),
    }
    return id
end

function Store.GetOwn(id)
    return Store.db and Store.db.own[id]
end

function Store.DeleteOwn(id)
    if Store.db then Store.db.own[id] = nil end
end

function Store.IterOwn()
    return pairs(Store.db and Store.db.own or {})
end

-- ---------------------------------------------------------------------------
-- Blizzard-loadout metadata (never the loadout itself)
-- ---------------------------------------------------------------------------
function Store.GetBlizzMeta(configID)
    local c = Store.Char()
    return c and c.blizzMeta[configID]
end

function Store.SetBlizzMeta(configID, meta)
    local c = Store.Char()
    if c then c.blizzMeta[configID] = meta end
end

-- Drop metadata for configIDs this character no longer has. `live` is a set
-- of every configID across all of the character's specs.
function Store.PruneBlizzMeta(live)
    local c = Store.Char()
    if not c then return end
    for configID in pairs(c.blizzMeta) do
        if not live[configID] then c.blizzMeta[configID] = nil end
    end
    -- Mappings to a deleted Blizzard loadout would suggest a build that is gone.
    for _, m in pairs(c.mappings) do
        for key, v in pairs(m) do
            local configID = tonumber(v.entryID:match("^blizz:(%d+)$") or "")
            if configID and not live[configID] then m[key] = nil end
        end
    end
end
