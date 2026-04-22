-- Deathlapse
-- Shows the last 20 seconds before death as a scrollable visual timeline.
-- A minimap button auto-shows the panel on death and hides it on resurrection.

local addonName = "Deathlapse"
Deathlapse = {}

-- ============================================================================
-- Constants
-- ============================================================================

local TIMELINE_DURATION    = 20      -- seconds of history captured
local CANVAS_LEFT_PAD      = 38      -- px for time labels on the left
local CANVAS_RIGHT_PAD     = 8
local CANVAS_H             = 118     -- total canvas height in px
local CANVAS_AXIS_Y        = 58      -- px from canvas top to the axis line
local DAMAGE_MAX_H         = 50      -- max bar height for damage (above axis)
local HEAL_MAX_H           = 44      -- max bar height for heals (below axis)
local LOG_REF_DAMAGE       = 10001   -- log scale reference: 10k = DAMAGE_MAX_H
local LOG_REF_HEAL         = 8001
local POOL_SIZE            = 220     -- texture pool per canvas
local BUFFER_CAPACITY      = 500     -- max events in rolling buffer
local BUFFER_PRUNE_AGE     = 25      -- seconds; prune events older than this

local FRAME_W              = 464
local FRAME_HEADER_H       = 24
local FRAME_KILLER_H       = 20
local TIMELINE_EFFECTIVE_W = FRAME_W - CANVAS_LEFT_PAD - CANVAS_RIGHT_PAD  -- 418 px

local SCHOOL_MASKS  = {0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40}
local SCHOOL_COLORS = {
    [0x01] = {0.85, 0.29, 0.10},   -- Physical
    [0x02] = {1.00, 0.92, 0.23},   -- Holy
    [0x04] = {1.00, 0.47, 0.00},   -- Fire
    [0x08] = {0.29, 0.80, 0.13},   -- Nature
    [0x10] = {0.24, 0.73, 0.97},   -- Frost
    [0x20] = {0.52, 0.10, 0.87},   -- Shadow
    [0x40] = {0.88, 0.25, 0.99},   -- Arcane
}
local DAMAGE_DEFAULT_COLOR = {0.85, 0.20, 0.20}
local HEAL_COLOR           = {0.22, 0.85, 0.38}
local OVERKILL_COLOR       = {1.00, 0.08, 0.08}

local DAMAGE_SUBEVENTS = {
    SWING_DAMAGE          = true,
    RANGE_DAMAGE          = true,
    SPELL_DAMAGE          = true,
    SPELL_PERIODIC_DAMAGE = true,
    ENVIRONMENTAL_DAMAGE  = true,
}
local HEAL_SUBEVENTS = {
    SPELL_HEAL          = true,
    SPELL_PERIODIC_HEAL = true,
}

-- ============================================================================
-- State
-- ============================================================================

local playerGUID    = nil
local eventBuffer   = {}
local deathSnapshot = nil
local deathTime     = nil
local killerName    = nil
local killerSpell   = nil
local minimapButton = nil
local timelineFrame = nil
local isDead        = false

-- ============================================================================
-- Utility
-- ============================================================================

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffcc3333[Deathlapse]|r " .. msg)
end

local function GetDB()
    if type(DeathlapseDB) ~= "table" then
        DeathlapseDB = {}
    end
    return DeathlapseDB
end

local function GetMinimapSettings()
    local db = GetDB()
    if type(db.minimap) ~= "table" then
        db.minimap = {}
    end
    if db.minimap.show == nil then
        db.minimap.show = true
    end
    if not db.minimap.position then
        db.minimap.position = 200
    end
    return db.minimap
end

local function SetSolidColor(tex, r, g, b, a)
    if tex.SetColorTexture then
        tex:SetColorTexture(r, g, b, a)
    else
        tex:SetTexture(r, g, b, a)
    end
end

local function HasBit(value, flag)
    if bit and bit.band then
        return bit.band(value, flag) ~= 0
    end
    if bit32 and bit32.band then
        return bit32.band(value, flag) ~= 0
    end
    return (value % (flag + flag)) >= flag
end

local function SchoolColor(school)
    if type(school) ~= "number" then
        return DAMAGE_DEFAULT_COLOR
    end
    for i = 1, #SCHOOL_MASKS do
        if HasBit(school, SCHOOL_MASKS[i]) then
            return SCHOOL_COLORS[SCHOOL_MASKS[i]] or DAMAGE_DEFAULT_COLOR
        end
    end
    return DAMAGE_DEFAULT_COLOR
end

local function SafeNumber(v)
    if v == nil then return nil end
    local ok, n = pcall(tonumber, v)
    return (ok and type(n) == "number") and n or nil
end

-- ============================================================================
-- Event Buffer
-- ============================================================================

local function PruneBuffer(now)
    local cutoff = now - BUFFER_PRUNE_AGE
    local first = 1
    while first <= #eventBuffer and eventBuffer[first].time < cutoff do
        first = first + 1
    end
    if first > 1 then
        local len = #eventBuffer - first + 1
        for i = 1, len do
            eventBuffer[i] = eventBuffer[i + first - 1]
        end
        for i = len + 1, #eventBuffer do
            eventBuffer[i] = nil
        end
    end
end

local function AddEvent(ev)
    eventBuffer[#eventBuffer + 1] = ev
    if #eventBuffer > BUFFER_CAPACITY then
        table.remove(eventBuffer, 1)
    end
    PruneBuffer(ev.time)
end

local function SnapshotForDeath(now)
    local cutoff = now - TIMELINE_DURATION
    local snap = {}
    for _, ev in ipairs(eventBuffer) do
        if ev.time >= cutoff then
            snap[#snap + 1] = ev
        end
    end
    return snap
end

-- ============================================================================
-- Combat Log Parsing
-- ============================================================================

local function ParseCombatEvent()
    if not CombatLogGetCurrentEventInfo then return end

    local _ts, subevent, _hid,
          srcGUID, srcName, _sf, _srf,
          dstGUID, _dn, _df, _drf,
          p1, p2, p3, p4, p5, p6, p7, p8, p9, p10
          = CombatLogGetCurrentEventInfo()

    if not subevent or not playerGUID then return end

    local isDestPlayer = dstGUID == playerGUID

    if DAMAGE_SUBEVENTS[subevent] and isDestPlayer then
        local amount, school, spellId, spellName, isCrit, overkill

        if subevent == "SWING_DAMAGE" then
            amount   = SafeNumber(p1) or 0
            overkill = SafeNumber(p2) or 0
            school   = SafeNumber(p3) or 0x01
            isCrit   = (p7 == true)
            spellName = "Melee"
        elseif subevent == "ENVIRONMENTAL_DAMAGE" then
            spellName = (type(p1) == "string" and p1 ~= "") and p1 or "Environment"
            amount   = SafeNumber(p2) or 0
            overkill = SafeNumber(p3) or 0
            school   = SafeNumber(p4) or 0x01
            isCrit   = (p8 == true)
        else
            spellId   = SafeNumber(p1)
            spellName = (type(p2) == "string" and p2 ~= "") and p2 or "Spell"
            school    = SafeNumber(p3) or 0x01
            amount    = SafeNumber(p4) or 0
            overkill  = SafeNumber(p5) or 0
            isCrit    = (p10 == true)
        end

        if amount > 0 then
            AddEvent({
                time      = GetTime(),
                subevent  = subevent,
                srcName   = (type(srcName) == "string" and srcName ~= "") and srcName or "Unknown",
                srcGUID   = srcGUID or "",
                amount    = amount,
                school    = school,
                spellId   = spellId,
                spellName = spellName,
                isHeal    = false,
                isCrit    = isCrit,
                overkill  = overkill,
            })
        end

    elseif HEAL_SUBEVENTS[subevent] and isDestPlayer then
        local spellId   = SafeNumber(p1)
        local spellName = (type(p2) == "string" and p2 ~= "") and p2 or "Heal"
        local school    = SafeNumber(p3) or 0x02
        local amount    = SafeNumber(p4) or 0
        local isCrit    = (p7 == true)

        if amount > 0 then
            AddEvent({
                time      = GetTime(),
                subevent  = subevent,
                srcName   = (type(srcName) == "string" and srcName ~= "") and srcName or "Unknown",
                srcGUID   = srcGUID or "",
                amount    = amount,
                school    = school,
                spellId   = spellId,
                spellName = spellName,
                isHeal    = true,
                isCrit    = isCrit,
                overkill  = 0,
            })
        end
    end
end

-- ============================================================================
-- Minimap Button
-- ============================================================================

local function UpdateMinimapButtonPosition()
    if not minimapButton then return end
    local settings = GetMinimapSettings()
    local angle    = math.rad(settings.position or 200)
    local radius   = 80
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function CreateMinimapButton()
    if minimapButton then return end

    minimapButton = CreateFrame("Button", "DeathlapseMinimapButton", Minimap)
    minimapButton:SetSize(32, 32)
    minimapButton:SetFrameStrata("MEDIUM")
    minimapButton:SetFrameLevel(8)
    minimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local icon = minimapButton:CreateTexture(nil, "BACKGROUND")
    icon:SetTexture("Interface\\Icons\\INV_Misc_Bone_HumanSkull_01")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    minimapButton.icon = icon

    local border = minimapButton:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(56, 56)
    border:SetPoint("TOPLEFT")

    local dot = minimapButton:CreateTexture(nil, "OVERLAY")
    dot:SetSize(8, 8)
    dot:SetPoint("TOPRIGHT", minimapButton, "TOPRIGHT", -2, -2)
    SetSolidColor(dot, 1, 0.1, 0.1, 0.9)
    dot:Hide()
    minimapButton.deathDot = dot

    minimapButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("|cffcc3333Deathlapse|r")
        if deathSnapshot and #deathSnapshot > 0 then
            GameTooltip:AddLine("Left-click to toggle death timeline", 1, 1, 1)
            GameTooltip:AddLine("Right-click to clear record", 0.7, 0.7, 0.7)
        else
            GameTooltip:AddLine("Waiting for death data...", 0.6, 0.6, 0.6)
            GameTooltip:AddLine("Timeline appears automatically on death", 0.5, 0.5, 0.5)
        end
        GameTooltip:Show()
    end)

    minimapButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    minimapButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    minimapButton:SetScript("OnClick", function(_, button)
        if button == "LeftButton" then
            Deathlapse:ToggleTimeline()
        elseif button == "RightButton" then
            Deathlapse:ClearSnapshot()
        end
    end)

    minimapButton:RegisterForDrag("LeftButton")
    minimapButton.dragging = false

    minimapButton:SetScript("OnDragStart", function(self)
        self.dragging = true
    end)

    minimapButton:SetScript("OnDragStop", function(self)
        self.dragging = false
        local settings = GetMinimapSettings()
        local mx, my  = Minimap:GetCenter()
        local px, py  = GetCursorPosition()
        local scale   = Minimap:GetEffectiveScale()
        settings.position = math.deg(math.atan2(py / scale - my, px / scale - mx))
        UpdateMinimapButtonPosition()
    end)

    minimapButton:SetScript("OnUpdate", function(self)
        if not self.dragging then return end
        local settings = GetMinimapSettings()
        local mx, my  = Minimap:GetCenter()
        local px, py  = GetCursorPosition()
        local scale   = Minimap:GetEffectiveScale()
        settings.position = math.deg(math.atan2(py / scale - my, px / scale - mx))
        UpdateMinimapButtonPosition()
    end)
end

function Deathlapse:UpdateMinimapIndicator()
    if not minimapButton then return end
    if deathSnapshot and #deathSnapshot > 0 then
        minimapButton.deathDot:Show()
    else
        minimapButton.deathDot:Hide()
    end
end

-- ============================================================================
-- Timeline Geometry Helpers  (exposed on Deathlapse for testing)
-- ============================================================================

function Deathlapse.EventXPosition(ev, refDeathTime)
    local dt = refDeathTime or deathTime
    if not dt then return nil end
    local fraction = (ev.time - dt + TIMELINE_DURATION) / TIMELINE_DURATION
    fraction = math.max(0, math.min(1, fraction))
    return CANVAS_LEFT_PAD + fraction * TIMELINE_EFFECTIVE_W
end

function Deathlapse.BarHeight(amount, maxH, logRef)
    if not amount or amount <= 0 then return 2 end
    local scale = maxH / math.log(logRef + 1)
    return math.max(2, math.min(maxH, scale * math.log(amount + 1)))
end

-- ============================================================================
-- Timeline Frame
-- ============================================================================

local function CreateTimelineFrame()
    if timelineFrame then return end

    local TOTAL_H = FRAME_HEADER_H + FRAME_KILLER_H + CANVAS_H + 22

    local f = CreateFrame("Frame", "DeathlapseTimelineFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(FRAME_W, TOTAL_H)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 100)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        GetDB().timelinePosition = {point = point, relPoint = relPoint, x = x, y = y}
    end)
    f:SetFrameStrata("HIGH")
    f:Hide()

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", f, "TOP", 0, -6)
    title:SetText("|cffcc3333Deathlapse|r — Last 20 Seconds")

    tinsert(UISpecialFrames, "DeathlapseTimelineFrame")

    -- Killer / summary line
    local killerFS = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    killerFS:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -(FRAME_HEADER_H + 4))
    killerFS:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -(FRAME_HEADER_H + 4))
    killerFS:SetJustifyH("LEFT")
    killerFS:SetText("")
    f.killerFS = killerFS

    -- Canvas
    local canvas = CreateFrame("Frame", nil, f)
    canvas:SetSize(FRAME_W, CANVAS_H)
    canvas:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -(FRAME_HEADER_H + FRAME_KILLER_H))
    f.canvas = canvas

    local bg = canvas:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    SetSolidColor(bg, 0, 0, 0, 0.45)

    -- Axis line
    local axis = canvas:CreateTexture(nil, "ARTWORK")
    axis:SetSize(TIMELINE_EFFECTIVE_W, 1)
    axis:SetPoint("TOPLEFT", canvas, "TOPLEFT", CANVAS_LEFT_PAD, -CANVAS_AXIS_Y)
    SetSolidColor(axis, 0.75, 0.75, 0.75, 0.65)

    -- Left fence (t = -20s)
    local leftFence = canvas:CreateTexture(nil, "ARTWORK")
    leftFence:SetSize(1, CANVAS_H - 12)
    leftFence:SetPoint("TOPLEFT", canvas, "TOPLEFT", CANVAS_LEFT_PAD, -6)
    SetSolidColor(leftFence, 0.5, 0.5, 0.5, 0.45)

    -- Death marker (t = 0, right edge)
    local deathLine = canvas:CreateTexture(nil, "ARTWORK")
    deathLine:SetSize(2, CANVAS_H - 12)
    deathLine:SetPoint("TOPLEFT", canvas, "TOPLEFT", CANVAS_LEFT_PAD + TIMELINE_EFFECTIVE_W - 1, -6)
    SetSolidColor(deathLine, 1, 0.1, 0.1, 0.9)

    local deathLabel = canvas:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    deathLabel:SetPoint("TOPRIGHT", canvas, "TOPRIGHT", -2, -5)
    deathLabel:SetText("|cffff2222NOW|r")

    -- Tick marks at -15s, -10s, -5s
    for i = 1, 3 do
        local frac = (i * 5) / TIMELINE_DURATION
        local tx = CANVAS_LEFT_PAD + frac * TIMELINE_EFFECTIVE_W
        local tick = canvas:CreateTexture(nil, "ARTWORK")
        tick:SetSize(1, 6)
        tick:SetPoint("TOPLEFT", canvas, "TOPLEFT", tx, -(CANVAS_AXIS_Y - 3))
        SetSolidColor(tick, 0.6, 0.6, 0.6, 0.5)
    end

    -- Time labels below canvas
    local labelY = -(FRAME_HEADER_H + FRAME_KILLER_H + CANVAS_H + 2)
    for i = 0, 4 do
        local frac  = i / 4
        local xPos  = CANVAS_LEFT_PAD + frac * TIMELINE_EFFECTIVE_W - 8
        local lbl   = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        lbl:SetPoint("TOPLEFT", f, "TOPLEFT", xPos, labelY)
        local secs  = -TIMELINE_DURATION + frac * TIMELINE_DURATION
        lbl:SetText(string.format("%ds", math.floor(secs)))
    end
    local nowLbl = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    nowLbl:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, labelY)
    nowLbl:SetText("|cffff2222now|r")

    -- Pre-create texture pool (reused each render)
    canvas.barPool    = {}
    canvas.barPoolIdx = 0
    for i = 1, POOL_SIZE do
        local tex = canvas:CreateTexture(nil, "ARTWORK")
        tex:Hide()
        canvas.barPool[i] = tex
    end

    -- Hover detection overlay
    local hover = CreateFrame("Frame", nil, canvas)
    hover:SetAllPoints(canvas)
    hover:EnableMouse(true)
    f.hover = hover

    hover:SetScript("OnUpdate", function(self)
        if not deathSnapshot or #deathSnapshot == 0 then
            GameTooltip:Hide()
            return
        end
        if not self:IsMouseOver() then
            GameTooltip:Hide()
            return
        end

        local screenX, screenY = GetCursorPosition()
        local scale  = UIParent:GetEffectiveScale()
        local vx     = screenX / scale
        local left   = self:GetLeft() or 0
        local relX   = vx - left

        local closest, closestDist = nil, 10
        for _, ev in ipairs(deathSnapshot) do
            local ex = Deathlapse.EventXPosition(ev, deathTime)
            if ex then
                local d = math.abs(relX - ex)
                if d < closestDist then
                    closestDist = d
                    closest = ev
                end
            end
        end

        if closest then
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            if closest.isHeal then
                GameTooltip:SetText("|cff22dd55" .. (closest.spellName or "Heal") .. "|r")
            else
                GameTooltip:SetText("|cffff3333" .. (closest.spellName or "Attack") .. "|r")
            end
            GameTooltip:AddLine("From: " .. (closest.srcName or "Unknown"), 0.8, 0.8, 0.8)

            local amtLine
            if closest.isHeal then
                amtLine = string.format("|cff22dd55+%d healed|r", closest.amount)
            else
                amtLine = string.format("|cffff3333-%d damage|r", closest.amount)
            end
            if closest.isCrit then
                amtLine = amtLine .. " |cffffcc00(crit)|r"
            end
            if (not closest.isHeal) and closest.overkill and closest.overkill > 0 then
                amtLine = amtLine .. string.format(" |cffff2222[+%d overkill]|r", closest.overkill)
            end
            GameTooltip:AddLine(amtLine, 1, 1, 1)

            local tOff = closest.time - deathTime
            GameTooltip:AddLine(string.format("%.1fs before death", math.abs(tOff)), 0.55, 0.55, 0.55)
            GameTooltip:Show()
        else
            GameTooltip:Hide()
        end
    end)

    hover:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    timelineFrame = f
end

local function RenderTimeline()
    if not timelineFrame then return end

    -- Reset texture pool
    local canvas = timelineFrame.canvas
    canvas.barPoolIdx = 0
    for _, tex in ipairs(canvas.barPool) do
        tex:Hide()
    end

    if not deathSnapshot or #deathSnapshot == 0 then
        timelineFrame.killerFS:SetText("|cff888888No death record yet. Die to start tracking.|r")
        return
    end

    -- Build killer/summary header
    local header = ""
    if killerName then
        header = "Killed by: |cffff4444" .. killerName .. "|r"
        if killerSpell then
            header = header .. "  — " .. killerSpell
        end
    end
    local dmgCount, healCount, totalDmg, totalHeal = 0, 0, 0, 0
    for _, ev in ipairs(deathSnapshot) do
        if ev.isHeal then
            healCount = healCount + 1
            totalHeal = totalHeal + ev.amount
        else
            dmgCount  = dmgCount + 1
            totalDmg  = totalDmg + ev.amount
        end
    end
    local summary = string.format("  |cffff6666%d hits  %d dmg|r", dmgCount, totalDmg)
    if healCount > 0 then
        summary = summary .. string.format("  |cff44ff88%d heals  %d healed|r", healCount, totalHeal)
    end
    timelineFrame.killerFS:SetText(header .. summary)

    -- Draw event markers
    for _, ev in ipairs(deathSnapshot) do
        local x = Deathlapse.EventXPosition(ev, deathTime)
        if x then
            local barW = ev.isCrit and 5 or 3
            local r, g, b, a

            if ev.isHeal then
                r, g, b = HEAL_COLOR[1], HEAL_COLOR[2], HEAL_COLOR[3]
                a = ev.isCrit and 1.0 or 0.82
            elseif ev.overkill and ev.overkill > 0 then
                r, g, b = OVERKILL_COLOR[1], OVERKILL_COLOR[2], OVERKILL_COLOR[3]
                a = 1.0
                barW = 5
            else
                local col = SchoolColor(ev.school)
                r, g, b = col[1], col[2], col[3]
                a = ev.isCrit and 1.0 or 0.82
            end

            local h, yTop
            if ev.isHeal then
                h    = Deathlapse.BarHeight(ev.amount, HEAL_MAX_H, LOG_REF_HEAL)
                yTop = -CANVAS_AXIS_Y                  -- grows downward from axis
            else
                h    = Deathlapse.BarHeight(ev.amount, DAMAGE_MAX_H, LOG_REF_DAMAGE)
                yTop = -(CANVAS_AXIS_Y - h)            -- grows upward to axis
            end

            canvas.barPoolIdx = canvas.barPoolIdx + 1
            local tex = canvas.barPool[canvas.barPoolIdx]
            if not tex then break end

            tex:SetSize(barW, h)
            tex:SetPoint("TOPLEFT", canvas, "TOPLEFT", x - math.floor(barW / 2), yTop)
            SetSolidColor(tex, r, g, b, a)
            tex:Show()
        end
    end
end

function Deathlapse:ShowTimeline()
    if not timelineFrame then
        CreateTimelineFrame()
    end
    local pos = GetDB().timelinePosition
    if pos then
        timelineFrame:ClearAllPoints()
        timelineFrame:SetPoint(pos.point, UIParent, pos.relPoint, pos.x, pos.y)
    end
    RenderTimeline()
    timelineFrame:Show()
end

function Deathlapse:HideTimeline()
    if timelineFrame then
        timelineFrame:Hide()
    end
end

function Deathlapse:ToggleTimeline()
    if not timelineFrame or not timelineFrame:IsShown() then
        self:ShowTimeline()
    else
        self:HideTimeline()
    end
end

function Deathlapse:ClearSnapshot()
    deathSnapshot = nil
    deathTime     = nil
    killerName    = nil
    killerSpell   = nil
    isDead        = false
    self:HideTimeline()
    self:UpdateMinimapIndicator()
    Print("Death record cleared.")
end

-- ============================================================================
-- Death Handling
-- ============================================================================

local function FindKiller(snap)
    local kName, kSpell = nil, nil
    -- prefer the event with overkill > 0 closest to end of snap
    for i = #snap, 1, -1 do
        local ev = snap[i]
        if not ev.isHeal and ev.overkill and ev.overkill > 0 then
            kName  = ev.srcName
            kSpell = (ev.spellName ~= "Melee") and ev.spellName or nil
            return kName, kSpell
        end
    end
    -- fallback: last damage event
    for i = #snap, 1, -1 do
        local ev = snap[i]
        if not ev.isHeal then
            kName  = ev.srcName
            kSpell = (ev.spellName ~= "Melee") and ev.spellName or nil
            return kName, kSpell
        end
    end
    return nil, nil
end

local function OnPlayerDied()
    isDead    = true
    deathTime = GetTime()
    deathSnapshot = SnapshotForDeath(deathTime)
    killerName, killerSpell = FindKiller(deathSnapshot)
    Deathlapse:UpdateMinimapIndicator()
    if GetMinimapSettings().showOnDeath ~= false then
        Deathlapse:ShowTimeline()
    end
end

local function OnPlayerAlive()
    isDead = false
    Deathlapse:HideTimeline()
    -- Snapshot is kept until next death or manual clear (/dl clear)
end

-- ============================================================================
-- Test Data Generator
-- ============================================================================

local function GenerateTestSnapshot()
    local now = GetTime()
    deathTime = now
    local snap = {}
    local srcNames = {"Onyxia", "Onyxia's Whelp", "Guard Mol'dar", "Arcanist Doan"}
    local spells   = {"Wing Buffet", "Flame Breath", "Deep Breath", "Shadowbolt", "Fireball"}
    local schools  = {0x01, 0x04, 0x20, 0x08, 0x10}

    for i = 1, 35 do
        local t      = now - TIMELINE_DURATION + (i / 35) * TIMELINE_DURATION
        local isHeal = (i % 6 == 0)
        local amount = math.random(isHeal and 200 or 50, isHeal and 4000 or 9000)
        local school = schools[math.random(#schools)]
        snap[#snap + 1] = {
            time      = t,
            subevent  = isHeal and "SPELL_HEAL" or "SPELL_DAMAGE",
            srcName   = isHeal and "Priest" or srcNames[math.random(#srcNames)],
            srcGUID   = "",
            amount    = amount,
            school    = school,
            spellId   = 1000 + i,
            spellName = isHeal and "Flash Heal" or spells[math.random(#spells)],
            isHeal    = isHeal,
            isCrit    = (math.random(4) == 1),
            overkill  = (not isHeal and i == 35) and math.random(500, 3000) or 0,
        }
    end
    deathSnapshot = snap
    killerName, killerSpell = FindKiller(snap)
end

-- ============================================================================
-- Slash Commands
-- ============================================================================

SLASH_DEATHLAPSE1 = "/deathlapse"
SLASH_DEATHLAPSE2 = "/dl"
SlashCmdList["DEATHLAPSE"] = function(msg)
    local args = {}
    for word in string.gmatch(msg, "%S+") do
        args[#args + 1] = string.lower(word)
    end
    local cmd = args[1] or ""

    if cmd == "" or cmd == "show" then
        Deathlapse:ShowTimeline()
    elseif cmd == "hide" then
        Deathlapse:HideTimeline()
    elseif cmd == "clear" then
        Deathlapse:ClearSnapshot()
    elseif cmd == "minimap" or cmd == "mm" then
        local s = GetMinimapSettings()
        s.show = not s.show
        if s.show then
            if not minimapButton then CreateMinimapButton() end
            minimapButton:Show()
            UpdateMinimapButtonPosition()
            Print("Minimap button shown.")
        else
            if minimapButton then minimapButton:Hide() end
            Print("Minimap button hidden. /dl minimap to restore.")
        end
    elseif cmd == "autoshow" then
        local s = GetMinimapSettings()
        s.showOnDeath = not (s.showOnDeath ~= false)
        Print("Auto-show on death: " .. (s.showOnDeath ~= false and "enabled" or "disabled"))
    elseif cmd == "test" then
        GenerateTestSnapshot()
        Deathlapse:UpdateMinimapIndicator()
        Deathlapse:ShowTimeline()
        Print("Showing test data.")
    elseif cmd == "help" or cmd == "?" then
        Print("Commands: show | hide | clear | minimap | autoshow | test | help")
    else
        Deathlapse:ToggleTimeline()
    end
end

-- ============================================================================
-- Event Handling
-- ============================================================================

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_DEAD")
eventFrame:RegisterEvent("PLAYER_ALIVE")
eventFrame:RegisterEvent("PLAYER_UNGHOST")
eventFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")

eventFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        playerGUID = UnitGUID and UnitGUID("player") or nil
        if GetMinimapSettings().show then
            CreateMinimapButton()
            UpdateMinimapButtonPosition()
        end
        Print("Loaded. Die to see your timeline, or /dl test to preview.")

    elseif event == "PLAYER_ENTERING_WORLD" then
        playerGUID = UnitGUID and UnitGUID("player") or nil

    elseif event == "PLAYER_DEAD" then
        OnPlayerDied()

    elseif event == "PLAYER_ALIVE" or event == "PLAYER_UNGHOST" then
        OnPlayerAlive()

    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        ParseCombatEvent()
    end
end)

-- ============================================================================
-- Exports for testing (test harness can reach these via Deathlapse table)
-- ============================================================================

Deathlapse._internal = {
    SchoolColor       = SchoolColor,
    HasBit            = HasBit,
    SafeNumber        = SafeNumber,
    PruneBuffer       = PruneBuffer,
    AddEvent          = AddEvent,
    SnapshotForDeath  = SnapshotForDeath,
    FindKiller        = FindKiller,
    GetEventBuffer    = function() return eventBuffer end,
    SetEventBuffer    = function(t) eventBuffer = t end,
    SetDeathTime      = function(t) deathTime = t end,
    TIMELINE_DURATION = TIMELINE_DURATION,
    CANVAS_LEFT_PAD   = CANVAS_LEFT_PAD,
    TIMELINE_EFFECTIVE_W = TIMELINE_EFFECTIVE_W,
}
