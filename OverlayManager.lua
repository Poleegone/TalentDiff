local TalentDiff = TalentDiff

-- ---------------------------------------------------------------------------
-- OverlayManager: single owner of every visual painted onto Blizzard talent
-- buttons. Created once at load and exposed as TalentDiff.OverlayManager so
-- UI.lua / Core.lua can drive it without leaking module-locals.
--
-- Invariants this module enforces (and that the prior scattered impl did not):
--   * Single writer. No code outside this file mutates pool entries.
--   * Active-set tracking. Apply() adds, Release()/ClearAll() remove. RefreshAll
--     uses the active set to release nodes that are no longer in the diff.
--   * Pool eviction. Weak keys so a recycled Blizzard button frame doesn't keep
--     its prior overlay alive — the GC takes the pair together.
--   * Atomic terminal state. RefreshAll never early-returns on hidden frames in
--     a way that leaves the pool out of sync; ClearAll is the one cleanup path.
-- ---------------------------------------------------------------------------

-- Per-status visual descriptors. Indexed by TalentDiff.STATUS value.
--   color      : rim tint (also feeds StatusHex / tooltip / panel via GetVisual)
--                ↑ EDIT HERE to change red/green saturation; values are
--                  normalized RGBA 0..1. Push the off-channels (red+blue for
--                  green; green+blue for red) toward 0 to increase saturation.
--   rimAlpha   : alpha applied to the mask-clipped silhouette outer layer
--   rimPad     : px the outer mask layer extends beyond the button rect — this
--                is what produces the visible rim band, since the inner MOD
--                cutout is sized to the button rect itself.
--   desaturate : whether to dim the underlying icon (REMOVED "loss" feel)
--   glowAlpha  : LEGACY — alpha for the hollow-circle halo in fallback path
--   glowPad    : LEGACY — outward pad for the halo in fallback path
--   shadeAlpha : LEGACY — inward black shade in fallback path
local STATUS_VISUAL = {
    [1] = { color = {0.10, 1.00, 0.25, 1.00}, rimAlpha = 0.85, rimPad = 5, desaturate = false, glowAlpha = 0.70, glowPad = 5, shadeAlpha = 0    }, -- ADDED   (saturated green)
    [2] = { color = {1.00, 0.08, 0.12, 1.00}, rimAlpha = 0.75, rimPad = 3, desaturate = true,  glowAlpha = 0.45, glowPad = 3, shadeAlpha = 0.30 }, -- REMOVED (saturated red)
    [3] = { color = {1.00, 0.78, 0.18, 1.00}, rimAlpha = 0.75, rimPad = 3, desaturate = false, glowAlpha = 0.55, glowPad = 3, shadeAlpha = 0    }, -- CHANGED
    [4] = { color = {0.50, 0.82, 1.00, 1.00}, rimAlpha = 0,    rimPad = 0, desaturate = false, glowAlpha = 0,    glowPad = 0, shadeAlpha = 0    }, -- RANK
}

-- Delta label colors mirror the rim hues so +N / -N stays visually coherent
-- with the rim it sits next to. Same saturation lever as STATUS_VISUAL.color.
local DELTA_POS_RGB = {0.10, 1.00, 0.25}
local DELTA_NEG_RGB = {1.00, 0.20, 0.22}

-- Verified-existing retail textures. WHITE8x8 builds the thin per-side outline strips
-- and (tinted black) the inward REMOVED shade; IconBorder-GlowRing is a clean hollow
-- circle for the underlying halo on circular nodes.
local LINE_TEXTURE  = "Interface\\Buttons\\WHITE8x8"
local GLOW_TEXTURE  = "Interface\\Buttons\\IconBorder-GlowRing"
local SHADE_TEXTURE = "Interface\\Buttons\\WHITE8x8"

-- Outline geometry. Glow padding is per-status (see STATUS_VISUAL.glowPad).
local EDGE_THICK = 2
local EDGE_INSET = 2

local STATUS_RANK = (TalentDiff.STATUS and TalentDiff.STATUS.RANK) or 4

-- Singleton manager. Module-private state lives in `self`.
local OverlayManager = {}
TalentDiff.OverlayManager = OverlayManager

-- Combine the per-status BASE styling (STATUS_VISUAL) with the user-facing
-- multipliers in TalentDiff.Config. One choke point so both PaintStructural
-- (initial paint) and Restyle (live slider re-tint) read the same numbers.
--
-- Returns (r, g, b, alpha, pad). The intensity multiplier is allowed to push
-- channels past 1.0 — Texture:SetVertexColor saturates clamped to [0,1] in the
-- shader pipeline, which is the visual we want (a brighter, more uniform tint
-- on top of already-saturated base colors). pad multiplies BOTH overlayScale
-- and rimThickness because the user-facing "size" and "thickness" sliders
-- both ultimately move the same outset; keeping two knobs lets thickness
-- dominate small adjustments while scale carries large ones.
local function GetCfg(key)
    local Config = TalentDiff and TalentDiff.Config
    if Config and Config.Get then return Config.Get(key) end
    return 1
end

function OverlayManager.ComputeEffective(visual)
    local intensity = GetCfg("overlayIntensity")
    local alpha     = GetCfg("overlayAlpha")
    local scale     = GetCfg("overlayScale")
    local thick     = GetCfg("rimThickness")
    local r = (visual.color[1] or 0) * intensity
    local g = (visual.color[2] or 0) * intensity
    local b = (visual.color[3] or 0) * intensity
    local a = (visual.rimAlpha or 0) * alpha
    local pad = (visual.rimPad or 0) * scale * thick
    return r, g, b, a, pad
end

-- Weak keys: a button frame dropped by Blizzard takes its overlay with it on GC.
OverlayManager.pool = setmetatable({}, { __mode = "k" })
OverlayManager.activeButtons = {}
OverlayManager.generation = 0

-- Animation profile + global synchronized clock.
--
-- ARCHITECTURE: ONE shared OnUpdate-driven phase counter for the entire addon,
-- not one AnimationGroup per overlay. Every animated overlay reads from the
-- same `AnimState.phase` each frame, so 30 painted nodes pulse in perfect
-- lockstep with no possibility of drift, no per-overlay restart on refresh,
-- and no asynchronous flashing when overlays are recreated mid-pulse.
--
-- The per-overlay AnimationGroup approach (now removed) caused visible desync
-- because each group started its clock at the timestamp it was first Played,
-- and any RefreshAll / Apply that recreated overlays restarted phase 0 for
-- those specific nodes. The global clock survives any refresh — its phase
-- only ever advances; new overlays just join the wave wherever it is now.
--
-- Alpha-only by design (still). Mask alignment is inviolable; SetScale on
-- textures would drift the rim off the Blizzard mask silhouette.
--
--   alphaDip       : depth of the dip relative to resting alpha at strength=1.
--                    0.15 → trough sits at restingAlpha * 0.85. Strength slider
--                    multiplies this.
--   basePeriod     : seconds for one full breathe at speed=1.0. ~2.0s is the
--                    "premium UI breathe" zone. Speed slider divides this.
--   minPeriod      : floor so the speed slider can't produce a flicker.
--   statusEnabled  : per-status opt-in. ADDED + REMOVED only.
local STATUS_ADDED   = (TalentDiff.STATUS and TalentDiff.STATUS.ADDED)   or 1
local STATUS_REMOVED = (TalentDiff.STATUS and TalentDiff.STATUS.REMOVED) or 2

local ANIMATION_PROFILE = {
    alphaDip   = 0.55,
    basePeriod = 2.0,
    minPeriod  = 0.9,
    statusEnabled = {
        [STATUS_ADDED]   = true,
        [STATUS_REMOVED] = true,
    },
}

-- Global animation clock. Phase advances monotonically while the driver runs;
-- it is never reset, so overlay churn (refresh / spec change / loadout swap)
-- cannot restart the wave. The driver lazy-stops itself when the active set
-- is empty so we don't burn frames painting nothing.
local AnimState = {
    phase = 0,
    enabled = true,
}

OverlayManager._animState = AnimState  -- expose for /td animdebug

-- One-shot diagnostic. /td debug flips this true; the next paint pass
-- collects per-button classification + atlas/mask binding into the buffer,
-- and RefreshAll's tail flushes the buffer into TalentDiff:ShowDebugLog (a
-- copyable scrollable window) so the user can Ctrl+A / Ctrl+C the result.
-- Chat is unsuitable for this dump because WoW's chat frame is not copyable.
OverlayManager.diagnoseOnce = false
OverlayManager._diagnoseBuffer = nil  -- set to {} when diagnoseOnce is armed

-- Session-scoped rate-limit sets so per-node warnings only fire once each
-- (chat would otherwise get hammered on every refresh / event-driven paint).
OverlayManager._warnedShape = {}  -- nodeID → true (unknown-shape warned)
OverlayManager._warnedAtlas = {}  -- (nodeID .. "/" .. atlasName) → true

-- ---------- visual lookup --------------------------------------------------

function OverlayManager:GetVisual(statusIdx)
    return STATUS_VISUAL[statusIdx]
end

-- ---------- node-shape classification --------------------------------------

-- Map a `talents-node-*` atlas/texture name to a normalized shape token.
-- Pattern order matters — `choiceflyout` must be checked before `choice`,
-- and `apex` is a single bucket regardless of -large / -small variants.
--
-- The strings we care about come from atlas names like
-- `talents-node-apex-large-gray` / `talents-node-square-yellow` /
-- `talents-node-circle-shadow`. We match case-insensitively.
local function NormalizedShapeFromString(s)
    if type(s) ~= "string" or s == "" then return nil end
    s = s:lower()
    if not s:find("talents%-node") and not s:find("talents\\node") then
        return nil
    end
    if s:find("choiceflyout")               then return "choiceflyout" end
    if s:find("apex")                       then return "apex"         end
    if s:find("subtree") or s:find("sub%-tree") or s:find("hero")
                                            then return "subtree"      end
    if s:find("choice")                     then return "choice"       end
    if s:find("square")                     then return "square"       end
    if s:find("pvptalent")                  then return "circle"       end
    if s:find("circle")                     then return "circle"       end
    return nil
end

-- Atlas-driven shape classifier. Reads `StateBorder:GetAtlas()` first — that's
-- Blizzard's authoritative shape ring — then falls back through a small
-- whitelist of regions that carry the same shape art on templates where
-- StateBorder is absent. Shadow / Ghost are deliberately NOT consulted: apex
-- nodes carry a circle Shadow atlas, which produced the apex-as-circle bug.
--
-- Per-button cache keyed by the atlas string short-circuits repeat reads when
-- Blizzard recycles a button frame for the same node — `_tdShapeAtlas` holds
-- the atlas we last classified, `_tdShape` / `_tdShapeKey` hold the result.
--
-- Returns: shape, srcKey (region the atlas came from), srcVal (atlas string)
local SHAPE_REGION_PRIORITY = {
    "StateBorder",
    "StateBorderHover",
    "Glow",
    "SelectableGlow",
    "Border",
}

local function ReadRegionAtlas(button, key)
    local v = button[key]
    if type(v) ~= "table" or type(v.GetAtlas) ~= "function" then return nil end
    local okT, ot = pcall(v.GetObjectType, v)
    if not okT or ot ~= "Texture" then return nil end
    local okA, atlas = pcall(v.GetAtlas, v)
    if okA and type(atlas) == "string" and atlas ~= "" then return atlas end
    return nil
end

local function ResolveShapeFromAtlas(button)
    if not button then return nil, nil, nil end
    for _, key in ipairs(SHAPE_REGION_PRIORITY) do
        local atlas = ReadRegionAtlas(button, key)
        if atlas then
            -- Cache hit: same atlas as last paint → reuse classification.
            if button._tdShapeAtlas == atlas and button._tdShape then
                return button._tdShape, button._tdShapeKey, atlas
            end
            local s = NormalizedShapeFromString(atlas)
            if s then
                button._tdShapeAtlas = atlas
                button._tdShape      = s
                button._tdShapeKey   = key
                return s, key, atlas
            end
            -- Atlas was readable but didn't match any known shape token —
            -- don't keep walking; StateBorder is authoritative. Returning nil
            -- here surfaces the unknown atlas via the rate-limited warning.
            return nil, key, atlas
        end
    end
    return nil, nil, nil
end

-- Walk button regions and return a flat list of `key={atlas=…,tex=…}` entries
-- for any region that has either an atlas or a texture path. Used by the
-- /td debug diagnostic so the user can SEE what regions Blizzard exposes per
-- node, which is how we extend the visual classifier when new shapes appear.
local function DumpButtonRegions(button)
    if not button then return "" end
    local out = {}
    for k, v in pairs(button) do
        if type(v) == "table" and type(v.GetObjectType) == "function" then
            local ok, objType = pcall(v.GetObjectType, v)
            if ok and objType == "Texture" then
                local atlas, tex
                if v.GetAtlas then
                    local okA, a = pcall(v.GetAtlas, v)
                    if okA then atlas = a end
                end
                if v.GetTexture then
                    local okT, t = pcall(v.GetTexture, v)
                    if okT then tex = t end
                end
                if (atlas and atlas ~= "") or (tex and tex ~= "" and type(tex) == "string") then
                    out[#out + 1] = string.format("%s={atlas=%s,tex=%s}", tostring(k), tostring(atlas), tostring(tex))
                end
            end
        end
    end
    if #out == 0 then return "(no Texture regions found)" end
    return table.concat(out, " ")
end

-- Classify a button as "circle" (passive talents — circular icons in Blizzard's
-- talent UI), "choice" (Selection + SubTreeSelection — octagonal in Blizzard's
-- UI), or nil (unknown — caller MUST NOT paint a rim). Semantic-only fallback
-- for ResolveShapeFromNodeVisuals — used when the button has no readable
-- talents-node-* atlas region.
--
-- Multi-signal detection in priority order. The previous "anything not
-- explicitly choice → circle" fall-through was the root cause of the all-
-- circles-rendered-on-octagonal-nodes regression: when GetNodeInfo or the
-- enum compare quietly mismatched, every node fell through to "circle". The
-- new contract is: if we can't prove the shape, return nil and let the
-- caller hide the rim + log a warning. Visible failure beats silent miscolor.
--
-- Returns: shape ("circle" | "choice" | nil), info (table or nil for diagnostics)
local function GetNodeShape(button)
    if not button then return nil, nil end

    local info
    if button.GetNodeInfo then
        local ok, result = pcall(button.GetNodeInfo, button)
        if ok then info = result end
    end

    -- 1-2. Authoritative info.type match against TraitNodeType enum.
    if info and Enum and Enum.TraitNodeType then
        if info.type == Enum.TraitNodeType.SubTreeSelection then return "choice", info end
        if info.type == Enum.TraitNodeType.Selection then return "choice", info end
    end

    -- 3. Sub-tree mixin signs: a SubTreeSelectionMixin button typically
    -- exposes GetSubTreeID or has a non-nil subTreeID. These survive even if
    -- info.type went sideways on a future patch.
    if (button.GetSubTreeID and type(button.GetSubTreeID) == "function") or button.subTreeID ~= nil then
        return "choice", info
    end

    -- 4. Choice-node mixin signs: the SelectMixin's XML template attaches
    -- PickedIcon / SelectedIcon textures that don't exist on passive buttons.
    if button.PickedIcon or button.SelectedIcon then
        return "choice", info
    end

    -- 5. Fallback to "circle" ONLY when info.type was readable (i.e. we
    -- actually have evidence this is a node) AND it didn't match any choice
    -- value. Without that evidence we fall through to nil — never guess.
    if info and info.type ~= nil then
        return "circle", info
    end

    return nil, info
end

-- The rim itself is a Blizzard atlas that is *already* hollow ring art —
-- transparent center, edge-only pixels. The mask just clips the rim's outer
-- silhouette to the exact node shape. The atlas provides the ring; the mask
-- provides silhouette truth. No subtraction, no MOD blending, no full-rect
-- color fills — just one tinted hollow texture clipped to the node shape.
-- Shape → rim atlas. Names match Blizzard's `talents-node-<shape>-yellow`
-- pattern observed in the /td debug regions dump. If any fail to resolve in
-- the live client, the existing "atlas not found" rate-limited warning will
-- fire with the exact name and nodeID for follow-up correction.
local RIM_ATLAS = {
    circle       = "talents-node-circle-yellow",
    choice       = "talents-node-choice-yellow",
    square       = "talents-node-square-yellow",
    apex         = "talents-node-apex-large-yellow",
    choiceflyout = "talents-node-choiceflyout-yellow",
    subtree      = "talents-node-subtree-yellow",
}

-- Resolve a Blizzard MASK TEXTURE PATH for a given node shape. Masks are the
-- geometric source of truth Blizzard uses to clip its own talent-node art, so
-- using them here guarantees overlay silhouette = node silhouette across every
-- resolution and UI scale. SetMask takes a texture file path (not an atlas
-- name), so candidates are full Interface\... paths.
--
-- Validation strategy: there is no GetMaskInfo API, and SetMask itself is
-- silent on failure. We probe each candidate via a hidden offscreen texture's
-- SetMask call and accept the first that doesn't throw; result cached per
-- shape. If no candidate resolves we still attempt to paint with no mask —
-- the atlas is already hollow, so an unmasked rim still reads as a ring,
-- just without silhouette-perfect outer clipping.
local MASK_CANDIDATES = {
    circle = {
        "Interface\\TalentFrame\\TalentsMaskNodeCircle\\talents-node-circle-mask",
    },
    square = {
        "Interface\\TalentFrame\\TalentsMaskNodeSquare\\talents-node-square-mask",
    },
    choice = {
        "Interface\\TalentFrame\\TalentsMaskNodeChoice\\talents-node-choice-mask",
    },
    apex = {
        "Interface\\TalentFrame\\TalentsMaskNodeApex\\talents-node-apex-large-mask",
        "Interface\\TalentFrame\\TalentsMaskApexNodeLargeCircle\\talents-node-apex-large-mask",
        "Interface\\TalentFrame\\TalentsMaskApexNodeLargeSquare\\talents-node-apex-active-large-mask",
    },
    choiceflyout = {
        "Interface\\TalentFrame\\TalentsMaskNodeChoiceFlyout\\talents-node-choiceflyout-mask",
    },
    subtree = {
        "Interface\\TalentFrame\\TalentsMaskNodeSubTree\\talents-node-subtree-mask",
    },
}
local maskCache = {}
local maskProbeFrame, maskProbeTex
local function getMaskProbe()
    if maskProbeTex then return maskProbeTex end
    maskProbeFrame = CreateFrame("Frame", nil, UIParent)
    maskProbeFrame:Hide()
    maskProbeTex = maskProbeFrame:CreateTexture(nil, "BACKGROUND")
    maskProbeTex:SetColorTexture(1, 1, 1, 1)
    return maskProbeTex
end
local function ResolveMaskPath(shape)
    if not shape then return nil end
    local cached = maskCache[shape]
    if cached ~= nil then
        return cached or nil
    end
    local probe = getMaskProbe()
    if not probe or not probe.SetMask then
        maskCache[shape] = false
        return nil
    end
    for _, path in ipairs(MASK_CANDIDATES[shape] or {}) do
        -- SetMask is silent on missing assets, but pcall guards the rare case
        -- where the API itself errors on a malformed path. Any mask that loads
        -- without throwing is treated as usable; if the file is missing the
        -- mask simply has no effect, which is no worse than the fallback path.
        local ok = pcall(probe.SetMask, probe, path)
        if ok then
            -- Clear the probe so it doesn't carry state into the next probe call.
            pcall(probe.SetMask, probe, nil)
            maskCache[shape] = path
            return path
        end
    end
    maskCache[shape] = false
    return nil
end

-- ---------- frame creation -------------------------------------------------

local function GetOrCreate(self, button)
    local ov = self.pool[button]
    if ov then return ov end

    ov = CreateFrame("Frame", nil, button)
    ov:EnableMouse(false)  -- never block node interaction
    ov:SetFrameLevel((button:GetFrameLevel() or 1) + 7)
    ov:SetAllPoints(button)

    -- Primary visual: a single mask-clipped hollow rim.
    --
    -- The rim texture is a Blizzard talent-node atlas that is ALREADY edge-only
    -- art (transparent center, ring-shaped pixels). At paint time we:
    --   * SetAtlas(talents-node-{circle,choice}-yellow) — hollow ring shape
    --   * SetVertexColor(r,g,b,a) — tint to status color
    --   * SetMask(blizzard mask path) — clip outer silhouette to node geometry
    --   * BlendMode ADD — purely additive glow over the tree backdrop
    --
    -- No second layer. No subtraction. No color fills behind the icon. The
    -- atlas's own transparent interior is what produces the hollow rim; the
    -- mask only enforces silhouette correctness.
    local rim = ov:CreateTexture(nil, "BACKGROUND", nil, -2)
    rim:SetBlendMode("ADD")
    rim:Hide()
    ov.rim = rim

    -- LEGACY: hollow-circle halo, retained for the missing-atlas fallback.
    local glow = ov:CreateTexture(nil, "BACKGROUND", nil, -1)
    glow:SetTexture(GLOW_TEXTURE)
    glow:SetBlendMode("ADD")
    glow:Hide()
    ov.glow = glow

    -- Inward "loss" shade for REMOVED. ARTWORK sublevel sits above the icon and below
    -- the OVERLAY edge strips. Mouse passthrough is guaranteed by EnableMouse(false) above.
    local shade = ov:CreateTexture(nil, "ARTWORK", nil, 2)
    shade:SetTexture(SHADE_TEXTURE)
    shade:SetVertexColor(0, 0, 0, 0)
    shade:SetAllPoints(ov)
    shade:Hide()
    ov.shade = shade

    -- Four thin per-side strips form a shape-agnostic outline that traces whatever rectangular
    -- bounding box the node uses (square actives, wide choice nodes, sub-tree pickers, …).
    local function makeEdge()
        local t = ov:CreateTexture(nil, "OVERLAY", nil, 7)
        t:SetTexture(LINE_TEXTURE)
        return t
    end
    local top, bottom = makeEdge(), makeEdge()
    local left, right = makeEdge(), makeEdge()

    top:SetPoint("BOTTOMLEFT",  ov, "TOPLEFT",  -EDGE_INSET, EDGE_INSET - EDGE_THICK)
    top:SetPoint("BOTTOMRIGHT", ov, "TOPRIGHT",  EDGE_INSET, EDGE_INSET - EDGE_THICK)
    top:SetHeight(EDGE_THICK)

    bottom:SetPoint("TOPLEFT",  ov, "BOTTOMLEFT",  -EDGE_INSET, -EDGE_INSET + EDGE_THICK)
    bottom:SetPoint("TOPRIGHT", ov, "BOTTOMRIGHT",  EDGE_INSET, -EDGE_INSET + EDGE_THICK)
    bottom:SetHeight(EDGE_THICK)

    left:SetPoint("TOPRIGHT",    ov, "TOPLEFT",    -EDGE_INSET + EDGE_THICK,  EDGE_INSET)
    left:SetPoint("BOTTOMRIGHT", ov, "BOTTOMLEFT", -EDGE_INSET + EDGE_THICK, -EDGE_INSET)
    left:SetWidth(EDGE_THICK)

    right:SetPoint("TOPLEFT",    ov, "TOPRIGHT",    EDGE_INSET - EDGE_THICK,  EDGE_INSET)
    right:SetPoint("BOTTOMLEFT", ov, "BOTTOMRIGHT", EDGE_INSET - EDGE_THICK, -EDGE_INSET)
    right:SetWidth(EDGE_THICK)

    ov.edges = { top = top, bottom = bottom, left = left, right = right }

    -- Animation: NO per-overlay clock. The global driver (OverlayManager._animDriver)
    -- writes this overlay's rim alpha each frame when ov._animated is true.
    -- New overlays inherit the current phase automatically — no Play, no
    -- restart, no per-node desync.

    -- Numeric rank-delta label. Try a punchier outlined template first; CreateFontString
    -- errors on unknown names, so wrap in pcall and fall back to a guaranteed template.
    local ok, delta = pcall(ov.CreateFontString, ov, nil, "OVERLAY", "NumberFontNormalLargeRightOutline")
    if not ok or not delta then
        delta = ov:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    end
    delta:ClearAllPoints()
    delta:SetPoint("BOTTOMLEFT", ov, "TOPRIGHT", 2, 2)
    delta:SetJustifyH("RIGHT")
    delta:Hide()
    ov.delta = delta

    self.pool[button] = ov
    return ov
end

-- ---------- paint helpers --------------------------------------------------

local function SetEdgesShown(ov, shown)
    for _, e in pairs(ov.edges) do
        if shown then e:Show() else e:Hide() end
    end
end

-- Best-effort icon desaturate for REMOVED. Walks the well-known Blizzard
-- talent-button portrait field names; if none resolve we no-op (the rim alone
-- will carry the signal). Tracks whether we touched it so we can restore on
-- Release / when status flips back.
local ICON_FIELDS = { "Icon", "icon", "IconTexture", "iconTexture" }
local function FindIconRegion(button)
    if not button then return nil end
    for _, field in ipairs(ICON_FIELDS) do
        local r = button[field]
        if r and r.SetDesaturated then return r end
    end
    return nil
end

-- Best-effort nodeID resolver, mirrors UI.lua's GetButtonNodeID. Used only
-- for diagnostic logging + warning rate-limit keys; never load-bearing.
local function GetNodeID(button)
    if not button then return nil end
    if button.GetNodeID then
        local ok, id = pcall(button.GetNodeID, button)
        if ok and id then return id end
    end
    if button.nodeID then return button.nodeID end
    if button.nodeInfo and button.nodeInfo.ID then return button.nodeInfo.ID end
    return nil
end

local function ApplyIconDesaturate(ov, button, on)
    if on and not ov._iconDesatRegion then
        local region = FindIconRegion(button)
        if region then
            local ok = pcall(region.SetDesaturated, region, true)
            if ok then ov._iconDesatRegion = region end
        end
    elseif not on and ov._iconDesatRegion then
        pcall(ov._iconDesatRegion.SetDesaturated, ov._iconDesatRegion, false)
        ov._iconDesatRegion = nil
    end
end

-- Rank-only differences show the corner delta and nothing else.
local function PaintRank(ov, button, nodeDiff)
    SetEdgesShown(ov, false)
    ov.rim:Hide()
    ov.glow:Hide()
    ov.shade:Hide()
    ApplyIconDesaturate(ov, button, false)
    local d = (nodeDiff.savedRank or 0) - (nodeDiff.currentRank or 0)
    local sign = d > 0 and "+" or ""
    ov.delta:SetText(sign .. tostring(d))
    -- Stash for Restyle: the delta direction (sign of d) is the only thing
    -- needed to re-tint without re-reading nodeDiff (which may not be in scope
    -- when sliders fire after the diff has been freed).
    ov._rankDelta = d
    local rgb = (d > 0) and DELTA_POS_RGB or DELTA_NEG_RGB
    local intensity = GetCfg("overlayIntensity")
    local alpha     = GetCfg("overlayAlpha")
    ov.delta:SetTextColor(rgb[1] * intensity, rgb[2] * intensity, rgb[3] * intensity, alpha)
    ov.delta:Show()
end

-- Add/removed/changed: paint a hollow Blizzard rim atlas, tinted to status
-- color, clipped to the node silhouette by a Blizzard mask texture.
--
-- The atlas (talents-node-<shape>-yellow) is already edge-only ring art with
-- a transparent interior — that's what produces the hollow look. The mask
-- (talents-node-<shape>-mask) clips the rim's outer boundary to the exact
-- node silhouette Blizzard rendered for this specific button.
--
-- AUTHORITATIVE SHAPE = the button's live visual atlas regions, period.
-- Semantic gameplay shape (info.type) is computed for diagnostics ONLY; it
-- does not influence rendering, because /td debug proved info.type is
-- gameplay metadata and lies about the rendered geometry (apex nodes have
-- info.type=0/1, but Blizzard renders them with apex atlases).
--
-- ANCHORING: the rim is anchored to `button.StateBorder` (Blizzard's visible
-- shape ring) when present, NOT to the button frame. This matters for apex
-- nodes whose hit-target frame is significantly larger than the visible art —
-- anchoring to the frame would inset the masked rim within the apex octagon.
-- Anchoring to StateBorder ties the rim to the same rectangle the mask was
-- authored against, so the silhouette aligns at any UI scale.
--
-- If the visual classifier can't determine a shape, the rim is hidden and a
-- one-shot warning fires — never a circle fallback, never a rectangular
-- fallback. Visible-broken beats silently-wrong.
local function PaintStructural(ov, button, visual)
    -- Read effective (base * user-tunable multipliers) values via the single
    -- combinator so live slider re-tints in Restyle stay in lock-step with
    -- whatever PaintStructural would produce on a full Apply pass.
    local r, g, b, alpha, pad = OverlayManager.ComputeEffective(visual)

    local visualShape, visualSrcKey, visualSrcVal = ResolveShapeFromAtlas(button)
    local gameplayShape, info = GetNodeShape(button)  -- diagnostics only

    local atlasName = visualShape and RIM_ATLAS[visualShape] or nil
    local maskPath = ResolveMaskPath(visualShape)
    local nodeID = GetNodeID(button)

    -- Always hide legacy fallback geometry — strip / halo / shade are no
    -- longer used. They remain in GetOrCreate only to avoid disturbing other
    -- code paths that reference ov.glow / ov.shade / ov.edges; left hidden
    -- here so they never contribute to the visual.
    SetEdgesShown(ov, false)
    ov.glow:Hide()
    ov.shade:Hide()

    -- Capture binding outcome for the one-shot diagnostic dump below. We have
    -- to call SetAtlas inside a pcall AND capture its return value (the actual
    -- "atlas was found" bool) — wrapping both in one pcall is the only way to
    -- distinguish "API errored" from "atlas missing".
    local atlasOk, maskOk
    local anchorTo = button.StateBorder or button

    if atlasName then
        ov.rim:ClearAllPoints()
        ov.rim:SetPoint("TOPLEFT",     anchorTo, "TOPLEFT",     -pad,  pad)
        ov.rim:SetPoint("BOTTOMRIGHT", anchorTo, "BOTTOMRIGHT",  pad, -pad)

        local pcallOk, found = pcall(function() return ov.rim:SetAtlas(atlasName) end)
        atlasOk = pcallOk and (found ~= false)  -- SetAtlas returns false when atlas missing; nil/true otherwise
        if atlasOk then
            -- Apply mask AFTER SetAtlas so the atlas's UVs are established
            -- before clipping; clear any prior mask first to avoid stale state
            -- on a recycled button whose previous shape differed.
            pcall(ov.rim.SetMask, ov.rim, nil)
            if maskPath then
                maskOk = pcall(ov.rim.SetMask, ov.rim, maskPath)
            end
            ov.rim:SetVertexColor(r, g, b, alpha)
            ov.rim:Show()
        else
            ov.rim:Hide()
        end
    else
        ov.rim:Hide()
    end

    -- Rate-limited warnings. Visible failure: chat tells the user a node
    -- couldn't be classified or an atlas was missing, so the absence of a rim
    -- is intentional and traceable rather than a silent regression.
    if not visualShape and nodeID and not OverlayManager._warnedShape[nodeID] then
        OverlayManager._warnedShape[nodeID] = true
        if TalentDiff.Print then
            TalentDiff:Print(string.format(
                "could not read visual shape from node %s regions — rim suppressed (gameplayShape=%s)",
                tostring(nodeID), tostring(gameplayShape)))
        end
    end
    if atlasName and atlasOk == false and nodeID then
        local key = tostring(nodeID) .. "/" .. atlasName
        if not OverlayManager._warnedAtlas[key] then
            OverlayManager._warnedAtlas[key] = true
            if TalentDiff.Print then
                TalentDiff:Print(string.format("atlas '%s' not found for node %s — rim suppressed",
                    atlasName, tostring(nodeID)))
            end
        end
    end

    -- One-shot diagnostic capture. Triggered by /td debug; each painted node
    -- pushes a header line + an indented region dump into the buffer, which
    -- RefreshAll flushes into the copyable debug window once the pass
    -- completes. The region dump is what tells us which atlas/texture names
    -- Blizzard hangs on each button — that's how we extend the visual
    -- classifier when new shape variants appear.
    if OverlayManager.diagnoseOnce and OverlayManager._diagnoseBuffer then
        local infoType = info and info.type
        local buf = OverlayManager._diagnoseBuffer
        -- visualShape is what we render against; gameplayShape is the
        -- info.type-derived bucket, kept here for cross-check only.
        buf[#buf + 1] = string.format(
            "node=%s info.type=%s visualShape=%s (%s='%s') gameplayShape=%s visualAtlas=%s setAtlas-found=%s mask=%s setMask-ok=%s",
            tostring(nodeID), tostring(infoType),
            tostring(visualShape), tostring(visualSrcKey), tostring(visualSrcVal),
            tostring(gameplayShape),
            tostring(atlasName), tostring(atlasOk),
            tostring(maskPath), tostring(maskOk))

        -- Geometry triplet. Reveals whether the button's hit-target frame and
        -- the visible StateBorder rectangle differ (the apex inset suspect),
        -- and confirms the rim ended up sized to the right rectangle. Empty
        -- "?x?" entries usually mean the texture has no points set yet on a
        -- freshly recycled button — re-running /td debug after the talent
        -- frame has been visible for a moment will populate them.
        local function fmtSize(o)
            if not o or type(o.GetSize) ~= "function" then return "?" end
            local okS, w, h = pcall(o.GetSize, o)
            if not okS or not w or not h then return "?" end
            return string.format("%.0fx%.0f", w, h)
        end
        local sb = button.StateBorder
        local sbAnchor = "?"
        if sb and type(sb.GetPoint) == "function" then
            local okP, point, _, relPoint, x, y = pcall(sb.GetPoint, sb, 1)
            if okP and point then
                sbAnchor = string.format("%s->%s @%.0f,%.0f", tostring(point), tostring(relPoint), x or 0, y or 0)
            end
        end
        buf[#buf + 1] = string.format("  sizes: button=%s stateBorder=%s (%s) rim=%s anchorTo=%s",
            fmtSize(button), fmtSize(sb), sbAnchor, fmtSize(ov.rim),
            (button.StateBorder and "StateBorder") or "button")
        buf[#buf + 1] = "  regions: " .. DumpButtonRegions(button)
    end

    ApplyIconDesaturate(ov, button, visual.desaturate == true)
    ov.delta:Hide()
end

-- ---------- animation lifecycle (global synchronized clock) ---------------
--
-- ARCHITECTURE: ONE OnUpdate-driven phase counter. Every animated overlay
-- reads `AnimState.phase` each frame and computes its own alpha as
-- `restingAlpha * factor`, where factor is a shared sine-derived value in
-- [1 - dip, 1]. Resting alpha is per-overlay (status × overlayAlpha config);
-- the *phase* is global. So all overlays breathe in perfect sync but each
-- respects its own intensity ceiling.
--
-- Lifecycle:
--   ApplyOverlayAnimation(ov, status)  — flag this overlay to follow the wave
--   StopOverlayAnimation(ov)           — clear flag, restore resting alpha
--   UpdateOverlayAnimation(ov)         — re-evaluate the flag from config
--   UpdateAnimationsAll()              — sweep the active set
--
-- All four are O(1) flag flips plus an alpha restore. The global driver is
-- the only place per-frame work happens; it auto-stops when no overlay is
-- animated, so a tree with no diff costs zero per-frame CPU.

-- Driver frame. Created once. Walks activeButtons each frame, computing one
-- shared sine factor and writing per-overlay alpha. No table allocation, no
-- closures, no per-frame overlay rebuilds.
local animDriver = CreateFrame("Frame")
animDriver:Hide()
OverlayManager._animDriver = animDriver

animDriver:SetScript("OnUpdate", function(_, elapsed)
    local speed = GetCfg("animationSpeed") or 1.0
    AnimState.phase = AnimState.phase + elapsed * speed
    if not GetCfg("enableAnimations") then return end

    local strength = GetCfg("animationStrength") or 1.0
    local dip = ANIMATION_PROFILE.alphaDip * strength
    -- Period scaling: speed is folded into phase advance; the sine just needs
    -- the base angular frequency. minPeriod is the floor for sane UX.
    local period = math.max(ANIMATION_PROFILE.minPeriod, ANIMATION_PROFILE.basePeriod)
    local omega = (2 * math.pi) / period
    -- Sine in [-1, 1] → [0, 1], then dip-scaled and inverted so the multiplier
    -- sits in [1 - dip, 1]: peak at sine crest, gentle trough below.
    local s = (math.sin(AnimState.phase * omega) + 1) * 0.5
    local factor = 1 - dip * (1 - s)

    local pool = OverlayManager.pool
    for button in pairs(OverlayManager.activeButtons) do
        local ov = pool[button]
        if ov and ov._animated and ov.rim then
            local resting = ov._restingAlpha or 1
            local r, g, b = ov.rim:GetVertexColor()
            ov.rim:SetVertexColor(r or 1, g or 1, b or 1, resting * factor)
        end
    end
end)

local function startDriverIfNeeded()
    if not animDriver:IsShown() and (OverlayManager._animatedCount or 0) > 0 then
        animDriver:Show()
    end
end
local function stopDriverIfIdle()
    if animDriver:IsShown() and (OverlayManager._animatedCount or 0) <= 0 then
        animDriver:Hide()
    end
end

OverlayManager._animatedCount = 0  -- diagnostics; mirrors animated overlays

-- Compute resting alpha deterministically from STATUS_VISUAL + config. This
-- MUST NOT read the rim's current vertex alpha — the global animation driver
-- continuously rewrites that to `restingAlpha * factor`, so reading it back
-- captures a mid-pulse value and compounds toward zero on every slider tick.
-- That was the "overlays disappear when sliders move" bug.
local function ComputeRestingAlpha(status)
    local visual = STATUS_VISUAL[status]
    if not visual then return 1 end
    return (visual.rimAlpha or 0) * (GetCfg("overlayAlpha") or 1)
end

function OverlayManager:ApplyOverlayAnimation(ov, status)
    if not ov or not ov.rim then return end
    local enabled = GetCfg("enableAnimations") and ANIMATION_PROFILE.statusEnabled[status]
    if not enabled or not ov.rim:IsShown() then
        self:StopOverlayAnimation(ov)
        return
    end

    -- Resting alpha is the configured ceiling, NOT a vertex-color read-back.
    -- See ComputeRestingAlpha comment for why.
    ov._restingAlpha = ComputeRestingAlpha(status)

    if not ov._animated then
        ov._animated = true
        self._animatedCount = (self._animatedCount or 0) + 1
        startDriverIfNeeded()
    end
end

function OverlayManager:StopOverlayAnimation(ov)
    if not ov then return end
    if ov._animated then
        ov._animated = false
        self._animatedCount = math.max(0, (self._animatedCount or 0) - 1)
        stopDriverIfIdle()
    end
    -- Restore resting alpha so a stopped overlay sits at its full configured
    -- ceiling, not wherever the driver last left it mid-cycle.
    if ov.rim and ov._restingAlpha then
        local r, g, b = ov.rim:GetVertexColor()
        ov.rim:SetVertexColor(r or 1, g or 1, b or 1, ov._restingAlpha)
    end
end

function OverlayManager:UpdateOverlayAnimation(ov)
    if not ov then return end
    self:ApplyOverlayAnimation(ov, ov._status)
end

-- Sweep the active set. Called from Config.Set when an animation key (or
-- overlayAlpha — which moves each overlay's resting ceiling) changes. Cheap:
-- per-overlay work is a flag check + a vertex-color read for the new resting
-- alpha. The driver itself doesn't need waking; it's already running iff any
-- overlay is animated.
function OverlayManager:UpdateAnimationsAll()
    for button, _ in pairs(self.activeButtons) do
        local ov = self.pool[button]
        if ov then self:UpdateOverlayAnimation(ov) end
    end
end

-- ---------- public API -----------------------------------------------------

function OverlayManager:Apply(button, nodeDiff)
    if not button or not nodeDiff then
        self:Release(button)
        return
    end
    local visual = STATUS_VISUAL[nodeDiff.status]
    if not visual then
        self:Release(button)
        return
    end

    local ov = GetOrCreate(self, button)
    -- Stash status (and rank for RANK) on the overlay so Restyle can rebuild
    -- the visual from config alone, without needing the source nodeDiff —
    -- which won't be in scope when the slider callback fires later.
    ov._status = nodeDiff.status
    if nodeDiff.status == STATUS_RANK then
        PaintRank(ov, button, nodeDiff)
    else
        PaintStructural(ov, button, visual)
    end
    ov:Show()
    self:ApplyOverlayAnimation(ov, nodeDiff.status)

    -- Stamp the generation so RefreshAll's reaper pass knows this overlay is
    -- still wanted. Plain table value on the active set; the button itself is
    -- the key so iteration order doesn't matter.
    self.activeButtons[button] = self.generation
end

-- Live re-tint of a single overlay using current config multipliers. Cheap
-- path: only touches SetVertexColor and the rim anchor offsets — no atlas
-- resolution, no SetMask, no shape re-classification, no texture allocation.
-- Skips silently if the overlay was never given a status (defensive).
function OverlayManager:Restyle(button, ov)
    if not ov or not button then return end
    local status = ov._status
    if not status then return end
    if status == STATUS_RANK then
        local d = ov._rankDelta or 0
        local rgb = (d > 0) and DELTA_POS_RGB or DELTA_NEG_RGB
        local intensity = GetCfg("overlayIntensity")
        local alpha     = GetCfg("overlayAlpha")
        ov.delta:SetTextColor(rgb[1] * intensity, rgb[2] * intensity, rgb[3] * intensity, alpha)
        return
    end
    local visual = STATUS_VISUAL[status]
    if not visual then return end
    local r, g, b, alpha, pad = OverlayManager.ComputeEffective(visual)
    if ov.rim and ov.rim:IsShown() then
        local anchorTo = button.StateBorder or button
        ov.rim:ClearAllPoints()
        ov.rim:SetPoint("TOPLEFT",     anchorTo, "TOPLEFT",     -pad,  pad)
        ov.rim:SetPoint("BOTTOMRIGHT", anchorTo, "BOTTOMRIGHT",  pad, -pad)
        ov.rim:SetVertexColor(r, g, b, alpha)
    end
    -- Always re-evaluate the animation state — even when the rim is hidden,
    -- ApplyOverlayAnimation correctly Stops the pulse and clears _animated, so
    -- a previously-animated overlay that lost its rim doesn't keep ticking.
    self:ApplyOverlayAnimation(ov, status)
end

-- Walk the active set and Restyle each overlay. Called from Config.Set so
-- every slider tick produces an immediate visible update. The active set is
-- the only iteration domain — pool entries that aren't currently rendered
-- (released or evicted) get the new style for free on their next Apply.
function OverlayManager:RestyleAll()
    for button, _ in pairs(self.activeButtons) do
        local ov = self.pool[button]
        if ov then self:Restyle(button, ov) end
    end
end

-- Single public entry point that does the right thing for ANY config change:
-- re-tints + re-anchors every active overlay, then re-evaluates animation
-- state. Cheap (no atlas / mask / shape work, no pool churn, no overlay
-- rebuild). Suitable to call from any slider / checkbox callback without
-- worrying about which kind of setting changed.
function OverlayManager:RefreshVisualSettings()
    self:RestyleAll()
    self:UpdateAnimationsAll()
end

-- Flips the diagnostic flag for the next paint pass. /td debug calls this
-- followed by TalentDiff:RefreshOverlays(); each painted node pushes one
-- line into the buffer, and RefreshAll flushes the buffer into the copyable
-- debug window once the pass completes.
function OverlayManager:Diagnose()
    self.diagnoseOnce = true
    self._diagnoseBuffer = {}
    if TalentDiff.Print then
        TalentDiff:Print("debug: next overlay paint will open a copyable diagnostics window")
    end
end

function OverlayManager:Release(button)
    if not button then return end
    local ov = self.pool[button]
    if ov then
        self:StopOverlayAnimation(ov)
        ApplyIconDesaturate(ov, button, false)
        ov:Hide()
    end
    self.activeButtons[button] = nil
end

function OverlayManager:ClearAll()
    for button in pairs(self.activeButtons) do
        local ov = self.pool[button]
        if ov then
            self:StopOverlayAnimation(ov)
            ApplyIconDesaturate(ov, button, false)
            ov:Hide()
        end
    end
    self.activeButtons = {}
end

-- Drives a full refresh from a freshly-computed diff plus iteration helpers
-- supplied by UI.lua (so Blizzard-frame helpers stay co-located with the rest
-- of the UI integration code).
--
-- Contract:
--   * diff == nil           → ClearAll, return.
--   * iterButtons == nil    → no-op (talent frame not present yet); state intact.
--   * diff has byNode       → Apply for every (button, diff) pair; Release any
--     button that was active before this pass and didn't get touched (i.e. the
--     "this node no longer differs" case).
function OverlayManager:RefreshAll(diff, iterButtons, getNodeID)
    if not diff then
        self:ClearAll()
        return
    end
    if not iterButtons or not getNodeID then return end

    self.generation = self.generation + 1
    local gen = self.generation

    for button in iterButtons() do
        local nodeID = getNodeID(button)
        local nd = nodeID and diff.byNode and diff.byNode[nodeID] or nil
        if nd then
            self:Apply(button, nd)
        elseif self.activeButtons[button] then
            -- Button was painted last pass but is no longer in the diff. Release
            -- so the overlay disappears immediately rather than lingering until
            -- the next ClearAll.
            self:Release(button)
        end
    end

    -- Reaper: any button left over with a stale generation belongs to a frame
    -- that the iterator no longer enumerates (button recycled / spec switched
    -- mid-flight). Release so the pool can't accumulate ghosts.
    for button, stamp in pairs(self.activeButtons) do
        if stamp ~= gen then
            local ov = self.pool[button]
            if ov then
                self:StopOverlayAnimation(ov)
                ApplyIconDesaturate(ov, button, false)
                ov:Hide()
            end
            self.activeButtons[button] = nil
        end
    end

    -- One-shot diagnostic: flush the buffer into the copyable debug window
    -- and clear the flag so subsequent event-driven refreshes are quiet.
    if self.diagnoseOnce then
        self.diagnoseOnce = false
        local buf = self._diagnoseBuffer
        self._diagnoseBuffer = nil
        if buf and TalentDiff.ShowDebugLog then
            -- Prepend current user-tunable config so the dump captures both
            -- the visual binding state AND the multipliers that produced it.
            -- Helpful when triaging "looks wrong" reports — the slider state
            -- is the first thing to rule out.
            local header = string.format(
                "config: overlayIntensity=%.2f overlayScale=%.2f rimThickness=%.2f overlayAlpha=%.2f\n"
             .. "anim:   enableAnimations=%s animationStrength=%.2f animationSpeed=%.2f animatedOverlays=%d",
                GetCfg("overlayIntensity"), GetCfg("overlayScale"),
                GetCfg("rimThickness"),     GetCfg("overlayAlpha"),
                tostring(GetCfg("enableAnimations") and true or false),
                GetCfg("animationStrength"), GetCfg("animationSpeed"),
                self._animatedCount or 0)
            local body
            if #buf == 0 then
                body = header .. "\n(no nodes were painted in this pass — open the talent UI and set a Compare-To target before running /td debug)"
            else
                body = header .. "\n" .. table.concat(buf, "\n")
            end
            TalentDiff:ShowDebugLog("TalentDiff /td debug — overlay binding dump", body)
        end
    end
end
