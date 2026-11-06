DQStore = {}
local S = DQStore

-- Named queries are also exercised against an isolated MariaDB by tests/sql_spec.py.
S.sql = {
    visit = [[INSERT INTO suimag_dailyquest_visits (citizenid, day_start) VALUES (?, ?) ON DUPLICATE KEY UPDATE citizenid = citizenid]],
    attendance = [[UPDATE suimag_dailyquest_progress SET progress = GREATEST(progress, LEAST(target,
        (SELECT COUNT(*) FROM suimag_dailyquest_visits WHERE citizenid = ? AND day_start >= ? AND day_start < ?)))
        WHERE citizenid = ? AND quest_id = ? AND period_start = ? AND status = 'active']],
    advance = [[UPDATE suimag_dailyquest_progress SET progress = LEAST(target, progress + ?)
        WHERE citizenid = ? AND quest_id = ? AND period_start = ? AND status = 'active']],
    list = [[SELECT * FROM suimag_dailyquest_progress
        WHERE citizenid = ? AND period_start <= ? AND ends_at > ?]],
    row = [[SELECT * FROM suimag_dailyquest_progress WHERE citizenid = ? AND quest_id = ? AND period_start = ?]],
    reserve = [[UPDATE suimag_dailyquest_progress SET status = 'pending', attempted_at = ?
        WHERE id = ? AND citizenid = ? AND status = 'active' AND progress >= target AND ends_at > ?]],
    release = [[UPDATE suimag_dailyquest_progress SET status = 'active', attempted_at = NULL
        WHERE id = ? AND status = 'pending']],
    finish = [[UPDATE suimag_dailyquest_progress SET status = 'claimed', claimed_at = ?
        WHERE id = ? AND status = 'pending']],
    gate = [[INSERT INTO suimag_dailyquest_signal_gates (citizenid, activity) VALUES (?, ?)
        ON DUPLICATE KEY UPDATE citizenid = citizenid]],
    throttle = [[UPDATE suimag_dailyquest_signal_gates SET last_at = ?, token = ?
        WHERE citizenid = ? AND activity = ? AND last_at <= ?]],
    gateDone = [[UPDATE suimag_dailyquest_signal_gates SET token = '' WHERE citizenid = ? AND activity = ? AND token = ?]],
    signal = [[UPDATE suimag_dailyquest_progress SET progress = LEAST(target, progress + 1)
        WHERE citizenid = ? AND quest_id = ? AND period_start = ? AND status = 'active'
        AND EXISTS (SELECT 1 FROM suimag_dailyquest_signal_gates WHERE citizenid = ? AND activity = ? AND token = ?)]],
}


-- Every progress path and payout query independently requires a current assignment.
local selected = [[ AND EXISTS (SELECT 1 FROM suimag_dailyquest_assignments a
    WHERE a.citizenid = suimag_dailyquest_progress.citizenid AND a.quest_id = suimag_dailyquest_progress.quest_id
    AND a.period_start = suimag_dailyquest_progress.period_start AND a.active = 1)]]
for _, name in ipairs({'attendance','advance','list','row','reserve','signal'}) do
    S.sql[name] = S.sql[name] .. selected
end
S.sql.time = [[UPDATE suimag_dailyquest_progress p JOIN suimag_dailyquest_assignments a
    ON a.citizenid=p.citizenid AND a.quest_id=p.quest_id AND a.period_start=p.period_start AND a.active=1
    SET p.progress=LEAST(p.target,p.progress+GREATEST(0,?-GREATEST(?,a.assigned_at)))
    WHERE p.citizenid=? AND p.quest_id=? AND p.period_start=? AND p.status='active']]
local function query(name, values)
    return { query = S.sql[name], values = values }
end

local function transact(queries)
    if #queries > 0 then assert(MySQL.transaction.await(queries), 'Quest transaction failed') end
end

function S.init()
    if Config.AutoCreateTables then
        local schema = assert(LoadResourceFile(GetCurrentResourceName(), 'sql/schema.sql'), 'Missing schema')
        for statement in schema:gmatch('([^;]+);') do MySQL.query.await(statement) end
    end
    S.bootId = assert(MySQL.scalar.await('SELECT UUID()'), 'Could not create signal boot ID')
    MySQL.query.await('SELECT citizenid, activity, last_at, token FROM suimag_dailyquest_signal_gates LIMIT 0')
    MySQL.query.await('SELECT exclude_crime, exclude_employment, updated_at FROM suimag_dailyquest_preferences LIMIT 0')
    MySQL.query.await('SELECT period_kind, period_start, ends_at, rerolls_used, token FROM suimag_dailyquest_boards LIMIT 0')
    MySQL.query.await('SELECT quest_id, slot, assigned_at, assigned_token, active FROM suimag_dailyquest_assignments LIMIT 0')
    MySQL.query.await('SELECT id, citizenid, period_start, ends_at, required_count, reward_type, reward_amount, status, attempted_at, claimed_at FROM suimag_dailyquest_bonuses LIMIT 0')
    -- Fail closed if any required table or column is missing, even with auto-create disabled.
    MySQL.query.await('SELECT id, citizenid, quest_id, period_kind, period_start, ends_at, target, progress, reward_type, reward_amount, reward_coin, reward_coin_amount, status, attempted_at, claimed_at FROM suimag_dailyquest_progress LIMIT 0')
    MySQL.query.await('SELECT citizenid, day_start FROM suimag_dailyquest_visits LIMIT 0')
    S.initSettlement()
    DQDebug.init()
end

function S.open(citizenid, now, assignments)
    local queries = {}
    local day = DQ.period('daily', now, Config.Reset)
    queries[#queries + 1] = query('visit', { citizenid, day.start })
    for _, quest in ipairs(Config.Quests) do
        local period = DQ.period(quest.period, now, Config.Reset)
        local assignment = assignments[quest.id]
        if quest.metric == 'attendance' and assignment and tonumber(assignment.period_start)==period.start then
            local firstDay = DQ.period('daily',tonumber(assignment.assigned_at),Config.Reset).start
            queries[#queries + 1] = query('attendance', {
                citizenid, math.max(period.start,firstDay), period.finish, citizenid, quest.id, period.start,
            })
        end
    end
    for _,entry in ipairs(S.rewardQueries(citizenid,now)) do queries[#queries+1]=entry end
    transact(queries)
end
function S.addTime(citizenid, from, to)
    local queries = {}
    for _, quest in ipairs(Config.Quests) do
        if quest.metric == 'playtime' then
            for _, segment in ipairs(DQ.segments(quest.period, from, to, Config.Reset)) do
                queries[#queries + 1] = query('time', { math.min(to,segment.period.finish), math.max(from,segment.period.start), citizenid, quest.id, segment.period.start })
            end
        end
    end
    transact(queries)
end

function S.consume(citizenid, now, debugEnabled)
    local queries = {}
    for _, quest in ipairs(Config.Quests) do
        if quest.metric == 'consume' then
            queries[#queries + 1] = query('advance', { 1, citizenid, quest.id, DQ.period(quest.period, now, Config.Reset).start })
        end
    end
    if debugEnabled then DQDebug.eventQueries(queries,citizenid,'consume',nil,now) end
    transact(queries)
end

function S.list(citizenid, now)
    return MySQL.query.await(S.sql.list, { citizenid, now, now })
end

function S.row(citizenid, questId, period)
    return MySQL.single.await(S.sql.row, { citizenid, questId, period })
end

function S.reserve(citizenid, id, now)
    return MySQL.update.await(S.sql.reserve, { now, id, citizenid, now }) == 1
end

function S.release(id)
    assert(MySQL.update.await(S.sql.release, { id }) == 1, 'Could not release claim')
end

function S.finish(id, now)
    assert(MySQL.update.await(S.sql.finish, { now, id }) == 1, 'Could not finalize claim')
end

function S.pending()
    return MySQL.query.await(S.sql.pending)
end

-- Legacy notifications carry no immutable completion ID. Persist a rolling cooldown,
-- and acquire an exclusive gate lock before touching any progress rows.
local signalSequence = 0
function S.signal(citizenid, activity, now, debugEnabled)
    signalSequence = signalSequence + 1
    local token = assert(S.bootId, 'Missing signal boot ID') .. '-' .. signalSequence
    local rule = Config.Activities[activity]
    local queries = {
        query('gate', { citizenid, activity }),
        query('throttle', { now, token, citizenid, activity, now - rule.cooldown }),
    }
    for _, quest in ipairs(Config.Quests) do
        if quest.metric == 'activity' and quest.activity == activity then
            queries[#queries + 1] = query('signal', {
                citizenid, quest.id, DQ.period(quest.period, now, Config.Reset).start,
                citizenid, activity, token,
            })
        end
    end
    if debugEnabled then DQDebug.eventQueries(queries,citizenid,'activity',activity,now,token) end
    queries[#queries + 1] = query('gateDone', { citizenid, activity, token })
    transact(queries)
end

function S.tracked(citizenid, increments)
    local queries = {}
    for _, entry in ipairs(increments) do
        local quest, period = entry.quest, entry.period
        queries[#queries + 1] = query('advance', { entry.amount, citizenid, quest.id, period.start })
    end
    transact(queries)
end
