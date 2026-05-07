local addonName, ns = ...

TalentDiff = TalentDiff or {}
local TalentDiff = TalentDiff
ns.TalentDiff = TalentDiff

TalentDiff.name = addonName
TalentDiff.frame = CreateFrame("Frame", "TalentDiffEventFrame")

-- Comparison state.
TalentDiff.state = {
    compareConfigID = nil,    -- selected Blizzard loadout configID (nil = none)
    classID = nil,            -- class of selected loadout
    specID = nil,             -- spec of selected loadout
    diff = nil,               -- cached diff result, see Compare.lua
    dirty = true,             -- needs recompute
}

function TalentDiff:Print(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffTalentDiff|r: " .. tostring(msg))
    end
end

function TalentDiff:MarkDirty()
    self.state.dirty = true
    if self.state.compareConfigID and self.RefreshOverlays then
        self:RefreshOverlays()
    end
end

function TalentDiff:ClearComparison()
    self.state.compareConfigID = nil
    self.state.classID = nil
    self.state.specID = nil
    self.state.diff = nil
    self.state.dirty = true
    if self.RefreshOverlays then self:RefreshOverlays() end
    if self.UpdateCompareControl then self:UpdateCompareControl() end
end

function TalentDiff:SetComparisonLoadout(configID)
    if not configID then
        self:ClearComparison()
        return
    end
    if not C_Traits or not C_Traits.GetConfigInfo then
        self:ClearComparison()
        return
    end
    local info = C_Traits.GetConfigInfo(configID)
    if not info then
        self:ClearComparison()
        return
    end

    local _, _, classID = UnitClass("player")
    local specIndex = GetSpecialization and GetSpecialization() or nil
    local currentSpecID = specIndex and select(1, GetSpecializationInfo(specIndex)) or nil

    -- Spec-safety: only allow loadouts for the current spec.
    if info.specID and currentSpecID and info.specID ~= currentSpecID then
        self:Print("Loadout is for a different spec; clearing comparison.")
        self:ClearComparison()
        return
    end

    self.state.compareConfigID = configID
    self.state.classID = classID
    self.state.specID = currentSpecID
    self.state.dirty = true
    if self.RefreshOverlays then self:RefreshOverlays() end
    if self.UpdateCompareControl then self:UpdateCompareControl() end
end

local function OnEvent(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        if TalentDiff.OnInit then TalentDiff:OnInit() end
    elseif event == "PLAYER_ENTERING_WORLD" then
        TalentDiff:MarkDirty()
        if TalentDiff.UpdateCompareControl then TalentDiff:UpdateCompareControl() end
    elseif event == "TRAIT_CONFIG_UPDATED" or event == "CONFIG_COMMIT_FAILED" or event == "TRAIT_CONFIG_LIST_UPDATED" then
        if TalentDiff.NotifyLoadComplete then TalentDiff:NotifyLoadComplete() end
        TalentDiff:MarkDirty()
        if TalentDiff.UpdateCompareControl then TalentDiff:UpdateCompareControl() end
    elseif event == "SELECTED_LOADOUT_CHANGED" then
        -- Fires when the active saved loadout changes (the engine's authoritative
        -- "which saved loadout is now applied" signal). Re-evaluate the swap button
        -- immediately so the UI reflects the new active state without waiting for
        -- the slower TRAIT_CONFIG_UPDATED that follows on full commits.
        if TalentDiff.NotifyLoadComplete then TalentDiff:NotifyLoadComplete() end
        TalentDiff:MarkDirty()
        if TalentDiff.UpdateCompareControl then TalentDiff:UpdateCompareControl() end
    elseif event == "PLAYER_SPECIALIZATION_CHANGED" or event == "ACTIVE_PLAYER_SPECIALIZATION_CHANGED" then
        -- Spec change may invalidate the chosen comparison loadout.
        if TalentDiff.state.compareConfigID then
            TalentDiff:SetComparisonLoadout(TalentDiff.state.compareConfigID)
        end
        if TalentDiff.UpdateCompareControl then TalentDiff:UpdateCompareControl() end
    elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        -- LoadConfig is protected; toggle Swap button enable state on combat boundaries.
        if TalentDiff.UpdateSwapButton then TalentDiff:UpdateSwapButton() end
    end
end

TalentDiff.frame:RegisterEvent("ADDON_LOADED")
TalentDiff.frame:RegisterEvent("PLAYER_ENTERING_WORLD")
TalentDiff.frame:RegisterEvent("TRAIT_CONFIG_UPDATED")
TalentDiff.frame:RegisterEvent("TRAIT_CONFIG_LIST_UPDATED")
TalentDiff.frame:RegisterEvent("CONFIG_COMMIT_FAILED")
TalentDiff.frame:RegisterEvent("SELECTED_LOADOUT_CHANGED")
TalentDiff.frame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
TalentDiff.frame:RegisterEvent("PLAYER_REGEN_DISABLED")
TalentDiff.frame:RegisterEvent("PLAYER_REGEN_ENABLED")
TalentDiff.frame:SetScript("OnEvent", OnEvent)

SLASH_TALENTDIFF1 = "/td"
SLASH_TALENTDIFF2 = "/talentdiff"
SlashCmdList["TALENTDIFF"] = function(msg)
    msg = msg and msg:lower():gsub("^%s+", ""):gsub("%s+$", "") or ""
    if msg == "clear" or msg == "off" then
        TalentDiff:ClearComparison()
        TalentDiff:Print("Comparison cleared.")
        return
    end
    TalentDiff:Print("Open the talent UI and use the 'Compare To' selector. /td clear to disable.")
end
