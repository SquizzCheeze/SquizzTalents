-- Settings panel (Esc > Options > AddOns > SquizzTalents): reminder toggles
-- and the content mappings for the current spec, with a remove button each.
-- Built as a canvas category because a mapping list is not a stock control.
local _, ns = ...
local L = ns.L

local SettingsPanel = {}
ns.Settings = SettingsPanel

local TOGGLES = {
    { key = "remindOnEnter", label = L["Remind when entering a dungeon, raid, delve or PvP instance"] },
    { key = "remindOnKeystone", label = L["Remind when a keystone is slotted"] },
    { key = "remindOnReadyCheck", label = L["Remind on ready check"] },
    { key = "remindUnmapped", label = L["Also remind in content that has no build chosen yet"] },
    { key = "attachToTalents", label = L["Open the loadout window beside Blizzard's talent window"],
        apply = function(on) ns.UI.SetAttachToTalents(on) end },
}

local panel, category, checkboxes, mappingRows = nil, nil, {}, {}

local function RenderMappings()
    if not panel then return end
    local specID = ns.Sources.GetCurrentSpecID()
    local specName = specID and select(2, GetSpecializationInfoForSpecID(specID)) or "?"
    panel.mapTitle:SetText(string.format(L["Content mappings (%s)"], specName))

    local names = {}
    for _, e in ipairs(ns.Sources.GetList(specID)) do names[e.id] = e.name end

    local items = {}
    for key, m in pairs(ns.Store.GetMappings(specID)) do
        items[#items + 1] = { key = key, label = m.label or key, entryID = m.entryID }
    end
    table.sort(items, function(a, b) return a.label < b.label end)

    for i, item in ipairs(items) do
        local row = mappingRows[i]
        if not row then
            row = CreateFrame("Frame", nil, panel)
            row:SetSize(560, 24)
            row:SetPoint("TOPLEFT", panel.mapTitle, "BOTTOMLEFT", 0, -6 - (i - 1) * 24)
            row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            row.text:SetPoint("LEFT")
            row.text:SetPoint("RIGHT", -90, 0)
            row.text:SetJustifyH("LEFT")
            row.text:SetWordWrap(false)
            row.remove = ns.Style.Button(row, REMOVE, 80, 20, "red")
            row.remove:SetPoint("RIGHT")
            mappingRows[i] = row
        end
        local target = names[item.entryID] or ("|cffff6666" .. L["missing build"] .. "|r")
        row.text:SetText(item.label .. "  |cff999999->|r  " .. target)
        row.remove:SetScript("OnClick", function()
            ns.Store.SetMapping(specID, item.key, nil)
            RenderMappings()
            ns.UI.RefreshAll()
        end)
        row:Show()
    end
    for i = #items + 1, #mappingRows do mappingRows[i]:Hide() end
    panel.mapEmpty:SetShown(#items == 0)
end

local function Build()
    panel = CreateFrame("Frame")
    panel:Hide()

    local S = ns.Style
    local title = panel:CreateFontString(nil, "OVERLAY")
    S.Font(title, 20)
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Squizz" .. S.AccentCode() .. "Talents|r")

    local prev = title
    for i, t in ipairs(TOGGLES) do
        local cb = S.Toggle(panel, t.label, function(on)
            if t.apply then t.apply(on) else ns.Store.SetSetting(t.key, on) end
        end)
        cb:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, i == 1 and -16 or -10)
        checkboxes[t.key] = cb
        prev = cb
    end

    local open = S.Button(panel, L["Open loadout window"], 180, 22)
    open:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -16)
    open:SetScript("OnClick", function() ns.UI.Toggle() end)

    panel.mapTitle = panel:CreateFontString(nil, "OVERLAY")
    S.Font(panel.mapTitle, 14, S.Accent().r, S.Accent().g, S.Accent().b)
    panel.mapTitle:SetPoint("TOPLEFT", open, "BOTTOMLEFT", 0, -24)

    local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("LEFT", panel.mapTitle, "RIGHT", 12, 0)
    hint:SetText(L["Add mappings from the reminder popup or by right-clicking a build."])
    hint:SetTextColor(0.7, 0.7, 0.7)

    panel.mapEmpty = panel:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    panel.mapEmpty:SetPoint("TOPLEFT", panel.mapTitle, "BOTTOMLEFT", 0, -8)
    panel.mapEmpty:SetText(L["No mappings yet."])

    panel:SetScript("OnShow", function()
        for key, cb in pairs(checkboxes) do cb:SetChecked(ns.Store.Setting(key) and true or false) end
        RenderMappings()
    end)

    category = Settings.RegisterCanvasLayoutCategory(panel, "SquizzTalents")
    Settings.RegisterAddOnCategory(category)
end

function SettingsPanel.Open()
    if not category then return end
    if InCombatLockdown() then
        ns.Print(L["Settings can't be opened in combat."])
        return
    end
    Settings.OpenToCategory(category:GetID())
end

ns.On("ADDON_LOADED", function(name)
    if name == ns.ADDON_NAME then Build() end
end)
