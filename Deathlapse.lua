-- Deathlapse
-- Death recap for TBC Anniversary Classic.
-- On death shows a waterfall HP chart (HotS Recap style): each column is one
-- hit-group, the blue bar is HP remaining, the red cap is damage taken,
-- green cap for heals.  Spell icons with source names appear below each column.

local addonName = "Deathlapse"
Deathlapse = {}

-- ============================================================================
-- Constants
-- ============================================================================

local TIMELINE_DURATION  = 20
local BUFFER_CAPACITY    = 500
local BUFFER_PRUNE_AGE   = 25

local GROUP_MERGE_WINDOW = 1.0   -- same spell+source within this many seconds → one column
local MAX_GROUPS         = 28    -- cap columns; oldest groups are dropped when exceeded

local FRAME_W            = 560
local FRAME_HEADER_H     = 24
local FRAME_SUMMARY_H    = 26
local CHART_LEFT         = 36   -- width of Y-label strip
local CHART_RIGHT        = 10
local CHART_H            = 130  -- height of the HP bar area
local ICON_ROW_H         = 28
local TIME_ROW_H         = 16
local FRAME_H            = FRAME_HEADER_H + FRAME_SUMMARY_H + CHART_H + ICON_ROW_H + TIME_ROW_H + 14

local CHART_W            = FRAME_W - CHART_LEFT - CHART_RIGHT   -- 514 px
local MIN_COL_W          = 18
local ICON_SIZE          = 22

local MELEE_ICON         = "Interface\\Icons\\Ability_MeleeDamage"
local ENV_ICON           = "Interface\\Icons\\Spell_Nature_Drowning"
local FALLBACK_ICON      = "Interface\\Icons\\INV_Misc_QuestionMark"

local SCHOOL_MASKS  = {0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40}
local SCHOOL_COLORS = {
    [0x01] = {0.85, 0.29, 0.10},
    [0x02] = {1.00, 0.92, 0.23},
    [0x04] = {1.00, 0.47, 0.00},
    [0x08] = {0.29, 0.80, 0.13},
    [0x10] = {0.24, 0.73, 0.97},
    [0x20] = {0.52, 0.10, 0.87},
    [0x40] = {0.88, 0.25, 0.99},
}
local COLOR_HP_BLUE   = {0.20, 0.47, 0.80}
local COLOR_DMG_RED   = {0.80, 0.13, 0.13}
local COLOR_HEAL_GRN  = {0.13, 0.75, 0.27}
local COLOR_HP_LINE   = {1.00, 1.00, 1.00}

local DAMAGE_SUBEVENTS = {
    SWING_DAMAGE=true, RANGE_DAMAGE=true,
    SPELL_DAMAGE=true, SPELL_PERIODIC_DAMAGE=true,
    ENVIRONMENTAL_DAMAGE=true,
}
local HEAL_SUBEVENTS = { SPELL_HEAL=true, SPELL_PERIODIC_HEAL=true }

-- ============================================================================
-- State
-- ============================================================================

local playerGUID    = nil
local playerMaxHp   = 1
local eventBuffer   = {}
local deathSnapshot = nil   -- raw events
local deathGroups   = nil   -- grouped columns
local deathTime     = nil
local killerName    = nil
local killerSpell   = nil
local minimapButton = nil
local timelineFrame = nil

-- ============================================================================
-- Utility
-- ============================================================================

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffcc3333[Deathlapse]|r " .. msg)
end

local function GetDB()
    if type(DeathlapseDB) ~= "table" then DeathlapseDB = {} end
    return DeathlapseDB
end

local function GetMinimapSettings()
    local db = GetDB()
    if type(db.minimap) ~= "table" then db.minimap = {} end
    if db.minimap.show == nil then db.minimap.show = true end
    if not db.minimap.position then db.minimap.position = 200 end
    return db.minimap
end

local function SetSolidColor(tex, r, g, b, a)
    if tex.SetColorTexture then tex:SetColorTexture(r, g, b, a)
    else tex:SetTexture(r, g, b, a) end
end

local function HasBit(value, flag)
    if bit and bit.band then return bit.band(value, flag) ~= 0 end
    if bit32 and bit32.band then return bit32.band(value, flag) ~= 0 end
    return (value % (flag + flag)) >= flag
end

local function SchoolColor(school)
    if type(school) ~= "number" then return SCHOOL_COLORS[0x01] end
    for i = 1, #SCHOOL_MASKS do
        if HasBit(school, SCHOOL_MASKS[i]) then
            return SCHOOL_COLORS[SCHOOL_MASKS[i]] or SCHOOL_COLORS[0x01]
        end
    end
    return SCHOOL_COLORS[0x01]
end

local function SafeNumber(v)
    if v == nil then return nil end
    local ok, n = pcall(tonumber, v)
    return (ok and type(n) == "number") and n or nil
end

local function GetEventIcon(ev)
    if ev.spellId and GetSpellInfo then
        local _, _, icon = GetSpellInfo(ev.spellId)
        if icon then return icon end
    end
    if ev.subevent == "SWING_DAMAGE" then return MELEE_ICON end
    if ev.subevent == "ENVIRONMENTAL_DAMAGE" then return ENV_ICON end
    return FALLBACK_ICON
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
        for i = 1, len do eventBuffer[i] = eventBuffer[i + first - 1] end
        for i = len + 1, #eventBuffer do eventBuffer[i] = nil end
    end
end

local function AddEvent(ev)
    eventBuffer[#eventBuffer + 1] = ev
    if #eventBuffer > BUFFER_CAPACITY then table.remove(eventBuffer, 1) end
    PruneBuffer(ev.time)
end

local function SnapshotForDeath(now)
    local cutoff = now - TIMELINE_DURATION
    local snap = {}
    for _, ev in ipairs(eventBuffer) do
        if ev.time >= cutoff then snap[#snap + 1] = ev end
    end
    return snap
end

-- ============================================================================
-- Event Grouping
-- ============================================================================

local function GroupEvents(snapshot)
    local groups = {}
    for _, ev in ipairs(snapshot) do
        local merged = false
        for i = #groups, math.max(1, #groups - 6), -1 do
            local g = groups[i]
            if g.srcName == ev.srcName
               and g.spellName == ev.spellName
               and g.isHeal == ev.isHeal
               and (ev.time - g.lastTime) <= GROUP_MERGE_WINDOW then
                g.totalAmount = g.totalAmount + ev.amount
                g.count       = g.count + 1
                g.lastTime    = ev.time
                g.hasCrit     = g.hasCrit or ev.isCrit
                g.overkill    = g.overkill + (ev.overkill or 0)
                merged        = true
                break
            end
        end
        if not merged then
            groups[#groups + 1] = {
                time        = ev.time,
                lastTime    = ev.time,
                srcName     = ev.srcName,
                spellName   = ev.spellName,
                spellId     = ev.spellId,
                subevent    = ev.subevent,
                school      = ev.school,
                isHeal      = ev.isHeal,
                totalAmount = ev.amount,
                count       = 1,
                hasCrit     = ev.isCrit,
                overkill    = ev.overkill or 0,
                iconEv      = ev,
            }
        end
    end
    -- Trim to MAX_GROUPS most recent
    while #groups > MAX_GROUPS do table.remove(groups, 1) end
    return groups
end

-- ============================================================================
-- HP Trajectory  (reconstructed backwards from death)
-- ============================================================================

local function ComputeHpTrajectory(groups, maxHp)
    if not maxHp or maxHp <= 0 then maxHp = 1 end
    local n = #groups
    local hpAfter  = {}
    local hpBefore = {}

    local hp = 0.0   -- start at 0 (death), walk backwards
    for i = n, 1, -1 do
        local g = groups[i]
        hpAfter[i] = math.max(0, math.min(1, hp))
        local effectiveAmt = g.totalAmount - g.overkill
        if effectiveAmt < 0 then effectiveAmt = 0 end
        local delta = effectiveAmt / maxHp
        if g.isHeal then hp = hp - delta else hp = hp + delta end
        hpBefore[i] = math.max(0, math.min(1, hp))
    end
    return hpBefore, hpAfter
end

-- ============================================================================
-- Attacker Breakdown
-- ============================================================================

local function TopAttackers(groups, limit)
    local totals = {}
    local totalDmg = 0
    for _, g in ipairs(groups) do
        if not g.isHeal then
            totals[g.srcName] = (totals[g.srcName] or 0) + g.totalAmount
            totalDmg = totalDmg + g.totalAmount
        end
    end
    local sorted = {}
    for name, amt in pairs(totals) do sorted[#sorted + 1] = {name = name, amt = amt} end
    table.sort(sorted, function(a, b) return a.amt > b.amt end)
    while #sorted > (limit or 2) do table.remove(sorted) end
    for _, entry in ipairs(sorted) do
        entry.pct = totalDmg > 0 and math.floor(entry.amt / totalDmg * 100 + 0.5) or 0
    end
    return sorted, totalDmg
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
                time=GetTime(), subevent=subevent,
                srcName=(type(srcName)=="string" and srcName~="") and srcName or "Unknown",
                srcGUID=srcGUID or "", amount=amount, school=school,
                spellId=spellId, spellName=spellName,
                isHeal=false, isCrit=isCrit, overkill=overkill,
            })
        end

    elseif HEAL_SUBEVENTS[subevent] and isDestPlayer then
        local spellId   = SafeNumber(p1)
        local spellName = (type(p2)=="string" and p2~="") and p2 or "Heal"
        local school    = SafeNumber(p3) or 0x02
        local amount    = SafeNumber(p4) or 0
        local isCrit    = (p7 == true)

        if amount > 0 then
            AddEvent({
                time=GetTime(), subevent=subevent,
                srcName=(type(srcName)=="string" and srcName~="") and srcName or "Unknown",
                srcGUID=srcGUID or "", amount=amount, school=school,
                spellId=spellId, spellName=spellName,
                isHeal=true, isCrit=isCrit, overkill=0,
            })
        end
    end
end

-- ============================================================================
-- Minimap Button
-- ============================================================================

local function UpdateMinimapButtonPosition()
    if not minimapButton then return end
    local s = GetMinimapSettings()
    local a = math.rad(s.position or 200)
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(a)*80, math.sin(a)*80)
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
        if deathGroups and #deathGroups > 0 then
            GameTooltip:AddLine("Left-click to toggle recap", 1, 1, 1)
            GameTooltip:AddLine("Right-click to clear", 0.7, 0.7, 0.7)
        else
            GameTooltip:AddLine("Recap appears on death", 0.6, 0.6, 0.6)
            GameTooltip:AddLine("/dl test to preview", 0.5, 0.5, 0.5)
        end
        GameTooltip:Show()
    end)
    minimapButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

    minimapButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    minimapButton:SetScript("OnClick", function(_, btn)
        if btn == "LeftButton" then Deathlapse:ToggleTimeline()
        else Deathlapse:ClearSnapshot() end
    end)

    minimapButton:RegisterForDrag("LeftButton")
    minimapButton.dragging = false
    minimapButton:SetScript("OnDragStart", function(self) self.dragging = true end)
    minimapButton:SetScript("OnDragStop", function(self)
        self.dragging = false
        local s = GetMinimapSettings()
        local mx, my = Minimap:GetCenter()
        local px, py = GetCursorPosition()
        local sc = Minimap:GetEffectiveScale()
        s.position = math.deg(math.atan2(py/sc - my, px/sc - mx))
        UpdateMinimapButtonPosition()
    end)
    minimapButton:SetScript("OnUpdate", function(self)
        if not self.dragging then return end
        local s = GetMinimapSettings()
        local mx, my = Minimap:GetCenter()
        local px, py = GetCursorPosition()
        local sc = Minimap:GetEffectiveScale()
        s.position = math.deg(math.atan2(py/sc - my, px/sc - mx))
        UpdateMinimapButtonPosition()
    end)
end

function Deathlapse:UpdateMinimapIndicator()
    if not minimapButton then return end
    if deathGroups and #deathGroups > 0 then minimapButton.deathDot:Show()
    else minimapButton.deathDot:Hide() end
end

-- ============================================================================
-- Geometry helpers (exported for tests)
-- ============================================================================

-- X position of a group within the chart, given column index and total columns
function Deathlapse.GroupX(colIdx, nCols)
    local colW = math.max(MIN_COL_W, math.floor(CHART_W / math.max(nCols, 1)))
    return CHART_LEFT + (colIdx - 1) * colW + math.floor(colW / 2)
end

function Deathlapse.ColWidth(nCols)
    return math.max(MIN_COL_W, math.floor(CHART_W / math.max(nCols, 1)))
end

-- Y pixel from TOP of chart canvas for a given HP fraction (0=dead, 1=full)
function Deathlapse.HpY(frac)
    return (1 - math.max(0, math.min(1, frac))) * CHART_H
end

-- Kept for backward-compat with existing tests
function Deathlapse.BarHeight(amount, maxH, logRef)
    if not amount or amount <= 0 then return 2 end
    local scale = maxH / math.log(logRef + 1)
    return math.max(2, math.min(maxH, scale * math.log(amount + 1)))
end

-- ============================================================================
-- Timeline Frame
-- ============================================================================

local function MakePoolTextures(parent, layer, count)
    local pool = {}
    for i = 1, count do
        local t = parent:CreateTexture(nil, layer)
        t:Hide()
        pool[i] = t
    end
    return pool
end

local function MakePoolFS(parent, fontObj, count)
    local pool = {}
    for i = 1, count do
        local fs = parent:CreateFontString(nil, "OVERLAY", fontObj)
        fs:Hide()
        pool[i] = fs
    end
    return pool
end

local function ResetPool(pool)
    for _, v in ipairs(pool) do v:Hide() end
end

local function CreateTimelineFrame()
    if timelineFrame then return end

    local f = CreateFrame("Frame", "DeathlapseTimelineFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(FRAME_W, FRAME_H)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local pt, _, rpt, x, y = self:GetPoint()
        GetDB().timelinePosition = {point=pt, relPoint=rpt, x=x, y=y}
    end)
    f:SetFrameStrata("HIGH")
    f:Hide()

    tinsert(UISpecialFrames, "DeathlapseTimelineFrame")

    -- Title
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", f, "TOP", 0, -6)
    title:SetText("|cffcc3333Deathlapse|r — Death Recap")

    -- Summary line (below header)
    local summaryFS = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    summaryFS:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -(FRAME_HEADER_H + 6))
    summaryFS:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -(FRAME_HEADER_H + 6))
    summaryFS:SetJustifyH("LEFT")
    summaryFS:SetText("")
    f.summaryFS = summaryFS

    -- Top attackers strip
    local attackerFS = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    attackerFS:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -(FRAME_HEADER_H + 18))
    attackerFS:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -(FRAME_HEADER_H + 18))
    attackerFS:SetJustifyH("LEFT")
    attackerFS:SetText("")
    f.attackerFS = attackerFS

    -- Chart canvas
    local chartY = -(FRAME_HEADER_H + FRAME_SUMMARY_H)
    local chart = CreateFrame("Frame", nil, f)
    chart:SetSize(FRAME_W, CHART_H)
    chart:SetPoint("TOPLEFT", f, "TOPLEFT", 0, chartY)
    f.chart = chart

    -- Chart background
    local chartBg = chart:CreateTexture(nil, "BACKGROUND")
    chartBg:SetAllPoints()
    SetSolidColor(chartBg, 0, 0, 0, 0.5)

    -- Y-axis labels (pre-created, static)
    for _, pct in ipairs({100, 75, 50, 25, 0}) do
        local lbl = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        local yPos = chartY - (1 - pct/100) * CHART_H + 4
        lbl:SetPoint("TOPRIGHT", f, "TOPLEFT", CHART_LEFT - 2, yPos)
        lbl:SetText(pct .. "%")
    end

    -- Horizontal gridlines at 25%, 50%, 75%
    for _, pct in ipairs({25, 50, 75}) do
        local gridY = (1 - pct/100) * CHART_H
        local gl = chart:CreateTexture(nil, "BACKGROUND")
        gl:SetSize(CHART_W, 1)
        gl:SetPoint("TOPLEFT", chart, "TOPLEFT", CHART_LEFT, -gridY)
        SetSolidColor(gl, 0.4, 0.4, 0.4, 0.3)
    end

    -- "NOW" label
    local nowLbl = chart:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nowLbl:SetPoint("TOPRIGHT", chart, "TOPRIGHT", -2, -4)
    nowLbl:SetText("|cffff2222NOW|r")

    -- Texture pools on chart
    chart.bluePool  = MakePoolTextures(chart, "ARTWORK",  MAX_GROUPS + 4)
    chart.capPool   = MakePoolTextures(chart, "ARTWORK",  MAX_GROUPS + 4)
    chart.linePool  = MakePoolTextures(chart, "OVERLAY",  MAX_GROUPS + 4)
    chart.borderPool= MakePoolTextures(chart, "ARTWORK",  MAX_GROUPS + 4)
    chart.iconPool  = MakePoolTextures(chart, "OVERLAY",  MAX_GROUPS + 4)
    chart.countFS   = MakePoolFS(chart, "GameFontNormalSmall", MAX_GROUPS + 4)
    chart.timeFS    = MakePoolFS(chart, "GameFontDisableSmall", MAX_GROUPS + 4)
    chart.srcFS     = MakePoolFS(chart, "GameFontDisableSmall", MAX_GROUPS + 4)

    -- Hover overlay
    local hover = CreateFrame("Frame", nil, chart)
    hover:SetAllPoints(chart)
    hover:EnableMouse(true)
    f.hover = hover

    hover:SetScript("OnUpdate", function(self)
        if not deathGroups or #deathGroups == 0 then GameTooltip:Hide(); return end
        if not self:IsMouseOver() then GameTooltip:Hide(); return end

        local screenX = GetCursorPosition()
        local sc      = UIParent:GetEffectiveScale()
        local relX    = screenX / sc - (self:GetLeft() or 0)

        local nCols = #deathGroups
        local colW  = Deathlapse.ColWidth(nCols)
        local colIdx = math.floor((relX - CHART_LEFT) / colW) + 1
        colIdx = math.max(1, math.min(nCols, colIdx))

        local g = deathGroups[colIdx]
        if not g then GameTooltip:Hide(); return end

        GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
        if g.isHeal then
            GameTooltip:SetText("|cff22dd55" .. g.spellName .. "|r")
        else
            GameTooltip:SetText("|cffff3333" .. g.spellName .. "|r")
        end
        GameTooltip:AddLine("From: " .. g.srcName, 0.8, 0.8, 0.8)
        local amtStr
        if g.isHeal then
            amtStr = string.format("|cff22dd55+%d healed|r", g.totalAmount)
        else
            amtStr = string.format("|cffff3333-%d damage|r", g.totalAmount)
        end
        if g.hasCrit then amtStr = amtStr .. " |cffffcc00(crit)|r" end
        if (not g.isHeal) and g.overkill > 0 then
            amtStr = amtStr .. string.format(" |cffff2222[+%d overkill]|r", g.overkill)
        end
        if g.count > 1 then amtStr = amtStr .. string.format("  |cffaaaaaa×%d hits|r", g.count) end
        GameTooltip:AddLine(amtStr, 1, 1, 1)
        local tOff = g.time - deathTime
        GameTooltip:AddLine(string.format("%.1fs before death", math.abs(tOff)), 0.55, 0.55, 0.55)
        GameTooltip:Show()
    end)
    hover:SetScript("OnLeave", function() GameTooltip:Hide() end)

    timelineFrame = f
end

-- ============================================================================
-- Rendering
-- ============================================================================

local function RenderTimeline()
    if not timelineFrame then return end
    local chart = timelineFrame.chart

    ResetPool(chart.bluePool)
    ResetPool(chart.capPool)
    ResetPool(chart.linePool)
    ResetPool(chart.borderPool)
    ResetPool(chart.iconPool)
    ResetPool(chart.countFS)
    ResetPool(chart.timeFS)
    ResetPool(chart.srcFS)

    if not deathGroups or #deathGroups == 0 then
        timelineFrame.summaryFS:SetText("|cff888888No death record yet.  /dl test to preview.|r")
        timelineFrame.attackerFS:SetText("")
        return
    end

    -- Summary header
    local dmgTotal, healTotal, dmgCount, healCount = 0, 0, 0, 0
    for _, g in ipairs(deathGroups) do
        if g.isHeal then healCount = healCount + g.count; healTotal = healTotal + g.totalAmount
        else dmgCount = dmgCount + g.count; dmgTotal = dmgTotal + g.totalAmount end
    end

    local summary = ""
    if killerName then
        summary = "Killed by: |cffff4444" .. killerName .. "|r"
        if killerSpell then summary = summary .. " — " .. killerSpell end
        summary = summary .. "  "
    end
    summary = summary .. string.format("|cffff6666%d hits  %d dmg|r", dmgCount, dmgTotal)
    if healCount > 0 then
        summary = summary .. string.format("  |cff44ff88%d heals  %d healed|r", healCount, healTotal)
    end
    timelineFrame.summaryFS:SetText(summary)

    -- Top attackers strip
    local attackers, _ = TopAttackers(deathGroups, 3)
    local atkStr = ""
    for i, a in ipairs(attackers) do
        if i > 1 then atkStr = atkStr .. "  |cff555555|  |r" end
        atkStr = atkStr .. string.format("|cffdddddd%s|r |cffff6666%d%%|r", a.name, a.pct)
    end
    timelineFrame.attackerFS:SetText(atkStr)

    -- Compute HP trajectory
    local hpBefore, hpAfter = ComputeHpTrajectory(deathGroups, playerMaxHp)

    local nCols = #deathGroups
    local colW  = Deathlapse.ColWidth(nCols)
    local barW  = math.max(8, colW - 4)

    for i, g in ipairs(deathGroups) do
        local cx   = CHART_LEFT + (i - 1) * colW + math.floor(colW / 2)
        local bx   = cx - math.floor(barW / 2)

        local hpB  = hpBefore[i]   -- HP fraction before event
        local hpA  = hpAfter[i]    -- HP fraction after event

        local yB   = Deathlapse.HpY(hpB)   -- pixel from top for hpBefore
        local yA   = Deathlapse.HpY(hpA)   -- pixel from top for hpAfter
        local yBot = CHART_H                 -- bottom of chart (0% HP)

        -- Blue bar: from hpAfter level down to 0%
        local blueH = math.max(1, yBot - yA)
        local blueTex = chart.bluePool[i]
        if blueTex then
            blueTex:SetSize(barW, blueH)
            blueTex:SetPoint("TOPLEFT", chart, "TOPLEFT", bx, -yA)
            SetSolidColor(blueTex, COLOR_HP_BLUE[1], COLOR_HP_BLUE[2], COLOR_HP_BLUE[3], 0.88)
            blueTex:Show()
        end

        -- Cap: from hpAfter to hpBefore (damage = red, heal = green)
        if math.abs(yB - yA) >= 1 then
            local capTex = chart.capPool[i]
            if capTex then
                local capTop = math.min(yA, yB)
                local capH   = math.abs(yB - yA)
                capTex:SetSize(barW, math.max(1, capH))
                capTex:SetPoint("TOPLEFT", chart, "TOPLEFT", bx, -capTop)
                if g.isHeal then
                    SetSolidColor(capTex, COLOR_HEAL_GRN[1], COLOR_HEAL_GRN[2], COLOR_HEAL_GRN[3], 0.90)
                else
                    local col = (g.overkill > 0) and {0.95, 0.05, 0.05} or COLOR_DMG_RED
                    SetSolidColor(capTex, col[1], col[2], col[3], g.hasCrit and 1.0 or 0.88)
                end
                capTex:Show()
            end
        end

        -- White separator line at hpAfter level
        local lineTex = chart.linePool[i]
        if lineTex and yA < yBot then
            lineTex:SetSize(barW, 1)
            lineTex:SetPoint("TOPLEFT", chart, "TOPLEFT", bx, -yA)
            SetSolidColor(lineTex, COLOR_HP_LINE[1], COLOR_HP_LINE[2], COLOR_HP_LINE[3], 0.80)
            lineTex:Show()
        end

        -- Bar border (thin left/right edges for readability)
        local borderTex = chart.borderPool[i]
        if borderTex then
            borderTex:SetSize(barW + 2, math.max(1, yBot - yB))
            borderTex:SetPoint("TOPLEFT", chart, "TOPLEFT", bx - 1, -yB)
            SetSolidColor(borderTex, 0, 0, 0, 0.40)
            borderTex:Show()
        end

        -- Icon below the bar
        local iconRowY = -(CHART_H + 3)
        local iconTex = chart.iconPool[i]
        if iconTex then
            local iconPath = GetEventIcon(g.iconEv or {spellId=g.spellId, subevent=g.subevent})
            iconTex:SetTexture(iconPath)
            iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            iconTex:SetSize(ICON_SIZE, ICON_SIZE)
            iconTex:SetPoint("TOP", chart, "TOPLEFT", cx, iconRowY)
            iconTex:Show()
        end

        -- Hit count label (xN)
        if g.count > 1 then
            local cfs = chart.countFS[i]
            if cfs then
                cfs:SetText("|cffffcc00×" .. g.count .. "|r")
                cfs:SetPoint("BOTTOM", chart, "TOPLEFT", cx, iconRowY - ICON_SIZE - 1)
                cfs:Show()
            end
        end

        -- Time label
        local tfs = chart.timeFS[i]
        if tfs then
            local tOff = math.abs(g.time - deathTime)
            tfs:SetText(string.format("%.1fs", tOff))
            tfs:SetPoint("TOP", chart, "TOPLEFT", cx, iconRowY - ICON_SIZE - 12)
            tfs:Show()
        end
    end
end

function Deathlapse:ShowTimeline()
    if not timelineFrame then CreateTimelineFrame() end
    local pos = GetDB().timelinePosition
    if pos then
        timelineFrame:ClearAllPoints()
        timelineFrame:SetPoint(pos.point, UIParent, pos.relPoint, pos.x, pos.y)
    end
    RenderTimeline()
    timelineFrame:Show()
end

function Deathlapse:HideTimeline()
    if timelineFrame then timelineFrame:Hide() end
end

function Deathlapse:ToggleTimeline()
    if not timelineFrame or not timelineFrame:IsShown() then self:ShowTimeline()
    else self:HideTimeline() end
end

function Deathlapse:ClearSnapshot()
    deathSnapshot = nil
    deathGroups   = nil
    deathTime     = nil
    killerName    = nil
    killerSpell   = nil
    self:HideTimeline()
    self:UpdateMinimapIndicator()
    Print("Death record cleared.")
end

-- ============================================================================
-- Death Handling
-- ============================================================================

local function FindKiller(snap)
    for i = #snap, 1, -1 do
        local ev = snap[i]
        if not ev.isHeal and ev.overkill and ev.overkill > 0 then
            return ev.srcName, (ev.spellName ~= "Melee") and ev.spellName or nil
        end
    end
    for i = #snap, 1, -1 do
        local ev = snap[i]
        if not ev.isHeal then
            return ev.srcName, (ev.spellName ~= "Melee") and ev.spellName or nil
        end
    end
    return nil, nil
end

local function OnPlayerDied()
    deathTime     = GetTime()
    playerMaxHp   = (UnitHealthMax and UnitHealthMax("player")) or playerMaxHp
    deathSnapshot = SnapshotForDeath(deathTime)
    deathGroups   = GroupEvents(deathSnapshot)
    killerName, killerSpell = FindKiller(deathSnapshot)
    Deathlapse:UpdateMinimapIndicator()
    if GetMinimapSettings().showOnDeath ~= false then
        Deathlapse:ShowTimeline()
    end
end

local function OnPlayerAlive()
    Deathlapse:HideTimeline()
end

-- ============================================================================
-- Test Data Generator
-- ============================================================================

local function GenerateTestSnapshot()
    local now     = GetTime()
    deathTime     = now
    playerMaxHp   = 8500

    local snap    = {}
    local srcNames = {"Onyxia", "Onyxia's Whelp", "Guard Mol'dar", "Arcanist Doan"}
    local spells   = {
        {name="Wing Buffet",  id=18500, school=0x01, subevent="SPELL_DAMAGE"},
        {name="Flame Breath", id=18435, school=0x04, subevent="SPELL_DAMAGE"},
        {name="Deep Breath",  id=23461, school=0x04, subevent="SPELL_DAMAGE"},
        {name="Shadowbolt",   id=9613,  school=0x20, subevent="SPELL_DAMAGE"},
        {name="Fireball",     id=9488,  school=0x04, subevent="SPELL_DAMAGE"},
        {name="Melee",        id=nil,   school=0x01, subevent="SWING_DAMAGE"},
    }
    local heals = {
        {name="Flash Heal",   id=9474,  school=0x02},
        {name="Renew",        id=9076,  school=0x02},
    }

    -- Spread events across 20 seconds, last event is the killing blow
    local events = {}
    -- 8 damage events with varying times
    for i = 1, 10 do
        local t = now - TIMELINE_DURATION + (i / 11) * TIMELINE_DURATION
        local sp = spells[math.random(#spells)]
        events[#events + 1] = {
            time=t, subevent=sp.subevent,
            srcName=srcNames[math.random(#srcNames)],
            srcGUID="",
            amount=math.random(600, 3200),
            school=sp.school, spellId=sp.id, spellName=sp.name,
            isHeal=false, isCrit=(math.random(4)==1), overkill=0,
        }
    end
    -- 3 dot groups (multiple ticks)
    for i = 1, 3 do
        local baseT = now - 15 + i*4
        for tick = 1, math.random(3, 5) do
            events[#events + 1] = {
                time=baseT + tick*0.5 - 0.5, subevent="SPELL_PERIODIC_DAMAGE",
                srcName="Onyxia", srcGUID="",
                amount=math.random(250, 600),
                school=0x04, spellId=18435, spellName="Flame Breath (DoT)",
                isHeal=false, isCrit=false, overkill=0,
            }
        end
    end
    -- 4 heal events
    for i = 1, 4 do
        local t = now - 18 + i*4
        local hl = heals[math.random(#heals)]
        events[#events + 1] = {
            time=t, subevent="SPELL_HEAL",
            srcName="Priest", srcGUID="",
            amount=math.random(800, 2400),
            school=0x02, spellId=hl.id, spellName=hl.name,
            isHeal=true, isCrit=(math.random(5)==1), overkill=0,
        }
    end
    -- killing blow
    events[#events + 1] = {
        time=now-0.2, subevent="SPELL_DAMAGE",
        srcName="Onyxia", srcGUID="",
        amount=5800, school=0x04, spellId=23461, spellName="Deep Breath",
        isHeal=false, isCrit=true, overkill=1200,
    }

    table.sort(events, function(a,b) return a.time < b.time end)
    deathSnapshot = events
    deathGroups   = GroupEvents(events)
    killerName, killerSpell = FindKiller(events)
end

-- ============================================================================
-- Slash Commands
-- ============================================================================

SLASH_DEATHLAPSE1 = "/deathlapse"
SLASH_DEATHLAPSE2 = "/dl"
SlashCmdList["DEATHLAPSE"] = function(msg)
    local args = {}
    for word in string.gmatch(msg, "%S+") do args[#args+1] = string.lower(word) end
    local cmd = args[1] or ""

    if cmd == "" or cmd == "show" then Deathlapse:ShowTimeline()
    elseif cmd == "hide"     then Deathlapse:HideTimeline()
    elseif cmd == "clear"    then Deathlapse:ClearSnapshot()
    elseif cmd == "minimap" or cmd == "mm" then
        local s = GetMinimapSettings()
        s.show = not s.show
        if s.show then
            if not minimapButton then CreateMinimapButton() end
            minimapButton:Show(); UpdateMinimapButtonPosition()
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
    else Deathlapse:ToggleTimeline() end
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
eventFrame:RegisterEvent("UNIT_MAXHEALTH")
eventFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")

eventFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        playerGUID  = UnitGUID and UnitGUID("player") or nil
        playerMaxHp = (UnitHealthMax and UnitHealthMax("player")) or 1
        if GetMinimapSettings().show then
            CreateMinimapButton(); UpdateMinimapButtonPosition()
        end
        Print("Loaded. Die to see your recap, or /dl test to preview.")

    elseif event == "PLAYER_ENTERING_WORLD" then
        playerGUID  = UnitGUID and UnitGUID("player") or nil
        playerMaxHp = (UnitHealthMax and UnitHealthMax("player")) or playerMaxHp

    elseif event == "UNIT_MAXHEALTH" and arg1 == "player" then
        playerMaxHp = (UnitHealthMax and UnitHealthMax("player")) or playerMaxHp

    elseif event == "PLAYER_DEAD"   then OnPlayerDied()
    elseif event == "PLAYER_ALIVE"
        or event == "PLAYER_UNGHOST" then OnPlayerAlive()
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        ParseCombatEvent()
    end
end)

-- ============================================================================
-- Exports for test harness
-- ============================================================================

Deathlapse._internal = {
    SchoolColor          = SchoolColor,
    HasBit               = HasBit,
    SafeNumber           = SafeNumber,
    PruneBuffer          = PruneBuffer,
    AddEvent             = AddEvent,
    SnapshotForDeath     = SnapshotForDeath,
    FindKiller           = FindKiller,
    GroupEvents          = GroupEvents,
    ComputeHpTrajectory  = ComputeHpTrajectory,
    GetEventBuffer       = function() return eventBuffer end,
    SetEventBuffer       = function(t) eventBuffer = t end,
    SetDeathTime         = function(t) deathTime = t end,
    TIMELINE_DURATION    = TIMELINE_DURATION,
    CANVAS_LEFT_PAD      = CHART_LEFT,
    TIMELINE_EFFECTIVE_W = CHART_W,
    MAX_GROUPS           = MAX_GROUPS,
    CHART_H              = CHART_H,
}
