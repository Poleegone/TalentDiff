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
--   rimAlpha   : alpha applied to the mask-clipped silhouette outer layer
--   rimPad     : px the outer mask layer extends beyond the button rect — this
--                is what produces the visible rim band, since the inner MOD
--                cutout is sized to the button rect itself.
--   desaturate : whether to dim the underlying icon (REMOVED "loss" feel)
--   glowAlpha  : LEGACY — alpha for the hollow-circle halo in fallback path
--   glowPad    : LEGACY — outward pad for the halo in fallback path
--   shadeAlpha : LEGACY — inward black shade in fallback path
local STATUS_VISUAL = {
    [1] = { color = {0.30, 1.00, 0.45, 1.00}, rimAlpha = 0.85, rimPad = 5, desaturate = false, glowAlpha = 0.70, glowPad = 5, shadeAlpha = 0    }, -- ADDED
    [2] = { color = {1.00, 0.18, 0.22, 1.00}, rimAlpha = 0.75, rimPad = 3, desaturate = true,  glowAlpha = 0.45, glowPad = 3, shadeAlpha = 0.30 }, -- REMOVED
    [3] = { color = {1.00, 0.78, 0.18, 1.00}, rimAlpha = 0.75, rimPad = 3, desaturate = false, glowAlpha = 0.55, glowPad = 3, shadeAlpha = 0    }, -- CHANGED
    [4] = { color = {0.50, 0.82, 1.00, 1.00}, rimAlpha = 0,    rimPad = 0, desaturate = false, glowAlpha = 0,    glowPad = 0, shadeAlpha = 0    }, -- RANK
}

-- Punchier than the prior values so +N / -N reads against icon sheen.
local DELTA_POS_RGB = {0.30, 1.00, 0.45}
local DELTA_NEG_RGB = {1.00, 0.30, 0.30}

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

-- Weak keys: a button frame dropped by Blizzard takes its overlay with it on GC.
OverlayManager.pool = setmetatable({}, { __mode = "k" })
OverlayManager.activeButtons = {}
OverlayManager.generation = 0

-- ---------- visual lookup --------------------------------------------------

function OverlayManager:GetVisual(statusIdx)
    return STATUS_VISUAL[statusIdx]
end

-- ---------- node-shape classification --------------------------------------

-- Classify a button as "circle" (passive talents — circular icons in Blizzard's
-- talent UI), "choice" (Selection + SubTreeSelection — octagonal in Blizzard's
-- UI), or nil (unknown / API unavailable). Used to pick a shape-matched rim
-- atlas; falls back to legacy strip+halo treatment when nil.
local function GetNodeShape(button)
    if not button or not button.GetNodeInfo then return nil end
    local ok, info = pcall(button.GetNodeInfo, button)
    if not ok or not info or not Enum or not Enum.TraitNodeType then return nil end
    if info.type == Enum.TraitNodeType.Selection then return "choice" end
    if info.type == Enum.TraitNodeType.SubTreeSelection then return "choice" end
    return "circle"
end

-- The rim itself is a Blizzard atlas that is *already* hollow ring art —
-- transparent center, edge-only pixels. The mask just clips the rim's outer
-- silhouette to the exact node shape. The atlas provides the ring; the mask
-- provides silhouette truth. No subtraction, no MOD blending, no full-rect
-- color fills — just one tinted hollow texture clipped to the node shape.
local RIM_ATLAS = {
    circle = "talents-node-circle-yellow",
    choice = "talents-node-choice-yellow",
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
        "Interface\\TalentFrame\\TalentsMaskApexNodeLargeCircle\\talents-node-apex-large-mask",
        "Interface\\TalentFrame\\TalentsMaskApexNodeSmallCircle\\talents-node-apex-small-mask",
    },
    choice = {
        "Interface\\TalentFrame\\TalentsMaskNodeChoice\\talents-node-choice-mask",
        "Interface\\TalentFrame\\TalentsMaskApexNodeLargeSquare\\talents-node-apex-active-large-mask",
        "Interface\\TalentFrame\\TalentsMaskNodeChoiceFlyout\\talents-node-choiceflyout-mask",
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
    local rgb = (d > 0) and DELTA_POS_RGB or DELTA_NEG_RGB
    ov.delta:SetTextColor(rgb[1], rgb[2], rgb[3], 1)
    ov.delta:Show()
end

-- Add/removed/changed: paint a hollow Blizzard rim atlas, tinted to status
-- color, clipped to the node silhouette by a Blizzard mask texture.
--
-- The atlas (talents-node-{circle,choice}-yellow) is already edge-only ring
-- art with a transparent interior — that's what produces the hollow look.
-- The mask (talents-node-*-mask) enforces that the rim's outer boundary
-- matches the actual node silhouette, including apex / sub-tree variants.
--
-- Single layer, ADD blend, no subtraction tricks. If the shape is unknown or
-- the atlas can't be set, the rim stays hidden — we never fall back to a
-- rectangular fill, since rectangular fills are the bug we're correcting.
local function PaintStructural(ov, button, visual)
    local r, g, b = visual.color[1], visual.color[2], visual.color[3]
    local shape = GetNodeShape(button)
    local atlasName = shape and RIM_ATLAS[shape] or nil
    local maskPath = ResolveMaskPath(shape)

    -- Always hide legacy fallback geometry — strip / halo / shade are no
    -- longer used. They remain in GetOrCreate only to avoid disturbing other
    -- code paths that reference ov.glow / ov.shade / ov.edges; left hidden
    -- here so they never contribute to the visual.
    SetEdgesShown(ov, false)
    ov.glow:Hide()
    ov.shade:Hide()

    if atlasName then
        local pad = visual.rimPad or 0
        ov.rim:ClearAllPoints()
        ov.rim:SetPoint("TOPLEFT",     ov, "TOPLEFT",     -pad,  pad)
        ov.rim:SetPoint("BOTTOMRIGHT", ov, "BOTTOMRIGHT",  pad, -pad)

        local okAtlas = pcall(ov.rim.SetAtlas, ov.rim, atlasName)
        if okAtlas then
            -- Apply mask AFTER SetAtlas so the atlas's UVs are established
            -- before clipping; clear any prior mask first to avoid stale state
            -- on a recycled button whose previous shape differed.
            pcall(ov.rim.SetMask, ov.rim, nil)
            if maskPath then
                pcall(ov.rim.SetMask, ov.rim, maskPath)
            end
            ov.rim:SetVertexColor(r, g, b, visual.rimAlpha or 0.8)
            ov.rim:Show()
        else
            ov.rim:Hide()
        end
    else
        ov.rim:Hide()
    end

    ApplyIconDesaturate(ov, button, visual.desaturate == true)
    ov.delta:Hide()
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
    if nodeDiff.status == STATUS_RANK then
        PaintRank(ov, button, nodeDiff)
    else
        PaintStructural(ov, button, visual)
    end
    ov:Show()

    -- Stamp the generation so RefreshAll's reaper pass knows this overlay is
    -- still wanted. Plain table value on the active set; the button itself is
    -- the key so iteration order doesn't matter.
    self.activeButtons[button] = self.generation
end

function OverlayManager:Release(button)
    if not button then return end
    local ov = self.pool[button]
    if ov then
        ApplyIconDesaturate(ov, button, false)
        ov:Hide()
    end
    self.activeButtons[button] = nil
end

function OverlayManager:ClearAll()
    for button in pairs(self.activeButtons) do
        local ov = self.pool[button]
        if ov then
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
                ApplyIconDesaturate(ov, button, false)
                ov:Hide()
            end
            self.activeButtons[button] = nil
        end
    end
end
