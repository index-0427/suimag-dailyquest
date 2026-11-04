DQ = {}

function DQ.integer(value, min, max)
    return type(value) == 'number' and value == value and value % 1 == 0
        and value >= (min or 0) and value <= (max or 2147483647)
end

function DQ.identifier(value, max)
    return type(value) == 'string' and #value > 0 and #value <= (max or 64)
        and value:match('^[%w_%-]+$') ~= nil
end

function DQ.validate(config)
    assert(DQ.identifier(config.Command), 'Invalid command')
    assert(config.Key == nil or type(config.Key) == 'string', 'Invalid key')
    assert(DQ.integer(config.TickSeconds, 5, 60), 'TickSeconds must be 5..60')
    assert(DQ.integer(config.RequestCooldownMs, 250, 60000), 'Invalid request cooldown')
    assert(DQ.integer(config.ConsumeCooldownSeconds, 1, 60), 'Invalid consume cooldown')
    assert(DQ.integer(config.Reset.offsetMinutes, -720, 840), 'Invalid UTC offset')
    assert(DQ.integer(config.Reset.hour, 0, 23), 'Invalid reset hour')
    assert(DQ.integer(config.Reset.weekDay, 1, 7), 'Invalid reset weekday')
    assert(type(config.AutoCreateTables) == 'boolean', 'Invalid AutoCreateTables')
    for name, value in pairs(config.Consumables) do
        assert(DQ.identifier(name) and value == true, 'Invalid consumable')
    end
    assert(type(config.Tracking) == 'table' and DQ.integer(config.Tracking.sampleSeconds, 1, 10), 'Invalid tracking interval')
    for _, mode in ipairs({ 'walk', 'cycle', 'drive' }) do
        assert(DQ.integer(config.Tracking.maxSpeed[mode], 1, 150), 'Invalid movement speed cap')
    end
    assert(type(config.Tracking.bicycles) == 'table' and #config.Tracking.bicycles > 0, 'Missing bicycle models')
    for _, model in ipairs(config.Tracking.bicycles) do assert(DQ.identifier(model), 'Invalid bicycle model') end
    for job, excluded in pairs(config.Tracking.excludedJobs) do
        assert(DQ.identifier(job) and excluded == true, 'Invalid excluded job')
    end
    local signalSources = {}
    for name, activity in pairs(config.Activities) do
        assert(DQ.identifier(name) and DQ.integer(activity.maxAmount, 1, 10000), 'Invalid activity')
        assert(type(activity.resources) == 'table', 'Missing activity allowlist')
        if activity.signal then
            assert(activity.signal == 'job' or activity.signal == 'recycle' or activity.signal == 'house'
                or activity.signal == 'boosting', 'Invalid activity signal')
            assert(DQ.identifier(activity.resource) and activity.resources[activity.resource], 'Missing signal resource')
            assert(DQ.integer(activity.cooldown, 1, 3600), 'Invalid signal cooldown')
            local signalKey = activity.signal .. ':' .. activity.resource
            assert(not signalSources[signalKey], 'Ambiguous signal resource')
            signalSources[signalKey] = true
            assert(activity.payment == nil or type(activity.payment) == 'boolean', 'Invalid payment condition')
            for reason, allowed in pairs(activity.reasons or {}) do
                assert(type(reason) == 'string' and #reason <= 128 and allowed == true, 'Invalid payment reason')
            end
        end
        for resource, allowed in pairs(activity.resources) do
            assert(DQ.identifier(resource) and allowed == true, 'Invalid resource allowlist')
        end
    end
    local definitions = {}
    assert(#config.Quests > 0 and #config.Quests <= 64, 'Define 1..64 quests')
    for _, quest in ipairs(config.Quests) do
        assert(DQ.identifier(quest.id) and not definitions[quest.id], 'Invalid or duplicate quest id')
        assert(quest.period == 'daily' or quest.period == 'weekly', 'Invalid period')
        assert(quest.metric == 'attendance' or quest.metric == 'playtime'
            or quest.metric == 'consume' or quest.metric == 'activity' or quest.metric == 'distance'
            or quest.metric == 'duty', 'Invalid metric')
        assert(DQ.integer(quest.target, 1, 10000000), 'Invalid target')
        assert(type(quest.title) == 'string' and #quest.title > 0 and #quest.title <= 160, 'Invalid title')
        assert(type(quest.description) == 'string' and #quest.description <= 1000, 'Invalid description')
        assert(quest.unit == nil or type(quest.unit) == 'string', 'Invalid unit')
        if quest.metric == 'distance' then
            assert(quest.mode == 'walk' or quest.mode == 'cycle' or quest.mode == 'drive', 'Invalid movement mode')
        elseif quest.metric == 'attendance' then
            assert(quest.target <= (quest.period == 'daily' and 1 or 7), 'Impossible attendance target')
        elseif quest.metric == 'activity' then
            assert(config.Activities[quest.activity], 'Missing activity definition')
        end
        local reward = quest.reward
        assert(type(reward) == 'table' and (reward.type == 'bank' or reward.type == 'cash'
            or reward.type == 'item'), 'Invalid reward type')
        assert(DQ.integer(reward.amount, 1, 10000000), 'Invalid reward amount')
        assert(reward.type ~= 'item' or DQ.identifier(reward.name), 'Invalid reward item')
        definitions[quest.id] = quest
    end
    return definitions
end

-- Epoch arithmetic only: host timezone and DST cannot affect the configured reset.
function DQ.period(kind, timestamp, reset)
    local shift = reset.offsetMinutes * 60 - reset.hour * 3600
    local day = math.floor((timestamp + shift) / 86400)
    if kind == 'weekly' then
        local weekDay = (day + 3) % 7 + 1 -- 1970-01-01 was Thursday (4).
        day = day - (weekDay - reset.weekDay) % 7
    end
    local start = day * 86400 - shift
    return { start = start, finish = start + (kind == 'weekly' and 604800 or 86400) }
end

function DQ.segments(kind, from, to, reset)
    local result = {}
    while from < to do
        local period = DQ.period(kind, from, reset)
        local finish = math.min(to, period.finish)
        result[#result + 1] = { period = period, amount = finish - from }
        from = finish
    end
    return result
end

function DQ.resetLabel(timestamp, reset)
    local offset = reset.offsetMinutes
    return os.date('!%m/%d %H:%M', timestamp + offset * 60)
        .. (' (UTC%s%02d:%02d)'):format(offset < 0 and '-' or '+', math.abs(offset) // 60, math.abs(offset) % 60)
end

-- Count only observed monotonic time. Discard clock jumps, stalls and timer wraps.
function DQ.elapsed(last, now, timer, maxSeconds)
    local seconds = math.floor((timer - last.timer) / 1000)
    local wall = now - last.wall
    if seconds < 0 or seconds > maxSeconds or wall < 0 or math.abs(wall - seconds) > 2 then return nil end
    return wall
end
