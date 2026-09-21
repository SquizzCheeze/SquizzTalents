-- Icon picker: a searchable grid instead of typing a spell or icon ID.
--
-- The game does not expose icon NAMES, so search works on what does have one:
--   Talents & spells   every talent of your class and your spellbook, by spell name
--   Specs & Mythic+    your specs and this season's M+ dungeons (read live, so no
--                      per-season list to maintain)
--   Every icon         the full macro icon catalogue (GetMacroIcons & co., the
--                      same lists Blizzard's macro icon picker uses). Searchable by
--                      number; entries the client returns as file names are
--                      searchable by that name too.
-- A number in the search box also matches a spell ID (its icon) or an icon ID.
local _, ns = ...
local L = ns.L

local Picker = {}
ns.IconPicker = Picker

local COLS, ROWS, SIZE, GAP = 10, 7, 36, 4

local CATEGORIES = {
    { key = "all", label = L["All"] },
    { key = "spells", label = L["Talents & spells"] },
    { key = "content", label = L["Specs & Mythic+"] },
    { key = "catalogue", label = L["Every icon"] },
}

-- ---------------------------------------------------------------------------
-- Data, built on first open and cached for the session (the catalogue is
-- tens of thousands of entries; talents/spells are rebuilt on spec change).
-- Each item: { icon = fileID|path, name = string?, lname = lowercase name }
-- ---------------------------------------------------------------------------
local named = { spells = nil, content = nil }
local catalogue

local function AddNamed(list, seen, icon, name)
    if not icon or not name or seen[icon] then return end
    seen[icon] = true
    list[#list + 1] = { icon = icon, name = name, lname = name:lower() }
end

local function BuildSpells()
    local list, seen = {}, {}
    local configID = C_ClassTalents.GetActiveConfigID()
    local info = configID and C_Traits.GetConfigInfo(configID)
    local treeID = info and info.treeIDs and info.treeIDs[1]
    if treeID then
        for _, nodeID in ipairs(C_Traits.GetTreeNodes(treeID) or {}) do
            local node = C_Traits.GetNodeInfo(configID, nodeID)
            for _, entryID in ipairs(node and node.entryIDs or {}) do
                local entry = C_Traits.GetEntryInfo(configID, entryID)
                local def = entry and entry.definitionID and C_Traits.GetDefinitionInfo(entry.definitionID)
                if def then
                    local spellID = def.spellID
                    local icon = def.overrideIcon or (spellID and C_Spell.GetSpellTexture(spellID))
                    local name = def.overrideName or (spellID and C_Spell.GetSpellName(spellID))
                    AddNamed(list, seen, icon, name)
                end
            end
        end
    end
    for line = 1, C_SpellBook.GetNumSpellBookSkillLines() do
        local lineInfo = C_SpellBook.GetSpellBookSkillLineInfo(line)
        if lineInfo then
            for i = 1, lineInfo.numSpellBookItems do
                local item = C_SpellBook.GetSpellBookItemInfo(lineInfo.itemIndexOffset + i,
                    Enum.SpellBookSpellBank.Player)
                if item then AddNamed(list, seen, item.iconID, item.name) end
            end
        end
    end
    table.sort(list, function(a, b) return a.lname < b.lname end)
    return list
end

local function BuildContent()
    local list, seen = {}, {}
    for _, spec in ipairs(ns.Sources.GetPlayerSpecs()) do
        AddNamed(list, seen, spec.icon, spec.name)
    end
    for _, mapID in ipairs(C_ChallengeMode.GetMapTable() or {}) do
        local name, _, _, texture = C_ChallengeMode.GetMapUIInfo(mapID)
        AddNamed(list, seen, texture, name)
    end
    AddNamed(list, seen, 134400, L["Question mark"])
    return list
end

-- Mirrors IconDataProvider_RefreshIconTextures: loose lists first, then the
-- macro lists. An entry is a fileID, or a file name under Interface\Icons.
local function BuildCatalogue()
    local raw = {}
    GetLooseMacroIcons(raw)
    GetLooseMacroItemIcons(raw)
    GetMacroIcons(raw)
    GetMacroItemIcons(raw)
    local list, seen = {}, {}
    for _, v in ipairs(raw) do
        local id = tonumber(v)
        local icon = id or ("Interface\\Icons\\" .. v)
        if not seen[icon] then
            seen[icon] = true
            local fileName = (not id) and tostring(v) or nil
            list[#list + 1] = { icon = icon, name = fileName, lname = fileName and fileName:lower() }
        end
    end
    return list
end

local function Data(key)
    if key == "catalogue" then
        catalogue = catalogue or BuildCatalogue()
        return catalogue
    end
    if not named[key] then named[key] = key == "spells" and BuildSpells() or BuildContent() end
    return named[key]
end

ns.On("ACTIVE_PLAYER_SPECIALIZATION_CHANGED", function() named.spells, named.content = nil, nil end)

-- Items for a category and search text.
local function Filter(category, text)
    text = strtrim(text or ""):lower()
    local out = {}
    local number = tonumber(text)
    local sources = category == "all" and { "spells", "content", "catalogue" } or { category }

    if number then
        -- A spell ID resolves to that spell's icon; any number may be an icon ID.
        local spellIcon = C_Spell.GetSpellTexture(number)
        if spellIcon then
            out[#out + 1] = { icon = spellIcon, name = (C_Spell.GetSpellName(number) or "?")
                .. " (" .. L["spell"] .. " " .. number .. ")" }
        end
        out[#out + 1] = { icon = number, name = L["Icon ID"] .. " " .. number }
        return out
    end

    local seen = {}
    for _, key in ipairs(sources) do
        for _, item in ipairs(Data(key)) do
            if not seen[item.icon] then
                local match = text == "" or (item.lname and item.lname:find(text, 1, true))
                if match then
                    seen[item.icon] = true
                    out[#out + 1] = item
                end
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------------------
local frame

local function Render()
    local items = frame.items
    local maxOffset = math.max(0, math.ceil(#items / COLS) - ROWS)
    frame.offset = math.max(0, math.min(frame.offset, maxOffset))
    local first = frame.offset * COLS
    for i, button in ipairs(frame.buttons) do
        local item = items[first + i]
        button.item = item
        if item then
            button.texture:SetTexture(item.icon)
            button.selected:SetShown(item.icon == frame.current)
            button:Show()
        else
            button:Hide()
        end
    end
    if #items == 0 then
        frame.count:SetText(L["No icons match."])
    else
        frame.count:SetText(string.format(L["%d-%d of %d  (mouse wheel to scroll)"], first + 1,
            math.min(first + COLS * ROWS, #items), #items))
    end
end

local function Refilter()
    frame.items = Filter(frame.category, frame.search:GetText())
    frame.offset = 0
    Render()
end

local function Choose(icon)
    if frame.entry then
        ns.Sources.SetIcon(frame.entry, icon)
        ns.UI.RefreshAll()
    end
    frame:Hide()
end

local function Build()
    frame = CreateFrame("Frame", "SquizzTalentsIconPicker", UIParent, "BackdropTemplate")
    local gridW = COLS * SIZE + (COLS - 1) * GAP
    local gridH = ROWS * SIZE + (ROWS - 1) * GAP
    local S = ns.Style
    frame:SetSize(gridW + 24, gridH + 128)
    frame:SetPoint("CENTER", 0, 40)
    S.Window(frame)
    frame:SetToplevel(true)
    frame:Hide()
    tinsert(UISpecialFrames, "SquizzTalentsIconPicker")

    frame.search = S.EditBox(frame, gridW - 158, 22)
    frame.search:SetPoint("TOPLEFT", 12, -(S.TITLE_HEIGHT + 8))
    frame.search:SetScript("OnTextChanged", function(self)
        self.placeholder:SetShown(self:GetText() == "")
        Refilter()
    end)
    frame.search.placeholder = frame.search:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.search.placeholder:SetPoint("LEFT", 7, 0)
    frame.search.placeholder:SetText(L["Search: spell name, spell ID or icon ID"])

    frame.categoryDrop = CreateFrame("DropdownButton", nil, frame, "WowStyle1DropdownTemplate")
    frame.categoryDrop:SetWidth(150)
    frame.categoryDrop:SetPoint("LEFT", frame.search, "RIGHT", 8, 0)
    frame.categoryDrop:SetupMenu(function(_, root)
        for _, c in ipairs(CATEGORIES) do
            root:CreateRadio(c.label, function() return frame.category == c.key end, function()
                frame.category = c.key
                Refilter()
            end)
        end
    end)

    frame.grid = CreateFrame("Frame", nil, frame)
    frame.grid:SetSize(gridW, gridH)
    frame.grid:SetPoint("TOPLEFT", 12, -(S.TITLE_HEIGHT + 40))
    frame.grid:EnableMouseWheel(true)
    frame.grid:SetScript("OnMouseWheel", function(_, delta)
        frame.offset = frame.offset - delta
        Render()
    end)

    frame.buttons = {}
    for i = 1, COLS * ROWS do
        local b = CreateFrame("Button", nil, frame.grid)
        b:SetSize(SIZE, SIZE)
        local col, row = (i - 1) % COLS, math.floor((i - 1) / COLS)
        b:SetPoint("TOPLEFT", col * (SIZE + GAP), -row * (SIZE + GAP))
        b.texture = b:CreateTexture(nil, "ARTWORK")
        b.texture:SetAllPoints()
        b.texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        b.selected = b:CreateTexture(nil, "OVERLAY")
        b.selected:SetPoint("TOPLEFT", -2, 2)
        b.selected:SetPoint("BOTTOMRIGHT", 2, -2)
        local a = S.Accent()
        b.selected:SetColorTexture(a.r, a.g, a.b, 0.55)
        S.Highlight(b, 0.35)
        -- Mouse wheel over a button should still scroll the grid.
        b:EnableMouseWheel(true)
        b:SetScript("OnMouseWheel", function(_, delta)
            frame.offset = frame.offset - delta
            Render()
        end)
        b:SetScript("OnClick", function(self) if self.item then Choose(self.item.icon) end end)
        b:SetScript("OnEnter", function(self)
            local item = self.item
            if not item then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(item.name or L["Icon"], 1, 1, 1)
            if type(item.icon) == "number" then
                GameTooltip:AddLine(L["Icon ID"] .. " " .. item.icon, 0.7, 0.7, 0.7)
            end
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", GameTooltip_Hide)
        frame.buttons[i] = b
    end

    frame.count = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.count:SetPoint("TOPLEFT", frame.grid, "BOTTOMLEFT", 0, -8)

    local reset = S.Button(frame, L["Use default icon"], 140, 22)
    reset:SetPoint("BOTTOMLEFT", 12, 12)
    reset:SetScript("OnClick", function() Choose(nil) end)

    local cancel = S.Button(frame, CANCEL, 90, 22)
    cancel:SetPoint("BOTTOMRIGHT", -12, 12)
    cancel:SetScript("OnClick", function() frame:Hide() end)
end

-- Open the picker for `entry`; clicking an icon sets it.
function Picker.Open(entry)
    if not frame then Build() end
    frame.entry = entry
    frame.current = entry.icon
    frame.title:SetText(string.format(L["Icon for \"%s\""], entry.name or "?"))
    frame.category = frame.category or "all"
    frame.search:SetText("")
    frame:Show()
    frame:Raise()
    frame.categoryDrop:GenerateMenu()
    Refilter()
end
