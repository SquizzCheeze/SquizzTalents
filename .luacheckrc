-- luacheck config for a WoW retail (12.1) addon.
std = "lua51"
max_line_length = 120
self = false

exclude_files = { ".luacheckrc" }

ignore = {
    "212/self", -- unused self in methods
}

-- Globals this addon WRITES. Everything else must stay in the namespace table.
globals = {
    "SquizzTalentsDB",
    "SquizzNotesQueue", -- shared with SquizzFrames, Squizzumables and Avatar Continued
    "SLASH_SQUIZZTALENTS1",
    "SLASH_SQUIZZTALENTS2",
    "SlashCmdList",
    "StaticPopupDialogs",
    "UISpecialFrames",
}

-- WoW API and FrameXML globals this addon READS. Add to this list when a new
-- API is used, after checking it against Blizzard's generated documentation.
read_globals = {
    -- Lua extensions provided by the client
    "strtrim", "tinsert", "tostringall", "issecretvalue",
    string = { fields = { "join" } },

    -- Namespaces
    "C_AddOns", "C_ChallengeMode", "C_ClassTalents", "C_PartyInfo", "C_Spell", "C_SpellBook",
    "C_SpecializationInfo",
    "C_Timer", "C_Traits", "Enum", "ExportUtil", "MenuUtil", "Settings",

    -- Functions
    "CreateFrame", "GetBuildInfo", "GetInstanceInfo", "GetNormalizedRealmName",
    "GetMacroIcons", "GetMacroItemIcons", "GetLooseMacroIcons", "GetLooseMacroItemIcons",
    "GetSpecializationInfoForSpecID", "GetTime", "InCombatLockdown",
    "StaticPopup_Show", "UnitFullName", "geterrorhandler", "time",
    "GameTooltip_Hide",

    -- Frames, fonts and constants
    "CANCEL", "CLOSE", "ChatFontNormal", "DELETE", "GameFontHighlight", "GameTooltip", "OKAY", "REMOVE",
    "SAVE", "UIParent", "RAID_CLASS_COLORS", "SOUNDKIT", "PlaySound", "UnitClass",
}
