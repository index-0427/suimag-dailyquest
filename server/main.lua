local definitions = DQ.validate(Config)
local sessions, blocked, locks, requests, consumption = {}, {}, {}, {}, {}
local ready = false
local resource = GetCurrentResourceName()
assert(resource == 'suimag-dailyquest', 'Resource folder must be named suimag-dailyquest (one instance only)')
local prefix = 'suimag-dailyquest:'

local function log(message)
    print(('[%s] %s'):format(resource, message))
end

local function conflict()
    for _, name in ipairs(Config.ConflictingResources) do
        if GetResourceState(name) == 'started' or GetResourceState(name) == 'starting' then return name end
    end
end

local function current(source, session)
    if sessions[source] ~= session or blocked[source] then return false end
    -- Exports cross a msgpack boundary: returned tables do NOT have stable identity.
    local player = exports.qbx_core:GetPlayer(source)
    return player and not player.Offline and player.PlayerData.source == source
        and player.PlayerData.citizenid == session.citizenid
end

local function run(source, fn)
    source = tonumber(source)
    if not DQ.integer(source, 1) then return { ok = false, error = 'player_unavailable' } end
    if not ready then return { ok = false, error = 'not_ready' } end
    if conflict() then return { ok = false, error = 'conflict' } end
    local player = exports.qbx_core:GetPlayer(source)
    local citizenid = player and player.PlayerData.citizenid
    if not DQ.identifier(citizenid) or blocked[source] or player.Offline or player.PlayerData.source ~= source then
        return { ok = false, error = 'player_unavailable' }
    end
    local session = sessions[source]
    if not session or session.citizenid ~= citizenid then
        session = { citizenid = citizenid, wall = os.time(), timer = GetGameTimer() }
        sessions[source] = session
    end
    -- Serialize all operations for a character, including exports and timer ticks.
    local waited = 0
    while locks[citizenid] do
        if waited >= 3000 then return { ok = false, error = 'busy' } end
        Wait(25)
        waited = waited + 25
        if not current(source, session) then return { ok = false, error = 'player_unavailable' } end
    end
    if not current(source, session) then return { ok = false, error = 'player_unavailable' } end
    locks[citizenid] = true
    local ok, result = xpcall(function()
        local now = os.time()
        local day = DQ.period('daily', now, Config.Reset).start
        if session.day ~= day then
            DQStore.open(citizenid, now)
            session.day = day
        end
        if not current(source, session) then return { ok = false, error = 'player_unavailable' } end
        return fn(session, now)
    end, debug.traceback)
    locks[citizenid] = nil
    if not ok then
        log('Operation failed: ' .. tostring(result))
        return { ok = false, error = 'storage_error' }
    end
    return result or { ok = true }
end


-- Resource-local API for trusted adapters; not a FiveM export or network event.
DQRuntime = {}
function DQRuntime.identity(sourceId)
    if not DQ.integer(sourceId, 1) or blocked[sourceId] then return nil end
    local player = exports.qbx_core:GetPlayer(sourceId)
    local data = player and not player.Offline and player.PlayerData
    if data and data.source == sourceId and DQ.identifier(data.citizenid) then return data.citizenid end
end
function DQRuntime.signal(sourceId, expectedCitizenId, activity)
    return run(sourceId, function(session, now)
        if session.citizenid ~= expectedCitizenId then return { ok=false, error='player_unavailable' } end
        DQStore.signal(session.citizenid, activity, now)
    end)
end
local function rateLimit(source, action)
    local now = GetGameTimer()
    requests[source] = requests[source] or {}
    local previous = requests[source][action]
    if previous and now >= previous and now - previous < Config.RequestCooldownMs then return false end
    requests[source][action] = now
    return true
end

local function snapshot(source)
    return run(source, function(session, now)
        local rows, quests = DQStore.list(session.citizenid, now), {}
        if not current(source, session) then return { ok = false, error = 'player_unavailable' } end
        local byId = {}
        for _, row in ipairs(rows) do
            byId[row.quest_id] = byId[row.quest_id] or {}
            byId[row.quest_id][tonumber(row.period_start)] = row
        end
        for _, quest in ipairs(Config.Quests) do
            local period = DQ.period(quest.period, now, Config.Reset)
            local row = byId[quest.id] and byId[quest.id][period.start]
            if row then
                local rewardLabel
                if row.reward_type == 'item' then
                    local item = exports.ox_inventory:Items(row.reward_name)
                    rewardLabel = ('%s × %d'):format(item and item.label or row.reward_name, row.reward_amount)
                else
                    rewardLabel = ('%s $%d'):format(row.reward_type == 'bank' and '銀行' or '現金', row.reward_amount)
                end
                quests[#quests + 1] = {
                    id = quest.id, period = quest.period, periodStart = period.start,
                    title = quest.title, description = quest.description,
                    value = row.progress, target = row.target, status = row.status,
                    unit = (quest.metric == 'playtime' or quest.metric == 'duty') and '分'
                        or quest.metric == 'distance' and 'km' or (quest.unit or '回'),
                    scale = (quest.metric == 'playtime' or quest.metric == 'duty') and 60
                        or quest.metric == 'distance' and 1000 or 1,
                    precision = quest.metric == 'distance' and 1 or 0,
                    available = not (quest.metric == 'activity' and Config.Activities[quest.activity].resource)
                        or GetResourceState(Config.Activities[quest.activity].resource) == 'started',
                    reward = rewardLabel,
                }
            end
        end
        return {
            ok = true, quests = quests, now = now,
            dailyReset = DQ.resetLabel(DQ.period('daily', now, Config.Reset).finish, Config.Reset),
            weeklyReset = DQ.resetLabel(DQ.period('weekly', now, Config.Reset).finish, Config.Reset),
        }
    end)
end

local function claim(source, questId, periodStart)
    local quest = type(questId) == 'string' and definitions[questId]
    if not quest or not DQ.integer(periodStart, 0, 4102444800) then return { ok = false, error = 'invalid_request' } end
    return run(source, function(session, now)
        if DQ.period(quest.period, now, Config.Reset).start ~= periodStart then
            return { ok = false, error = 'expired' }
        end
        local row = DQStore.row(session.citizenid, questId, periodStart)
        if not row then return { ok = false, error = 'invalid_request' } end
        if row.status == 'pending' then return { ok = false, error = 'pending', claimId = row.id } end
        if row.status == 'claimed' then return { ok = false, error = 'claimed' } end
        if row.progress < row.target then return { ok = false, error = 'incomplete' } end
        assert(DQ.integer(row.reward_amount, 1, 10000000), 'Invalid saved reward amount')
        assert(row.reward_type == 'bank' or row.reward_type == 'cash'
            or (row.reward_type == 'item' and DQ.identifier(row.reward_name)), 'Invalid saved reward type')
        if row.reward_type == 'item' then
            if not exports.ox_inventory:Items(row.reward_name) then return { ok = false, error = 'invalid_item' } end
            if not exports.ox_inventory:CanCarryItem(source, row.reward_name, row.reward_amount) then
                return { ok = false, error = 'inventory_full' }
            end
        end
        if not current(source, session) then return { ok = false, error = 'player_unavailable' } end
        if not DQStore.reserve(session.citizenid, row.id, os.time()) then
            return { ok = false, error = 'claim_unavailable' }
        end
        -- No reward may be issued after a DB yield without checking identity and expiry again.
        if not current(source, session) or os.time() >= row.ends_at or conflict() then
            DQStore.release(row.id)
            return { ok = false, error = 'claim_unavailable' }
        end
        log(('Claim %s reserved for %s / %s'):format(row.id, session.citizenid, questId))
        local ok, delivered = pcall(function()
            if row.reward_type == 'item' then
                return exports.ox_inventory:AddItem(source, row.reward_name, row.reward_amount)
            end
            return exports.qbx_core:AddMoney(source, row.reward_type, row.reward_amount, 'dailyquest:' .. row.id)
        end)
        if ok and delivered == false then
            -- The provider explicitly rejected the operation without delivering a reward.
            DQStore.release(row.id)
            return { ok = false, error = 'reward_failed' }
        end
        if not ok or delivered ~= true then
            log(('Claim %s is PENDING: reward outcome unknown; do not automatically retry.'):format(row.id))
            return { ok = false, error = 'pending', claimId = row.id }
        end
        log(('Claim %s reward provider returned success.'):format(row.id))
        local saved, err = pcall(DQStore.finish, row.id, os.time())
        if not saved then
            log(('Claim %s is PENDING after delivery: %s'):format(row.id, tostring(err)))
            return { ok = false, error = 'pending', claimId = row.id }
        end
        return { ok = true }
    end)
end

lib.callback.register(prefix .. 'list', function(source)
    if not rateLimit(source, 'list') then return { ok = false, error = 'rate_limited' } end
    return snapshot(source)
end)

lib.callback.register(prefix .. 'claim', function(source, questId, periodStart)
    if not rateLimit(source, 'claim') then return { ok = false, error = 'rate_limited' } end
    return claim(source, questId, periodStart)
end)

-- Local server event ONLY. Never RegisterNetEvent this event or trust client completion reports.
AddEventHandler('ox_inventory:usedItem', function(sourceId, itemName)
    if not Config.Consumables[itemName] or GetInvokingResource() ~= 'ox_inventory' then return end
    local now = GetGameTimer()
    local previous = consumption[sourceId]
    if previous and now >= previous and now - previous < Config.ConsumeCooldownSeconds * 1000 then return end
    consumption[sourceId] = now
    run(sourceId, function(session, timestamp)
        DQStore.consume(session.citizenid, timestamp)
    end)
end)

exports('RecordActivity', function(source, activity, amount, receipt)
    local caller = GetInvokingResource()
    local rule = type(activity) == 'string' and Config.Activities[activity]
    if not rule or not rule.resources[caller] then return false, 'forbidden' end
    if not DQ.integer(amount, 1, rule.maxAmount) or not DQ.identifier(receipt, 96) then
        return false, 'invalid_activity'
    end
    local result = run(source, function(session, now)
        DQStore.activity(session.citizenid, activity, receipt, amount, now)
    end)
    return result.ok, result.error
end)

local function unload(sourceId)
    sourceId = tonumber(sourceId)
    if not sourceId then return end
    blocked[sourceId] = true
    sessions[sourceId], requests[sourceId], consumption[sourceId] = nil, nil, nil
end

AddEventHandler('QBCore:Server:OnPlayerUnload', function(sourceId)
    if GetInvokingResource() == 'qbx_core' then unload(sourceId) end
end)

-- The local construction event is trusted; the similarly named OnPlayerLoaded is a client net event.
AddEventHandler('QBCore:Server:PlayerLoaded', function(player)
    if GetInvokingResource() ~= 'qbx_core' then return end
    local data = type(player) == 'table' and player.PlayerData
    local sourceId = data and tonumber(data.source)
    if not sourceId then return end
    local live = exports.qbx_core:GetPlayer(sourceId)
    if not live or live.PlayerData.citizenid ~= data.citizenid then return end
    blocked[sourceId] = nil
    sessions[sourceId], requests[sourceId], consumption[sourceId] = nil, nil, nil
end)

AddEventHandler('playerDropped', function()
    unload(source)
    blocked[source] = nil
end)

AddEventHandler('onResourceStart', function(name)
    for _, other in ipairs(Config.ConflictingResources) do
        if name == other then log('Conflicting resource ' .. name .. ': quests are suspended until it stops.') end
    end
end)

-- Console only: no player ACE, network event or public endpoint exposes other characters.
RegisterCommand('dailyquest_pending', function(source)
    if source ~= 0 then return end
    if not ready then log('Database is not ready.'); return end
    local ok, rows = pcall(DQStore.pending)
    if not ok then log('Could not read pending claims.'); return end
    log('Pending claims (up to 50): ' .. json.encode(rows))
end, true)

RegisterCommand('dailyquest_status', function(source)
    if source == 0 then log(('DB ready=%s; conflict=%s'):format(tostring(ready), conflict() or 'none')) end
end, true)

MySQL.ready(function()
    CreateThread(function()
        while not ready do
            local ok, err = pcall(DQStore.init)
            ready = ok
            if not ok then log('Database initialization failed; retrying in 30s: ' .. tostring(err)); Wait(30000) end
        end
        log('Ready. Command: /' .. Config.Command)
        if conflict() then log('Conflicting resource ' .. conflict() .. ': quests are suspended until it stops.') end
    end)
end)

CreateThread(function()
    while true do
        Wait(Config.TickSeconds * 1000)
        if ready then
            for _, id in ipairs(GetPlayers()) do
                local sourceId = tonumber(id)
                run(sourceId, function(session, now)
                    local timer = GetGameTimer()
                    local seconds = DQ.elapsed(session, now, timer, Config.TickSeconds * 2)
                    -- Advance before awaiting DB. An ambiguous write must never be replayed.
                    session.wall, session.timer = now, timer
                    local tracked = DQTracking.drain(session)
                    if seconds and seconds > 0 then DQStore.addTime(session.citizenid, now - seconds, now) end
                    if #tracked > 0 then DQStore.tracked(session.citizenid, tracked) end
                end)
            end
        end
    end
end)

CreateThread(function()
    while true do
        Wait(Config.Tracking.sampleSeconds * 1000)
        if ready and not conflict() then
            for sourceId, session in pairs(sessions) do
                if current(sourceId, session) then
                    local player = exports.qbx_core:GetPlayer(sourceId)
                    if player and player.PlayerData.citizenid == session.citizenid then
                        local ok, frame = pcall(DQTracking.frame, sourceId, player.PlayerData)
                        if ok then DQTracking.sample(session, frame)
                        else session.tracking = nil; log('Tracking sample failed: ' .. tostring(frame)) end
                    else session.tracking = nil end
                end
            end
        else
            for _, session in pairs(sessions) do session.tracking = nil end
        end
    end
end)
