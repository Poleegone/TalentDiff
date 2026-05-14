local TalentDiff = TalentDiff
local TD = TalentDiff

-- ---------------------------------------------------------------------------
-- Options: lightweight movable window for live-tuning the four overlay
-- multipliers. Sits at DIALOG strata so it floats above PlayerSpellsFrame
-- (HIGH) and the player can drag sliders while watching overlays update.
--
-- Persistence is delegated entirely to TalentDiff.Config (which writes to
-- TalentDiffDB). Live updates are driven by Config.Set, which calls
-- OverlayManager:RestyleAll under the hood.
-- ---------------------------------------------------------------------------

-- Row table. `kind="slider"` rows render as OptionsSliderTemplate; `kind="check"`
-- rows render as a checkbox. Order is the visual top-to-bottom order in the
-- window. Bounds match the spec; animation-strength / -speed slider ranges are
-- intentionally narrow so the user cannot dial in flicker / arcade pulses.
local ROWS = {
    { kind = "slider", key = "overlayIntensity",  label = "Highlight Intensity", min = 0.20, max = 2.00, step = 0.05 },
    { kind = "slider", key = "overlayScale",      label = "Overlay Scale",       min = 0.80, max = 1.50, step = 0.05 },
    { kind = "slider", key = "rimThickness",      label = "Border Thickness",    min = 0.00, max = 3.00, step = 0.05 },
    { kind = "slider", key = "overlayAlpha",      label = "Overlay Alpha",       min = 0.10, max = 1.00, step = 0.05 },
    { kind = "check",  key = "enableAnimations",  label = "Enable Animations" },
    { kind = "slider", key = "animationStrength", label = "Animation Strength",  min = 0.20, max = 2.00, step = 0.05 },
    { kind = "slider", key = "animationSpeed",    label = "Animation Speed",     min = 0.50, max = 1.80, step = 0.05 },
}

-- Build one slider row. Returns the slider; the value FontString is parented
-- to it so the row's _refresh closure can drive both at once.
local function MakeSliderRow(parent, row, yOffset)
    local slider = CreateFrame("Slider", nil, parent, "OptionsSliderTemplate")
    slider:SetWidth(260)
    slider:SetMinMaxValues(row.min, row.max)
    slider:SetValueStep(row.step)
    slider:SetObeyStepOnDrag(true)
    slider:SetPoint("TOP", parent, "TOP", 0, yOffset)
    slider.Low:SetText(string.format("%.2f", row.min))
    slider.High:SetText(string.format("%.2f", row.max))
    slider.Text:SetText(row.label)

    local valueText = slider:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    valueText:SetPoint("TOP", slider, "BOTTOM", 0, -2)

    -- Guard so programmatic SetValue (sync from DB on Show) doesn't recurse
    -- into Config.Set → restyle → no-op write. Pure cosmetic, but keeps the
    -- slider's OnValueChanged contract clean.
    local syncing = false

    slider:SetScript("OnValueChanged", function(self, value)
        valueText:SetText(string.format("%.2f", value))
        if syncing then return end
        if TD.Config and TD.Config.Set then
            TD.Config.Set(row.key, value)
        end
    end)

    slider._refresh = function()
        local v = (TD.Config and TD.Config.Get and TD.Config.Get(row.key)) or 1
        syncing = true
        slider:SetValue(v)
        syncing = false
        valueText:SetText(string.format("%.2f", v))
    end

    return slider
end

-- Checkbox row. Mirrors the slider row's contract: returns a widget with a
-- `_refresh` closure so the BuildFrame loop can drive both uniformly.
local function MakeCheckRow(parent, row, yOffset)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(26, 26)
    cb:SetPoint("TOP", parent, "TOP", -110, yOffset)
    if cb.Text then cb.Text:SetText(row.label) end

    local syncing = false
    cb:SetScript("OnClick", function(self)
        if syncing then return end
        if TD.Config and TD.Config.Set then
            TD.Config.Set(row.key, self:GetChecked() and true or false)
        end
    end)

    cb._refresh = function()
        local v = TD.Config and TD.Config.Get and TD.Config.Get(row.key)
        syncing = true
        cb:SetChecked(v and true or false)
        syncing = false
    end

    return cb
end

local function BuildFrame()
    local f = CreateFrame("Frame", "TalentDiffOptionsFrame", UIParent, "BackdropTemplate")
    f:SetSize(320, 480)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop",  f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    f:Hide()

    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true, tileSize = 32, edgeSize = 32,
        insets   = { left = 11, right = 12, top = 12, bottom = 11 },
    })

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -14)
    title:SetText("TalentDiff Options")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)

    -- Slider rows. Spacing matches OptionsSliderTemplate's natural height
    -- (~16px) plus the value label below (~14px); 50px between row anchors
    -- gives clean separation without crowding.
    f._rows = {}
    local y = -50
    for _, row in ipairs(ROWS) do
        local widget
        if row.kind == "check" then
            widget = MakeCheckRow(f, row, y)
            y = y - 36
        else
            widget = MakeSliderRow(f, row, y)
            y = y - 50
        end
        f._rows[#f._rows + 1] = widget
    end

    -- Reset-to-defaults button. Funnels through Config.Reset, then re-syncs
    -- every slider to the new values so the visible state matches the DB.
    local reset = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    reset:SetSize(120, 22)
    reset:SetPoint("BOTTOM", 0, 16)
    reset:SetText("Reset to Defaults")
    reset:SetScript("OnClick", function()
        if TD.Config and TD.Config.Reset then TD.Config.Reset() end
        for _, s in ipairs(f._rows) do s._refresh() end
    end)

    return f
end

-- Public entry point. Lazy-builds the frame on first call, then toggles.
-- On show, re-syncs sliders from the DB (handles the case where another
-- code path — slash command argument, future presets — mutated values
-- while the frame was hidden).
function TalentDiff:ToggleOptions()
    local f = self._optionsFrame
    if not f then
        f = BuildFrame()
        self._optionsFrame = f
    end
    if f:IsShown() then
        f:Hide()
    else
        for _, s in ipairs(f._rows) do s._refresh() end
        f:Show()
        f:Raise()
    end
end
