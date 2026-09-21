-- Init, the shared event bus and slash commands.
local ADDON_NAME, ns = ...
local L = ns.L

ns.ADDON_NAME = ADDON_NAME
ns.PREFIX = "|cff33cc99[SquizzTalents]|r "

function ns.Print(...)
    print(ns.PREFIX .. string.join(" ", tostringall(...)))
end

-- True when v can be read, compared and indexed. Nothing this addon reads is
-- combat data, but the guard is cheap and a secret would otherwise throw.
function ns.IsPlain(v)
    return v ~= nil and not (issecretvalue and issecretvalue(v))
end

-- ---------------------------------------------------------------------------
-- Event bus: one frame, any number of listeners per event.
-- ---------------------------------------------------------------------------
local listeners = {}
local eventFrame = CreateFrame("Frame")

function ns.On(event, fn)
    if not listeners[event] then
        listeners[event] = {}
        eventFrame:RegisterEvent(event)
    end
    table.insert(listeners[event], fn)
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    local list = listeners[event]
    if not list then return end
    for i = 1, #list do
        local ok, err = pcall(list[i], ...)
        if not ok then geterrorhandler()(err) end
    end
end)

-- Run fn now, or once combat ends if we are in it.
local afterCombat = {}
function ns.RunOutOfCombat(key, fn)
    if not InCombatLockdown() then
        fn()
    else
        afterCombat[key] = fn
    end
end

ns.On("PLAYER_REGEN_ENABLED", function()
    local queued = afterCombat
    afterCombat = {}
    for _, fn in pairs(queued) do fn() end
end)

ns.On("ADDON_LOADED", function(name)
    if name ~= ADDON_NAME then return end
    ns.Store.Init()
end)

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------
SLASH_SQUIZZTALENTS1 = "/squizztalents"
SLASH_SQUIZZTALENTS2 = "/sqt"
SlashCmdList.SQUIZZTALENTS = function(msg)
    local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()
    if cmd == "" or cmd == "show" then
        ns.UI.Toggle()
    elseif cmd == "save" then
        if rest ~= "" then
            ns.UI.SaveCurrent(rest)
        else
            ns.UI.PromptSave()
        end
    elseif cmd == "debug" then
        ns.Debug.Show()
    elseif cmd == "import" then
        ns.Transfer.ShowImport()
    elseif cmd == "notes" or cmd == "changelog" then
        ns.Welcome.ShowReleaseNotes()
    elseif cmd == "config" or cmd == "settings" then
        ns.Settings.Open()
    elseif cmd == "testoutdated" then
        -- Save a copy of the current build with its tree hash altered, so the
        -- Outdated tag / Update / Delete outdated can be tested without a patch.
        -- Character 7 of the string holds bits 36-41: inside the 128-bit hash.
        local str = ns.Sources.GetActiveImportString()
        if not str then return ns.Print(L["Could not export the current build"]) end
        local c = str:sub(7, 7)
        local swapped = str:sub(1, 6) .. (c == "A" and "B" or "A") .. str:sub(8)
        local specID = ns.Sources.GetCurrentSpecID()
        ns.Store.AddOwn({ name = L["Outdated test"], specID = specID, importString = swapped })
        ns.Print(L["Saved \"Outdated test\". It should show as Outdated."])
        ns.UI.RefreshAll()
    elseif cmd == "remind" then
        -- Run the reminder check now, as if a ready check had fired.
        local data, reason = ns.Reminder.Evaluate("manual")
        if data then
            ns.UI.ShowReminder(data)
        else
            ns.Print(L["No reminder: "] .. tostring(reason))
        end
    else
        ns.Print(L["Commands:"])
        print("  /sqt  " .. L["- open the loadout window"])
        print("  /sqt save [name]  " .. L["- save the current build"])
        print("  /sqt import  " .. L["- import a talent code"])
        print("  /sqt remind  " .. L["- run the reminder check now"])
        print("  /sqt config  " .. L["- open the settings"])
        print("  /sqt notes  " .. L["- show the release notes"])
        print("  /sqt debug  " .. L["- dump the loadout list, mappings and last apply result"])
    end
end
