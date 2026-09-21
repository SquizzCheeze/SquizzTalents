-- Loadout window, reminder popup, right-click menus and dialogs. Plain,
-- non-secure frames of our own; nothing here touches Blizzard's talent UI.
local _, ns = ...
local L = ns.L

local UI = {}
ns.UI = UI

local ROW_HEIGHT = 26
local STATUS_COLORS = {
    success = "|cff33ff66", partial = "|cffffcc33", committing = "|cffcccccc",
    unconfirmed = "|cffffcc33", failed = "|cffff4444", blocked = "|cffff8844",
    error = "|cffff4444",
}
local S = ns.Style
local TOP = S.TITLE_HEIGHT + 6 -- first content line, below the title bar

local lastStatusLine = nil

-- ---------------------------------------------------------------------------
-- Shared pieces
-- ---------------------------------------------------------------------------
local function StyleWindow(f, title)
    S.Window(f, title)
end

local function MakeText(parent, template)
    local fs = parent:CreateFontString(nil, "OVERLAY", template)
    fs:SetJustifyH("LEFT")
    return fs
end

-- The dialog that owns a StaticPopup edit box (it can sit one level deeper).
local function DialogOf(editBox)
    local p = editBox:GetParent()
    if p and not p.which and p:GetParent() then p = p:GetParent() end
    return p
end

-- Labels of every mapping on specID that points at entryID.
local function MappingLabelsFor(specID, entryID)
    local out = {}
    for _, m in pairs(ns.Store.GetMappings(specID)) do
        if m.entryID == entryID then out[#out + 1] = m.label end
    end
    table.sort(out)
    return out
end

-- A list of loadout rows inside `container`. opts:
--   onClick(entry, button)   click handler
--   suggestedID              entry id to highlight as the suggestion
--   blockReason              greys rows out and explains why in the tooltip
--   hideDuplicates           skip own entries identical to a Blizzard one
local function CreateRowList(container)
    local list = { rows = {} }

    local function OnEnter(row)
        local e = row.entry
        if not e then return end
        GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
        GameTooltip:AddLine(e.name, 1, 1, 1)
        GameTooltip:AddLine(e.source == "blizz" and L["Blizzard loadout"] or L["Saved by SquizzTalents"])
        if e.duplicateName then
            GameTooltip:AddLine(string.format(L["Same build as \"%s\""], e.duplicateName), 0.7, 0.7, 0.7)
        end
        if e.staleReason then
            GameTooltip:AddLine(L["Outdated: "] .. e.staleReason, 1, 0.3, 0.3, true)
            GameTooltip:AddLine(L["Fix your talents, then right-click > Update to current talents."],
                0.7, 0.7, 0.7, true)
        end
        if #e.tags > 0 then
            GameTooltip:AddLine(L["Tags: "] .. table.concat(e.tags, ", "), 0.7, 0.7, 0.7, true)
        end
        local maps = MappingLabelsFor(e.specID, e.id)
        if #maps > 0 then
            GameTooltip:AddLine(L["Used for: "] .. table.concat(maps, ", "), 0.9, 0.8, 0.4, true)
        end
        if list.blockReason then
            GameTooltip:AddLine(list.blockReason, 1, 0.4, 0.3, true)
        else
            GameTooltip:AddLine(L["Click to apply"], 0.4, 1, 0.4)
        end
        if list.rightClickHint then GameTooltip:AddLine(list.rightClickHint, 0.7, 0.7, 0.7) end
        GameTooltip:Show()
    end

    local function GetRow(i)
        local row = list.rows[i]
        if row then return row end
        row = CreateFrame("Button", nil, container)
        row:SetHeight(ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
        row:SetPoint("RIGHT")
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row:SetScript("OnClick", function(self, button)
            if self.entry and list.onClick then list.onClick(self.entry, button, self) end
        end)
        row:SetScript("OnEnter", OnEnter)
        row:SetScript("OnLeave", GameTooltip_Hide)

        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        S.Highlight(row, 0.2)

        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(ROW_HEIGHT - 4, ROW_HEIGHT - 4)
        row.icon:SetPoint("LEFT", 2, 0)
        row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        row.tag = MakeText(row, "GameFontNormalSmall")
        row.tag:SetPoint("RIGHT", -6, 0)
        row.tag:SetJustifyH("RIGHT")

        row.name = MakeText(row, "GameFontHighlight")
        row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
        row.name:SetPoint("RIGHT", row.tag, "LEFT", -6, 0)
        row.name:SetWordWrap(false)

        list.rows[i] = row
        return row
    end

    -- Returns the number of rows shown.
    function list:Render(entries, opts)
        opts = opts or {}
        self.onClick = opts.onClick
        self.blockReason = opts.blockReason
        self.rightClickHint = opts.rightClickHint
        local n = 0
        for _, e in ipairs(entries) do
            -- Never hide the suggestion itself, even when it is a duplicate.
            local hidden = opts.hideDuplicates and e.duplicateOf and e.id ~= opts.suggestedID
            if not hidden then
                n = n + 1
                local row = GetRow(n)
                row.entry = e
                row.icon:SetTexture(e.icon or 134400)
                local name = e.name or "?"
                if e.duplicateName and not opts.hideDuplicates then
                    name = name .. " |cff888888(= " .. e.duplicateName .. ")|r"
                end
                row.name:SetText(name)

                local suggested = opts.suggestedID and e.id == opts.suggestedID
                if e.isActive then
                    local a = S.Accent()
                    row.tag:SetText(S.AccentCode() .. L["Active"] .. "|r")
                    row.bg:SetColorTexture(a.r, a.g, a.b, 0.18)
                elseif e.staleReason then
                    row.tag:SetText("|cffff4444" .. L["Outdated"] .. "|r")
                    row.bg:SetColorTexture(1, 0.2, 0.2, suggested and 0.18 or 0.08)
                elseif suggested then
                    row.tag:SetText("|cffffd100" .. L["Suggested"] .. "|r")
                    row.bg:SetColorTexture(1, 0.82, 0, 0.16)
                else
                    row.tag:SetText(e.source == "blizz" and ("|cff8888ff" .. L["Blizzard"] .. "|r")
                        or ("|cffaaaaaa" .. L["Saved"] .. "|r"))
                    row.bg:SetColorTexture(S.PANEL[1], S.PANEL[2], S.PANEL[3], 1)
                end
                local dim = opts.blockReason and 0.5 or 1
                row.name:SetTextColor(dim, dim, dim)
                row:Show()
            end
        end
        for i = n + 1, #self.rows do
            self.rows[i]:Hide()
            self.rows[i].entry = nil
        end
        return n
    end

    return list
end

-- ---------------------------------------------------------------------------
-- Dialogs
-- ---------------------------------------------------------------------------
function UI.SaveCurrent(name)
    name = strtrim(name or "")
    if name == "" then
        ns.Print(L["A name is required."])
        return
    end
    local id, err = ns.Sources.Own.SaveCurrent(name)
    if id then
        ns.Print(string.format(L["Saved \"%s\"."], name))
    else
        ns.Print(err)
    end
    UI.RefreshAll()
end

StaticPopupDialogs["SQUIZZTALENTS_SAVE"] = {
    text = L["Save the current build as:"],
    button1 = SAVE,
    button2 = CANCEL,
    hasEditBox = true,
    maxLetters = 48,
    OnAccept = function(dialog)
        UI.SaveCurrent(dialog:GetEditBox():GetText())
    end,
    EditBoxOnEnterPressed = function(editBox)
        UI.SaveCurrent(editBox:GetText())
        DialogOf(editBox):Hide()
    end,
    EditBoxOnEscapePressed = function(editBox) DialogOf(editBox):Hide() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["SQUIZZTALENTS_DELETE"] = {
    text = L["Delete the saved build \"%s\"?"],
    button1 = DELETE,
    button2 = CANCEL,
    OnAccept = function(_, entry)
        ns.Sources.Own.Delete(entry)
        UI.RefreshAll()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["SQUIZZTALENTS_DELETE_BLIZZ"] = {
    text = L["Delete the Blizzard loadout \"%s\"? This removes it from the talent window too."],
    button1 = DELETE,
    button2 = CANCEL,
    OnAccept = function(_, entry)
        local ok, err = ns.Sources.Blizz.Delete(entry)
        if ok then
            -- Blizzard's talent window only re-reads its loadout list on events
            -- received while it is OPEN (not on show), so a closed window keeps
            -- its stale list. Poking its frame from here would taint it.
            ns.Print(string.format(L["Deleted \"%s\". If Blizzard's talent window still lists it, /reload."],
                entry.name))
        else
            ns.Print(err)
        end
        UI.RefreshAll()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["SQUIZZTALENTS_UPDATE"] = {
    text = L["Overwrite \"%s\" with your current talents? Its name, icon, tags and content mappings are kept."],
    button1 = OKAY,
    button2 = CANCEL,
    OnAccept = function(_, entry)
        local ok, err = ns.Sources.Own.UpdateToCurrent(entry)
        ns.Print(ok and string.format(L["Updated \"%s\"."], entry.name) or err)
        UI.RefreshAll()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["SQUIZZTALENTS_DELETE_STALE"] = {
    text = L["Delete %d outdated saved build(s)?\n\n%s"],
    button1 = DELETE,
    button2 = CANCEL,
    OnAccept = function(_, entries)
        for _, e in ipairs(entries) do ns.Sources.Own.Delete(e) end
        ns.Print(string.format(L["Deleted %d outdated build(s)."], #entries))
        UI.RefreshAll()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

-- Generic one-line input. data = { initial, onAccept(text) }; the prompt is
-- passed as the popup's text argument.
StaticPopupDialogs["SQUIZZTALENTS_INPUT"] = {
    text = "%s",
    button1 = OKAY,
    button2 = CANCEL,
    hasEditBox = true,
    maxLetters = 200,
    OnShow = function(dialog, data)
        dialog:GetEditBox():SetText(data and data.initial or "")
        dialog:GetEditBox():HighlightText()
    end,
    OnAccept = function(dialog, data)
        data.onAccept(dialog:GetEditBox():GetText())
        UI.RefreshAll()
    end,
    EditBoxOnEnterPressed = function(editBox, data)
        data.onAccept(editBox:GetText())
        DialogOf(editBox):Hide()
        UI.RefreshAll()
    end,
    EditBoxOnEscapePressed = function(editBox) DialogOf(editBox):Hide() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

local function PromptInput(prompt, initial, onAccept)
    StaticPopup_Show("SQUIZZTALENTS_INPUT", prompt, nil, { initial = initial, onAccept = onAccept })
end

function UI.PromptSave()
    StaticPopup_Show("SQUIZZTALENTS_SAVE")
end

function UI.PromptTags(entry)
    PromptInput(string.format(L["Tags for \"%s\" (comma separated):"], entry.name),
        table.concat(entry.tags, ", "), function(text)
            ns.Sources.SetTags(entry, ns.Sources.ParseTags(text))
        end)
end

-- Searchable icon grid (IconPicker.lua). Spell and icon IDs still work there:
-- type the number into its search box.
function UI.PromptIcon(entry)
    ns.IconPicker.Open(entry)
end

function UI.PromptRename(entry)
    PromptInput(L["New name:"], entry.name, function(text)
        text = strtrim(text or "")
        if text ~= "" then ns.Sources.Rename(entry, text) end
    end)
end

-- ---------------------------------------------------------------------------
-- Right-click menu (both windows)
-- ---------------------------------------------------------------------------
local function OpenEntryMenu(owner, entry)
    local ctx = ns.Reminder.GetContext()
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(entry.name)
        root:CreateButton(L["Apply"], function() ns.Apply.Run(entry) end)
        if ctx then
            local mappings = ns.Store.GetMappings(entry.specID)
            local sub = root:CreateButton(L["Use for this content"])
            for _, key in ipairs(ctx.keys) do
                local label = ctx.labels[key]
                local mapped = mappings[key] and mappings[key].entryID == entry.id
                sub:CreateButton((mapped and "|cff33ff66* |r" or "") .. label, function()
                    if mapped then
                        ns.Store.SetMapping(entry.specID, key, nil)
                    else
                        ns.Store.SetMapping(entry.specID, key, entry.id, label)
                    end
                    UI.RefreshAll()
                end)
            end
        end
        root:CreateDivider()
        root:CreateButton(L["Export code..."], function() ns.Transfer.Export(entry) end)
        root:CreateButton(L["Edit tags..."], function() UI.PromptTags(entry) end)
        root:CreateButton(L["Set icon..."], function() UI.PromptIcon(entry) end)
        if entry.source == "own" then
            root:CreateButton(L["Update to current talents..."], function()
                StaticPopup_Show("SQUIZZTALENTS_UPDATE", entry.name, nil, entry)
            end)
            root:CreateButton(L["Rename..."], function() UI.PromptRename(entry) end)
            root:CreateButton(L["Delete..."], function()
                StaticPopup_Show("SQUIZZTALENTS_DELETE", entry.name, nil, entry)
            end)
        else
            root:CreateButton(L["Delete..."], function()
                StaticPopup_Show("SQUIZZTALENTS_DELETE_BLIZZ", entry.name, nil, entry)
            end)
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Main window
-- ---------------------------------------------------------------------------
local main -- the window, created on first use

local function CreateMain()
    main = CreateFrame("Frame", "SquizzTalentsFrame", UIParent, "BackdropTemplate")
    main:SetSize(320, 200)
    main:SetPoint("CENTER")
    StyleWindow(main, "SquizzTalents")
    main:Hide()
    tinsert(UISpecialFrames, "SquizzTalentsFrame") -- Escape closes it

    main.context = MakeText(main, "GameFontHighlightSmall")
    main.context:SetPoint("TOPLEFT", 10, -TOP)
    main.context:SetPoint("RIGHT", -10, 0)
    main.context:SetWordWrap(true)

    main.content = CreateFrame("Frame", nil, main)
    main.content:SetPoint("TOPLEFT", main.context, "BOTTOMLEFT", -2, -6)
    main.content:SetPoint("RIGHT", -8, 0)
    main.content:SetHeight(1)
    main.list = CreateRowList(main.content)

    main.block = MakeText(main, "GameFontNormalSmall")
    main.block:SetPoint("TOPLEFT", main.content, "BOTTOMLEFT", 2, -6)
    main.block:SetPoint("RIGHT", -8, 0)

    -- Only shown while some saved builds for this spec are outdated.
    main.cleanup = S.Button(main, "", 180, 22, "red")
    main.cleanup:SetPoint("TOPLEFT", main.content, "BOTTOMLEFT", 0, -4)
    main.cleanup:SetScript("OnClick", function(self)
        local stale = self.stale or {}
        if #stale == 0 then return end
        local names = {}
        for _, e in ipairs(stale) do names[#names + 1] = e.name end
        StaticPopup_Show("SQUIZZTALENTS_DELETE_STALE", #stale, table.concat(names, "\n"), stale)
    end)
    main.cleanup:Hide()

    main.save = S.Button(main, L["Save current build"], 140, 22)
    main.save:SetPoint("BOTTOMLEFT", 8, 8)
    main.save:SetScript("OnClick", UI.PromptSave)

    main.import = S.Button(main, L["Import"], 70, 22)
    main.import:SetPoint("LEFT", main.save, "RIGHT", 4, 0)
    main.import:SetScript("OnClick", function() ns.Transfer.ShowImport() end)

    main.settings = S.Button(main, L["Settings"], 80, 22)
    main.settings:SetPoint("BOTTOMRIGHT", -8, 8)
    main.settings:SetScript("OnClick", function() ns.Settings.Open() end)

    main.status = MakeText(main, "GameFontHighlightSmall")
    main.status:SetPoint("BOTTOMLEFT", main.save, "TOPLEFT", 0, 6)
    main.status:SetPoint("RIGHT", -8, 0)
    main.status:SetWordWrap(true)

    main:SetScript("OnShow", function() UI.RefreshAll() end)
end

local function RenderMain()
    if not main or not main:IsShown() then return end
    local specID = ns.Sources.GetCurrentSpecID()
    local entries = ns.Sources.GetList(specID)
    ns.Sources.Annotate(entries)
    local block = ns.Apply.BlockReason()

    local specName = specID and select(2, GetSpecializationInfoForSpecID(specID))
    main.title:SetText("SquizzTalents" .. (specName and ("  " .. S.AccentCode() .. specName .. "|r") or ""))

    local ctx = ns.Reminder.GetContext()
    local suggestedID
    if ctx and specID then
        suggestedID = ns.Reminder.Resolve(ctx, specID)
        main.context:SetText(string.format(L["In: %s"], ctx.labels[ctx.keys[1]])
            .. (suggestedID and "" or ("\n|cff999999" .. L["Right-click a build to use it here."] .. "|r")))
    else
        main.context:SetText("")
    end

    local n = main.list:Render(entries, {
        suggestedID = suggestedID,
        blockReason = block,
        rightClickHint = L["Right-click for options"],
        onClick = function(entry, button, row)
            if button == "RightButton" then
                OpenEntryMenu(row, entry)
            else
                ns.Apply.Run(entry)
                UI.RefreshAll()
            end
        end,
    })

    local contentHeight = math.max(n, 1) * ROW_HEIGHT
    main.content:SetHeight(contentHeight)

    local stale = {}
    for _, e in ipairs(entries) do
        if e.staleReason then stale[#stale + 1] = e end
    end
    main.cleanup.stale = stale
    main.cleanup:SetShown(#stale > 0)
    main.cleanup:SetText(string.format(L["Delete outdated (%d)..."], #stale))
    main.block:ClearAllPoints()
    main.block:SetPoint("TOPLEFT", #stale > 0 and main.cleanup or main.content, "BOTTOMLEFT", 2, -6)
    main.block:SetPoint("RIGHT", -8, 0)
    local cleanupHeight = #stale > 0 and 28 or 0

    if n == 0 then
        main.block:SetText(specID and L["No loadouts for this spec yet."] or L["No specialization selected"])
        main.block:SetTextColor(0.7, 0.7, 0.7)
    else
        main.block:SetText(block and (L["Cannot apply: "] .. block) or "")
        main.block:SetTextColor(1, 0.5, 0.3)
    end
    main.save:SetEnabled(specID ~= nil and not InCombatLockdown())
    main.status:SetText(lastStatusLine or "")

    local contextHeight = main.context:GetText() ~= "" and (main.context:GetStringHeight() + 6) or 0
    local extra = (main.block:GetText() ~= "" and 18 or 0) + (lastStatusLine and 30 or 0)
    main:SetHeight(TOP + 4 + contextHeight + contentHeight + cleanupHeight + extra + 44)
end

function UI.Toggle()
    if not main then CreateMain() end
    main:SetShown(not main:IsShown())
end

-- ---------------------------------------------------------------------------
-- Reminder popup
-- ---------------------------------------------------------------------------
local popup

local function CreatePopup()
    popup = CreateFrame("Frame", "SquizzTalentsReminderFrame", UIParent, "BackdropTemplate")
    popup:SetSize(400, 200)
    popup:SetPoint("TOP", 0, -140)
    StyleWindow(popup)
    popup:Hide()
    popup.closeButton:SetScript("OnClick", function() UI.DismissReminder() end)

    popup.sub = MakeText(popup, "GameFontHighlightSmall")
    popup.sub:SetPoint("TOPLEFT", 10, -TOP)
    popup.sub:SetPoint("RIGHT", -10, 0)
    popup.sub:SetWordWrap(true)

    popup.content = CreateFrame("Frame", nil, popup)
    popup.content:SetPoint("TOPLEFT", popup.sub, "BOTTOMLEFT", -2, -8)
    popup.content:SetPoint("RIGHT", -8, 0)
    popup.content:SetHeight(1)
    popup.list = CreateRowList(popup.content)

    popup.block = MakeText(popup, "GameFontNormalSmall")
    popup.block:SetPoint("TOPLEFT", popup.content, "BOTTOMLEFT", 2, -6)
    popup.block:SetPoint("RIGHT", -8, 0)
    popup.block:SetTextColor(1, 0.5, 0.3)

    popup.later = S.Button(popup, L["Not now"], 80, 22)
    popup.later:SetPoint("BOTTOMRIGHT", -8, 8)
    popup.later:SetScript("OnClick", function() UI.DismissReminder() end)

    -- "Remember for" dropdown: which mapping a click on a build saves. A radio
    -- list, so the selected option is always visible; each option names the
    -- build it currently points at, so what is saved is never a guess.
    popup.rememberLabel = MakeText(popup, "GameFontNormalSmall")
    popup.rememberLabel:SetPoint("BOTTOMLEFT", 10, 14)
    popup.rememberLabel:SetText(L["Remember for:"])

    popup.remember = CreateFrame("DropdownButton", nil, popup, "WowStyle1DropdownTemplate")
    popup.remember:SetPoint("LEFT", popup.rememberLabel, "RIGHT", 6, 0)
    popup.remember:SetPoint("RIGHT", popup.later, "LEFT", -6, 0)
    popup.remember:SetupMenu(function(_, root)
        local data = popup.data
        if not data then return end
        local ctx = data.ctx
        local mappings = ns.Store.GetMappings(data.specID)
        local names = {}
        for _, e in ipairs(data.list) do names[e.id] = e.name end

        local function IsSelected(index) return popup.rememberIndex == index end
        local function SetSelected(index)
            popup.rememberIndex = index
            UI.RenderReminder()
        end

        root:CreateRadio(L["Don't remember (just apply)"], IsSelected, SetSelected, 0)
        for index, key in ipairs(ctx.keys) do
            local label = ctx.labels[key]
            local m = mappings[key]
            if m then
                label = label .. "  |cff999999(" .. (names[m.entryID] or L["missing build"]) .. ")|r"
            end
            root:CreateRadio(label, IsSelected, SetSelected, index)
        end
    end)
    popup.remember:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(L["Clicking a build saves it for the content picked here."], 1, 1, 1, true)
        GameTooltip:AddLine(L["Grey text is the build each option points at now."], 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    popup.remember:SetScript("OnLeave", GameTooltip_Hide)

    popup.status = MakeText(popup, "GameFontHighlightSmall")
    popup.status:SetPoint("BOTTOMLEFT", 10, 38)
    popup.status:SetPoint("RIGHT", -8, 0)
end

function UI.RenderReminder()
    if not popup or not popup:IsShown() or not popup.data then return end
    local data = popup.data
    local ctx = data.ctx
    ns.Sources.Annotate(data.list)
    local block = ns.Apply.BlockReason()

    popup.title:SetText(S.AccentCode() .. L["Talents:"] .. "|r " .. ctx.labels[ctx.keys[1]])
    if data.suggestion then
        popup.sub:SetText(string.format(L["Your build for this content is \"%s\", but it isn't active."],
            data.suggestion.name))
    else
        popup.sub:SetText(L["No build chosen for this content yet. Pick one:"])
    end

    local n = popup.list:Render(data.list, {
        suggestedID = data.suggestion and data.suggestion.id,
        blockReason = block,
        hideDuplicates = true,
        onClick = function(entry, button, row)
            if button == "RightButton" then
                OpenEntryMenu(row, entry)
                return
            end
            if ns.Apply.BlockReason() then return end
            local key = ctx.keys[popup.rememberIndex]
            if key then ns.Store.SetMapping(data.specID, key, entry.id, ctx.labels[key]) end
            popup.applyingID = entry.id
            ns.Apply.Run(entry)
            UI.RefreshAll()
        end,
    })

    -- Rebuild so the selection text and the "(points at)" names are current.
    popup.remember:GenerateMenu()
    popup.block:SetText(block and (L["Cannot apply: "] .. block) or "")
    popup.status:SetText(popup.statusLine or "")

    local contentHeight = math.max(n, 1) * ROW_HEIGHT
    popup.content:SetHeight(contentHeight)
    local extra = (block and 18 or 0) + (popup.statusLine and 20 or 0)
    popup:SetHeight(TOP + popup.sub:GetStringHeight() + 12 + contentHeight + extra + 44)
end

function UI.ShowReminder(data)
    if not popup then CreatePopup() end
    popup.data = data
    popup.statusLine = nil
    popup.applyingID = nil
    -- Open on what is actually saved: the mapping that produced the suggestion.
    -- Unmapped: "this instance, any difficulty", the most common intent.
    popup.rememberIndex = 2
    if data.mappedKey then
        for index, key in ipairs(data.ctx.keys) do
            if key == data.mappedKey then popup.rememberIndex = index end
        end
    end
    popup:Show()
    UI.RenderReminder()
end

function UI.HideReminder()
    if popup then popup:Hide() end
end

function UI.DismissReminder()
    if popup and popup.data then ns.Reminder.Dismiss(popup.data.ctx) end
    UI.HideReminder()
end

-- ---------------------------------------------------------------------------
-- Refresh + apply results
-- ---------------------------------------------------------------------------
local refreshQueued = false
function UI.RefreshAll()
    if refreshQueued then return end
    refreshQueued = true
    C_Timer.After(0, function()
        refreshQueued = false
        RenderMain()
        UI.RenderReminder()
    end)
end
UI.Refresh = UI.RefreshAll

function UI.OnApplyFinished(result)
    local color = STATUS_COLORS[result.status] or ""
    lastStatusLine = string.format("%s%s|r  %s%s", color, result.status,
        result.entryName or "?", result.reason and (": " .. result.reason) or "")
    if result.status ~= "success" then ns.Print(lastStatusLine) end

    if popup and popup:IsShown() and popup.applyingID == result.entryID then
        popup.applyingID = nil
        if result.status == "success" then
            popup:Hide()
        else
            popup.statusLine = lastStatusLine
        end
    end
    UI.RefreshAll()
end

for _, event in ipairs({
    "TRAIT_CONFIG_UPDATED", "TRAIT_CONFIG_LIST_UPDATED", "TRAIT_CONFIG_DELETED",
    "ACTIVE_PLAYER_SPECIALIZATION_CHANGED",
    "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "CHALLENGE_MODE_START",
    "CHALLENGE_MODE_COMPLETED", "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA",
}) do
    ns.On(event, UI.RefreshAll)
end
