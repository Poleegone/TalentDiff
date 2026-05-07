local TalentDiff = TalentDiff

-- Diff status constants.
TalentDiff.STATUS = {
    SAME    = 0,
    ADDED   = 1, -- selected in current, absent from saved loadout
    REMOVED = 2, -- selected in saved loadout, absent from current
    CHANGED = 3, -- different entry chosen (choice node)
    RANK    = 4, -- same entry, different rank
}

-- Recompute diff between current active config and the selected saved loadout.
-- Result: { byNode = { [nodeID] = { status, currentRank, savedRank, currentName, savedName } }, summary = {...} }
function TalentDiff:ComputeDiff()
    local state = self.state
    if not state.compareConfigID then
        state.diff = nil
        state.dirty = false
        return nil
    end

    local current = self:ReadCurrent()
    local saved = self:ReadConfig(state.compareConfigID)

    local byNode = {}
    local addedCount, removedCount, changedCount = 0, 0, 0

    -- Perspective: current active build is the baseline; compared (saved) loadout is the target.
    -- ADDED   = present in compared, absent from current  (will be gained on switch)
    -- REMOVED = present in current,  absent from compared (will be lost on switch)
    -- CHANGED = different entry chosen at the same node
    -- RANK    = same entry, rank delta (savedRank - currentRank)

    for nodeID, cur in pairs(current) do
        local sv = saved[nodeID]
        if not sv then
            byNode[nodeID] = {
                status = self.STATUS.REMOVED,
                currentRank = cur.rank,
                savedRank = 0,
                currentName = cur.name,
                savedName = nil,
            }
            removedCount = removedCount + 1
        elseif sv.entryID ~= cur.entryID then
            byNode[nodeID] = {
                status = self.STATUS.CHANGED,
                currentRank = cur.rank,
                savedRank = sv.rank,
                currentName = cur.name,
                savedName = sv.name,
            }
            changedCount = changedCount + 1
        elseif sv.rank ~= cur.rank then
            byNode[nodeID] = {
                status = self.STATUS.RANK,
                currentRank = cur.rank,
                savedRank = sv.rank,
                currentName = cur.name,
                savedName = sv.name,
            }
            changedCount = changedCount + 1
        end
    end

    for nodeID, sv in pairs(saved) do
        if not current[nodeID] then
            byNode[nodeID] = {
                status = self.STATUS.ADDED,
                currentRank = 0,
                savedRank = sv.rank,
                currentName = nil,
                savedName = sv.name,
            }
            addedCount = addedCount + 1
        end
    end

    state.diff = {
        byNode = byNode,
        summary = {
            added = addedCount,
            removed = removedCount,
            changed = changedCount,
        },
    }
    state.dirty = false
    return state.diff
end

-- Returns the cached diff for the current selection, computing if dirty.
function TalentDiff:GetDiff()
    local state = self.state
    if not state.compareConfigID then return nil end
    if state.dirty or not state.diff then
        return self:ComputeDiff()
    end
    return state.diff
end

-- Returns the diff entry for a single node (or nil if same / no comparison).
function TalentDiff:GetNodeDiff(nodeID)
    local diff = self:GetDiff()
    if not diff then return nil end
    return diff.byNode[nodeID]
end
