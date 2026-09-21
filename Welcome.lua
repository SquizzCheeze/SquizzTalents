--[[ SquizzTalents welcome / release notes

    The first-run greeting and the "what changed" note after an update. Ported
    from SquizzFrames' Modules/Welcome/Welcome.lua (itself from Squizzumables):
    a scrolling body, the first-run/update/nothing decision, and the seen
    version read straight off the SavedVariables root.

    The notes are duplicated here rather than read from CHANGELOG.txt because an
    addon cannot read its own text files at runtime. So this is a HIGHLIGHT list,
    not a changelog: a few lines per release, what a player would notice.
]]
local ADDON_NAME, ns = ...
local L = ns.L

local Welcome = {}
ns.Welcome = Welcome

-- Highlights per version, newest first, keyed by the .toc Version string.
-- ADD A NEW ENTRY AS PART OF RELEASING. A version with no entry still shows
-- the update window, just without bullets.
local RELEASE_NOTES = {
    ["1.0"] = {
        "First release. Your Blizzard loadouts and your own saved builds in one list, with no cap on how many "
            .. "you save. Click one to apply it.",
        "A reminder when you enter a dungeon, raid, delve or PvP instance, slot a keystone, or on a ready check -- "
            .. "only when your active build is not the one you chose for that content.",
        "Choose builds for content from the reminder or by right-clicking a build: one difficulty, the whole "
            .. "instance, or every dungeon/raid/delve.",
        "Builds made on an older talent tree are marked Outdated; right-click > Update to current talents "
            .. "refreshes one and keeps its name, tags and mappings.",
        "Settings under Options > AddOns > SquizzTalents, or /sqt config.",
    },
}

local function CurrentVersion()
    return C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version") or "?"
end

-- ONE UPDATE NOTE AT A TIME, across all of the Squizz addons.
--
-- SquizzFrames, Squizzumables and Avatar Continued each carry a copy of this
-- window, and the copies were identical: same size, same spot, same DIALOG
-- strata, same frame level. Frames that tie on strata and level have no defined
-- draw order, so when two of them updated at the same login their notes drew
-- through each other and flickered as the order flipped.
--
-- The queue lives in _G and is created by whichever addon loads first. Notes
-- that come due at login wait behind one already on screen and appear when it
-- closes; notes opened by hand (/sf notes) show straight away, on top.
--
-- KEEP THIS BLOCK IDENTICAL IN ALL THREE ADDONS. They share the table, so its
-- shape is an interface between them.
local NotesQueue = _G.SquizzNotesQueue or { pending = {} }
_G.SquizzNotesQueue = NotesQueue

local function PresentNotes(f, queued)
    local active = NotesQueue.active
    if queued and active and active ~= f and active:IsShown() then
        for _, waiting in ipairs(NotesQueue.pending) do
            if waiting == f then return end
        end
        table.insert(NotesQueue.pending, f)
        return
    end
    NotesQueue.active = f
    f:Show()
    f:Raise()
end

local function OnNotesHidden(f)
    if NotesQueue.active ~= f then return end
    NotesQueue.active = nil
    local nextFrame = table.remove(NotesQueue.pending, 1)
    if nextFrame then
        PresentNotes(nextFrame, false)
    end
end

-- Narrower than the frame by the scroll bar's gutter.
local BODY_WIDTH = 404
local WHITE8 = "Interface\\Buttons\\WHITE8x8"

local frame

local function BuildFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", "SquizzTalentsWelcome", UIParent, "BackdropTemplate")
    frame:SetSize(460, 320)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()
    frame:SetToplevel(true)
    frame:HookScript("OnHide", OnNotesHidden)
    frame:SetBackdrop({ bgFile = WHITE8, edgeFile = WHITE8, edgeSize = 1 })
    frame:SetBackdropColor(0.09, 0.09, 0.09, 0.96)
    frame:SetBackdropBorderColor(0.2, 0.8, 0.6, 0.8)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, -16)
    frame.title = title

    -- Scrolls, bounded between the title and the buttons, so a long release
    -- can never push text under the buttons (Squizzumables shipped that bug).
    local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
    scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -26, 52)
    frame.scroll = scroll

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(BODY_WIDTH, 1)
    scroll:SetScrollChild(content)
    frame.content = content

    local body = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    body:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    body:SetWidth(BODY_WIDTH)
    body:SetJustifyH("LEFT")
    body:SetJustifyV("TOP")
    body:SetSpacing(4)
    body:SetTextColor(0.78, 0.78, 0.78, 1)
    frame.body = body

    local openBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    openBtn:SetSize(150, 26)
    openBtn:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 18, 16)
    openBtn:SetText(L["Open SquizzTalents"])
    openBtn:SetScript("OnClick", function()
        frame:Hide()
        ns.UI.Toggle()
    end)

    local closeBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    closeBtn:SetSize(90, 26)
    closeBtn:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -18, 16)
    closeBtn:SetText(CLOSE)
    closeBtn:SetScript("OnClick", function() frame:Hide() end)

    return frame
end

-- queued: true for the automatic login note, which waits its turn behind
-- another addon's note; false/nil when opened by hand.
local function Show(titleText, bodyText, queued)
    local f = BuildFrame()
    f.title:SetText(titleText)
    f.body:SetText(bodyText)
    -- Size the scroll child AFTER SetText, to the wrapped height.
    f.content:SetHeight(math.max(1, f.body:GetStringHeight() + 4))
    f.scroll:SetVerticalScroll(0)
    PresentNotes(f, queued)
end

local function ShowFirstRun(queued)
    Show(L["Welcome to SquizzTalents"],
        L["SquizzTalents keeps your talent builds in one list and reminds you to swap when you enter content."]
        .. "\n\n"
        .. L["Type /sqt to open it. Your Blizzard loadouts are already listed; Save current build adds your own, "
            .. "with no limit on how many."] .. "\n\n"
        .. L["Right-click a build to use it for a dungeon, a raid, a delve or PvP. When you enter that content "
            .. "on a different build, a reminder offers to swap."] .. "\n\n"
        .. L["Settings are under Options > AddOns > SquizzTalents, or /sqt config."], queued)
end

local function ShowUpdated(version, queued)
    local notes = RELEASE_NOTES[version]
    local body = string.format(L["SquizzTalents has been updated to %s."], version) .. "\n\n"
    if notes then
        for _, line in ipairs(notes) do
            body = body .. "- " .. line .. "\n"
        end
        body = body .. "\n" .. L["The full changelog is in CHANGELOG.txt in the addon folder."]
    else
        body = body .. L["See CHANGELOG.txt in the addon folder for what changed."]
    end
    Show(L["SquizzTalents updated"], body, queued)
end

-- Reads lastSeenVersion straight off the SavedVariables root.
local function CheckVersion()
    if not SquizzTalentsDB then return end
    local version = CurrentVersion()
    local seen = SquizzTalentsDB.lastSeenVersion
    if seen == nil then
        -- New install, or an upgrade from before this file existed.
        if ns.hadSavedVariables then
            ShowUpdated(version, true)
        else
            ShowFirstRun(true)
        end
    elseif seen ~= version then
        ShowUpdated(version, true)
    end
    SquizzTalentsDB.lastSeenVersion = version
end

-- After login so the SavedVariables exist, delayed past the loading screen.
ns.On("PLAYER_LOGIN", function()
    C_Timer.After(4, CheckVersion)
end)

Welcome.ShowReleaseNotes = function() ShowUpdated(CurrentVersion()) end
Welcome.ShowFirstRun = ShowFirstRun
