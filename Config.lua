local TalentDiff = TalentDiff
local TD = TalentDiff

-- ---------------------------------------------------------------------------
-- Config: single source of truth for user-tunable visual multipliers.
--
-- The per-status BASE styling lives in OverlayManager.STATUS_VISUAL (color,
-- rimAlpha, rimPad). Config holds the four user-facing multipliers that get
-- combined with the base at paint time via OverlayManager.ComputeEffective.
--
-- Persistence is the existing SavedVariablesPerCharacter `TalentDiffDB`
-- (declared in TalentDiff.toc); fields are lazily initialised so older saves
-- without these keys upgrade transparently.
-- ---------------------------------------------------------------------------

TD.Config = TD.Config or {}
local Config = TD.Config

local DEFAULTS = {
    overlayIntensity  = 1.0,  -- 0.2 .. 2.0  — multiplies STATUS_VISUAL.color RGB
    overlayScale      = 1.0,  -- 0.8 .. 1.5  — multiplies rimPad (apparent ring outset)
    rimThickness      = 1.0,  -- 0.0 .. 3.0  — second multiplier on rimPad (thicker band)
    overlayAlpha      = 1.0,  -- 0.1 .. 1.0  — multiplies STATUS_VISUAL.rimAlpha
    enableAnimations  = true, -- master on/off for the gentle alpha pulse
    animationStrength = 1.0,  -- 0.2 .. 2.0  — scales the alpha dip depth
    animationSpeed    = 1.0,  -- 0.5 .. 1.8  — scales pulse rate (>1 = faster)
}

-- Read-only view of defaults; callers must not mutate.
function Config.Defaults()
    return DEFAULTS
end

-- Lazy-init the SavedVariables table. Called from Core.lua on ADDON_LOADED
-- (after WoW has populated TalentDiffDB from disk). Missing keys back-fill
-- from DEFAULTS so a player who upgrades the addon doesn't see nil reads.
function Config.Init()
    TalentDiffDB = TalentDiffDB or {}
    for k, v in pairs(DEFAULTS) do
        if TalentDiffDB[k] == nil then TalentDiffDB[k] = v end
    end
end

-- Bounded read. Callers in the paint path should never see nil.
function Config.Get(key)
    local db = TalentDiffDB
    if db == nil then return DEFAULTS[key] end
    local v = db[key]
    if v == nil then return DEFAULTS[key] end
    return v
end

-- Set + refresh. Single entry point so the slash-command path, the slider
-- callbacks, and any future preset system all funnel through one helper.
-- We always call OverlayManager:RefreshVisualSettings — it does both a
-- RestyleAll (style/color/anchor refresh) and an UpdateAnimationsAll (anim
-- state re-evaluation). Routing different key types to different subset
-- helpers was a source of bugs (overlayAlpha changes ceiling AND animation
-- floor; enableAnimations changes anim AND should redraw stopped rims at
-- their resting alpha). One unified path is correct and cheap.
function Config.Set(key, value)
    if TalentDiffDB == nil then TalentDiffDB = {} end
    if DEFAULTS[key] == nil then return end  -- guard typos
    TalentDiffDB[key] = value
    local OM = TD.OverlayManager
    if OM and OM.RefreshVisualSettings then OM:RefreshVisualSettings() end
end

function Config.Reset()
    if TalentDiffDB == nil then TalentDiffDB = {} end
    for k, v in pairs(DEFAULTS) do TalentDiffDB[k] = v end
    local OM = TD.OverlayManager
    if OM and OM.RefreshVisualSettings then OM:RefreshVisualSettings() end
end
