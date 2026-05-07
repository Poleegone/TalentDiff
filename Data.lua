local TalentDiff = TalentDiff

local function GetActiveConfigID()
    -- The "active" saved loadout — the configID the player currently has applied
    -- via Blizzard's loadout dropdown. C_ClassTalents.GetActiveConfigID() returns
    -- the *base spec config* (a separate container, never one of the saved
    -- loadouts), so equality checks against saved-loadout IDs would never match.
    -- GetLastSelectedSavedConfigID(specID) is the canonical "currently selected
    -- loadout" indicator — this is what Blizzard's own ClassTalentsFrameMixin
    -- uses to restore the dropdown selection on OnShow.
    if C_ClassTalents and C_ClassTalents.GetLastSelectedSavedConfigID then
        local specIndex = GetSpecialization and GetSpecialization() or nil
        local specID = specIndex and select(1, GetSpecializationInfo(specIndex)) or nil
        if specID then
            local id = C_ClassTalents.GetLastSelectedSavedConfigID(specID)
            if id then return id end
        end
    end
    return nil
end

-- Returns a list of {configID, name, isActive} for the player's saved Blizzard
-- loadouts for the *current* spec. Uses C_ClassTalents APIs only — no addon storage.
function TalentDiff:GetSavedLoadouts()
    local list = {}
    if not C_ClassTalents or not C_ClassTalents.GetConfigIDsBySpecID then
        return list
    end

    local specIndex = GetSpecialization and GetSpecialization() or nil
    if not specIndex then return list end
    local specID = select(1, GetSpecializationInfo(specIndex))
    if not specID then return list end

    local activeID = GetActiveConfigID()
    local ids = C_ClassTalents.GetConfigIDsBySpecID(specID) or {}
    for _, configID in ipairs(ids) do
        local info = C_Traits and C_Traits.GetConfigInfo and C_Traits.GetConfigInfo(configID)
        if info then
            list[#list + 1] = {
                configID = configID,
                name = info.name or ("Loadout " .. tostring(configID)),
                isActive = (configID == activeID),
            }
        end
    end

    table.sort(list, function(a, b) return (a.name or "") < (b.name or "") end)
    return list
end

-- Resolve a friendly name for a node's active entry (spell / choice talent).
local function GetEntryName(configID, entryID)
    if not configID or not entryID or entryID == 0 then return nil end
    if not C_Traits or not C_Traits.GetEntryInfo then return nil end
    local entryInfo = C_Traits.GetEntryInfo(configID, entryID)
    if not entryInfo or not entryInfo.definitionID then return nil end
    local defInfo = C_Traits.GetDefinitionInfo(entryInfo.definitionID)
    if not defInfo then return nil end
    if defInfo.overriddenSpellID and defInfo.overriddenSpellID > 0 and GetSpellInfo then
        local n = GetSpellInfo(defInfo.overriddenSpellID); if n then return n end
    end
    if defInfo.spellID and defInfo.spellID > 0 and GetSpellInfo then
        local n = GetSpellInfo(defInfo.spellID); if n then return n end
    end
    return defInfo.overrideName
end

-- Read a single configID's nodes into a node-keyed map: { [nodeID] = { rank, entryID, name } }.
-- A node is included only if it has rank > 0 (i.e. is selected).
function TalentDiff:ReadConfig(configID)
    local out = {}
    if not configID or not C_Traits then return out end
    local configInfo = C_Traits.GetConfigInfo(configID)
    if not configInfo or not configInfo.treeIDs then return out end

    for _, treeID in ipairs(configInfo.treeIDs) do
        local nodeIDs = C_Traits.GetTreeNodes(treeID) or {}
        for _, nodeID in ipairs(nodeIDs) do
            local nodeInfo = C_Traits.GetNodeInfo(configID, nodeID)
            if nodeInfo then
                -- Equality must use what the loadout *stored*, not the runtime sum.
                -- currentRank includes granted/auto ranks that aren't always serialised
                -- symmetrically into saved configs, producing spurious diffs.
                local purchased = (nodeInfo.ranksPurchased or 0) + (nodeInfo.ranksIncreased or 0)
                if purchased > 0 then
                    local activeEntry = nodeInfo.activeEntry
                    local entryID = activeEntry and activeEntry.entryID or nil
                    -- SubTreeSelection: subTreeID is the stable identity of the chosen
                    -- hero tree; entryID can vary across configs while subTreeID matches.
                    if Enum and Enum.TraitNodeType and nodeInfo.type == Enum.TraitNodeType.SubTreeSelection then
                        entryID = (activeEntry and activeEntry.subTreeID) or entryID
                    end
                    out[nodeID] = {
                        rank = purchased,
                        entryID = entryID,
                        name = GetEntryName(configID, activeEntry and activeEntry.entryID or nil),
                    }
                end
            end
        end
    end
    return out
end

function TalentDiff:ReadCurrent()
    -- Diffing reads from the live applied talents, which live in the base spec
    -- config (C_ClassTalents.GetActiveConfigID), NOT in any saved loadout's
    -- configID. The saved-loadout ID is just a label/snapshot for the dropdown.
    local liveID = C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_ClassTalents.GetActiveConfigID() or nil
    return self:ReadConfig(liveID)
end

function TalentDiff:GetActiveConfigID()
    return GetActiveConfigID()
end
