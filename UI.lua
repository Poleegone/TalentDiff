local TalentDiff = TalentDiff

local STATUS = TalentDiff.STATUS or {}
local OverlayManager = TalentDiff.OverlayManager

-- Hex helper used by the dropdown summary and tooltip prefixes. Reads from the
-- OverlayManager's semantic visual table so any palette tweak in one place
-- propagates to overlays AND text colors automatically.
local function StatusHex(idx)
    local v = OverlayManager and OverlayManager:GetVisual(idx) or nil
    if not v then return "ffffff" end
    local c = v.color
    return string.format("%02x%02x%02x",
        math.floor(c[1] * 255 + 0.5),
        math.floor(c[2] * 255 + 0.5),
        math.floor(c[3] * 255 + 0.5))
end

local compareDropdown          -- the "Compare To" dropdown frame
local swapButton                -- the "Swap To" button next to the dropdown
local diffListToggle            -- "Show Diff" button next to swap
local optionsCogButton          -- small cog icon to the right of Show Diff; toggles options frame
local diffListPanel             -- floating panel showing per-row diff list
local AppendTooltipForNode      -- forward declaration; defined in the tooltip-hook section
local swapInProgress = false    -- true between LoadInProgress and TRAIT_CONFIG_UPDATED/CONFIG_COMMIT_FAILED
local hookedTalentFrame = false
local hookedTooltips = false

-- Default Blizzard "?" icon used as a final fallback when we can't resolve a real one.
local FALLBACK_ICON = 134400
-- Per-row layout constants for the diff list panel.
local ROW_HEIGHT   = 24
local ROW_ICON_SZ  = 20
local ROW_PAD_X    = 6
local ROW_GAP_Y    = 2

-- ---------- Helpers --------------------------------------------------------

local function GetTalentFrame()
    -- Blizzard's class-talent UI in retail; live tab of PlayerSpellsFrame.
    if PlayerSpellsFrame and PlayerSpellsFrame.TalentsFrame then
        return PlayerSpellsFrame.TalentsFrame
    end
    return nil
end

local function IterTalentButtons(talentFrame)
    -- Mixin provides EnumerateAllTalentButtons() in retail.
    if talentFrame and talentFrame.EnumerateAllTalentButtons then
        return talentFrame:EnumerateAllTalentButtons()
    end
    return function() return nil end
end

local function GetButtonNodeID(button)
    if not button then return nil end
    if button.GetNodeID then
        local ok, id = pcall(button.GetNodeID, button)
        if ok and id then return id end
    end
    if button.nodeID then return button.nodeID end
    if button.nodeInfo and button.nodeInfo.ID then return button.nodeInfo.ID end
    return nil
end

-- ---------- Overlay --------------------------------------------------------
--
-- All visual painting on talent buttons goes through TalentDiff.OverlayManager
-- (OverlayManager.lua). UI.lua only owns the Blizzard-frame helpers needed to
-- enumerate buttons and resolve nodeIDs; the manager handles pool lifecycle,
-- semantic state application, and stale-overlay reaping.

-- ---------- Copyable debug log window --------------------------------------
--
-- Used by `/td debug` to surface per-node classification + atlas/mask binding
-- in a window the user can select / copy from. WoW's chat frame doesn't allow
-- copy/paste, so dumping multi-line diagnostics there is useless. A multiline
-- EditBox inside a ScrollFrame is the standard WoW-native pattern for this
-- (Blizzard's own /macro and /script error windows use the same approach).

local debugLogPanel  -- created lazily on first ShowDebugLog call

local DEBUG_PANEL_BACKDROP = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

local function EnsureDebugLogPanel()
    if debugLogPanel then return debugLogPanel end

    local panel = CreateFrame("Frame", "TalentDiffDebugPanel", UIParent, "BackdropTemplate")
    panel:SetSize(640, 420)
    panel:SetFrameStrata("DIALOG")
    panel:SetBackdrop(DEBUG_PANEL_BACKDROP)
    panel:SetBackdropColor(0, 0, 0, 0.92)
    panel:SetClampedToScreen(true)
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    panel:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    panel:Hide()

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", panel, "TOP", 0, -10)
    panel.title = title

    local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOP", title, "BOTTOM", 0, -2)
    hint:SetText("Click in the box, Ctrl+A to select all, Ctrl+C to copy.")
    panel.hint = hint

    local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 2, 2)
    close:SetScript("OnClick", function() panel:Hide() end)

    -- ScrollFrame wraps a multiline EditBox. The EditBox auto-sizes its height
    -- to its content via SetScript("OnTextChanged") + SetHeight; the scroll
    -- frame handles the viewport. Standard WoW copy-paste pattern.
    local scroll = CreateFrame("ScrollFrame", "$parentScroll", panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT",     panel, "TOPLEFT",      12, -50)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -32,  12)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject("GameFontHighlightSmall")
    edit:SetWidth(scroll:GetWidth())
    edit:SetScript("OnEscapePressed", edit.ClearFocus)
    -- Auto-grow height to content so ScrollFrame's vertical scrolling has the
    -- right child extent. GetStringHeight is the standard WoW idiom for this.
    edit:SetScript("OnTextChanged", function(self)
        self:SetHeight(math.max(scroll:GetHeight(), self:GetStringHeight() + 8))
    end)
    scroll:SetScrollChild(edit)
    panel.edit = edit
    panel.scroll = scroll

    debugLogPanel = panel
    return panel
end

function TalentDiff:ShowDebugLog(title, text)
    local panel = EnsureDebugLogPanel()
    panel.title:SetText(title or "TalentDiff Debug")
    panel.edit:SetText(text or "")
    -- Park scroll at top + clear any focus from a prior session so the new
    -- dump is immediately visible without the user having to scroll.
    panel.scroll:SetVerticalScroll(0)
    panel.edit:ClearFocus()
    panel:Show()
    panel:Raise()
end

function TalentDiff:RefreshOverlays()
    local talentFrame = GetTalentFrame()
    if not talentFrame then
        -- Talent UI hasn't been built yet (first /reload before opening the
        -- frame). Comparison cleared → drop everything; otherwise wait for the
        -- frame's OnShow hook to drive the next paint pass.
        if not self.state.compareConfigID then OverlayManager:ClearAll() end
        return
    end

    local diff = self:GetDiff()
    if not diff then
        OverlayManager:ClearAll()
        return
    end

    -- We always feed the manager iteration callbacks even when the frame is
    -- hidden — it bumps generation and reaps stale entries that way. Apply()
    -- still works on hidden buttons; visibility is governed by the parent.
    OverlayManager:RefreshAll(
        diff,
        function() return IterTalentButtons(talentFrame) end,
        GetButtonNodeID
    )
end

-- ---------- Diff-list row data --------------------------------------------

-- Resolve {icon, spellID, name} for a given (configID, nodeID) by walking
-- C_Traits' nodeInfo → activeEntry → definitionInfo chain. spellID drives the
-- row tooltip; iconID drives the row's icon texture. Falls back gracefully
-- when any link is missing — rows still render with the diff-supplied name.
-- Resolve a single entryID into (icon, spellID, name). Tries spell info first
-- (drives the native talent tooltip on row hover), then falls back to the
-- definition's overrideIcon / overrideName so passive nodes without a spell
-- payload still render with the right art.
local function ResolveEntry(configID, entryID)
    if not entryID or entryID == 0 then return nil, nil, nil end
    local entryInfo = C_Traits.GetEntryInfo(configID, entryID)
    if not entryInfo or not entryInfo.definitionID then return nil, nil, nil end
    local def = C_Traits.GetDefinitionInfo(entryInfo.definitionID)
    if not def then return nil, nil, nil end

    local spellID = (def.overriddenSpellID and def.overriddenSpellID > 0) and def.overriddenSpellID
                 or (def.spellID and def.spellID > 0 and def.spellID)
                 or nil
    local icon, name
    if spellID and C_Spell and C_Spell.GetSpellInfo then
        local si = C_Spell.GetSpellInfo(spellID)
        if si then icon, name = si.iconID, si.name end
    end
    if not icon and spellID and GetSpellTexture then icon = GetSpellTexture(spellID) end
    if not icon and def.overrideIcon and def.overrideIcon > 0 then icon = def.overrideIcon end
    if not name then name = def.overrideName end
    return icon, spellID, name
end

-- Resolve a SubTreeSelection node (hero-tree picker). Visuals live on the
-- subTreeInfo, not the entry's definitionInfo — entries here have no spellID
-- and no overrideIcon, so the regular ResolveEntry path produces "?". The
-- subTreeID identifies which hero tree is picked (e.g. Elune's Chosen vs
-- Druid of the Claw); we resolve its name + icon directly.
local function ResolveSubTreeVisuals(configID, nodeInfo)
    if not nodeInfo or not C_Traits or not C_Traits.GetSubTreeInfo then return nil, nil, nil end
    local subTreeID = nodeInfo.activeEntry and nodeInfo.activeEntry.subTreeID or nil
    -- Fallback: scan entry list for a subTreeID when activeEntry is missing.
    if not subTreeID and nodeInfo.entryIDs then
        for _, eid in ipairs(nodeInfo.entryIDs) do
            local entryInfo = C_Traits.GetEntryInfo(configID, eid)
            if entryInfo and entryInfo.subTreeID then
                subTreeID = entryInfo.subTreeID
                break
            end
        end
    end
    if not subTreeID then return nil, nil, nil end

    local sub = C_Traits.GetSubTreeInfo(configID, subTreeID)
    if not sub then return nil, nil, nil end
    return sub.iconElementID, nil, sub.name  -- no spellID; row tooltip uses text header
end

-- Resolve {icon, spellID, name} for the entry the given config has selected at
-- nodeID. Walks nodeInfo's activeEntry first, with fallbacks for cases where
-- the engine doesn't fill it in:
--   * SubTreeSelection nodes (hero-tree pickers) need GetSubTreeInfo lookup.
--   * Choice nodes where the queried config doesn't have the node picked
--     (live=nothing or saved=nothing) leave activeEntry nil. We fall back to
--     the first entryID under nodeInfo.entryIDs so the row at least renders
--     SOME representative icon for the choice slot — better than "?".
local function ResolveEntryVisuals(configID, nodeID)
    if not configID or not nodeID or not C_Traits then return nil, nil, nil end
    local nodeInfo = C_Traits.GetNodeInfo(configID, nodeID)
    if not nodeInfo then return nil, nil, nil end

    if Enum and Enum.TraitNodeType and nodeInfo.type == Enum.TraitNodeType.SubTreeSelection then
        return ResolveSubTreeVisuals(configID, nodeInfo)
    end

    local entryID = nodeInfo.activeEntry and nodeInfo.activeEntry.entryID or nil
    local icon, spellID, name = ResolveEntry(configID, entryID)
    if icon or name then return icon, spellID, name end

    -- Fallback: scan the node's available entries and take the first that
    -- resolves to something visible. Handles passives whose activeEntry is
    -- present but the entryID resolves to a definition with no spellID, and
    -- choice nodes where the queried config doesn't have a pick committed.
    if nodeInfo.entryIDs then
        for _, eid in ipairs(nodeInfo.entryIDs) do
            local i2, s2, n2 = ResolveEntry(configID, eid)
            if i2 or n2 then return i2, s2, n2 end
        end
    end
    return nil, nil, nil
end

-- Build an ordered list of row descriptors from the cached diff. Order:
-- ADDED first (gain), then REMOVED (loss), then CHANGED (swap), then RANK
-- (rank delta). Within each group, alphabetical by display name.
local function BuildDiffRowList()
    local diff = TalentDiff:GetDiff()
    if not diff or not diff.byNode then return {} end
    local activeID = TalentDiff:GetActiveConfigID()
    local savedID = TalentDiff.state.compareConfigID
    -- ReadCurrent uses C_ClassTalents.GetActiveConfigID (the *base spec config*),
    -- NOT the saved-loadout activeID. The visual resolver walks the same path.
    local liveID = C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_ClassTalents.GetActiveConfigID() or activeID

    local groups = { [STATUS.ADDED] = {}, [STATUS.REMOVED] = {}, [STATUS.CHANGED] = {}, [STATUS.RANK] = {} }

    for nodeID, nd in pairs(diff.byNode) do
        local row = { nodeID = nodeID, status = nd.status }
        if nd.status == STATUS.ADDED then
            local icon, spellID, name = ResolveEntryVisuals(savedID, nodeID)
            row.icon, row.spellID = icon, spellID
            row.name = name or nd.savedName or "?"
        elseif nd.status == STATUS.REMOVED then
            local icon, spellID, name = ResolveEntryVisuals(liveID, nodeID)
            row.icon, row.spellID = icon, spellID
            row.name = name or nd.currentName or "?"
        elseif nd.status == STATUS.CHANGED then
            local oldIcon, oldSpell, oldName = ResolveEntryVisuals(liveID, nodeID)
            local newIcon, newSpell, newName = ResolveEntryVisuals(savedID, nodeID)
            row.icon, row.spellID = newIcon, newSpell
            row.altIcon, row.altSpellID = oldIcon, oldSpell
            row.name = (newName or nd.savedName or "?")
            row.altName = (oldName or nd.currentName or "?")
        elseif nd.status == STATUS.RANK then
            local icon, spellID, name = ResolveEntryVisuals(liveID, nodeID)
            row.icon, row.spellID = icon, spellID
            row.name = name or nd.currentName or "?"
            row.currentRank = nd.currentRank or 0
            row.savedRank = nd.savedRank or 0
        end
        if groups[row.status] then
            table.insert(groups[row.status], row)
        end
    end

    local function byName(a, b) return (a.name or "") < (b.name or "") end
    for _, g in pairs(groups) do table.sort(g, byName) end

    local rows = {}
    for _, status in ipairs({ STATUS.ADDED, STATUS.REMOVED, STATUS.CHANGED, STATUS.RANK }) do
        for _, row in ipairs(groups[status] or {}) do rows[#rows + 1] = row end
    end
    return rows
end

-- ---------- Compare-To dropdown --------------------------------------------

local function BuildDropdownMenu(self, level)
    local loadouts = TalentDiff:GetSavedLoadouts()
    local sel = TalentDiff.state.compareConfigID

    local none = UIDropDownMenu_CreateInfo()
    none.text = "<none>"
    none.checked = (sel == nil)
    none.func = function()
        TalentDiff:ClearComparison()
        UIDropDownMenu_SetText(compareDropdown, "Compare to: <none>")
        CloseDropDownMenus()
    end
    UIDropDownMenu_AddButton(none, level)

    for _, lo in ipairs(loadouts) do
        local info = UIDropDownMenu_CreateInfo()
        local label = lo.name
        if lo.isActive then label = label .. " |cff888888(active)|r" end
        info.text = label
        info.checked = (lo.configID == sel)
        info.func = function()
            TalentDiff:SetComparisonLoadout(lo.configID)
            UIDropDownMenu_SetText(compareDropdown, "Compare to: " .. lo.name)
            CloseDropDownMenus()
        end
        UIDropDownMenu_AddButton(info, level)
    end

    if #loadouts == 0 then
        local info = UIDropDownMenu_CreateInfo()
        info.text = "<no saved loadouts>"
        info.notCheckable = true
        info.disabled = true
        UIDropDownMenu_AddButton(info, level)
    end
end

local function EnsureCompareDropdown(talentFrame)
    if compareDropdown then return compareDropdown end

    compareDropdown = CreateFrame("Frame", "TalentDiffCompareDropdown", talentFrame, "UIDropDownMenuTemplate")
    UIDropDownMenu_SetWidth(compareDropdown, 180)
    UIDropDownMenu_SetText(compareDropdown, "Compare to: <none>")
    UIDropDownMenu_Initialize(compareDropdown, BuildDropdownMenu)

    -- Anchor near Blizzard's loadout dropdown if we can find it; otherwise top-left.
    local anchor = talentFrame.LoadoutDropDown or talentFrame.LoadSystem or talentFrame
    compareDropdown:ClearAllPoints()
    if anchor and anchor.GetObjectType then
        compareDropdown:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", -16, -2)
    else
        compareDropdown:SetPoint("TOPLEFT", talentFrame, "TOPLEFT", 8, -8)
    end

    -- Swap-To button: one-click activation of the currently selected compared loadout.
    swapButton = CreateFrame("Button", "TalentDiffSwapButton", talentFrame, "UIPanelButtonTemplate")
    swapButton:SetSize(80, 22)
    swapButton:SetText("Swap To")
    -- The dropdown widget includes a chunk of internal right-side padding; -8 pulls
    -- the button visually flush; +2 nudges its centre to match the dropdown's text baseline.
    swapButton:SetPoint("LEFT", compareDropdown, "RIGHT", -8, 2)

    swapButton:SetScript("OnClick", function()
        local cid = TalentDiff.state.compareConfigID
        if not cid then return end
        if InCombatLockdown and InCombatLockdown() then
            TalentDiff:Print("Cannot swap loadouts during combat.")
            return
        end
        -- Immediate UX feedback: dismiss the diff panel as soon as the user
        -- commits to swapping. The engine-side success path also clears
        -- comparison via NotifyLoadComplete, but that races on TRAIT_CONFIG_UPDATED
        -- and shouldn't be the only thing closing the panel.
        if diffListPanel then diffListPanel:Hide() end

        -- Activation pathway, in priority order. Prefer 12.0.5's purpose-built
        -- C_ClassTalents.SwitchTo* engine entry points (which fire the matching
        -- CLASS_TALENTS_SWITCH_TO_LOADOUT_BY_* events and run the native cast-bar
        -- pipeline). Fall back to the documented C_ClassTalents.LoadConfig on
        -- environments where those aren't present.

        local function startWatchdog()
            swapInProgress = true
            TalentDiff:UpdateSwapButton()
            -- StaticPopup-cancel paths don't fire TRAIT_CONFIG_UPDATED, so clear the
            -- in-flight flag after a short window so the button doesn't lock forever.
            C_Timer.After(5, function()
                if swapInProgress then
                    swapInProgress = false
                    if TalentDiff.UpdateSwapButton then TalentDiff:UpdateSwapButton() end
                end
            end)
        end

        -- 1. C_ClassTalents.SwitchToLoadoutByName — added in 12.0.5 as the
        --    canonical engine entry point for "switch to a saved loadout."
        --    Mirrors what /lon does and fires CLASS_TALENTS_SWITCH_TO_LOADOUT_BY_NAME.
        local info = C_Traits and C_Traits.GetConfigInfo and C_Traits.GetConfigInfo(cid) or nil
        local name = info and info.name or nil
        if name and C_ClassTalents and C_ClassTalents.SwitchToLoadoutByName then
            C_ClassTalents.SwitchToLoadoutByName(name)
            startWatchdog()
            return
        end

        -- 2. ClassTalentHelper.SwitchToLoadoutByName — the slash-command helper
        --    (Blizzard_ChatFrame). Auto-loads PlayerSpellsFrame if needed and
        --    routes through TalentsFrame:LoadConfigByName → LoadConfigInternal.
        --    Used when the new C_ClassTalents.SwitchTo* engine API isn't available.
        if name and ClassTalentHelper and ClassTalentHelper.SwitchToLoadoutByName then
            ClassTalentHelper.SwitchToLoadoutByName(name)
            startWatchdog()
            return
        end

        -- 3. Last-resort raw API. Documented and stable since 10.0, but raw
        --    LoadConfig bypasses the talent frame's SetCommitStarted wrapper so
        --    the cast-bar UI may not animate; the engine still performs the swap.
        if C_ClassTalents and C_ClassTalents.LoadConfig then
            local result, changeError = C_ClassTalents.LoadConfig(cid, true)
            if Enum and Enum.LoadConfigResult and result == Enum.LoadConfigResult.Error then
                TalentDiff:Print("Swap failed: " .. tostring(changeError or "unknown error"))
                return
            end
            startWatchdog()
        end
    end)

    swapButton:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Swap To", 1, 1, 1)
        local sel = TalentDiff.state.compareConfigID
        local activeID = TalentDiff:GetActiveConfigID()
        if not sel then
            GameTooltip:AddLine("Select a loadout in the Compare To dropdown first.", 1, 0.6, 0.6, true)
        elseif swapInProgress then
            GameTooltip:AddLine("Swap in progress…", 1, 0.82, 0, true)
        elseif InCombatLockdown and InCombatLockdown() then
            GameTooltip:AddLine("Cannot swap during combat.", 1, 0.6, 0.6, true)
        elseif activeID and sel == activeID then
            GameTooltip:AddLine("This loadout is already active.", 1, 0.82, 0, true)
        else
            GameTooltip:AddLine("Activate the selected loadout.", 1, 1, 1, true)
        end
        GameTooltip:Show()
    end)
    swapButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- "Show Diff" toggle button — opens/closes the floating per-row diff list panel.
    -- Hidden whenever there is no active comparison (UpdateDiffListToggle handles state).
    diffListToggle = CreateFrame("Button", "TalentDiffListToggle", talentFrame, "UIPanelButtonTemplate")
    diffListToggle:SetSize(90, 22)
    diffListToggle:SetText("Show Diff")
    diffListToggle:SetPoint("LEFT", swapButton, "RIGHT", 4, 0)
    diffListToggle:SetScript("OnClick", function()
        TalentDiff:ToggleDiffPanel()
    end)
    diffListToggle:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Show Diff", 1, 1, 1)
        GameTooltip:AddLine("Open a list of every talent that will be added, removed, swapped, or re-ranked when applying the compared loadout.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    diffListToggle:SetScript("OnLeave", function() GameTooltip:Hide() end)
    diffListToggle:Hide()

    -- Cog/settings icon button immediately right of Show Diff. Toggles the
    -- TalentDiff options frame. Sized 22x22 to feel proportionate against the
    -- 22px-tall UIPanelButtons. Texture: Interface\Buttons\UI-OptionsButton —
    -- a Blizzard-shipped gear icon that's been stable across patches.
    optionsCogButton = CreateFrame("Button", "TalentDiffOptionsCog", talentFrame)
    optionsCogButton:SetSize(22, 22)
    optionsCogButton:SetPoint("LEFT", diffListToggle, "RIGHT", 4, 0)

    local cogTex = optionsCogButton:CreateTexture(nil, "ARTWORK")
    cogTex:SetAllPoints(optionsCogButton)
    cogTex:SetTexture("Interface\\Buttons\\UI-OptionsButton")
    optionsCogButton.tex = cogTex

    -- Highlight texture: standard Blizzard button glow on hover.
    local cogHi = optionsCogButton:CreateTexture(nil, "HIGHLIGHT")
    cogHi:SetAllPoints(optionsCogButton)
    cogHi:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    cogHi:SetBlendMode("ADD")

    optionsCogButton:SetScript("OnClick", function()
        if TalentDiff.ToggleOptions then TalentDiff:ToggleOptions() end
    end)
    optionsCogButton:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("TalentDiff Options", 1, 1, 1)
        GameTooltip:AddLine("Tune overlay color, thickness, alpha, and the breathing animation.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    optionsCogButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

    return compareDropdown
end

function TalentDiff:UpdateCompareControl()
    if not compareDropdown then
        return
    end
    local sel = self.state.compareConfigID
    if not sel then
        UIDropDownMenu_SetText(compareDropdown, "Compare to: <none>")
    else
        local info = C_Traits and C_Traits.GetConfigInfo and C_Traits.GetConfigInfo(sel)
        UIDropDownMenu_SetText(compareDropdown, "Compare to: " .. ((info and info.name) or "?"))
    end
    self:UpdateSwapButton()
    self:UpdateDiffListToggle()
    self:UpdateDiffPanel()
end

-- Show/hide the "Show Diff" toggle based on whether a comparison is active.
-- The panel itself is hidden separately when comparison clears.
function TalentDiff:UpdateDiffListToggle()
    if not diffListToggle then return end
    if self.state.compareConfigID then
        diffListToggle:Show()
    else
        diffListToggle:Hide()
        if diffListPanel then diffListPanel:Hide() end
    end
end

-- Called from Core.lua on TRAIT_CONFIG_UPDATED / CONFIG_COMMIT_FAILED /
-- SELECTED_LOADOUT_CHANGED so the mid-flight Swap state can release once
-- Blizzard finishes (or aborts) the load. If the swap we initiated actually
-- succeeded — i.e. the now-active loadout matches what we asked for — also
-- clear the comparison so the UI returns to its neutral state.
function TalentDiff:NotifyLoadComplete()
    local wasInFlight = swapInProgress
    swapInProgress = false

    if wasInFlight then
        local sel = self.state.compareConfigID
        local activeID = self:GetActiveConfigID()
        if sel and activeID and sel == activeID then
            -- Successful swap: the requested loadout is now the active one.
            -- ClearComparison handles overlay drop, dropdown text reset, and
            -- swap-button refresh in one call.
            self:ClearComparison()
            return
        end
    end

    if swapButton then self:UpdateSwapButton() end
end

function TalentDiff:UpdateSwapButton()
    if not swapButton then return end
    local sel = self.state.compareConfigID
    local activeID = self:GetActiveConfigID()
    local inCombat = InCombatLockdown and InCombatLockdown() or false
    local enabled = sel ~= nil
        and not inCombat
        and not swapInProgress
        and not (activeID ~= nil and sel == activeID)
    if enabled then
        swapButton:Enable()
    else
        swapButton:Disable()
    end
end

-- ---------- Diff list panel -----------------------------------------------

-- Native-feeling backdrop matching Blizzard's BackdropTemplate panels.
local PANEL_BACKDROP = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

local function ShowRowTooltip(row)
    if not GameTooltip then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    -- Prefer the spell tooltip for the resolved entry — this matches what the
    -- native talent button shows. If we couldn't resolve a spellID (rare;
    -- choice nodes without spell payloads), fall back to a plain text header.
    local data = row._diffRow
    if data and data.spellID and GameTooltip.SetSpellByID then
        GameTooltip:SetSpellByID(data.spellID)
    else
        GameTooltip:SetText(data and data.name or "?", 1, 1, 1)
    end
    if data and data.nodeID then
        AppendTooltipForNode(GameTooltip, data.nodeID)
    end
    GameTooltip:Show()
end

-- Row pool keyed per-column so left/right scroll independently.
local function GetOrCreateColumnRow(column, index)
    local row = column.rows[index]
    if row then return row end

    row = CreateFrame("Frame", nil, column.content)
    row:SetHeight(ROW_HEIGHT)

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(ROW_ICON_SZ, ROW_ICON_SZ)
    icon:SetPoint("LEFT", row, "LEFT", ROW_PAD_X, 0)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.icon = icon

    local label = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("LEFT",  icon, "RIGHT", 6, 0)
    label:SetPoint("RIGHT", row,  "RIGHT", -ROW_PAD_X, 0)
    label:SetJustifyH("LEFT")
    label:SetWordWrap(false)
    row.label = label

    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self) ShowRowTooltip(self) end)
    row:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

    column.rows[index] = row
    return row
end

-- Rows in this two-column layout are always single-side:
--   side = "removed" → red, REMOVED-style (left column)
--   side = "added"   → green, ADDED-style (right column)
-- CHANGED splits into two entries (one each side); RANK lands on the side
-- matching the sign of (savedRank - currentRank).
local function ApplyColumnRow(row, entry)
    row._diffRow = entry
    if entry.icon then row.icon:SetTexture(entry.icon) else row.icon:SetTexture(FALLBACK_ICON) end
    row.icon:SetDesaturated(entry.side == "removed")

    local hex = (entry.side == "removed") and StatusHex(STATUS.REMOVED) or StatusHex(STATUS.ADDED)
    local sigil = (entry.side == "removed") and "- " or "+ "
    local suffix = entry.suffix or ""
    row.label:SetText(string.format("|cff%s%s%s|r%s", hex, sigil, entry.name or "?", suffix))
    row:Show()
end

-- Persist current panel position into SavedVariables so it returns to the
-- exact spot on /reload. Called from the drag-stop handler.
local function SavePanelPosition(panel)
    if not TalentDiffDB then return end
    local point, _, relativePoint, x, y = panel:GetPoint(1)
    if not point then return end
    TalentDiffDB.panel = TalentDiffDB.panel or {}
    TalentDiffDB.panel.point = point
    TalentDiffDB.panel.relativePoint = relativePoint
    TalentDiffDB.panel.x = x
    TalentDiffDB.panel.y = y
end

-- Restore saved panel position; if none, anchor to screen center as a sane
-- first-run default. Anchored to UIParent because the panel is detached.
local function RestorePanelPosition(panel)
    panel:ClearAllPoints()
    local p = TalentDiffDB and TalentDiffDB.panel or nil
    if p and p.point then
        panel:SetPoint(p.point, UIParent, p.relativePoint or p.point, p.x or 0, p.y or 0)
    else
        panel:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
end

local function BuildColumn(panel, key, title, anchorOpts)
    -- One column inside the panel: header + scroll + content. Rows are pooled
    -- per-column so left and right lists scroll independently.
    local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    header:SetPoint("TOPLEFT",  panel, "TOPLEFT",  anchorOpts.headerLeft,  -50)
    header:SetPoint("TOPRIGHT", panel, "TOPLEFT",  anchorOpts.headerRight, -50)
    header:SetJustifyH("LEFT")
    header:SetText(title)

    local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT",     panel, "TOPLEFT",     anchorOpts.scrollLeft,  -70)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMLEFT",  anchorOpts.scrollRight,  12)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(1, 1)
    scroll:SetScrollChild(content)

    panel[key] = { header = header, scroll = scroll, content = content, rows = {} }
    return panel[key]
end

local function EnsureDiffPanel()
    if diffListPanel then return diffListPanel end

    -- Detached, draggable panel parented to UIParent so it survives the
    -- talent frame closing and remains positionable anywhere on screen.
    local panel = CreateFrame("Frame", "TalentDiffListPanel", UIParent, "BackdropTemplate")
    panel:SetSize(420, 380)
    panel:SetFrameStrata("HIGH")
    panel:SetBackdrop(PANEL_BACKDROP)
    panel:SetBackdropColor(0, 0, 0, 0.88)
    panel:SetClampedToScreen(true)
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePanelPosition(self)
    end)
    panel:Hide()

    RestorePanelPosition(panel)

    -- Header title.
    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", panel, "TOP", 0, -10)
    title:SetText("Loadout Diff")
    panel.title = title

    -- Counts line under the header — same at-a-glance summary as before.
    local counts = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    counts:SetPoint("TOP", title, "BOTTOM", 0, -2)
    counts:SetJustifyH("CENTER")
    panel.counts = counts

    -- Close button (top-right).
    local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 2, 2)
    close:SetScript("OnClick", function() panel:Hide() end)

    -- Two columns. Geometry: 420 wide, 12px outer pad, 8px gutter → 196 each.
    -- Headers + scrolls share the same x-offsets so the visual gutter is clean.
    BuildColumn(panel, "leftCol", "|cff" .. StatusHex(STATUS.REMOVED) .. "Removed|r",
        { headerLeft = 16, headerRight = 16 + 196, scrollLeft = 16, scrollRight = 16 + 196 - 18 })
    BuildColumn(panel, "rightCol", "|cff" .. StatusHex(STATUS.ADDED) .. "Added|r",
        { headerLeft = 220, headerRight = 220 + 196, scrollLeft = 220, scrollRight = 220 + 196 - 18 })

    -- Vertical divider between the two columns.
    local divider = panel:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(1, 1, 1, 0.15)
    divider:SetWidth(1)
    divider:SetPoint("TOP",    panel, "TOP",    0, -50)
    divider:SetPoint("BOTTOM", panel, "BOTTOM", 0,  12)
    panel.divider = divider

    -- Empty-state placeholders, one per column.
    panel.leftCol.empty = panel:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    panel.leftCol.empty:SetPoint("CENTER", panel.leftCol.scroll, "CENTER", 0, 0)
    panel.leftCol.empty:SetText("Nothing removed.")
    panel.leftCol.empty:Hide()

    panel.rightCol.empty = panel:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    panel.rightCol.empty:SetPoint("CENTER", panel.rightCol.scroll, "CENTER", 0, 0)
    panel.rightCol.empty:SetText("Nothing added.")
    panel.rightCol.empty:Hide()

    diffListPanel = panel
    return panel
end

-- Convert the diff into two parallel column lists. Each entry carries the
-- nodeID (so hover tooltips can call AppendTooltipForNode) and a side-specific
-- spellID/icon/name so the row renders the right talent on each column.
local function PartitionDiffIntoColumns()
    local rows = BuildDiffRowList()
    local left, right = {}, {}
    for _, r in ipairs(rows) do
        if r.status == STATUS.ADDED then
            right[#right + 1] = {
                side = "added", nodeID = r.nodeID,
                icon = r.icon, spellID = r.spellID, name = r.name,
            }
        elseif r.status == STATUS.REMOVED then
            left[#left + 1] = {
                side = "removed", nodeID = r.nodeID,
                icon = r.icon, spellID = r.spellID, name = r.name,
            }
        elseif r.status == STATUS.CHANGED then
            -- Split across columns: old → REMOVED side, new → ADDED side.
            -- The row-data alt* fields hold the "old" copy; primary fields hold "new".
            left[#left + 1] = {
                side = "removed", nodeID = r.nodeID,
                icon = r.altIcon, spellID = r.altSpellID, name = r.altName or "?",
            }
            right[#right + 1] = {
                side = "added", nodeID = r.nodeID,
                icon = r.icon, spellID = r.spellID, name = r.name or "?",
            }
        end
        -- RANK rows are intentionally omitted from the column lists; rank-only
        -- deltas remain visible in the header counts and on the tree overlay.
    end
    local function byName(a, b) return (a.name or "") < (b.name or "") end
    table.sort(left, byName)
    table.sort(right, byName)
    return left, right
end

local function LayoutColumn(column, entries)
    for i, entry in ipairs(entries) do
        local row = GetOrCreateColumnRow(column, i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT",  column.content, "TOPLEFT",  0, -((i - 1) * (ROW_HEIGHT + ROW_GAP_Y)))
        row:SetPoint("TOPRIGHT", column.content, "TOPRIGHT", 0, -((i - 1) * (ROW_HEIGHT + ROW_GAP_Y)))
        ApplyColumnRow(row, entry)
    end
    for i = #entries + 1, #column.rows do
        column.rows[i]:Hide()
    end
    local total = #entries * (ROW_HEIGHT + ROW_GAP_Y)
    column.content:SetHeight(math.max(total, 1))
    column.content:SetWidth(column.scroll:GetWidth())
    if #entries == 0 then column.empty:Show() else column.empty:Hide() end
end

local function RebuildDiffRows()
    if not diffListPanel then return end
    local left, right = PartitionDiffIntoColumns()
    LayoutColumn(diffListPanel.leftCol,  left)
    LayoutColumn(diffListPanel.rightCol, right)
end

function TalentDiff:UpdateDiffPanel()
    if not diffListPanel or not diffListPanel:IsShown() then return end
    if not self.state.compareConfigID then
        diffListPanel:Hide()
        return
    end
    local diff = self:GetDiff()
    local s = diff and diff.summary or nil
    if s and diffListPanel.counts then
        diffListPanel.counts:SetFormattedText(
            "|cff%s+%d|r  |cff%s-%d|r  |cff%s~%d|r",
            StatusHex(STATUS.ADDED),   s.added   or 0,
            StatusHex(STATUS.REMOVED), s.removed or 0,
            StatusHex(STATUS.CHANGED), s.changed or 0)
    end
    RebuildDiffRows()
end

function TalentDiff:ToggleDiffPanel()
    EnsureDiffPanel()
    if diffListPanel:IsShown() then
        diffListPanel:Hide()
    else
        if not self.state.compareConfigID then return end
        diffListPanel:Show()
        self:UpdateDiffPanel()
    end
end

-- ---------- Tooltip hook ---------------------------------------------------

function AppendTooltipForNode(tooltip, nodeID)
    local nd = TalentDiff:GetNodeDiff(nodeID)
    if not nd then return end
    local visual = OverlayManager and OverlayManager:GetVisual(nd.status) or nil
    if not visual then return end

    -- Prefix hex is sourced from the OverlayManager visual table via StatusHex
    -- so palette tweaks in one place propagate to both overlays and tooltip text.
    tooltip:AddLine(" ")
    if nd.status == STATUS.ADDED then
        tooltip:AddLine("|cff" .. StatusHex(STATUS.ADDED) .. "TalentDiff:|r Will be added by compared loadout"
            .. ((nd.savedName and (" — " .. nd.savedName)) or ""), 1, 1, 1)
    elseif nd.status == STATUS.REMOVED then
        tooltip:AddLine("|cff" .. StatusHex(STATUS.REMOVED) .. "TalentDiff:|r Will be removed by compared loadout"
            .. ((nd.currentName and (" — " .. nd.currentName)) or ""), 1, 1, 1)
    elseif nd.status == STATUS.CHANGED then
        tooltip:AddLine("|cff" .. StatusHex(STATUS.CHANGED) .. "TalentDiff:|r Compared loadout picks "
            .. (nd.savedName or "?") .. " (current: " .. (nd.currentName or "?") .. ")", 1, 1, 1)
    elseif nd.status == STATUS.RANK then
        tooltip:AddLine(string.format("|cff%sTalentDiff:|r Compared loadout changes rank %d \194\187 %d",
            StatusHex(STATUS.RANK), nd.currentRank or 0, nd.savedRank or 0), 1, 1, 1)
    end
    tooltip:Show()
end

local function HookTooltips(talentFrame)
    if hookedTooltips or not talentFrame then return end
    hookedTooltips = true

    -- Each talent button calls a method to populate its tooltip; hook the post-call.
    -- We hook the buttons lazily as they appear by hooking a refresh point.
    local function HookButton(button)
        if button._talentDiffHooked then return end
        button._talentDiffHooked = true
        button:HookScript("OnEnter", function(self)
            local nodeID = GetButtonNodeID(self)
            if nodeID and GameTooltip and GameTooltip:IsOwned(self) then
                AppendTooltipForNode(GameTooltip, nodeID)
            end
        end)
    end

    -- Hook all currently visible buttons + any future button via talentFrame's update.
    for button in IterTalentButtons(talentFrame) do
        HookButton(button)
    end
    -- Lazy-hook newly-revealed buttons on each open. The HookTalentFrame OnShow
    -- below handles refresh/control updates, so this handler is button-hooks only.
    if talentFrame.HookScript then
        talentFrame:HookScript("OnShow", function()
            for button in IterTalentButtons(talentFrame) do HookButton(button) end
        end)
    end
end

-- ---------- Talent frame integration ---------------------------------------

local function HookTalentFrame()
    if hookedTalentFrame then return end
    local talentFrame = GetTalentFrame()
    if not talentFrame then return end
    hookedTalentFrame = true

    EnsureCompareDropdown(talentFrame)
    HookTooltips(talentFrame)

    talentFrame:HookScript("OnShow", function()
        TalentDiff:UpdateCompareControl()
        TalentDiff:RefreshOverlays()
    end)
    talentFrame:HookScript("OnHide", function()
        -- Single authoritative cleanup path: drop every painted overlay so the
        -- next OnShow paints from a clean state. The active set is the source
        -- of truth; we don't need to re-iterate buttons here.
        OverlayManager:ClearAll()
        if diffListPanel then diffListPanel:Hide() end
        -- Options frame piggy-backs on the talent frame's lifecycle: closing
        -- the talent UI auto-dismisses the (otherwise floating) options window
        -- so no orphaned panel lingers on screen.
        if TalentDiff._optionsFrame then TalentDiff._optionsFrame:Hide() end
    end)

    -- Hook updates that re-layout buttons (rank changes, refunds, switches).
    if talentFrame.UpdateTreeCurrencyInfo then
        hooksecurefunc(talentFrame, "UpdateTreeCurrencyInfo", function()
            if TalentDiff.state.compareConfigID then
                TalentDiff:MarkDirty()
            end
        end)
    end
    if talentFrame.SetTalentTreeID then
        hooksecurefunc(talentFrame, "SetTalentTreeID", function()
            if TalentDiff.state.compareConfigID then
                TalentDiff:MarkDirty()
            end
        end)
    end
end

-- Defers HookTalentFrame to the moment PlayerSpellsFrame is actually shown.
-- Running at ADDON_LOADED of Blizzard_PlayerSpells happens BEFORE the talent
-- frame's first OnShow → InitializeLoadSystem → RefreshLoadoutOptions has
-- finished populating LoadSystem.possibleSelections. Hooking that early — and
-- in particular creating a child UIDropDownMenuTemplate frame parented to
-- TalentsFrame — appeared to race the native LoadSystem's setup, leaving the
-- dropdown stuck on "Default Loadout" after /reload + N. Deferring to first
-- OnShow guarantees the native setup finishes first.
local function ArmDeferredHook()
    if hookedTalentFrame then return end
    if not PlayerSpellsFrame or not PlayerSpellsFrame.HookScript then return end
    PlayerSpellsFrame:HookScript("OnShow", function()
        if hookedTalentFrame then return end
        HookTalentFrame()
        if hookedTalentFrame then
            -- HookScript inside OnShow doesn't fire its own added handler this
            -- pass, so prime our overlays/control state for the current open.
            TalentDiff:UpdateCompareControl()
            TalentDiff:RefreshOverlays()
        end
    end)
end

function TalentDiff:OnInit()
    -- SavedVariablesPerCharacter — populated by the engine before our
    -- ADDON_LOADED fires. Seed missing fields so first-run defaults are sane.
    TalentDiffDB = TalentDiffDB or {}
    TalentDiffDB.panel = TalentDiffDB.panel or {}

    -- Blizzard's PlayerSpellsFrame lives in the Blizzard_PlayerSpells addon.
    -- Wait for it to load, then arm the deferred hook on its first OnShow.
    if C_AddOns.IsAddOnLoaded("Blizzard_PlayerSpells") then
        ArmDeferredHook()
        return
    end

    local watcher = CreateFrame("Frame")
    watcher:RegisterEvent("ADDON_LOADED")
    watcher:SetScript("OnEvent", function(frame, _, name)
        if name == "Blizzard_PlayerSpells" then
            frame:UnregisterAllEvents()
            ArmDeferredHook()
        end
    end)
end
