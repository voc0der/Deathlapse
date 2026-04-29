-- Deathlapse
-- Death recap for TBC Anniversary Classic.
-- On death shows a waterfall HP chart (HotS Recap style): each column is one
-- hit-group, the blue bar is HP remaining, the red cap is damage taken,
-- green cap for heals. Spell icons and compact time labels sit below each column.

local addonName = "Deathlapse"
local addonAuthor = "voc0der"
local addonWebsite = "https://github.com/voc0der/Deathlapse"
Deathlapse = {}

-- ============================================================================
-- Constants
-- ============================================================================

local TIMELINE_DURATION  = 20
local FULL_HP_EPS        = 0.995
local BUFFER_CAPACITY    = 500
local BUFFER_PRUNE_AGE   = 25

local ADDON_PREFIX    = "DLAPSE"
local LINK_CHUNK_SIZE = 200
local LINK_FSEP       = "\031"
local LINK_GSEP       = "\030"

local GROUP_MERGE_WINDOW = 1.0   -- same spell+source within this many seconds → one column
local MAX_GROUPS         = 28    -- cap columns; oldest groups are dropped when exceeded

local FRAME_DEFAULT_W    = 760
local FRAME_MIN_W        = 560
local FRAME_MAX_W        = 1120
local FRAME_HEADER_H     = 24
local FRAME_SUMMARY_H    = 52
local CHART_LEFT         = 42   -- width of Y-label strip
local CHART_RIGHT        = 16
local CHART_H            = 170  -- default height of the HP bar area
local CHART_MIN_H        = 130
local ICON_ROW_H         = 30
local TIME_ROW_H         = 18
local FRAME_BOTTOM_PAD   = 18
local FRAME_DEFAULT_H    = FRAME_HEADER_H + FRAME_SUMMARY_H + CHART_H + ICON_ROW_H + TIME_ROW_H + FRAME_BOTTOM_PAD
local FRAME_MIN_H        = FRAME_HEADER_H + FRAME_SUMMARY_H + CHART_MIN_H + ICON_ROW_H + TIME_ROW_H + FRAME_BOTTOM_PAD
local FRAME_MAX_H        = 560

local FRAME_W            = FRAME_DEFAULT_W
local FRAME_H            = FRAME_DEFAULT_H
local CHART_W            = FRAME_W - CHART_LEFT - CHART_RIGHT
local MIN_COL_W          = 18
local ICON_MIN_SIZE      = 16
local ICON_MAX_SIZE      = 28

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
local COLOR_HP_BLUE   = {0.13, 0.34, 0.62}
local COLOR_DMG_RED   = {0.72, 0.12, 0.13}
local COLOR_HEAL_GRN  = {0.16, 0.62, 0.30}
local COLOR_HP_LINE   = {0.88, 0.92, 1.00}

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
local deathWindowStart = nil
local killerName     = nil
local killerSpell    = nil
local receivedChunks = {}
local receivedData   = {}
local minimapButton  = nil
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

local function SetGradient(tex, orientation, r1, g1, b1, r2, g2, b2, alpha)
    -- Use inline solid-white (1,1,1,1) rather than a file path so the base
    -- texture is guaranteed opaque regardless of how TBC loads the asset.
    tex:SetTexture(1, 1, 1, 1)
    if tex.SetGradientAlpha then
        tex:SetGradientAlpha(orientation, r1, g1, b1, alpha, r2, g2, b2, alpha)
    else
        SetSolidColor(tex, (r1 + r2) * 0.5, (g1 + g2) * 0.5, (b1 + b2) * 0.5, alpha)
    end
end

local function ClampValue(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function GetLayout(frameW, frameH)
    frameW = ClampValue(math.floor((frameW or FRAME_DEFAULT_W) + 0.5), FRAME_MIN_W, FRAME_MAX_W)
    frameH = ClampValue(math.floor((frameH or FRAME_DEFAULT_H) + 0.5), FRAME_MIN_H, FRAME_MAX_H)

    local chartH = frameH - FRAME_HEADER_H - FRAME_SUMMARY_H - ICON_ROW_H - TIME_ROW_H - FRAME_BOTTOM_PAD
    chartH = math.max(CHART_MIN_H, chartH)

    return {
        frameW   = frameW,
        frameH   = frameH,
        chartTop = FRAME_HEADER_H + FRAME_SUMMARY_H,
        chartW   = math.max(1, frameW - CHART_LEFT - CHART_RIGHT),
        chartH   = chartH,
        iconTop  = -(chartH + 7),
    }
end

local function GetSavedTimelineSize()
    local size = GetDB().timelineSize
    local w = type(size) == "table" and tonumber(size.w) or nil
    local h = type(size) == "table" and tonumber(size.h) or nil
    local layout = GetLayout(w or FRAME_DEFAULT_W, h or FRAME_DEFAULT_H)
    return layout.frameW, layout.frameH
end

local function SaveTimelineSize(frame)
    if not frame or not frame.GetWidth or not frame.GetHeight then return end
    local layout = GetLayout(frame:GetWidth(), frame:GetHeight())
    GetDB().timelineSize = {w = layout.frameW, h = layout.frameH}
end

local function GetUnpack()
    if type(unpack) == "function" then return unpack end
    if type(table) == "table" and type(table.unpack) == "function" then return table.unpack end
    return nil
end

local function GetElvUIEngine()
    local elv = _G and _G.ElvUI
    if type(elv) ~= "table" then return nil end

    local unpackFn = GetUnpack()
    if unpackFn then
        local ok, engine = pcall(function() return unpackFn(elv) end)
        if ok and type(engine) == "table" then return engine end
    end

    if type(elv[1]) == "table" then return elv[1] end
    if type(elv.GetModule) == "function" then return elv end
    return nil
end

local function HideDefaultFrameArt(frame)
    if not frame or type(frame.GetRegions) ~= "function" then return end
    local regions = {frame:GetRegions()}
    for _, region in ipairs(regions) do
        if region and type(region.GetTexture) == "function" and type(region.Hide) == "function" then
            region:Hide()
        end
    end
end

local function ApplyElvUISkin(frame)
    local engine = GetElvUIEngine()
    if not engine or not frame then return false end

    local skins
    if type(engine.GetModule) == "function" then
        local ok, mod = pcall(function() return engine:GetModule("Skins") end)
        if ok then skins = mod end
    end

    local canSkin = type(frame.SetTemplate) == "function"
                 or type(frame.CreateBackdrop) == "function"
                 or (skins and type(skins.HandleFrame) == "function")
    if not canSkin then return false end

    HideDefaultFrameArt(frame)

    if type(frame.SetTemplate) == "function" then
        pcall(function() frame:SetTemplate("Transparent") end)
    elseif type(frame.CreateBackdrop) == "function" then
        pcall(function() frame:CreateBackdrop("Transparent") end)
    end

    if skins and type(skins.HandleFrame) == "function" then
        pcall(function() skins:HandleFrame(frame, true) end)
    end
    if skins and frame.CloseButton and type(skins.HandleCloseButton) == "function" then
        pcall(function() skins:HandleCloseButton(frame.CloseButton) end)
    end
    if skins and frame.linkBtn and type(skins.HandleButton) == "function" then
        pcall(function() skins:HandleButton(frame.linkBtn) end)
    end

    frame.deathlapseElvUISkinned = true
    return true
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
                g.overheal    = g.overheal + (ev.overheal or 0)
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
                overheal    = ev.overheal or 0,
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

local function ClipGroupsToRelevantWindow(groups, maxHp)
    if not groups or #groups == 0 then return groups, nil end

    local hpBefore, hpAfter = ComputeHpTrajectory(groups, maxHp)
    local startIdx = 1

    for i = #groups, 1, -1 do
        local g = groups[i]
        if hpBefore[i] and hpBefore[i] >= FULL_HP_EPS then
            startIdx = i
            break
        end
        if i < #groups and ((hpAfter[i] and hpAfter[i] >= FULL_HP_EPS)
            or (g.isHeal and (g.overheal or 0) > 0)) then
            startIdx = i + 1
            break
        end
    end

    if startIdx <= 1 then
        return groups, groups[1] and groups[1].time or nil
    end

    local clipped = {}
    for i = startIdx, #groups do
        clipped[#clipped + 1] = groups[i]
    end
    return clipped, clipped[1] and clipped[1].time or nil
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
-- Link Sharing
-- ============================================================================

local function SerializeRecap()
    if not deathGroups or #deathGroups == 0 then return nil end
    local dt = deathTime or GetTime()
    local rows = {
        table.concat({tostring(playerMaxHp), killerName or "", killerSpell or ""}, LINK_FSEP)
    }
    for _, g in ipairs(deathGroups) do
        rows[#rows+1] = table.concat({
            string.format("%.1f", g.time - dt),
            g.srcName,
            g.spellName,
            tostring(g.spellId or ""),
            tostring(g.school or 1),
            g.isHeal and "1" or "0",
            tostring(g.totalAmount),
            tostring(g.count),
            g.hasCrit and "1" or "0",
            tostring(g.overkill or 0),
            tostring(g.overheal or 0),
        }, LINK_FSEP)
    end
    return table.concat(rows, LINK_GSEP)
end

local function SplitRow(row)
    local fields, pos = {}, 1
    while pos <= #row do
        local n = row:find(LINK_FSEP, pos, true)
        if n then fields[#fields+1] = row:sub(pos, n-1); pos = n + 1
        else   fields[#fields+1] = row:sub(pos); break end
    end
    return fields
end

local function DeserializeRecap(data)
    local rows, pos = {}, 1
    while pos <= #data do
        local n = data:find(LINK_GSEP, pos, true)
        if n then rows[#rows+1] = data:sub(pos, n-1); pos = n + 1
        else   rows[#rows+1] = data:sub(pos); break end
    end
    if #rows < 1 then return nil end

    local hdr    = SplitRow(rows[1])
    local maxHp  = tonumber(hdr[1]) or 1
    local kName  = (hdr[2] and hdr[2] ~= "") and hdr[2] or nil
    local kSpell = (hdr[3] and hdr[3] ~= "") and hdr[3] or nil

    local now, groups = GetTime(), {}
    for i = 2, #rows do
        local f = SplitRow(rows[i])
        if #f >= 11 then
            local tOff   = tonumber(f[1]) or 0
            local spId   = tonumber(f[4])
            local isHeal = f[6] == "1"
            local sub    = spId and (isHeal and "SPELL_HEAL" or "SPELL_DAMAGE") or "SWING_DAMAGE"
            groups[#groups+1] = {
                time        = now + tOff,
                lastTime    = now + tOff,
                srcName     = f[2],
                spellName   = f[3],
                spellId     = spId,
                school      = tonumber(f[5]) or 1,
                isHeal      = isHeal,
                totalAmount = tonumber(f[7]) or 0,
                count       = tonumber(f[8]) or 1,
                hasCrit     = f[9] == "1",
                overkill    = tonumber(f[10]) or 0,
                overheal    = tonumber(f[11]) or 0,
                iconEv      = {spellId=spId, subevent=sub},
            }
        end
    end
    return groups, maxHp, kName, kSpell
end

local function HandleAddonMessage(prefix, msg, sender)
    if prefix ~= ADDON_PREFIX then return end
    local seq, total, chunk = msg:match("^(%d+)/(%d+)/(.*)$")
    seq   = tonumber(seq)
    total = tonumber(total)
    if not seq or not total or not chunk then return end

    local key = sender:match("^([^%-]+)") or sender
    local rc  = receivedChunks[key]
    if not rc or rc.total ~= total then
        receivedChunks[key] = {total=total, chunks={}}
        rc = receivedChunks[key]
    end
    rc.chunks[seq] = chunk

    local have = 0
    for _ in pairs(rc.chunks) do have = have + 1 end
    if have < total then return end

    local parts = {}
    for s = 1, total do parts[s] = rc.chunks[s] or "" end
    receivedData[key]   = table.concat(parts)
    receivedChunks[key] = nil
    Print("|cffffcc00" .. key .. "|r shared a death recap — "
        .. "|Hdeathlapse:" .. key .. "|h|cff88ccff[Click to view]|r|h")
end

function Deathlapse:ShareRecap()
    if not deathGroups or #deathGroups == 0 then
        Print("No death recap to share.")
        return
    end
    local data = SerializeRecap()
    if not data then return end

    local chunks, i = {}, 1
    while i <= #data do
        chunks[#chunks+1] = data:sub(i, i + LINK_CHUNK_SIZE - 1)
        i = i + LINK_CHUNK_SIZE
    end

    local channel = (IsInRaid and IsInRaid()) and "RAID"
                 or (IsInGroup and IsInGroup()) and "PARTY"
                 or "SAY"
    for seq, chunk in ipairs(chunks) do
        pcall(SendAddonMessage, ADDON_PREFIX, seq .. "/" .. #chunks .. "/" .. chunk, channel)
    end

    local pName = (UnitName and UnitName("player")) or "Unknown"
    pcall(SendChatMessage, "[Deathlapse Death Recap] by " .. pName, channel)
    Print("Recap shared in " .. channel
        .. " (" .. #chunks .. " packet" .. (#chunks > 1 and "s" or "") .. ").")
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
        local overheal  = SafeNumber(p5) or 0
        local isCrit    = (p7 == true)

        if amount > 0 then
            AddEvent({
                time=GetTime(), subevent=subevent,
                srcName=(type(srcName)=="string" and srcName~="") and srcName or "Unknown",
                srcGUID=srcGUID or "", amount=amount, school=school,
                spellId=spellId, spellName=spellName,
                isHeal=true, isCrit=isCrit, overkill=0, overheal=overheal,
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
function Deathlapse.GroupX(colIdx, nCols, chartW)
    local colW = Deathlapse.ColWidth(nCols, chartW)
    return CHART_LEFT + (colIdx - 1) * colW + math.floor(colW / 2)
end

function Deathlapse.ColWidth(nCols, chartW)
    return math.max(MIN_COL_W, math.floor((chartW or CHART_W) / math.max(nCols, 1)))
end

-- Y pixel from TOP of chart canvas for a given HP fraction (0=dead, 1=full)
function Deathlapse.HpY(frac, chartH)
    chartH = chartH or CHART_H
    return (1 - math.max(0, math.min(1, frac))) * chartH
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
    for _, v in ipairs(pool) do
        if v.ClearAllPoints then v:ClearAllPoints() end
        v:Hide()
    end
end

local RenderTimeline

local function LayoutTimelineFrame(frame)
    frame = frame or timelineFrame
    if not frame or not frame.chart then return end

    local layout = GetLayout(frame.GetWidth and frame:GetWidth() or FRAME_DEFAULT_W,
                             frame.GetHeight and frame:GetHeight() or FRAME_DEFAULT_H)
    frame.layout = layout

    if frame.summaryFS then
        frame.summaryFS:ClearAllPoints()
        frame.summaryFS:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -(FRAME_HEADER_H + 6))
        frame.summaryFS:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, -(FRAME_HEADER_H + 6))
    end

    if frame.attackerFS then
        frame.attackerFS:ClearAllPoints()
        frame.attackerFS:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -(FRAME_HEADER_H + 22))
        frame.attackerFS:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, -(FRAME_HEADER_H + 22))
    end

    if frame.windowFS then
        frame.windowFS:ClearAllPoints()
        frame.windowFS:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -(FRAME_HEADER_H + 38))
        frame.windowFS:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, -(FRAME_HEADER_H + 38))
    end

    local chart = frame.chart
    chart:ClearAllPoints()
    chart:SetSize(layout.frameW, layout.chartH)
    chart:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -layout.chartTop)

    if frame.yLabels then
        for _, entry in ipairs(frame.yLabels) do
            local yPos = -(1 - entry.pct / 100) * layout.chartH + 4
            entry.fs:ClearAllPoints()
            entry.fs:SetPoint("TOPRIGHT", chart, "TOPLEFT", CHART_LEFT - 4, yPos)
        end
    end

    if chart.gridLines then
        for _, entry in ipairs(chart.gridLines) do
            local gridY = (1 - entry.pct / 100) * layout.chartH
            entry.tex:ClearAllPoints()
            entry.tex:SetSize(layout.chartW, 1)
            entry.tex:SetPoint("TOPLEFT", chart, "TOPLEFT", CHART_LEFT, -gridY)
        end
    end

    if chart.zeroLine then
        chart.zeroLine:ClearAllPoints()
        chart.zeroLine:SetSize(layout.chartW, 1)
        chart.zeroLine:SetPoint("TOPLEFT", chart, "TOPLEFT", CHART_LEFT, -layout.chartH)
    end

    if frame.nowLbl then
        frame.nowLbl:ClearAllPoints()
        frame.nowLbl:SetPoint("TOPRIGHT", chart, "TOPRIGHT", -8, -4)
    end
end

local function CreateTimelineFrame()
    if timelineFrame then return end

    local savedW, savedH = GetSavedTimelineSize()
    local f = CreateFrame("Frame", "DeathlapseTimelineFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(savedW, savedH)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
    f:SetMovable(true)
    if f.SetResizable then f:SetResizable(true) end
    if f.SetResizeBounds then
        f:SetResizeBounds(FRAME_MIN_W, FRAME_MIN_H, FRAME_MAX_W, FRAME_MAX_H)
    else
        if f.SetMinResize then f:SetMinResize(FRAME_MIN_W, FRAME_MIN_H) end
        if f.SetMaxResize then f:SetMaxResize(FRAME_MAX_W, FRAME_MAX_H) end
    end
    if f.SetClampedToScreen then f:SetClampedToScreen(true) end
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
    f.title = title

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

    local windowFS = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    windowFS:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -(FRAME_HEADER_H + 38))
    windowFS:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -(FRAME_HEADER_H + 38))
    windowFS:SetJustifyH("CENTER")
    windowFS:SetText("")
    f.windowFS = windowFS

    -- Chart canvas
    local layout = GetLayout(savedW, savedH)
    local chartY = -layout.chartTop
    local chart = CreateFrame("Frame", nil, f)
    chart:SetSize(layout.frameW, layout.chartH)
    chart:SetPoint("TOPLEFT", f, "TOPLEFT", 0, chartY)
    f.chart = chart

    -- Chart background
    local chartBg = chart:CreateTexture(nil, "BACKGROUND")
    chartBg:SetAllPoints()
    SetSolidColor(chartBg, 0.02, 0.02, 0.03, 0.56)
    chart.chartBg = chartBg

    -- Y-axis labels (pre-created, static)
    f.yLabels = {}
    for _, pct in ipairs({100, 75, 50, 25, 0}) do
        local lbl = chart:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        local yPos = -(1 - pct/100) * layout.chartH + 4
        lbl:SetPoint("TOPRIGHT", chart, "TOPLEFT", CHART_LEFT - 2, yPos)
        lbl:SetText(pct .. "%")
        f.yLabels[#f.yLabels + 1] = {fs = lbl, pct = pct}
    end

    -- Horizontal gridlines at 25%, 50%, 75%
    chart.gridLines = {}
    for _, pct in ipairs({25, 50, 75}) do
        local gridY = (1 - pct/100) * layout.chartH
        local gl = chart:CreateTexture(nil, "BORDER")
        gl:SetSize(layout.chartW, 1)
        gl:SetPoint("TOPLEFT", chart, "TOPLEFT", CHART_LEFT, -gridY)
        SetSolidColor(gl, 0.45, 0.45, 0.55, 0.22)
        chart.gridLines[#chart.gridLines + 1] = {tex = gl, pct = pct}
    end

    local zeroLine = chart:CreateTexture(nil, "BORDER")
    zeroLine:SetSize(layout.chartW, 1)
    zeroLine:SetPoint("TOPLEFT", chart, "TOPLEFT", CHART_LEFT, -layout.chartH)
    SetSolidColor(zeroLine, 0.65, 0.65, 0.72, 0.32)
    chart.zeroLine = zeroLine

    -- "NOW" label
    local nowLbl = chart:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nowLbl:SetPoint("TOPRIGHT", chart, "TOPRIGHT", -2, -4)
    nowLbl:SetText("|cffff2222NOW|r")
    f.nowLbl = nowLbl

    -- Texture pools on chart
    chart.bluePool      = MakePoolTextures(chart, "BORDER",      MAX_GROUPS + 4)
    chart.capPool       = MakePoolTextures(chart, "ARTWORK",     MAX_GROUPS + 4)
    chart.linePool      = MakePoolTextures(chart, "OVERLAY",     MAX_GROUPS + 4)
    chart.borderPool    = MakePoolTextures(chart, "BACKGROUND",  MAX_GROUPS + 4)
    chart.iconBorderPool= MakePoolTextures(chart, "ARTWORK",     MAX_GROUPS + 4)
    chart.iconPool      = MakePoolTextures(chart, "OVERLAY",     MAX_GROUPS + 4)
    chart.countFS       = MakePoolFS(chart, "GameFontNormalSmall",   MAX_GROUPS + 4)
    chart.timeFS        = MakePoolFS(chart, "GameFontDisableSmall",  MAX_GROUPS + 4)
    chart.srcFS         = MakePoolFS(chart, "GameFontDisableSmall",  MAX_GROUPS + 4)

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
        local layout = timelineFrame and timelineFrame.layout or GetLayout()
        local colW  = Deathlapse.ColWidth(nCols, layout.chartW)
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
        if g.isHeal and (g.overheal or 0) > 0 then
            amtStr = amtStr .. string.format(" |cff99ffbb(+%d overheal)|r", g.overheal)
        end
        if g.count > 1 then amtStr = amtStr .. string.format("  |cffaaaaaax%d hits|r", g.count) end
        GameTooltip:AddLine(amtStr, 1, 1, 1)
        local tOff = g.time - deathTime
        GameTooltip:AddLine(string.format("%.1fs before death", math.abs(tOff)), 0.55, 0.55, 0.55)
        GameTooltip:Show()
    end)
    hover:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Share button (bottom-left corner) — standard Blizzard panel button, red-tinted, chain icon.
    local linkBtn = CreateFrame("Button", "DeathlapseShareButton", f, "UIPanelButtonTemplate")
    linkBtn:SetSize(26, 22)
    linkBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 8, 5)
    linkBtn:SetFrameLevel(f:GetFrameLevel() + 5)
    if linkBtn.Text then linkBtn.Text:SetText("") end

    -- Red vertex color on the three button-cap textures (non-ElvUI path).
    for _, key in ipairs({"Left", "Middle", "Right"}) do
        if linkBtn[key] and linkBtn[key].SetVertexColor then
            linkBtn[key]:SetVertexColor(0.72, 0.13, 0.13)
        end
    end

    -- Mail/send glyph — INV_Letter_15 is used by the TBC Minimap mail indicator,
    -- so it is guaranteed to ship with TBC Anniversary.
    local linkIcon = linkBtn:CreateTexture(nil, "OVERLAY")
    linkIcon:SetTexture("Interface\\Icons\\INV_Letter_15")
    linkIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    linkIcon:SetSize(14, 14)
    linkIcon:SetPoint("CENTER")
    linkBtn.linkIcon = linkIcon

    linkBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("|cff88ccffShare Recap|r")
        GameTooltip:AddLine("Broadcasts your death recap to the group.", 1, 1, 1)
        GameTooltip:AddLine("Others with Deathlapse can click to view.", 0.65, 0.65, 0.65)
        GameTooltip:Show()
    end)
    linkBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    linkBtn:SetScript("OnClick", function() Deathlapse:ShareRecap() end)
    f.linkBtn = linkBtn

    timelineFrame = f
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(18, 18)
    grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -5, 5)
    if grip.SetNormalTexture then grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up") end
    if grip.SetHighlightTexture then grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight") end
    if grip.SetPushedTexture then grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down") end
    grip:SetScript("OnMouseDown", function()
        if f.StartSizing then f:StartSizing("BOTTOMRIGHT") end
    end)
    grip:SetScript("OnMouseUp", function()
        if f.StopMovingOrSizing then f:StopMovingOrSizing() end
        SaveTimelineSize(f)
        LayoutTimelineFrame(f)
        RenderTimeline()
    end)
    f.resizeGrip = grip

    f:SetScript("OnSizeChanged", function(self)
        LayoutTimelineFrame(self)
        if self:IsShown() then RenderTimeline() end
    end)

    LayoutTimelineFrame(f)
    ApplyElvUISkin(f)
end

-- ============================================================================
-- Rendering
-- ============================================================================

RenderTimeline = function()
    if not timelineFrame then return end
    local chart = timelineFrame.chart

    ResetPool(chart.bluePool)
    ResetPool(chart.capPool)
    ResetPool(chart.linePool)
    ResetPool(chart.borderPool)
    ResetPool(chart.iconBorderPool)
    ResetPool(chart.iconPool)
    ResetPool(chart.countFS)
    ResetPool(chart.timeFS)
    ResetPool(chart.srcFS)

    if not deathGroups or #deathGroups == 0 then
        timelineFrame.summaryFS:SetText("|cff888888No death record yet.  /dl test to preview.|r")
        timelineFrame.attackerFS:SetText("")
        if timelineFrame.windowFS then timelineFrame.windowFS:SetText("") end
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
        summary = "Killed by: |cffff6666" .. killerName .. "|r"
        if killerSpell then summary = summary .. " — " .. killerSpell end
        summary = summary .. "  "
    end
    summary = summary .. string.format("|cffff7777%d hits  %d dmg|r", dmgCount, dmgTotal)
    if healCount > 0 then
        summary = summary .. string.format("  |cff66e69a%d heals  %d healed|r", healCount, healTotal)
    end
    timelineFrame.summaryFS:SetText(summary)

    local windowDuration = TIMELINE_DURATION
    if deathWindowStart and deathTime then
        windowDuration = math.max(0, math.min(TIMELINE_DURATION, deathTime - deathWindowStart))
    elseif deathGroups[1] and deathTime then
        windowDuration = math.max(0, math.min(TIMELINE_DURATION, deathTime - deathGroups[1].time))
    end
    if timelineFrame.windowFS then
        timelineFrame.windowFS:SetText(string.format("|cffb8c7ffYou took %d damage in %.1f seconds|r", dmgTotal, windowDuration))
    end

    -- Top attackers strip
    local attackers, _ = TopAttackers(deathGroups, 3)
    local atkStr = ""
    for i, a in ipairs(attackers) do
        if i > 1 then atkStr = atkStr .. "  |cff555555|  |r" end
        atkStr = atkStr .. string.format("|cffdddddd%s|r |cffff8888%d%%|r", a.name, a.pct)
    end
    timelineFrame.attackerFS:SetText(atkStr)

    -- Compute HP trajectory
    local hpBefore, hpAfter = ComputeHpTrajectory(deathGroups, playerMaxHp)
    local layout = timelineFrame.layout or GetLayout()

    local nCols   = #deathGroups
    local colW    = Deathlapse.ColWidth(nCols, layout.chartW)
    local colSize = ClampValue(colW - 2, ICON_MIN_SIZE, ICON_MAX_SIZE)
    local barW    = colSize
    local iconSize = colSize
    local timeEvery = (colW >= 34) and 1 or math.max(2, math.ceil(34 / math.max(colW, 1)))

    for i, g in ipairs(deathGroups) do
        local cx   = CHART_LEFT + (i - 1) * colW + math.floor(colW / 2)
        local bx   = cx - math.floor(barW / 2)

        local hpB  = hpBefore[i]   -- HP fraction before event
        local hpA  = hpAfter[i]    -- HP fraction after event

        local yB   = Deathlapse.HpY(hpB, layout.chartH) -- pixel from top for hpBefore
        local yA   = Deathlapse.HpY(hpA, layout.chartH) -- pixel from top for hpAfter
        local yBot = layout.chartH                       -- bottom of chart (0% HP)

        -- Blue bar: from hpAfter level down to 0%
        -- Subtle column track behind the bar (full height, same width as bar + 2px border).
        local borderTex = chart.borderPool[i]
        if borderTex then
            borderTex:SetSize(colSize + 2, yBot)
            borderTex:SetPoint("TOPLEFT", chart, "TOPLEFT", bx - 1, 0)
            SetSolidColor(borderTex, 0, 0, 0, 0.22)
            borderTex:Show()
        end

        -- Blue bar: from hpAfter level down to 0% — gradient lighter at top (more HP), darker near death.
        local blueH = math.max(1, yBot - yA)
        local blueTex = chart.bluePool[i]
        if blueTex then
            blueTex:SetSize(barW, blueH)
            blueTex:SetPoint("TOPLEFT", chart, "TOPLEFT", bx, -yA)
            SetGradient(blueTex, "VERTICAL", 0.08, 0.20, 0.46, 0.20, 0.50, 0.88, 0.82)
            blueTex:Show()
        end

        -- Cap: from hpAfter to hpBefore (damage = red, heal = green) with gradient.
        if math.abs(yB - yA) >= 1 then
            local capTex = chart.capPool[i]
            if capTex then
                local capTop = math.min(yA, yB)
                local capH   = math.abs(yB - yA)
                capTex:SetSize(barW, math.max(1, capH))
                capTex:SetPoint("TOPLEFT", chart, "TOPLEFT", bx, -capTop)
                if g.isHeal then
                    SetGradient(capTex, "VERTICAL", 0.10, 0.46, 0.22, 0.22, 0.82, 0.40, 0.82)
                elseif g.overkill > 0 then
                    local alpha = g.hasCrit and 0.95 or 0.88
                    SetGradient(capTex, "VERTICAL", 0.65, 0.06, 0.06, 0.98, 0.12, 0.12, alpha)
                else
                    local alpha = g.hasCrit and 0.92 or 0.82
                    SetGradient(capTex, "VERTICAL", 0.50, 0.08, 0.08, 0.88, 0.18, 0.18, alpha)
                end
                capTex:Show()
            end
        end

        -- White separator line at hpAfter level.
        local lineTex = chart.linePool[i]
        if lineTex and yA < yBot then
            lineTex:SetSize(barW, 1)
            lineTex:SetPoint("TOPLEFT", chart, "TOPLEFT", bx, -yA)
            SetSolidColor(lineTex, COLOR_HP_LINE[1], COLOR_HP_LINE[2], COLOR_HP_LINE[3], 0.75)
            lineTex:Show()
        end

        -- Icon below the bar — 1px dark border frame then icon on top.
        local iconRowY = layout.iconTop
        local iconX = cx - math.floor(iconSize / 2)

        local iconBorderTex = chart.iconBorderPool[i]
        if iconBorderTex then
            iconBorderTex:SetSize(iconSize + 2, iconSize + 2)
            iconBorderTex:SetPoint("TOPLEFT", chart, "TOPLEFT", iconX - 1, iconRowY + 1)
            SetSolidColor(iconBorderTex, 0, 0, 0, 0.80)
            iconBorderTex:Show()
        end

        local iconTex = chart.iconPool[i]
        if iconTex then
            local iconPath = GetEventIcon(g.iconEv or {spellId=g.spellId, subevent=g.subevent})
            iconTex:SetTexture(iconPath)
            iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            iconTex:SetSize(iconSize, iconSize)
            iconTex:SetPoint("TOPLEFT", chart, "TOPLEFT", iconX, iconRowY)
            iconTex:Show()
        end

        -- Hit count label is tucked into the icon instead of taking its own row.
        if g.count > 1 then
            local cfs = chart.countFS[i]
            if cfs then
                if cfs.SetWidth then cfs:SetWidth(iconSize + 8) end
                cfs:SetJustifyH("RIGHT")
                cfs:SetText("|cffffcc00x" .. g.count .. "|r")
                cfs:SetPoint("BOTTOMRIGHT", chart, "TOPLEFT", iconX + iconSize + 4, iconRowY - iconSize + 1)
                cfs:Show()
            end
        end

        -- Time label
        local tfs = chart.timeFS[i]
        if tfs and (timeEvery == 1 or i == 1 or i == nCols
            or ((i - 1) % timeEvery == 0 and i <= nCols - timeEvery)) then
            local tOff = math.abs(g.time - deathTime)
            if tfs.SetWidth then tfs:SetWidth(math.max(30, colW * timeEvery)) end
            tfs:SetJustifyH("CENTER")
            tfs:SetText(string.format("%.1fs", tOff))
            tfs:SetPoint("TOP", chart, "TOPLEFT", cx, iconRowY - iconSize - 5)
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
    deathWindowStart = nil
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

local function SetDeathGroupsFromSnapshot(snapshot)
    local grouped = GroupEvents(snapshot)
    deathGroups, deathWindowStart = ClipGroupsToRelevantWindow(grouped, playerMaxHp)
end

local function OnPlayerDied()
    deathTime     = GetTime()
    playerMaxHp   = (UnitHealthMax and UnitHealthMax("player")) or playerMaxHp
    deathSnapshot = SnapshotForDeath(deathTime)
    SetDeathGroupsFromSnapshot(deathSnapshot)
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

    local events = {}

    local function damage(tOff, src, spell, spellId, school, amount, crit, overkill, subevent)
        events[#events + 1] = {
            time=now - tOff, subevent=subevent or "SPELL_DAMAGE",
            srcName=src, srcGUID="", amount=amount, school=school,
            spellId=spellId, spellName=spell,
            isHeal=false, isCrit=crit, overkill=overkill or 0,
        }
    end

    local function heal(tOff, src, spell, spellId, amount, crit, overheal)
        events[#events + 1] = {
            time=now - tOff, subevent="SPELL_HEAL",
            srcName=src, srcGUID="", amount=amount, school=0x02,
            spellId=spellId, spellName=spell,
            isHeal=true, isCrit=crit, overkill=0, overheal=overheal or 0,
        }
    end

    -- Older combat is deliberately present, then a top-off heal clips it away.
    damage(18.2, "Guard Mol'dar", "Wing Buffet", 18500, 0x01, 845, true)
    damage(16.4, "Onyxia's Whelp", "Melee", nil, 0x01, 420, false, 0, "SWING_DAMAGE")
    heal(14.5, "Priest", "Renew", 9076, 1100, false)
    damage(12.8, "Arcanist Doan", "Fireball", 9488, 0x04, 760, false)
    heal(6.4, "Priest", "Flash Heal", 9474, 2300, true, 900)

    -- The recap should start here: full health to dead in roughly HotS-sized time.
    damage(5.8, "Onyxia", "Flame Breath", 18435, 0x04, 1200, false)
    damage(4.6, "Guard Mol'dar", "Wing Buffet", 18500, 0x01, 1450, true)
    damage(3.9, "Onyxia's Whelp", "Melee", nil, 0x01, 1100, false, 0, "SWING_DAMAGE")
    heal(3.2, "Priest", "Flash Heal", 9474, 600, false)
    damage(2.5, "Onyxia", "Flame Breath", 18435, 0x04, 1800, false)
    damage(1.7, "Onyxia", "Flame Breath (DoT)", 18435, 0x04, 850, false, 0, "SPELL_PERIODIC_DAMAGE")
    damage(1.2, "Onyxia", "Flame Breath (DoT)", 18435, 0x04, 850, false, 0, "SPELL_PERIODIC_DAMAGE")
    damage(0.2, "Onyxia", "Deep Breath", 23461, 0x04, 2400, true, 550)

    table.sort(events, function(a,b) return a.time < b.time end)
    deathSnapshot = events
    SetDeathGroupsFromSnapshot(events)
    killerName, killerSpell = FindKiller(events)
end

-- ============================================================================
-- Slash Commands
-- ============================================================================

local function PrintAbout()
    Print(addonName .. " by " .. addonAuthor)
    Print(addonWebsite)
end

SLASH_DEATHLAPSE1 = "/deathlapse"
SLASH_DEATHLAPSE2 = "/dl"
SlashCmdList["DEATHLAPSE"] = function(msg)
    local args = {}
    for word in string.gmatch(msg, "%S+") do args[#args+1] = string.lower(word) end
    local cmd = args[1] or ""

    if cmd == "" or cmd == "show" then Deathlapse:ShowTimeline()
    elseif cmd == "hide"     then Deathlapse:HideTimeline()
    elseif cmd == "clear"    then Deathlapse:ClearSnapshot()
    elseif cmd == "about"    then PrintAbout()
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
    elseif cmd == "reset" then
        GetDB().timelinePosition = nil
        GetDB().timelineSize = nil
        if timelineFrame then
            timelineFrame:ClearAllPoints()
            timelineFrame:SetSize(FRAME_DEFAULT_W, FRAME_DEFAULT_H)
            timelineFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
            LayoutTimelineFrame(timelineFrame)
            RenderTimeline()
        end
        Print("Timeline position and size reset.")
    elseif cmd == "test" then
        GenerateTestSnapshot()
        Deathlapse:UpdateMinimapIndicator()
        Deathlapse:ShowTimeline()
        Print("Showing test data.")
    elseif cmd == "help" or cmd == "?" then
        Print("Commands: show | hide | clear | about | minimap | autoshow | reset | test | help")
    else Deathlapse:ToggleTimeline() end
end

-- ============================================================================
-- Hyperlink Click Handler
-- ============================================================================

do
    local _origSetItemRef = SetItemRef
    SetItemRef = function(link, text, button, ...)
        if type(link) == "string" and link:sub(1, 11) == "deathlapse:" then
            local sender = link:sub(12)
            local data   = receivedData[sender]
            if not data then
                Print("No recap data from " .. sender .. " — they may need to share again.")
                return
            end
            local groups, maxHp, kName, kSpell = DeserializeRecap(data)
            if not groups or #groups == 0 then
                Print("Could not read recap from " .. sender .. ".")
                return
            end
            deathGroups      = groups
            playerMaxHp      = maxHp
            killerName       = kName
            killerSpell      = kSpell
            deathTime        = groups[#groups].time
            deathWindowStart = nil
            Deathlapse:ShowTimeline()
            Print("Showing |cffffcc00" .. sender .. "|r's death recap.")
            return
        end
        return _origSetItemRef(link, text, button, ...)
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
eventFrame:RegisterEvent("UNIT_MAXHEALTH")
eventFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
eventFrame:RegisterEvent("CHAT_MSG_ADDON")

eventFrame:SetScript("OnEvent", function(_, event, arg1, arg2, arg3, arg4)
    if event == "ADDON_LOADED" then
        if arg1 == addonName then
            playerGUID  = UnitGUID and UnitGUID("player") or nil
            playerMaxHp = (UnitHealthMax and UnitHealthMax("player")) or 1
            if RegisterAddonMessagePrefix then
                RegisterAddonMessagePrefix(ADDON_PREFIX)
            end
            if GetMinimapSettings().show then
                CreateMinimapButton(); UpdateMinimapButtonPosition()
            end
            Print("Loaded. Die to see your recap, or /dl test to preview.")
        elseif arg1 == "ElvUI" and timelineFrame and not timelineFrame.deathlapseElvUISkinned then
            ApplyElvUISkin(timelineFrame)
        end

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
    elseif event == "CHAT_MSG_ADDON" then
        HandleAddonMessage(arg1, arg2, arg4)
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
    ClipGroupsToRelevantWindow = ClipGroupsToRelevantWindow,
    GetLayout            = GetLayout,
    GetEventBuffer       = function() return eventBuffer end,
    SetEventBuffer       = function(t) eventBuffer = t end,
    SetDeathTime         = function(t) deathTime = t end,
    TIMELINE_DURATION    = TIMELINE_DURATION,
    CANVAS_LEFT_PAD      = CHART_LEFT,
    TIMELINE_EFFECTIVE_W = CHART_W,
    MAX_GROUPS           = MAX_GROUPS,
    CHART_H              = CHART_H,
}
