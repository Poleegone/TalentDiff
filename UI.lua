local TalentDiff = TalentDiff

local STATUS = TalentDiff.STATUS or {}

-- Indexed by STATUS value (see Compare.lua).
-- ADDED = green, REMOVED = red, CHANGED = amber, RANK = light blue.
local STATUS_VISUAL = {
    [1] = { color = {0.20, 0.95, 0.35, 1.0} }, -- ADDED
    [2] = { color = {1.00, 0.20, 0.20, 1.0} }, -- REMOVED
    [3] = { color = {1.00, 0.70, 0.10, 1.0} }, -- CHANGED
    [4] = { color = {0.40, 0.75, 1.00, 1.0} }, -- RANK
}

-- Verified-existing retail textures. WHITE8x8 builds the thin per-side outline strips;
-- IconBorder-GlowRing is a clean hollow circle for the underlying halo on circular nodes.
local LINE_TEXTURE = "Interface\\Buttons\\WHITE8x8"
local GLOW_TEXTURE = "Interface\\Buttons\\IconBorder-GlowRing"

-- Outline geometry.
local EDGE_THICK   = 2     -- strip thickness in pixels
local EDGE_INSET   = 2     -- distance outside the button's edge
local GLOW_PAD     = 3     -- glow texture extends this many px outside the button

local compareDropdown          -- the "Compare To" dropdown frame
local swapButton                -- the "Swap To" button next to the dropdown
local swapInProgress = false    -- true between LoadInProgress and TRAIT_CONFIG_UPDATED/CONFIG_COMMIT_FAILED
local overlayPool = {}          -- recycle overlay textures keyed by node button
local hookedTalentFrame = false
local hookedTooltips = false

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

-- True for nodes that visually render as a circle (passives). Choice (Selection) and
-- hero sub-tree picker nodes are wider/asymmetric and should NOT receive the circular halo.
local function IsCircularNode(button)
    if not button or not button.GetNodeInfo then return false end
    local ok, info = pcall(button.GetNodeInfo, button)
    if not ok or not info or not Enum or not Enum.TraitNodeType then return false end
    if info.type == Enum.TraitNodeType.Selection then return false end
    if info.type == Enum.TraitNodeType.SubTreeSelection then return false end
    return true
end

-- ---------- Overlay --------------------------------------------------------

local function ReleaseOverlay(button)
    local ov = overlayPool[button]
    if ov then ov:Hide() end
end

local function GetOrCreateOverlay(button)
    local ov = overlayPool[button]
    if ov then return ov end

    ov = CreateFrame("Frame", nil, button)
    ov:EnableMouse(false)  -- never block node interaction
    ov:SetFrameLevel((button:GetFrameLevel() or 1) + 7)
    ov:SetAllPoints(button)

    -- Soft circular halo behind the strip outline; only shown for circular (passive) nodes.
    -- IconBorder-GlowRing is a clean white/grey hollow circle that tints under SetVertexColor.
    local glow = ov:CreateTexture(nil, "BACKGROUND", nil, -1)
    glow:SetTexture(GLOW_TEXTURE)
    glow:SetBlendMode("ADD")
    glow:SetPoint("TOPLEFT", ov, "TOPLEFT", -GLOW_PAD, GLOW_PAD)
    glow:SetPoint("BOTTOMRIGHT", ov, "BOTTOMRIGHT", GLOW_PAD, -GLOW_PAD)
    glow:Hide()
    ov.glow = glow

    -- Four thin per-side strips form a shape-agnostic outline that traces whatever rectangular
    -- bounding box the node uses (square actives, wide choice nodes, sub-tree pickers, …).
    local function makeEdge()
        local t = ov:CreateTexture(nil, "OVERLAY", nil, 7)
        t:SetTexture(LINE_TEXTURE)
        return t
    end
    local top, bottom = makeEdge(), makeEdge()
    local left, right = makeEdge(), makeEdge()

    -- Top strip: spans full width, sits EDGE_INSET above the button's top.
    top:SetPoint("BOTTOMLEFT", ov, "TOPLEFT", -EDGE_INSET, EDGE_INSET - EDGE_THICK)
    top:SetPoint("BOTTOMRIGHT", ov, "TOPRIGHT", EDGE_INSET, EDGE_INSET - EDGE_THICK)
    top:SetHeight(EDGE_THICK)

    -- Bottom strip: spans full width, sits EDGE_INSET below the button's bottom.
    bottom:SetPoint("TOPLEFT", ov, "BOTTOMLEFT", -EDGE_INSET, -EDGE_INSET + EDGE_THICK)
    bottom:SetPoint("TOPRIGHT", ov, "BOTTOMRIGHT", EDGE_INSET, -EDGE_INSET + EDGE_THICK)
    bottom:SetHeight(EDGE_THICK)

    -- Left strip: spans full height between the top/bottom strips, sits outside the left edge.
    left:SetPoint("TOPRIGHT", ov, "TOPLEFT", -EDGE_INSET + EDGE_THICK, EDGE_INSET)
    left:SetPoint("BOTTOMRIGHT", ov, "BOTTOMLEFT", -EDGE_INSET + EDGE_THICK, -EDGE_INSET)
    left:SetWidth(EDGE_THICK)

    -- Right strip: mirror of left.
    right:SetPoint("TOPLEFT", ov, "TOPRIGHT", EDGE_INSET - EDGE_THICK, EDGE_INSET)
    right:SetPoint("BOTTOMLEFT", ov, "BOTTOMRIGHT", EDGE_INSET - EDGE_THICK, -EDGE_INSET)
    right:SetWidth(EDGE_THICK)

    ov.edges = { top = top, bottom = bottom, left = left, right = right }

    -- Numeric rank-delta label (corner). Outline font removes the need for a separate shadow.
    local delta = ov:CreateFontString(nil, "OVERLAY", "GameFontNormalOutline")
    delta:SetPoint("BOTTOMRIGHT", ov, "BOTTOMRIGHT", 4, -3)
    delta:SetJustifyH("RIGHT")
    delta:Hide()
    ov.delta = delta

    overlayPool[button] = ov
    return ov
end

local function SetEdgesColor(ov, r, g, b, a)
    for _, e in pairs(ov.edges) do
        e:SetVertexColor(r, g, b, a or 1)
    end
end

local function SetEdgesShown(ov, shown)
    for _, e in pairs(ov.edges) do
        if shown then e:Show() else e:Hide() end
    end
end

local function ApplyOverlay(button, nodeDiff)
    if not nodeDiff then
        ReleaseOverlay(button)
        return
    end
    local visual = STATUS_VISUAL[nodeDiff.status]
    if not visual then
        ReleaseOverlay(button)
        return
    end

    local ov = GetOrCreateOverlay(button)
    local r, g, b = visual.color[1], visual.color[2], visual.color[3]

    -- Priority: rank-only differences show the corner delta and nothing else.
    -- Add/remove/changed show the per-side outline (and a circular halo on round nodes).
    if nodeDiff.status == STATUS.RANK then
        SetEdgesShown(ov, false)
        ov.glow:Hide()
        local d = (nodeDiff.savedRank or 0) - (nodeDiff.currentRank or 0)
        local sign = d > 0 and "+" or ""
        ov.delta:SetText(sign .. tostring(d))
        if d > 0 then
            ov.delta:SetTextColor(0.20, 0.95, 0.35, 1)
        else
            ov.delta:SetTextColor(1.00, 0.25, 0.25, 1)
        end
        ov.delta:Show()
    else
        SetEdgesColor(ov, r, g, b, 1)
        SetEdgesShown(ov, true)
        if IsCircularNode(button) then
            ov.glow:SetVertexColor(r, g, b, 0.55)
            ov.glow:Show()
        else
            ov.glow:Hide()
        end
        ov.delta:Hide()
    end
    ov:Show()
end

function TalentDiff:RefreshOverlays()
    local talentFrame = GetTalentFrame()
    if not talentFrame or not talentFrame:IsShown() then return end

    local diff = self:GetDiff()
    if not diff then
        for button in IterTalentButtons(talentFrame) do
            ReleaseOverlay(button)
        end
        return
    end

    for button in IterTalentButtons(talentFrame) do
        local nodeID = GetButtonNodeID(button)
        local nd = nodeID and diff.byNode[nodeID] or nil
        ApplyOverlay(button, nd)
    end
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

-- ---------- Tooltip hook ---------------------------------------------------

local function AppendTooltipForNode(tooltip, nodeID)
    local nd = TalentDiff:GetNodeDiff(nodeID)
    if not nd then return end
    local visual = STATUS_VISUAL[nd.status]
    if not visual then return end

    tooltip:AddLine(" ")
    if nd.status == STATUS.ADDED then
        tooltip:AddLine("|cff44ff66TalentDiff:|r Will be added by compared loadout"
            .. ((nd.savedName and (" — " .. nd.savedName)) or ""), 1, 1, 1)
    elseif nd.status == STATUS.REMOVED then
        tooltip:AddLine("|cffff5555TalentDiff:|r Will be removed by compared loadout"
            .. ((nd.currentName and (" — " .. nd.currentName)) or ""), 1, 1, 1)
    elseif nd.status == STATUS.CHANGED then
        tooltip:AddLine("|cffffbb33TalentDiff:|r Compared loadout picks "
            .. (nd.savedName or "?") .. " (current: " .. (nd.currentName or "?") .. ")", 1, 1, 1)
    elseif nd.status == STATUS.RANK then
        tooltip:AddLine(string.format("|cff88ccffTalentDiff:|r Compared loadout changes rank %d \194\187 %d",
            nd.currentRank or 0, nd.savedRank or 0), 1, 1, 1)
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
        for button in IterTalentButtons(talentFrame) do
            ReleaseOverlay(button)
        end
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
