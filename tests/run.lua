-- Deathlapse test suite
-- Run with: lua tests/run.lua

local passed = 0
local failed = 0

local function ok(cond, name)
    if cond then
        passed = passed + 1
        print("  PASS  " .. name)
    else
        failed = failed + 1
        print("  FAIL  " .. name)
    end
end

local function approx(a, b, tol)
    tol = tol or 0.001
    return math.abs(a - b) <= tol
end

-- ============================================================================
-- Minimal WoW API shim
-- ============================================================================

local _time = 1000.0
function GetTime() return _time end

function UnitGUID(unit)
    if unit == "player" then return "Player-1234-ABCDEF" end
    return nil
end

function CombatLogGetCurrentEventInfo() return nil end

-- Frame / texture stubs
local function stub_frame()
    local f = {}
    f._events = {}
    f._scripts = {}
    f._shown = true
    function f:RegisterEvent(e) self._events[e] = true end
    function f:SetScript(ev, fn) self._scripts[ev] = fn end
    function f:Show() self._shown = true end
    function f:Hide() self._shown = false end
    function f:IsShown() return self._shown end
    function f:GetLeft() return 0 end
    function f:GetBottom() return 0 end
    function f:IsMouseOver() return false end
    return f
end

function CreateFrame(ftype, name, parent, template)
    return stub_frame()
end

DEFAULT_CHAT_FRAME = { AddMessage = function() end }
DeathlapseDB = {}

function tinsert(t, v) table.insert(t, v) end
UISpecialFrames = {}
UIParent = stub_frame()
Minimap  = stub_frame()
function Minimap:GetCenter() return 0, 0 end
function Minimap:GetEffectiveScale() return 1 end
function UIParent:GetEffectiveScale() return 1 end

SlashCmdList = {}
SLASH_DEATHLAPSE1 = nil
SLASH_DEATHLAPSE2 = nil

GameTooltip = {
    SetOwner    = function() end,
    SetText     = function() end,
    AddLine     = function() end,
    Show        = function() end,
    Hide        = function() end,
}

-- bit library shim (pure Lua)
bit = {
    band = function(a, b)
        local result = 0
        local bit_val = 1
        while a > 0 and b > 0 do
            if a % 2 == 1 and b % 2 == 1 then
                result = result + bit_val
            end
            a       = math.floor(a / 2)
            b       = math.floor(b / 2)
            bit_val = bit_val * 2
        end
        return result
    end
}

-- ============================================================================
-- Load addon
-- ============================================================================

dofile("Deathlapse.lua")

local I = Deathlapse._internal

-- ============================================================================
-- SafeNumber
-- ============================================================================

print("\n-- SafeNumber --")
ok(I.SafeNumber(42) == 42,            "integer passthrough")
ok(I.SafeNumber("7") == 7,            "string to number")
ok(I.SafeNumber(3.14) == 3.14,        "float passthrough")
ok(I.SafeNumber(nil) == nil,          "nil returns nil")
ok(I.SafeNumber("x") == nil,          "non-numeric string returns nil")

-- ============================================================================
-- HasBit
-- ============================================================================

print("\n-- HasBit --")
ok(I.HasBit(0x04, 0x04),              "exact fire mask")
ok(I.HasBit(0x14, 0x04),              "fire in multi-school 0x14")
ok(not I.HasBit(0x08, 0x04),          "nature does not have fire bit")
ok(I.HasBit(0x01, 0x01),              "physical mask")
ok(not I.HasBit(0, 0x01),             "zero has no bits")

-- ============================================================================
-- SchoolColor
-- ============================================================================

print("\n-- SchoolColor --")
local physCol = I.SchoolColor(0x01)
ok(type(physCol) == "table" and #physCol == 3, "physical returns RGB table")

local fireCol = I.SchoolColor(0x04)
ok(fireCol[1] > 0.8 and fireCol[2] < 0.6,      "fire color is red-orange")

local frostCol = I.SchoolColor(0x10)
ok(frostCol[3] > 0.8,                           "frost color is blue-dominant")

local unknownCol = I.SchoolColor(nil)
ok(type(unknownCol) == "table",                 "nil school returns default color")

local multiSchool = I.SchoolColor(0x14)         -- Frost+Fire; lowest bit = 0x04 Fire
ok(multiSchool == fireCol,                      "multi-school picks lowest set bit")

-- ============================================================================
-- BarHeight
-- ============================================================================

print("\n-- BarHeight --")
ok(Deathlapse.BarHeight(0,    50, 10001) == 2,  "zero amount returns minimum 2")
ok(Deathlapse.BarHeight(-5,   50, 10001) == 2,  "negative amount returns minimum 2")
ok(Deathlapse.BarHeight(1,    50, 10001) >= 2,  "tiny amount >= 2")

local h10k = Deathlapse.BarHeight(10000, 50, 10001)
ok(approx(h10k, 50, 1),                         "reference amount ≈ max height")

local h100  = Deathlapse.BarHeight(100, 50, 10001)
local h1000 = Deathlapse.BarHeight(1000, 50, 10001)
ok(h100 < h1000,                                "larger damage = taller bar")
ok(h1000 < 50,                                  "1000 damage below max height")
ok(h100 >= 2,                                   "100 damage above minimum")

-- ============================================================================
-- EventXPosition
-- ============================================================================

print("\n-- EventXPosition --")

local DURATION = I.TIMELINE_DURATION   -- 20
local LEFT_PAD = I.CANVAS_LEFT_PAD    -- 38
local TW       = I.TIMELINE_EFFECTIVE_W -- 418

local dt = 2000.0
-- event at exactly death time → fraction 1.0 → rightmost position
local evAtDeath = {time = dt}
ok(approx(Deathlapse.EventXPosition(evAtDeath, dt), LEFT_PAD + TW, 1),
   "event at death → right edge")

-- event 20s before death → fraction 0.0 → leftmost position
local evStart = {time = dt - DURATION}
ok(approx(Deathlapse.EventXPosition(evStart, dt), LEFT_PAD, 1),
   "event at -20s → left edge")

-- event 10s before death → fraction 0.5 → middle
local evMid = {time = dt - 10}
ok(approx(Deathlapse.EventXPosition(evMid, dt), LEFT_PAD + TW * 0.5, 1),
   "event at -10s → midpoint")

-- event before the window → clamped to left edge
local evOld = {time = dt - 100}
ok(approx(Deathlapse.EventXPosition(evOld, dt), LEFT_PAD, 1),
   "event before window → clamped to left edge")

-- event after death (shouldn't happen but must not crash)
local evFuture = {time = dt + 5}
ok(approx(Deathlapse.EventXPosition(evFuture, dt), LEFT_PAD + TW, 1),
   "event after death → clamped to right edge")

-- nil deathTime returns nil
ok(Deathlapse.EventXPosition({time = 100}, nil) == nil,
   "nil deathTime → nil")

-- ============================================================================
-- PruneBuffer / AddEvent
-- ============================================================================

print("\n-- PruneBuffer / AddEvent --")

I.SetEventBuffer({})
_time = 1000.0

local function makeEv(t, isHeal)
    return {time = t, subevent = "SPELL_DAMAGE", srcName = "X", srcGUID = "",
            amount = 100, school = 0x01, spellId = 1, spellName = "S",
            isHeal = isHeal or false, isCrit = false, overkill = 0}
end

-- Add events spread over 30 seconds; oldest should be pruned
for i = 1, 10 do
    _time = 975.0 + i * 3   -- t = 978, 981, ..., 1005
    I.AddEvent(makeEv(_time))
end

local buf = I.GetEventBuffer()
-- Events older than _time - BUFFER_PRUNE_AGE (25) = 980 should be pruned
local minTime = 1005 - 25  -- 980
for _, ev in ipairs(buf) do
    ok(ev.time >= minTime, string.format("pruned: ev.time=%.0f >= %.0f", ev.time, minTime))
end
ok(#buf > 0, "buffer is not empty after pruning")

-- ============================================================================
-- SnapshotForDeath
-- ============================================================================

print("\n-- SnapshotForDeath --")

I.SetEventBuffer({})
for i = 1, 30 do
    local t = 900 + i * 4  -- t = 904, 908, ..., 1020
    I.AddEvent(makeEv(t))
end

local deathAt = 1020
local snap = I.SnapshotForDeath(deathAt)

-- All snapshot events should be within 20s of death
for _, ev in ipairs(snap) do
    ok(ev.time >= deathAt - DURATION, string.format("snapshot: ev.time=%.0f >= %.0f", ev.time, deathAt - DURATION))
end
ok(#snap > 0, "snapshot is non-empty")
ok(#snap < 30, "snapshot excludes old events")

-- ============================================================================
-- FindKiller
-- ============================================================================

print("\n-- FindKiller --")

local snapNoOverkill = {
    makeEv(100), makeEv(110), makeEv(120),
}
snapNoOverkill[3].srcName   = "Onyxia"
snapNoOverkill[3].spellName = "Flame Breath"
snapNoOverkill[3].isHeal    = false

local k1, s1 = I.FindKiller(snapNoOverkill)
ok(k1 == "Onyxia",        "FindKiller picks last damage source when no overkill")
ok(s1 == "Flame Breath",  "FindKiller returns spell name")

local snapOverkill = {
    makeEv(100), makeEv(110),
}
snapOverkill[1].srcName  = "Arcanist Doan"
snapOverkill[1].spellName = "Fireball"
snapOverkill[2].srcName  = "Minion"
snapOverkill[2].overkill = 500  -- this is the actual killing blow
snapOverkill[2].spellName = "Melee"

local k2, s2 = I.FindKiller(snapOverkill)
ok(k2 == "Minion",  "FindKiller prefers overkill event")
ok(s2 == nil,       "FindKiller returns nil spell for Melee overkill")

-- ============================================================================
-- Summary
-- ============================================================================

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
    os.exit(1)
end
