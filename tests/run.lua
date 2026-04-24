-- Deathlapse test suite
-- Run with: lua tests/run.lua

local passed = 0
local failed = 0

local function ok(cond, name)
    if cond then passed = passed + 1; print("  PASS  " .. name)
    else failed = failed + 1; print("  FAIL  " .. name) end
end

local function approx(a, b, tol)
    tol = tol or 1.0
    return math.abs(a - b) <= tol
end

-- ============================================================================
-- WoW API shim
-- ============================================================================

local _time = 1000.0
function GetTime() return _time end
function UnitGUID(u) return u=="player" and "Player-1234-ABCDEF" or nil end
function UnitHealthMax() return 10000 end
function CombatLogGetCurrentEventInfo() return nil end

local function stub_frame()
    local f = {_shown=true, _scripts={}, _events={}}
    function f:RegisterEvent(e) self._events[e]=true end
    function f:SetScript(ev,fn) self._scripts[ev]=fn end
    function f:Show() self._shown=true end
    function f:Hide() self._shown=false end
    function f:IsShown() return self._shown end
    function f:GetLeft() return 0 end
    function f:GetBottom() return 0 end
    function f:IsMouseOver() return false end
    function f:GetEffectiveScale() return 1 end
    function f:GetCenter() return 0,0 end
    return f
end

function CreateFrame() return stub_frame() end
DEFAULT_CHAT_FRAME = {AddMessage=function()end}
DeathlapseDB = {}
SlashCmdList = {}
SLASH_DEATHLAPSE1 = nil
SLASH_DEATHLAPSE2 = nil
tinsert = table.insert
UISpecialFrames = {}
UIParent  = stub_frame()
Minimap   = stub_frame()
GameTooltip = {
    SetOwner=function()end, SetText=function()end,
    AddLine=function()end,  Show=function()end, Hide=function()end,
}
bit = {
    band = function(a,b)
        local r,bv = 0,1
        while a>0 and b>0 do
            if a%2==1 and b%2==1 then r=r+bv end
            a=math.floor(a/2); b=math.floor(b/2); bv=bv*2
        end
        return r
    end
}

dofile("Deathlapse.lua")
local I = Deathlapse._internal

-- ============================================================================
-- SafeNumber
-- ============================================================================
print("\n-- SafeNumber --")
ok(I.SafeNumber(42)==42,         "integer")
ok(I.SafeNumber("7")==7,         "string→number")
ok(I.SafeNumber(nil)==nil,        "nil→nil")
ok(I.SafeNumber("x")==nil,        "non-numeric→nil")

-- ============================================================================
-- HasBit / SchoolColor
-- ============================================================================
print("\n-- HasBit --")
ok(I.HasBit(0x04,0x04),           "exact fire mask")
ok(I.HasBit(0x14,0x04),           "fire in multi 0x14")
ok(not I.HasBit(0x08,0x04),       "nature ≠ fire")

print("\n-- SchoolColor --")
local fc = I.SchoolColor(0x04)
ok(type(fc)=="table" and #fc==3,  "fire returns RGB table")
ok(fc[1]>0.8 and fc[2]<0.6,       "fire is orange-red dominant")
ok(I.SchoolColor(nil)==I.SchoolColor(0x01), "nil falls back to physical")

-- ============================================================================
-- BarHeight (kept for compat)
-- ============================================================================
print("\n-- BarHeight --")
ok(Deathlapse.BarHeight(0,50,10001)==2,       "zero → minimum 2")
ok(Deathlapse.BarHeight(-1,50,10001)==2,      "negative → minimum 2")
local h10k = Deathlapse.BarHeight(10000,50,10001)
ok(approx(h10k,50,1),                        "reference amount ≈ max")
ok(Deathlapse.BarHeight(100,50,10001) < Deathlapse.BarHeight(1000,50,10001),
   "larger amount = taller bar")

-- ============================================================================
-- HpY
-- ============================================================================
print("\n-- HpY --")
local CH = I.CHART_H
ok(approx(Deathlapse.HpY(1.0), 0,   1), "100% HP → top (y=0)")
ok(approx(Deathlapse.HpY(0.0), CH,  1), "0% HP   → bottom")
ok(approx(Deathlapse.HpY(0.5), CH/2,1), "50% HP  → middle")
ok(Deathlapse.HpY(1.5)==Deathlapse.HpY(1.0), "clamp above 1")
ok(Deathlapse.HpY(-0.1)==Deathlapse.HpY(0),  "clamp below 0")

-- ============================================================================
-- ColWidth / GroupX
-- ============================================================================
print("\n-- ColWidth / GroupX --")
local TW = I.TIMELINE_EFFECTIVE_W
ok(Deathlapse.ColWidth(1) == TW,             "1 column = full width")
ok(Deathlapse.ColWidth(1000) >= 18,           "always >= MIN_COL_W")
local x1 = Deathlapse.GroupX(1, 10)
local x2 = Deathlapse.GroupX(2, 10)
ok(x2 > x1,                                  "columns increase left→right")

-- ============================================================================
-- PruneBuffer / AddEvent
-- ============================================================================
print("\n-- Buffer --")
I.SetEventBuffer({})
local function ev(t)
    return {time=t,subevent="SPELL_DAMAGE",srcName="X",srcGUID="",
            amount=100,school=0x01,spellId=1,spellName="S",
            isHeal=false,isCrit=false,overkill=0}
end
for i=1,10 do _time=975+i*3; I.AddEvent(ev(_time)) end
local buf = I.GetEventBuffer()
local minT = 1005 - 25
for _, e in ipairs(buf) do
    ok(e.time >= minT, string.format("pruned: %.0f >= %.0f", e.time, minT))
end
ok(#buf > 0, "buffer non-empty")

-- ============================================================================
-- SnapshotForDeath
-- ============================================================================
print("\n-- SnapshotForDeath --")
I.SetEventBuffer({})
for i=1,30 do I.AddEvent(ev(900+i*4)) end
local snap = I.SnapshotForDeath(1020)
local DUR = I.TIMELINE_DURATION
for _, e in ipairs(snap) do
    ok(e.time >= 1020-DUR, string.format("snapshot: %.0f >= %.0f", e.time, 1020-DUR))
end
ok(#snap > 0 and #snap < 30, "snapshot is a subset")

-- ============================================================================
-- GroupEvents
-- ============================================================================
print("\n-- GroupEvents --")
local rawEvs = {
    ev(100), ev(100.3), ev(100.6),   -- same spell/src within 1s → 1 group
    ev(105),                          -- different time → new group
}
for _, e in ipairs(rawEvs) do e.spellName="Fireball"; e.srcName="Mage" end
rawEvs[4].spellName = "Frostbolt"    -- different spell → separate group

local groups = I.GroupEvents(rawEvs)
ok(#groups == 2, "3 same-spell events + 1 different = 2 groups")
ok(groups[1].count == 3,             "first group has count=3")
ok(groups[1].totalAmount == 300,     "first group totalAmount=300")
ok(groups[2].count == 1,             "second group has count=1")

-- Heal vs damage always separate
local mixEvs = {ev(200), ev(200.1)}
mixEvs[1].isHeal=false; mixEvs[1].spellName="X"; mixEvs[1].srcName="Y"
mixEvs[2].isHeal=true;  mixEvs[2].spellName="X"; mixEvs[2].srcName="Y"
local mixGroups = I.GroupEvents(mixEvs)
ok(#mixGroups == 2, "damage + heal same spell → separate groups")

-- ============================================================================
-- ComputeHpTrajectory
-- ============================================================================
print("\n-- ComputeHpTrajectory --")
local testGroups = {
    {totalAmount=2000, overkill=0, isHeal=false},
    {totalAmount=3000, overkill=0, isHeal=false},
    {totalAmount=1000, overkill=0, isHeal=true},
    {totalAmount=5000, overkill=1000, isHeal=false},
}
local maxHp = 10000
local hpB, hpA = I.ComputeHpTrajectory(testGroups, maxHp)

ok(hpA[4] == 0,             "last event: hpAfter=0 (death)")
ok(hpB[4] > 0,              "last event: hpBefore > 0")
ok(hpA[3] > hpA[2],         "after heal: HP is higher than after prev damage")
ok(hpB[1] <= 1.0,           "hpBefore capped at 1.0")
ok(hpA[1] >= 0,             "hpAfter never negative")

-- Verify overkill reduces effective damage used in reconstruction
local ok_groups = {
    {totalAmount=8000, overkill=5000, isHeal=false},   -- effective=3000
}
local hpB2, hpA2 = I.ComputeHpTrajectory(ok_groups, 10000)
ok(approx(hpB2[1], 0.30, 0.01), "overkill: hpBefore = (8000-5000)/10000 = 0.30")

-- ============================================================================
-- FindKiller
-- ============================================================================
print("\n-- FindKiller --")
local s1 = {ev(100), ev(110), ev(120)}
s1[3].srcName="Onyxia"; s1[3].spellName="Flame Breath"
local k1,sp1 = I.FindKiller(s1)
ok(k1=="Onyxia",       "FindKiller: last damage source")
ok(sp1=="Flame Breath","FindKiller: spell name")

local s2 = {ev(100), ev(110)}
s2[1].srcName="DoT"; s2[1].spellName="Fireball"; s2[1].overkill=0
s2[2].srcName="Onyxia"; s2[2].spellName="Melee"; s2[2].overkill=800
local k2,sp2 = I.FindKiller(s2)
ok(k2=="Onyxia",  "FindKiller: prefers overkill")
ok(sp2==nil,      "FindKiller: Melee → nil spell")

-- ============================================================================
print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
