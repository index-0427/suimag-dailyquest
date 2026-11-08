dofile('config.lua')
dofile('server/domain.lua')
local count = 0
local function eq(actual, expected, message)
    count = count + 1
    assert(actual == expected, (message or 'mismatch') .. ': ' .. tostring(actual) .. ' ~= ' .. tostring(expected))
end
local reset = Config.Reset
-- 2026-11-04 05:00 JST == 2026-11-03 20:00 UTC.
local boundary = 1793736000
eq(os.date('!%Y-%m-%d %H:%M', boundary), '2026-11-03 20:00')
eq(DQ.period('daily', boundary - 1, reset).finish, boundary, 'before reset')
eq(DQ.period('daily', boundary, reset).start, boundary, 'at reset')
eq(DQ.period('daily', boundary + 1, reset).start, boundary, 'after reset')
local monday = boundary - 2 * 86400
eq(os.date('!%Y-%m-%d %H:%M', monday), '2026-11-01 20:00')
eq(DQ.period('weekly', monday - 1, reset).finish, monday)
eq(DQ.period('weekly', monday, reset).start, monday)
eq(DQ.period('weekly', boundary, reset).start, monday)
eq(DQ.period('weekly', monday + 604800, reset).start, monday + 604800)
eq(DQ.period('weekly', monday, { offsetMinutes = 540, hour = 5, weekDay = 7 }).start, monday - 86400)
local parts = DQ.segments('daily', boundary - 7, boundary + 8, reset)
eq(#parts, 2)
eq(parts[1].amount, 7)
eq(parts[2].amount, 8)
eq(parts[1].period.finish, parts[2].period.start)
eq(#DQ.segments('daily', boundary, boundary, reset), 0)
local weekly = DQ.segments('weekly', monday - 1, monday + 1, reset)
eq(#weekly, 2)
eq(weekly[1].amount + weekly[2].amount, 2)
for timestamp = 1700000000, 1850000000, 137371 do
    for _, kind in ipairs({ 'daily', 'weekly' }) do
        local p = DQ.period(kind, timestamp, reset)
        eq(p.start <= timestamp and timestamp < p.finish, true, 'contains timestamp')
        eq(DQ.period(kind, p.finish - 1, reset).start, p.start)
        eq(DQ.period(kind, p.finish, reset).start, p.finish)
    end
end
eq(DQ.elapsed({ timer=1000, wall=100 }, 115, 16000, 30), 15)
eq(DQ.elapsed({ timer=1000, wall=100 }, 115, 16999, 30), 15)
eq(DQ.elapsed({ timer=1000, wall=100 }, 116, 16999, 30), 16, 'fractional ticks do not lose wall seconds')
eq(DQ.elapsed({ timer=1000, wall=100 }, 99, 16000, 30), nil)
eq(DQ.elapsed({ timer=1000, wall=100 }, 500, 16000, 30), nil)
eq(DQ.elapsed({ timer=1000, wall=100 }, 500, 401000, 30), nil)
eq(DQ.elapsed({ timer=2147483640, wall=100 }, 115, -2147483000, 30), nil)
for _, value in ipairs({ -1, 0.1, math.huge, -math.huge, '1', false, 0/0 }) do eq(DQ.integer(value), false) end
eq(DQ.identifier('abc-123_ABC'), true)
eq(DQ.identifier('a:b'), false)
eq(DQ.identifier(string.rep('a', 65)), false)
eq(DQ.identifier(''), false)
eq(type(DQ.validate(Config)), 'table')
local function invalid(change)
    dofile('config.lua')
    change(Config)
    eq(pcall(DQ.validate, Config), false, 'invalid config rejected')
end
invalid(function(c) c.Quests[2].id = c.Quests[1].id end)
invalid(function(c) c.Quests[1].target = 0 end)
invalid(function(c) c.Quests[1].target = 2 end)
invalid(function(c) c.Rewards.daily = math.huge end)
invalid(function(c) c.Rewards.account = 'crypto' end)
invalid(function(c) c.Quests[1].metric = 'activity'; c.Quests[1].activity = 'missing' end)
invalid(function(c) c.Activities.atm.item = nil end)
invalid(function(c) c.Activities.store.item = {} end)
invalid(function(c) c.Reset.weekDay = 0 end)
invalid(function(c) c.Reset.offsetMinutes = 900 end)
invalid(function(c) c.Quests[1].reward={type='bank',amount=1000} end)
print(('domain: %d assertions passed'):format(count))
