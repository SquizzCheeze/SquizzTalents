-- Shared look, matching SquizzFrames' options panel (Modules/Options/Widgets.lua
-- and OptionsFrame.lua there): dark flat panels with a black 1px border, a
-- 26px title bar with an accent line under it, flat buttons that fill with the
-- accent on hover, and class-coloured toggles and highlights.
--
-- Self-contained on purpose: SquizzTalents must not depend on SquizzFrames
-- being installed, so this copies the look rather than calling its widgets.
local _, ns = ...

local S = {}
ns.Style = S

S.WHITE = "Interface\\Buttons\\WHITE8x8"
S.FONT = "Fonts\\FRIZQT__.TTF"
S.BG = { 0.1, 0.1, 0.1, 0.95 }
S.PANEL = { 0.115, 0.115, 0.115, 1 }
S.BORDER = { 0, 0, 0, 1 }
S.TITLE_HEIGHT = 26

-- Player class colour, the accent SquizzFrames uses by default. Cached: the
-- class never changes within a session.
local accent
function S.Accent()
    if accent then return accent end
    local _, classFile = UnitClass("player")
    local c = ns.IsPlain(classFile) and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    accent = c and { r = c.r, g = c.g, b = c.b } or { r = 0.2, g = 0.8, b = 0.6 }
    return accent
end

-- "|cffRRGGBB" for the accent, for inline text colouring.
function S.AccentCode()
    local a = S.Accent()
    return string.format("|cff%02x%02x%02x", a.r * 255, a.g * 255, a.b * 255)
end

function S.Backdrop(frame, bg, border)
    bg, border = bg or S.BG, border or S.BORDER
    frame:SetBackdrop({
        bgFile = S.WHITE,
        edgeFile = S.WHITE,
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    frame:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 1)
    frame:SetBackdropBorderColor(border[1], border[2], border[3], border[4] or 1)
end

function S.Font(fontString, size, r, g, b)
    fontString:SetFont(S.FONT, size or 12, "OUTLINE")
    fontString:SetTextColor(r or 1, g or 1, b or 1, 1)
end

-- ---------------------------------------------------------------------------
-- Buttons. style: "accent-hover" (default), "accent", "red".
-- A tooltip goes in button.tooltipFunc(button), NOT an OnEnter script: the
-- hover colour lives in OnEnter, and SetScript would replace it.
-- ---------------------------------------------------------------------------
function S.Button(parent, text, width, height, style)
    local a = S.Accent()
    local normal, hover
    if style == "accent" then
        normal, hover = { a.r, a.g, a.b, 0.3 }, { a.r, a.g, a.b, 0.6 }
    elseif style == "red" then
        normal, hover = { 0.6, 0.1, 0.1, 0.6 }, { 0.6, 0.1, 0.1, 1 }
    else
        normal, hover = S.PANEL, { a.r, a.g, a.b, 0.6 }
    end

    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(width, height)
    S.Backdrop(b, normal, S.BORDER)
    b:SetMotionScriptsWhileDisabled(true)

    local fs = b:CreateFontString(nil, "OVERLAY")
    S.Font(fs, 12)
    fs:SetPoint("CENTER")
    b.fontString = fs

    function b:SetText(str) self.fontString:SetText(str or "") end
    function b:GetText() return self.fontString:GetText() end

    local baseSetEnabled = b.SetEnabled
    function b:SetEnabled(on)
        baseSetEnabled(self, on)
        local v = on and 1 or 0.45
        self.fontString:SetTextColor(v, v, v, 1)
        if not on then self:SetBackdropColor(normal[1], normal[2], normal[3], normal[4] or 1) end
    end

    b:SetScript("OnEnter", function(self)
        if self:IsEnabled() then
            self:SetBackdropColor(hover[1], hover[2], hover[3], hover[4] or 1)
        end
        if self.tooltipFunc then self.tooltipFunc(self) end
    end)
    b:SetScript("OnLeave", function(self)
        self:SetBackdropColor(normal[1], normal[2], normal[3], normal[4] or 1)
        if self.tooltipFunc then GameTooltip_Hide() end
    end)
    b:HookScript("OnClick", function() PlaySound(SOUNDKIT.U_CHAT_SCROLL_BUTTON) end)

    b:SetText(text)
    return b
end

-- ---------------------------------------------------------------------------
-- Window chrome: panel backdrop, 26px title bar with an accent line, red X.
-- Sets frame.titleBar, frame.title (FontString) and frame.closeButton.
-- ---------------------------------------------------------------------------
function S.Window(frame, titleText)
    S.Backdrop(frame, S.BG, S.BORDER)
    frame:SetFrameStrata("DIALOG")
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)

    local bar = CreateFrame("Frame", nil, frame)
    bar:SetPoint("TOPLEFT", 1, -1)
    bar:SetPoint("TOPRIGHT", -1, -1)
    bar:SetHeight(S.TITLE_HEIGHT - 1)
    local barBg = bar:CreateTexture(nil, "BACKGROUND")
    barBg:SetAllPoints()
    barBg:SetColorTexture(S.PANEL[1], S.PANEL[2], S.PANEL[3], 1)
    local a = S.Accent()
    local line = bar:CreateTexture(nil, "BORDER")
    line:SetPoint("BOTTOMLEFT")
    line:SetPoint("BOTTOMRIGHT")
    line:SetHeight(1)
    line:SetColorTexture(a.r, a.g, a.b, 0.5)
    frame.titleBar = bar

    local title = bar:CreateFontString(nil, "OVERLAY")
    S.Font(title, 13)
    title:SetPoint("LEFT", 9, 0)
    title:SetPoint("RIGHT", -30, 0)
    title:SetJustifyH("LEFT")
    title:SetWordWrap(false)
    title:SetText(titleText or "")
    frame.title = title

    local close = S.Button(bar, "X", 20, 20, "red")
    close:SetPoint("RIGHT", -3, 0)
    close:SetScript("OnClick", function() frame:Hide() end)
    frame.closeButton = close
end

-- Accent-tinted highlight for a clickable row or icon.
function S.Highlight(button, alpha)
    local a = S.Accent()
    local t = button:CreateTexture(nil, "HIGHLIGHT")
    t:SetAllPoints()
    t:SetColorTexture(a.r, a.g, a.b, alpha or 0.25)
    button:SetHighlightTexture(t)
    return t
end

-- ---------------------------------------------------------------------------
-- Toggle: SquizzFrames' flat switch (square knob slides right and takes the
-- accent colour when on). No animation -- it snaps.
-- toggle:SetChecked(bool); onChange(checked) fires on click.
-- ---------------------------------------------------------------------------
local TOGGLE_W, TOGGLE_H, KNOB, PAD = 30, 16, 10, 3
local KNOB_OFF = { 0.45, 0.45, 0.45 }

function S.Toggle(parent, label, onChange)
    local a = S.Accent()
    local cb = CreateFrame("CheckButton", nil, parent, "BackdropTemplate")
    cb:SetSize(TOGGLE_W, TOGGLE_H)
    S.Backdrop(cb, S.PANEL, S.BORDER)

    local knob = cb:CreateTexture(nil, "ARTWORK")
    knob:SetSize(KNOB, KNOB)
    cb.knob = knob

    local text = cb:CreateFontString(nil, "OVERLAY")
    S.Font(text, 12)
    text:SetPoint("LEFT", cb, "RIGHT", 8, 0)
    text:SetText(label or "")
    cb.labelText = text
    cb:SetHitRectInsets(0, -text:GetStringWidth() - 8, 0, 0)

    local function Visual(on)
        knob:ClearAllPoints()
        if on then
            knob:SetPoint("RIGHT", -PAD, 0)
            knob:SetColorTexture(a.r, a.g, a.b, 1)
            cb:SetBackdropColor(a.r * 0.28, a.g * 0.28, a.b * 0.28, 1)
        else
            knob:SetPoint("LEFT", PAD, 0)
            knob:SetColorTexture(KNOB_OFF[1], KNOB_OFF[2], KNOB_OFF[3], 1)
            cb:SetBackdropColor(S.PANEL[1], S.PANEL[2], S.PANEL[3], 1)
        end
    end

    local baseSetChecked = cb.SetChecked
    function cb:SetChecked(on)
        baseSetChecked(self, on)
        Visual(on and true or false)
    end

    cb:SetScript("OnClick", function(self)
        local on = self:GetChecked() and true or false
        Visual(on)
        PlaySound(on and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
        if onChange then onChange(on) end
    end)
    cb:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(a.r, a.g, a.b, 0.6) end)
    cb:SetScript("OnLeave", function(self) self:SetBackdropBorderColor(0, 0, 0, 1) end)

    Visual(false)
    return cb
end

-- Flat single-line edit box to match the panels (replaces InputBoxTemplate).
function S.EditBox(parent, width, height)
    local a = S.Accent()
    local e = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    e:SetSize(width, height or 22)
    S.Backdrop(e, S.PANEL, S.BORDER)
    e:SetFont(S.FONT, 12, "")
    e:SetTextColor(1, 1, 1, 1)
    e:SetTextInsets(6, 6, 0, 0)
    e:SetAutoFocus(false)
    e:SetScript("OnEditFocusGained", function(self) self:SetBackdropBorderColor(a.r, a.g, a.b, 0.8) end)
    e:SetScript("OnEditFocusLost", function(self) self:SetBackdropBorderColor(0, 0, 0, 1) end)
    e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return e
end
