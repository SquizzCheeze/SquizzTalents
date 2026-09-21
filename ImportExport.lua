-- Import and export using Blizzard's own talent import codes -- the same
-- strings the talent window's Import/Export and sites like Wowhead use.
--
--   Import to SquizzTalents   stored as an own build, for any spec of your class
--   Import to Blizzard        a new Blizzard loadout via C_ClassTalents.ImportLoadout,
--                             the call Blizzard's import dialog makes; current spec only
--   Export                    any build's code, ready to copy
local _, ns = ...
local L = ns.L

local Transfer = {}
ns.Transfer = Transfer


-- ---------------------------------------------------------------------------
-- Parsing / validation
-- ---------------------------------------------------------------------------

-- Validate a pasted code. Returns info or nil + reason:
--   { text, specID, specName, treeID, content, isCurrentSpec, duplicateName }
function Transfer.Parse(raw)
    local text = (raw or ""):gsub("%s+", "")
    if text == "" then return nil, nil end
    -- Blizzard's base64 decoder does no validation: a stray character becomes a
    -- nil that throws further down. Refuse anything outside the alphabet first.
    if text:find("[^%w%+/]") then return nil, L["That is not a talent import code."] end

    local ok, version, specID, hash, content, treeID
    ok = pcall(function()
        local stream = ExportUtil.MakeImportDataStream(text)
        version, specID, hash = ns.Apply.ReadHeader(stream)
        if not version then return end
        treeID = C_ClassTalents.GetTraitTreeForSpec(specID)
        if treeID then
            content = ns.Apply.ReadContent(stream, C_Traits.GetTreeNodes(treeID))
        end
    end)
    if not ok or not version then return nil, L["That code is damaged or incomplete."] end
    if version ~= C_Traits.GetLoadoutSerializationVersion() then
        return nil, L["That code uses an older talent format. Export it again from the game."]
    end

    local mine = false
    for _, spec in ipairs(ns.Sources.GetPlayerSpecs()) do
        if spec.specID == specID then mine = true end
    end
    local specName = select(2, GetSpecializationInfoForSpecID(specID))
    if not mine then
        return nil, string.format(L["That build is for %s, which is not your class."], specName or "?")
    end
    if not treeID or not content then return nil, L["That code is damaged or incomplete."] end
    if not ns.Apply.HashIsEmpty(hash) and not ns.Apply.HashEquals(hash, C_Traits.GetTreeHash(treeID)) then
        return nil, L["That code was made for an older version of the talent tree."]
    end

    local info = {
        text = text,
        specID = specID,
        specName = specName,
        treeID = treeID,
        content = content,
        isCurrentSpec = specID == ns.Sources.GetCurrentSpecID(),
    }
    for _, e in ipairs(ns.Sources.Own.List(specID)) do
        if e.importString == text then info.duplicateName = e.name end
    end
    return info
end

-- ---------------------------------------------------------------------------
-- Import targets
-- ---------------------------------------------------------------------------
function Transfer.ImportToOwn(info, name)
    local ownID = ns.Store.AddOwn({ name = name, specID = info.specID, importString = info.text })
    return "own:" .. ownID
end

-- Why a Blizzard loadout cannot be created from info right now, or nil.
function Transfer.BlizzardBlockReason(info)
    if InCombatLockdown() then return L["In combat"] end
    if not info.isCurrentSpec then
        return string.format(L["Blizzard loadouts can only be created for your current spec (%s)."],
            info.specName or "?")
    end
    if not C_ClassTalents.CanCreateNewConfig() then
        return L["Blizzard's loadout limit is reached. Save it to SquizzTalents instead."]
    end
    if not C_ClassTalents.GetActiveConfigID() then return L["No active talent config (below level 10?)"] end
    return nil
end

-- Mirrors ClassTalentImportExportMixin:ConvertToImportLoadoutEntryInfo and its
-- two helpers exactly, since C_ClassTalents.ImportLoadout wants that shape.
local function ToImportEntries(configID, treeID, content)
    local results = {}
    for index, nodeID in ipairs(C_Traits.GetTreeNodes(treeID)) do
        local r = content[index]
        local node = C_Traits.GetNodeInfo(configID, nodeID)
        if node and r and r.selected then
            local granted = not r.purchased
            if node.type == Enum.TraitNodeType.Tiered then
                local remaining = granted and 0 or (r.partialRanks or node.maxRanks)
                for i, entryID in ipairs(node.entryIDs) do
                    local entryInfo = C_Traits.GetEntryInfo(configID, entryID)
                    if entryInfo then
                        local ranks = math.min(remaining, entryInfo.maxRanks)
                        local isGranted = granted and i == 1
                        if ranks > 0 or isGranted then
                            results[#results + 1] = {
                                nodeID = nodeID,
                                ranksGranted = isGranted and 1 or 0,
                                ranksPurchased = ranks,
                                selectionEntryID = entryID,
                            }
                        end
                        remaining = remaining - ranks
                    end
                end
            else
                local entryID
                if r.choiceIndex then
                    entryID = node.entryIDs[r.choiceIndex]
                elseif node.activeEntry then
                    entryID = node.activeEntry.entryID
                end
                entryID = entryID or node.entryIDs[1]
                if entryID then
                    results[#results + 1] = {
                        nodeID = nodeID,
                        ranksGranted = granted and 1 or 0,
                        ranksPurchased = granted and 0 or (r.partialRanks or node.maxRanks),
                        selectionEntryID = entryID,
                    }
                end
            end
        end
    end
    return results
end

function Transfer.ImportToBlizzard(info, name)
    local block = Transfer.BlizzardBlockReason(info)
    if block then return nil, block end
    local configID = C_ClassTalents.GetActiveConfigID()
    local entries = ToImportEntries(configID, info.treeID, info.content)
    local ok, success, importError = pcall(C_ClassTalents.ImportLoadout, configID, entries, name, info.text)
    if not ok then return nil, tostring(success) end
    if not success then
        return nil, (ns.IsPlain(importError) and importError ~= "") and importError
            or L["The game refused to create the loadout"]
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Export
-- ---------------------------------------------------------------------------
function Transfer.GetExportString(entry)
    if entry.source == "own" then return entry.importString end
    local str = ns.Sources.Blizz.GetImportString(entry)
    if str then return str end
    -- Fallback: a Blizzard loadout that is active exports as the active build.
    if entry.isActive then return ns.Sources.GetActiveImportString() end
    return nil, L["Could not export this loadout. Apply it first, then export."]
end

StaticPopupDialogs["SQUIZZTALENTS_EXPORT"] = {
    text = L["Talent code for \"%s\" -- Ctrl+C to copy:"],
    button1 = CLOSE,
    hasEditBox = true,
    editBoxWidth = 360,
    maxLetters = 4000,
    OnShow = function(dialog, code)
        local box = dialog:GetEditBox()
        box:SetText(code or "")
        box:SetFocus()
        box:HighlightText()
    end,
    -- Keep the code intact if a stray key lands in the box.
    EditBoxOnTextChanged = function(editBox, code)
        if editBox:GetText() ~= code then
            editBox:SetText(code or "")
            editBox:HighlightText()
        end
    end,
    EditBoxOnEnterPressed = function(editBox)
        local p = editBox:GetParent()
        if p and not p.which then p = p:GetParent() end
        p:Hide()
    end,
    EditBoxOnEscapePressed = function(editBox)
        local p = editBox:GetParent()
        if p and not p.which then p = p:GetParent() end
        p:Hide()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

function Transfer.Export(entry)
    local code, err = Transfer.GetExportString(entry)
    if not code then
        ns.Print(err)
        return
    end
    StaticPopup_Show("SQUIZZTALENTS_EXPORT", entry.name, nil, code)
end

-- ---------------------------------------------------------------------------
-- Import dialog
-- ---------------------------------------------------------------------------
local dialog

local function SetButtonState(button, enabled, reason)
    button:SetEnabled(enabled)
    button.disabledReason = (not enabled) and reason or nil
end

local function ButtonTooltip(button)
    if not button.disabledReason then return end
    GameTooltip:SetOwner(button, "ANCHOR_TOP")
    GameTooltip:AddLine(button.disabledReason, 1, 0.5, 0.3, true)
    GameTooltip:Show()
end

local function Validate()
    local info, err = Transfer.Parse(dialog.code:GetText())
    dialog.info = info
    if not info then
        dialog.status:SetText(err and ("|cffff5555" .. err .. "|r") or ("|cff999999"
            .. L["Paste a code from the talent window's Export, or from a build site."] .. "|r"))
        SetButtonState(dialog.toOwn, false, err)
        SetButtonState(dialog.toBlizz, false, err)
        return
    end
    local line = "|cff33ff66" .. string.format(L["Valid %s build."], info.specName or "?") .. "|r"
    if not info.isCurrentSpec then
        line = line .. " |cffffcc33" .. L["(not your current spec: it will be listed when you switch)"] .. "|r"
    end
    if info.duplicateName then
        line = line .. "\n|cffffcc33" .. string.format(L["You already saved this build as \"%s\"."],
            info.duplicateName) .. "|r"
    end
    dialog.status:SetText(line)
    SetButtonState(dialog.toOwn, true)
    local block = Transfer.BlizzardBlockReason(info)
    SetButtonState(dialog.toBlizz, block == nil, block)
end

local function NameOrDefault()
    local name = strtrim(dialog.name:GetText() or "")
    if name ~= "" then return name end
    return string.format(L["Imported %s"], dialog.info and dialog.info.specName or "")
end

local function Build()
    local S = ns.Style
    dialog = CreateFrame("Frame", "SquizzTalentsImportFrame", UIParent, "BackdropTemplate")
    dialog:SetSize(420, 214)
    dialog:SetPoint("CENTER", 0, 80)
    S.Window(dialog, L["Import talent build"])
    dialog:SetToplevel(true)
    dialog:Hide()
    tinsert(UISpecialFrames, "SquizzTalentsImportFrame")

    local codeLabel = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    codeLabel:SetPoint("TOPLEFT", 12, -(S.TITLE_HEIGHT + 10))
    codeLabel:SetText(L["Talent code:"])

    dialog.code = S.EditBox(dialog, 396, 22)
    dialog.code:SetPoint("TOPLEFT", codeLabel, "BOTTOMLEFT", 0, -3)
    dialog.code:SetMaxLetters(4000)
    dialog.code:SetScript("OnTextChanged", Validate)
    dialog.code:SetScript("OnEscapePressed", function() dialog:Hide() end)

    dialog.status = dialog:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    dialog.status:SetPoint("TOPLEFT", dialog.code, "BOTTOMLEFT", 0, -4)
    dialog.status:SetPoint("RIGHT", -12, 0)
    dialog.status:SetJustifyH("LEFT")
    dialog.status:SetWordWrap(true)

    local nameLabel = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameLabel:SetPoint("TOPLEFT", dialog.code, "BOTTOMLEFT", 0, -40)
    nameLabel:SetText(L["Name:"])

    dialog.name = S.EditBox(dialog, 396, 22)
    dialog.name:SetPoint("TOPLEFT", nameLabel, "BOTTOMLEFT", 0, -3)
    dialog.name:SetMaxLetters(48)
    dialog.name:SetScript("OnEscapePressed", function() dialog:Hide() end)

    dialog.toOwn = S.Button(dialog, L["Save to SquizzTalents"], 194, 24, "accent")
    dialog.toOwn:SetPoint("BOTTOMLEFT", 12, 12)
    dialog.toOwn.tooltipFunc = ButtonTooltip
    dialog.toOwn:SetScript("OnClick", function()
        if not dialog.info then return end
        local name = NameOrDefault()
        Transfer.ImportToOwn(dialog.info, name)
        ns.Print(string.format(L["Imported \"%s\" (%s)."], name, dialog.info.specName or "?"))
        dialog:Hide()
        ns.UI.RefreshAll()
    end)

    dialog.toBlizz = S.Button(dialog, L["Create Blizzard loadout"], 194, 24)
    dialog.toBlizz:SetPoint("BOTTOMRIGHT", -12, 12)
    dialog.toBlizz.tooltipFunc = ButtonTooltip
    dialog.toBlizz:SetScript("OnClick", function()
        if not dialog.info then return end
        local name = NameOrDefault()
        local ok, err = Transfer.ImportToBlizzard(dialog.info, name)
        if ok then
            ns.Print(string.format(L["Created Blizzard loadout \"%s\". Click it in /sqt to apply it."], name))
            dialog:Hide()
        else
            ns.Print(err)
        end
        ns.UI.RefreshAll()
    end)

    dialog:SetScript("OnShow", function()
        dialog.code:SetText("")
        dialog.name:SetText("")
        Validate()
        dialog.code:SetFocus()
    end)
end

function Transfer.ShowImport()
    if not dialog then Build() end
    dialog:Show()
    dialog:Raise()
end
