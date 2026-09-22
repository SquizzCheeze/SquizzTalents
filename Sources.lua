-- Loadout sources behind one normalized shape:
--   { id, source = "blizz"|"own", name, icon, specID, tags, configID?, importString? }
-- Blizzard loadouts are read live every time and never copied into the db;
-- only our metadata (tags, icon) is stored, keyed by configID.
local _, ns = ...
local L = ns.L

local Sources = {}
ns.Sources = Sources

-- ---------------------------------------------------------------------------
-- Spec helpers. The bare GetSpecialization* globals are gone in 12.1.
-- ---------------------------------------------------------------------------
function Sources.GetCurrentSpecID()
    local index = C_SpecializationInfo.GetSpecialization()
    if not ns.IsPlain(index) or index <= 0 then return nil end
    local specID = C_SpecializationInfo.GetSpecializationInfo(index)
    if not ns.IsPlain(specID) or specID == 0 then return nil end
    return specID
end

-- specID, name, icon for every spec this character has (slots 1-4 until empty).
function Sources.GetPlayerSpecs()
    local specs = {}
    for index = 1, 4 do
        local specID, name, _, icon = C_SpecializationInfo.GetSpecializationInfo(index)
        if not ns.IsPlain(specID) or specID == 0 then break end
        specs[#specs + 1] = { specID = specID, name = name, icon = icon }
    end
    return specs
end

function Sources.GetSpecIcon(specID)
    if not specID then return nil end
    local _, _, _, icon = GetSpecializationInfoForSpecID(specID)
    return icon
end

-- The active config's export string, or nil + reason.
function Sources.GetActiveImportString()
    local configID = C_ClassTalents.GetActiveConfigID()
    if not configID then return nil, L["No active talent config (below level 10?)"] end
    local ok, str = pcall(C_Traits.GenerateImportString, configID)
    if not ok or not ns.IsPlain(str) or str == "" then
        return nil, L["Could not export the current build"]
    end
    return str
end

-- ---------------------------------------------------------------------------
-- Blizzard adapter
-- ---------------------------------------------------------------------------
local Blizz = {}
Sources.Blizz = Blizz

function Blizz.List(specID)
    local out = {}
    local ok, configIDs = pcall(C_ClassTalents.GetConfigIDsBySpecID, specID)
    if not ok or type(configIDs) ~= "table" then return out end
    for _, configID in ipairs(configIDs) do
        local info = C_Traits.GetConfigInfo(configID)
        if info then
            local meta = ns.Store.GetBlizzMeta(configID) or {}
            out[#out + 1] = {
                id = "blizz:" .. configID,
                source = "blizz",
                name = info.name,
                icon = meta.icon or Sources.GetSpecIcon(specID),
                specID = specID,
                tags = meta.tags or {},
                configID = configID,
            }
        end
    end
    return out
end

-- Export string for a saved Blizzard loadout, for "is this the active build".
-- UNVERIFIED that GenerateImportString accepts a saved (non-active) configID.
function Blizz.GetImportString(entry)
    local ok, str = pcall(C_Traits.GenerateImportString, entry.configID)
    if ok and ns.IsPlain(str) and str ~= "" then return str end
    return nil
end

-- Remove metadata for configs that no longer exist on this character. Only
-- when the lists are populated: at login they can be empty for a moment, and
-- pruning then would erase everything.
function Blizz.PruneOrphans()
    local live, any = {}, false
    for _, spec in ipairs(Sources.GetPlayerSpecs()) do
        local ok, ids = pcall(C_ClassTalents.GetConfigIDsBySpecID, spec.specID)
        if ok and type(ids) == "table" then
            for _, id in ipairs(ids) do
                live[id] = true
                any = true
            end
        end
    end
    if any then ns.Store.PruneBlizzMeta(live) end
end

-- ---------------------------------------------------------------------------
-- Own adapter
-- ---------------------------------------------------------------------------
local Own = {}
Sources.Own = Own

function Own.List(specID)
    local out = {}
    for ownID, e in ns.Store.IterOwn() do
        if e.specID == specID then
            out[#out + 1] = {
                id = "own:" .. ownID,
                source = "own",
                ownID = ownID,
                name = e.name,
                icon = e.icon or Sources.GetSpecIcon(specID),
                specID = e.specID,
                tags = e.tags or {},
                importString = e.importString,
                created = e.created,
            }
        end
    end
    table.sort(out, function(a, b) return (a.created or 0) < (b.created or 0) end)
    return out
end

-- Save the active build as an own entry. Returns the new entry id or nil + reason.
function Own.SaveCurrent(name, icon, tags)
    local specID = Sources.GetCurrentSpecID()
    if not specID then return nil, L["No specialization selected"] end
    local configID = C_ClassTalents.GetActiveConfigID()
    if configID and C_Traits.ConfigHasStagedChanges(configID) then
        return nil, L["You have unapplied talent changes. Apply or discard them first."]
    end
    local str, err = Sources.GetActiveImportString()
    if not str then return nil, err end
    local ownID = ns.Store.AddOwn({
        name = name,
        icon = icon,
        specID = specID,
        tags = tags,
        importString = str,
    })
    return "own:" .. ownID
end

function Own.Delete(entry)
    ns.Store.DeleteOwn(entry.ownID)
    ns.Store.ForgetEntry(entry.id)
end

-- Overwrite an own build with the active talents, keeping its name, icon,
-- tags and every mapping that points at it (the id does not change).
function Own.UpdateToCurrent(entry)
    local own = ns.Store.GetOwn(entry.ownID)
    if not own then return nil, L["Build not found"] end
    if own.specID ~= Sources.GetCurrentSpecID() then
        return nil, L["Switch to this build's specialization first"]
    end
    local configID = C_ClassTalents.GetActiveConfigID()
    if configID and C_Traits.ConfigHasStagedChanges(configID) then
        return nil, L["You have unapplied talent changes. Apply or discard them first."]
    end
    local str, err = Sources.GetActiveImportString()
    if not str then return nil, err end
    own.importString = str
    own.updated = time()
    return true
end

-- Own builds for `specID` that can no longer be applied as saved.
function Own.ListStale(specID)
    local out = {}
    for _, e in ipairs(Own.List(specID)) do
        if ns.Apply.StaleReason(e.importString, e.specID) then out[#out + 1] = e end
    end
    return out
end

-- Delete a Blizzard loadout. Same call Blizzard's loadout edit dialog makes;
-- our metadata and mappings for it are pruned on TRAIT_CONFIG_LIST_UPDATED.
function Blizz.Delete(entry)
    if InCombatLockdown() then return nil, L["In combat"] end
    if not C_ClassTalents.DeleteConfig(entry.configID) then
        return nil, L["The game refused to delete this loadout"]
    end
    ns.Store.SetBlizzMeta(entry.configID, nil)
    ns.Store.ForgetEntry(entry.id)
    return true
end

-- ---------------------------------------------------------------------------
-- Metadata edits, the same for both sources. Blizzard entries keep theirs in
-- blizzMeta (never touching the loadout); own entries on the entry itself.
-- ---------------------------------------------------------------------------
local function MetaFor(entry)
    if entry.source == "own" then return ns.Store.GetOwn(entry.ownID) end
    local meta = ns.Store.GetBlizzMeta(entry.configID)
    if not meta then
        meta = { tags = {} }
        ns.Store.SetBlizzMeta(entry.configID, meta)
    end
    return meta
end

function Sources.SetTags(entry, tags)
    local meta = MetaFor(entry)
    if meta then meta.tags = tags end
end

function Sources.SetIcon(entry, icon)
    local meta = MetaFor(entry)
    if meta then meta.icon = icon end
end

-- Only own entries can be renamed; Blizzard names belong to the talent UI.
function Sources.Rename(entry, name)
    local own = entry.source == "own" and ns.Store.GetOwn(entry.ownID)
    if own then own.name = name end
end

-- "a, b ,c" -> { "a", "b", "c" }
function Sources.ParseTags(text)
    local tags = {}
    for tag in (text or ""):gmatch("[^,]+") do
        tag = strtrim(tag)
        if tag ~= "" then tags[#tags + 1] = tag end
    end
    return tags
end

-- ---------------------------------------------------------------------------
-- Unified list for one spec (default: current), Blizzard first.
-- ---------------------------------------------------------------------------
function Sources.GetList(specID)
    specID = specID or Sources.GetCurrentSpecID()
    if not specID then return {} end
    local list = Blizz.List(specID)
    for _, e in ipairs(Own.List(specID)) do list[#list + 1] = e end
    return list
end

function Sources.Find(id)
    for _, e in ipairs(Sources.GetList()) do
        if e.id == id then return e end
    end
    return nil
end

-- Export string for any entry.
function Sources.GetEntryImportString(entry)
    if entry.source == "own" then return entry.importString end
    return Blizz.GetImportString(entry)
end

-- Annotate the list in place:
--   e.importStringResolved  export string (nil if unreadable)
--   e.isActive              matches the active build
--   e.duplicateOf           own entry identical to this Blizzard entry (id)
-- Returns the active export string.
function Sources.Annotate(list)
    local current = Sources.GetActiveImportString()
    -- Matched on purchased talents, not the raw string; see Apply.Signature.
    local currentSig = ns.Apply.Signature(current)
    local blizzByString = {}
    for _, e in ipairs(list) do
        e.importStringResolved = Sources.GetEntryImportString(e)
        e.signature = ns.Apply.Signature(e.importStringResolved)
        e.isActive = current ~= nil and (e.importStringResolved == current
            or (currentSig ~= nil and e.signature == currentSig))
        if e.source == "blizz" and e.signature then
            blizzByString[e.signature] = blizzByString[e.signature] or e
        end
    end
    for _, e in ipairs(list) do
        local twin = e.source == "own" and e.signature and blizzByString[e.signature]
        e.duplicateOf = twin and twin.id or nil
        e.duplicateName = twin and twin.name or nil
        -- Blizzard's talent window validates its own loadouts; only ours need it.
        e.staleReason = e.source == "own" and ns.Apply.StaleReason(e.importString, e.specID) or nil
    end
    return current
end
Sources.MarkActive = Sources.Annotate

-- DeleteConfig completes asynchronously: the configID is still listed right
-- after the call and only disappears with TRAIT_CONFIG_DELETED.
ns.On("TRAIT_CONFIG_LIST_UPDATED", function()
    Blizz.PruneOrphans()
end)
ns.On("TRAIT_CONFIG_DELETED", function()
    Blizz.PruneOrphans()
end)
