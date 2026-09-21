-- /sqt debug: a copyable dump of the normalized list, the current content and
-- mapping, the last reminder decision and the last apply result.
local ADDON_NAME, ns = ...
local L = ns.L

local Debug = {}
ns.Debug = Debug

---@param s string?
local function Short(s)
    if not s then return "nil" end
    if #s <= 24 then return s end
    return s:sub(1, 12) .. "..." .. s:sub(-8) .. " (" .. #s .. ")"
end

function Debug.BuildText()
    local out = {}
    local function add(fmt, ...) out[#out + 1] = string.format(fmt, ...) end
    local version, build, _, toc = GetBuildInfo()
    add("SquizzTalents %s | client %s.%s toc %s", C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version") or "?",
        tostring(version), tostring(build), tostring(toc))
    local specID = ns.Sources.GetCurrentSpecID()
    local configID = C_ClassTalents.GetActiveConfigID()
    local current = ns.Sources.GetActiveImportString()
    add("specID=%s activeConfigID=%s starterBuild=%s staged=%s", tostring(specID), tostring(configID),
        tostring(C_ClassTalents.GetStarterBuildActive()),
        tostring(configID and C_Traits.ConfigHasStagedChanges(configID)))
    add("lastSelectedSaved=%s", tostring(specID and C_ClassTalents.GetLastSelectedSavedConfigID(specID)))
    add("activeString=%s", Short(current))
    add("blockReason=%s", tostring(ns.Apply.BlockReason()))

    local name, instanceType, difficultyID, difficultyName, _, _, _, instanceID = GetInstanceInfo()
    add("instance: %s type=%s id=%s difficulty=%s (%s) delveInProgress=%s", tostring(name),
        tostring(instanceType), tostring(instanceID), tostring(difficultyID), tostring(difficultyName),
        tostring(C_PartyInfo.IsDelveInProgress and C_PartyInfo.IsDelveInProgress()))
    local ctx = ns.Reminder.GetContext()
    if ctx and specID then
        local mappedID, key = ns.Reminder.Resolve(ctx, specID)
        add("context: kind=%s keys=%s mapped=%s via %s", ctx.kind, table.concat(ctx.keys, " | "),
            tostring(mappedID), tostring(key))
    else
        add("context: none (not reminder content)")
    end
    local ev = ns.Reminder.lastEvaluation
    add("last reminder check: %s", ev and string.format("%s -> %s (%.0fs ago) [%s]", ev.trigger, ev.reason,
        GetTime() - ev.at, tostring(ev.snapshot)) or "none")
    local settings = {}
    for k, v in pairs(ns.Store.db.settings) do settings[#settings + 1] = k .. "=" .. tostring(v) end
    table.sort(settings)
    add("settings: %s", table.concat(settings, " "))

    add("")
    local list = ns.Sources.GetList(specID)
    ns.Sources.Annotate(list)
    add("-- list (%d)", #list)
    for i, e in ipairs(list) do
        add("%d. id=%s source=%s name=%q specID=%s configID=%s active=%s dupOf=%s tags={%s}", i, e.id,
            e.source, tostring(e.name), tostring(e.specID), tostring(e.configID), tostring(e.isActive),
            tostring(e.duplicateOf), table.concat(e.tags, ","))
        add("   string=%s stale=%s", Short(e.importStringResolved), tostring(e.staleReason))
    end

    add("")
    local maps = {}
    for key, m in pairs(ns.Store.GetMappings(specID)) do
        maps[#maps + 1] = string.format("   %s -> %s (%s)", key, m.entryID, tostring(m.label))
    end
    table.sort(maps)
    add("-- mappings for this spec (%d)", #maps)
    for _, line in ipairs(maps) do out[#out + 1] = line end

    add("")
    local r = ns.Apply.last
    if r then
        add("-- last apply: %s (%s) status=%s", tostring(r.entryName), tostring(r.entryID), tostring(r.status))
        add("   reason=%s loadResult=%s targets=%s took=%.2fs", tostring(r.reason), tostring(r.loadResult),
            tostring(r.targets), (r.finishedAt or 0) - (r.startedAt or 0))
        if r.unmet and #r.unmet > 0 then
            local ids = {}
            for _, nodeID in ipairs(r.unmet) do ids[#ids + 1] = tostring(nodeID) end
            add("   unmet nodeIDs: %s", table.concat(ids, ", "))
        end
    else
        add("-- last apply: none")
    end
    if ns.Apply.pending then add("-- apply PENDING for %s", tostring(ns.Apply.pending.result.entryName)) end
    return table.concat(out, "\n")
end

local frame
function Debug.Show()
    if not frame then
        frame = CreateFrame("Frame", "SquizzTalentsDebugFrame", UIParent, "BackdropTemplate")
        frame:SetSize(600, 380)
        frame:SetPoint("CENTER")
        frame:SetFrameStrata("DIALOG")
        frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1 })
        frame:SetBackdropColor(0, 0, 0, 0.92)
        frame:SetBackdropBorderColor(0.2, 0.8, 0.6, 0.8)
        frame:EnableMouse(true)
        frame:SetMovable(true)
        frame:RegisterForDrag("LeftButton")
        frame:SetScript("OnDragStart", frame.StartMoving)
        frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
        tinsert(UISpecialFrames, "SquizzTalentsDebugFrame")

        local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hint:SetPoint("TOPLEFT", 10, -8)
        hint:SetText(L["Ctrl+A, Ctrl+C to copy"])

        local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", 2, 2)

        local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 10, -28)
        scroll:SetPoint("BOTTOMRIGHT", -30, 10)

        local edit = CreateFrame("EditBox", nil, scroll)
        edit:SetMultiLine(true)
        edit:SetFontObject(ChatFontNormal)
        edit:SetWidth(550)
        edit:SetAutoFocus(false)
        edit:SetScript("OnEscapePressed", function() frame:Hide() end)
        scroll:SetScrollChild(edit)
        frame.edit = edit
    end
    frame.edit:SetText(Debug.BuildText())
    frame:Show()
    frame.edit:SetFocus()
    frame.edit:HighlightText()
end
