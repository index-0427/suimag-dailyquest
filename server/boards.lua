local S, P = DQStore, DQSelection
local function q(name, values) return { query=S.sql[name], values=values } end
local function transaction(queries) assert(MySQL.transaction.await(queries), 'Board transaction failed') end
local sequence = 0
local function token()
    sequence = sequence + 1
    return assert(S.bootId, 'Missing boot ID') .. '-board-' .. sequence
end

S.sql.preferences = [[SELECT exclude_crime, exclude_employment FROM suimag_dailyquest_preferences WHERE citizenid = ?]]
S.sql.savePreferences = [[INSERT INTO suimag_dailyquest_preferences (citizenid, exclude_crime, exclude_employment, updated_at)
    VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE exclude_crime = VALUES(exclude_crime),
    exclude_employment = VALUES(exclude_employment), updated_at = VALUES(updated_at)]]
S.sql.boards = [[SELECT * FROM suimag_dailyquest_boards WHERE citizenid = ? AND period_start <= ? AND ends_at > ?]]
S.sql.assignments = [[SELECT a.* FROM suimag_dailyquest_assignments a JOIN suimag_dailyquest_boards b
    USING (citizenid, period_kind, period_start) WHERE a.citizenid = ? AND b.period_start <= ? AND b.ends_at > ?]]
S.sql.makeBoard = [[INSERT INTO suimag_dailyquest_boards (citizenid, period_kind, period_start, ends_at, token)
    VALUES (?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE citizenid = citizenid]]
S.sql.assign = [[INSERT INTO suimag_dailyquest_assignments (citizenid, period_kind, period_start, quest_id, slot, assigned_at, assigned_token)
    SELECT citizenid, period_kind, period_start, ?, ?, ?, ? FROM suimag_dailyquest_boards
    WHERE citizenid = ? AND period_kind = ? AND period_start = ? AND token = ?]]
S.sql.ensureAssigned = [[INSERT INTO suimag_dailyquest_progress
    (citizenid, quest_id, period_kind, period_start, ends_at, target, reward_type, reward_name, reward_amount)
    SELECT ?, ?, ?, ?, ?, ?, ?, ?, ? FROM suimag_dailyquest_boards
    WHERE citizenid = ? AND period_kind = ? AND period_start = ? AND token = ?
    ON DUPLICATE KEY UPDATE
        reward_type = IF(status='active',VALUES(reward_type),reward_type),
        reward_name = IF(status='active',VALUES(reward_name),reward_name),
        reward_amount = IF(status='active',VALUES(reward_amount),reward_amount)]]
S.sql.clearBoardToken = [[UPDATE suimag_dailyquest_boards SET token = ''
    WHERE citizenid = ? AND period_kind = ? AND period_start = ? AND token = ?]]
S.sql.takeReroll = [[UPDATE suimag_dailyquest_boards b SET rerolls_used = 1, token = ?
    WHERE b.citizenid = ? AND b.period_kind = ? AND b.period_start = ? AND b.ends_at > ?
    AND b.rerolls_used = 0
    AND EXISTS (SELECT 1 FROM suimag_dailyquest_assignments a JOIN suimag_dailyquest_progress p
        ON p.citizenid = a.citizenid AND p.quest_id = a.quest_id AND p.period_start = a.period_start
        WHERE a.citizenid = b.citizenid AND a.period_kind = b.period_kind AND a.period_start = b.period_start
        AND a.quest_id = ? AND a.active = 1 AND p.status = 'active' AND p.progress < p.target)
    AND NOT EXISTS (SELECT 1 FROM suimag_dailyquest_assignments a
        WHERE a.citizenid = b.citizenid AND a.period_kind = b.period_kind AND a.period_start = b.period_start AND a.quest_id = ?)
    AND NOT EXISTS (SELECT 1 FROM suimag_dailyquest_progress p
        WHERE p.citizenid = b.citizenid AND p.period_start = b.period_start AND p.quest_id = ? AND p.status <> 'active')]]
S.sql.retire = [[UPDATE suimag_dailyquest_assignments a SET active = 0
    WHERE citizenid = ? AND period_kind = ? AND period_start = ? AND quest_id = ?
    AND EXISTS (SELECT 1 FROM suimag_dailyquest_boards b WHERE b.citizenid = a.citizenid
        AND b.period_kind = a.period_kind AND b.period_start = a.period_start AND b.token = ?)]]
S.sql.resetReplacement = [[UPDATE suimag_dailyquest_progress p SET progress = 0, attempted_at = NULL, claimed_at = NULL
    WHERE citizenid = ? AND quest_id = ? AND period_start = ? AND status = 'active'
    AND EXISTS (SELECT 1 FROM suimag_dailyquest_boards b WHERE b.citizenid = p.citizenid
        AND b.period_kind = p.period_kind AND b.period_start = p.period_start AND b.token = ?)]]
S.sql.allPeriodRows = [[SELECT quest_id, period_start, status FROM suimag_dailyquest_progress WHERE citizenid = ? AND period_start = ?]]

function S.preferences(citizenid)
    local row = MySQL.single.await(S.sql.preferences, {citizenid})
    if row then return { crime=tonumber(row.exclude_crime)==1, employment=tonumber(row.exclude_employment)==1 } end
end
function S.savePreferences(citizenid, preferences, now)
    MySQL.update.await(S.sql.savePreferences, {citizenid,preferences.crime and 1 or 0,preferences.employment and 1 or 0,now})
end

local function assignmentQueries(queries, cid, quest, period, slot, now, nonce)
    queries[#queries+1] = q('assign', {quest.id,slot,now,nonce,cid,quest.period,period.start,nonce})
    local reward = DQ.reward(quest.period)
    queries[#queries+1] = q('ensureAssigned', {
        cid,quest.id,quest.period,period.start,period.finish,quest.target,reward.type,'',reward.amount,
        cid,quest.period,period.start,nonce,
    })
end

function S.boardState(citizenid, now)
    local boards = {}
    for _, board in ipairs(MySQL.query.await(S.sql.boards,{citizenid,now,now})) do boards[board.period_kind] = board end
    local assignments = MySQL.query.await(S.sql.assignments,{citizenid,now,now})
    return boards, assignments
end

function S.ensureBoards(citizenid, prefs, data, state, now)
    local boards = S.boardState(citizenid, now)
    local queries = {}
    for _, kind in ipairs({'daily','weekly'}) do
        if not boards[kind] then
            local selected, err = P.pick(kind,Config.Draw[kind],prefs,data,state,now,{},kind=='daily',false)
            if not selected then return false, err end
            local period, nonce = DQ.period(kind,now,Config.Reset), token()
            queries[#queries+1] = q('makeBoard',{citizenid,kind,period.start,period.finish,nonce})
            for slot, quest in ipairs(selected) do assignmentQueries(queries,citizenid,quest,period,slot,now,nonce) end
            queries[#queries+1] = q('clearBoardToken',{citizenid,kind,period.start,nonce})
        end
    end
    if #queries > 0 then transaction(queries) end
    return true
end

function S.reroll(citizenid, quest, prefs, data, state, now, definitions)
    local boards, assignments = S.boardState(citizenid, now)
    local board = boards[quest.period]
    if not board or tonumber(board.rerolls_used) ~= 0 then return false, 'reroll_used' end
    local used, old, otherQuick = {}, nil, false
    for _, assignment in ipairs(assignments) do
        if assignment.period_kind == quest.period then
            used[assignment.quest_id] = true
            if tonumber(assignment.active) == 1 then
                if assignment.quest_id == quest.id then old = assignment
                elseif definitions[assignment.quest_id] and definitions[assignment.quest_id].quick then otherQuick = true end
            end
        end
    end
    if not old then return false, 'not_assigned' end
    local row = S.row(citizenid,quest.id,tonumber(board.period_start))
    if not row or row.status ~= 'active' or row.progress >= row.target then return false, 'reroll_completed' end
    -- Do not reset paid or unresolved rewards left by an older version of the resource.
    for _, previous in ipairs(MySQL.query.await(S.sql.allPeriodRows,{citizenid,board.period_start})) do
        if previous.status ~= 'active' then used[previous.quest_id] = true end
    end
    local picks, err = P.pick(quest.period,1,prefs,data,state,now,used,quest.period=='daily' and not otherQuick,true)
    if not picks then return false, err end
    local replacement, nonce = picks[1], token()
    local period = {start=tonumber(board.period_start),finish=tonumber(board.ends_at)}
    local queries = {
        q('takeReroll',{nonce,citizenid,quest.period,period.start,now,quest.id,replacement.id,replacement.id}),
        q('retire',{citizenid,quest.period,period.start,quest.id,nonce}),
    }
    assignmentQueries(queries,citizenid,replacement,period,tonumber(old.slot),now,nonce)
    queries[#queries+1] = q('resetReplacement',{citizenid,replacement.id,period.start,nonce})
    queries[#queries+1] = q('clearBoardToken',{citizenid,quest.period,period.start,nonce})
    transaction(queries)
    -- A competing transaction may have won without this one changing anything.
    local _, after = S.boardState(citizenid, now)
    for _, assignment in ipairs(after) do
        if assignment.quest_id == replacement.id and tonumber(assignment.active)==1
            and assignment.assigned_token==nonce then return true, replacement.id end
    end
    return false, 'reroll_used'
end
