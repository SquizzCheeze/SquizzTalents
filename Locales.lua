-- Localization. Keys are the enUS strings; a missing translation falls back to
-- the key itself, so enUS needs no table of its own.
local _, ns = ...

local L = setmetatable({}, {
    __index = function(_, key) return key end,
})
ns.L = L

-- Other locales fill L here, e.g.:
-- if GetLocale() == "deDE" then
--     L["Save current build"] = "Aktuellen Build speichern"
-- end
