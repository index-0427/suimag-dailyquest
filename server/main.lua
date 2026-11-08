local definitions = DQ.validate(Config)
local sessions, blocked, locks, requests, consumption = {}, {}, {}, {}, {}
local ready = false
local resource = GetCurrentResourceName()
local prefix = 'suimag-dailyquest:'
local settleDaily

local function log(message)
    print(('[%s] %s'):format(resource, message))
end

local function current(source, session)
    if sessions[source] ~= session or blocked[source] then return false end
    -- Exports cross a msgpack boundary: returned tables do NOT have stable identity.
    local player = exports.qbx_core:GetPlayer(source)
    return player and not player.Offline and player.PlayerData.source == source
        and player.PlayerData.citizenid == session.citizenid
end


local function reloadAssignments(session, now)
    local boards, assignments = DQStore.boardState(session.citizenid,now)
    session.boards, session.assignments = boards, {}
    session.trackingAssignments = session.trackingAssignments or {}
    for key, assignment in pairs(session.trackingAssignments) do
        local finish=tonumber(assignment.period_start)+(assignment.period_kind=='daily' and 86400 or 604800)
        if finish<now-30 then session.trackingAssignments[key]=nil end
    end
    for _, assignment in ipairs(assignments) do
        local key=assignment.quest_id..':'..math.floor(tonumber(assignment.period_start))
        if tonumber(assignment.active)==1 then
            session.assignments[assignment.quest_id]=assignment
            session.trackingAssignments[key]=assignment
        else session.trackingAssignments[key]=nil end
    end
end

local function flushTime(session,now)
    local timer=GetGameTimer()
    local seconds=DQ.elapsed(session,now,timer,Config.TickSeconds*2)
    session.wall,session.timer=now,timer
    local tracked=DQTracking.drain(session)
    if seconds and seconds>0 then DQStore.addTime(session.citizenid,now-seconds,now) end
    if #tracked>0 then DQStore.tracked(session.citizenid,tracked) end
    if current(session.source,session) and DQDebug.active(session.source,session) then DQDebug.flush(session,now) end
end

local function maybeSettle(source,session,now)
    if not session.preferences then return end
    local day=DQ.period('daily',now,Config.Reset).start
    if session.autoDay~=day then session.autoDay=day;session.nextAuto=nil end
    if session.nextAuto and now<session.nextAuto then return end
    session.nextAuto=now+Config.AutoClaim.intervalSeconds
    -- Persist observations up to the boundary before deciding what yesterday completed.
    flushTime(session,now)
    if current(source,session) then settleDaily(source,session,now) end
end

local function run(source, fn, allowSetup, skipDraw)
    source = tonumber(source)
    if not DQ.integer(source, 1) then return { ok = false, error = 'player_unavailable' } end
    if not ready then return { ok = false, error = 'not_ready' } end
    local player = exports.qbx_core:GetPlayer(source)
    local citizenid = player and player.PlayerData.citizenid
    if not DQ.identifier(citizenid) or blocked[source] or player.Offline or player.PlayerData.source ~= source then
        return { ok = false, error = 'player_unavailable' }
    end
    local session = sessions[source]
    if not session or session.citizenid ~= citizenid then
        session = { source=source, citizenid = citizenid, wall = os.time(), timer = GetGameTimer() }
        sessions[source] = session
    end
    -- Serialize all operations for a character, including activity signals and timer ticks.
    local waited = 0
    while locks[citizenid] do
        if waited >= 3000 then return { ok = false, error = 'busy' } end
        Wait(25)
        waited = waited + 25
        if not current(source, session) then return { ok = false, error = 'player_unavailable' } end
    end
    if not current(source, session) then return { ok = false, error = 'player_unavailable' } end
    locks[citizenid] = true
    DQDebug.active(source,session)
    local ok, result = xpcall(function()
        local now = os.time()
        local day = DQ.period('daily', now, Config.Reset).start
        if session.day ~= day and not skipDraw then
            session.preferences=DQStore.preferences(citizenid) or false
            if not current(source,session) then return {ok=false,error='player_unavailable'} end
            if session.preferences then
                maybeSettle(source,session,os.time())
                if not current(source,session) then return {ok=false,error='player_unavailable'} end
                local data=exports.qbx_core:GetPlayer(source).PlayerData
                local initialized,err=DQStore.ensureBoards(citizenid,session.preferences,data,GetResourceState,now)
                if not initialized then
                    session.drawError=err
                    if allowSetup then reloadAssignments(session,now); return fn(session,now) end
                    return {ok=false,error=err}
                end
                session.drawError=nil
                reloadAssignments(session,now)
                DQStore.open(citizenid,now,session.assignments)
            else session.assignments={} end
            session.day=day
        end
        if not current(source,session) then return {ok=false,error='player_unavailable'} end
        if not session.preferences and not allowSetup then return {ok=false,error='setup_required'} end
        if not skipDraw then maybeSettle(source,session,os.time()) end
        if not current(source,session) then return {ok=false,error='player_unavailable'} end
        return fn(session,now)
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
        DQStore.signal(session.citizenid, activity, now, DQDebug.active(sourceId,session))
    end,sessions[sourceId] and DQDebug.active(sourceId,sessions[sourceId]))
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
        if not session.preferences then return {ok=true,needsSetup=true,quests={},canDebug=DQDebug.allowed(source)} end
        local rows, quests = DQStore.list(session.citizenid, now), {}
        local bonusRow=DQStore.bonusState(session.citizenid,DQ.period('daily',now,Config.Reset).start)
        local bonus
        if bonusRow then
            local total=tonumber(bonusRow.required_count)
            local completed=tonumber(bonusRow.completed_count)
            assert(DQ.integer(total,1,20) and DQ.integer(completed,0,20),'Invalid daily bonus counts')
            local rewardLabel=('%s $%d'):format(bonusRow.reward_type=='bank' and '銀行' or '現金',bonusRow.reward_amount)
            if (tonumber(bonusRow.reward_coin_amount) or 0)>0 then
                local item=exports.ox_inventory:Items(bonusRow.reward_coin)
                rewardLabel=rewardLabel..(' + %s × %d'):format(item and item.label or bonusRow.reward_coin,bonusRow.reward_coin_amount)
            end
            bonus={
                periodStart=tonumber(bonusRow.period_start),status=bonusRow.status,
                total=total,completed=completed,
                reward=rewardLabel,
                canClaim=bonusRow.status=='active' and tonumber(bonusRow.assigned_count)==total and completed==total,
            }
        end
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
                local rewardLabel = ('%s $%d'):format(row.reward_type == 'bank' and '銀行' or '現金', row.reward_amount)
                if (tonumber(row.reward_coin_amount) or 0)>0 then
                    local item=exports.ox_inventory:Items(row.reward_coin)
                    rewardLabel=rewardLabel..(' + %s × %d'):format(item and item.label or row.reward_coin,row.reward_coin_amount)
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
                    available = quest.metric ~= 'activity'
                        or GetResourceState(Config.Activities[quest.activity].resource) == 'started',
                    reward=rewardLabel, tags=quest.tags,
                    canReroll=row.status=='active' and row.progress<row.target
                        and tonumber(session.boards[quest.period].rerolls_used)==0,
                }
            end
        end
        return {
            ok=true,quests=quests,preferences=session.preferences,dailyBonus=bonus,canDebug=DQDebug.allowed(source),
            drawError=session.drawError,
            rerolls={daily=session.boards.daily and 1-tonumber(session.boards.daily.rerolls_used) or 0,
                weekly=session.boards.weekly and 1-tonumber(session.boards.weekly.rerolls_used) or 0},
            serverNow=os.time(),
            dailyResetAt=DQ.period('daily',now,Config.Reset).finish,
            dailyReset = DQ.resetLabel(DQ.period('daily', now, Config.Reset).finish, Config.Reset),
            weeklyReset = DQ.resetLabel(DQ.period('weekly', now, Config.Reset).finish, Config.Reset),
        }
    end,true)
end

local function deliverReserved(source,session,row,kind,automatic)
    local bonus=kind=='daily_bonus'
    local release=bonus and DQStore.releaseBonus or DQStore.release
    local finish=bonus and DQStore.finishBonus or DQStore.finish
    local claimKey=bonus and ('bonus:'..row.id) or row.id
    -- No reward may be issued after a DB yield without checking identity and expiry again.
    local invalidTime
    if automatic then invalidTime=row.period_kind~='daily' or os.time()<row.ends_at
    else invalidTime=os.time()>=row.ends_at end
    if not current(source, session) or invalidTime then
        release(row.id)
        return { ok = false, error = 'claim_unavailable' }
    end
    local coinAmount=tonumber(row.reward_coin_amount or 0)
    assert(DQ.integer(coinAmount,0,255),'Invalid saved coin count')
    if coinAmount>0 then
        assert(DQ.identifier(row.reward_coin),'Invalid saved coin item')
        if not exports.ox_inventory:Items(row.reward_coin) then
            release(row.id);return {ok=false,error='invalid_item'}
        end
        if not exports.ox_inventory:CanCarryItem(source,row.reward_coin,coinAmount) then
            release(row.id);return {ok=false,error='inventory_full'}
        end
        local expired=automatic and os.time()<row.ends_at or not automatic and os.time()>=row.ends_at
        if not current(source,session) or expired then
            release(row.id);return {ok=false,error='claim_unavailable'}
        end
    end
    log(('Claim %s reserved for %s / %s'):format(claimKey, session.citizenid, row.quest_id or kind))
    local ok, delivered = pcall(function()
        return exports.qbx_core:AddMoney(source, row.reward_type, row.reward_amount, 'dailyquest:' .. claimKey)
    end)
    if ok and delivered == false then
        -- The provider explicitly rejected the operation without delivering a reward.
        release(row.id)
        return { ok = false, error = 'reward_failed' }
    end
    if not ok or delivered ~= true then
        log(('Claim %s is PENDING: reward outcome unknown; do not automatically retry.'):format(claimKey))
        return { ok = false, error = 'pending', claimId = claimKey }
    end
    log(('Claim %s money delivered: %s %d.'):format(claimKey,row.reward_type,row.reward_amount))
    if coinAmount>0 then
        -- Money has already been delivered. Never release or retry the whole reward from here.
        if not current(source,session) then
            log(('Claim %s is PENDING: money delivered; character changed before coins.'):format(claimKey))
            return {ok=false,error='pending',claimId=claimKey}
        end
        local coinOk,coinDelivered=pcall(function()
            return exports.ox_inventory:AddItem(source,row.reward_coin,coinAmount)
        end)
        if not coinOk or coinDelivered~=true then
            log(('Claim %s is PENDING: money delivered; coin %s x%d result=%s.'):format(
                claimKey,row.reward_coin,coinAmount,coinOk and tostring(coinDelivered) or 'unknown'))
            return {ok=false,error='pending',claimId=claimKey}
        end
        log(('Claim %s coins delivered: %s x%d.'):format(claimKey,row.reward_coin,coinAmount))
    end
    log(('Claim %s reward provider returned success.'):format(claimKey))
    local saved, err = pcall(finish, row.id, os.time())
    if not saved then
        log(('Claim %s is PENDING after delivery: %s'):format(claimKey, tostring(err)))
        return { ok = false, error = 'pending', claimId = claimKey }
    end
    return { ok = true, coin=row.reward_coin, coinAmount=coinAmount }
end

settleDaily=function(source,session,now)
    local result=DQAuto.collect(source,session,now,current,deliverReserved)
    if not current(source,session) then return end
    if result.quests+result.bonuses>0 then
        local money={}
        if result.bank>0 then money[#money+1]=('銀行 $%d'):format(result.bank) end
        if result.cash>0 then money[#money+1]=('現金 $%d'):format(result.cash) end
        for name,amount in pairs(result.coins) do
            local item=exports.ox_inventory:Items(name)
            money[#money+1]=('%s × %d'):format(item and item.label or name,amount)
        end
        TriggerClientEvent('ox_lib:notify',source,{
            title='デイリー報酬の自動受取',type='success',
            description=('クエスト%d件・全クリア%d件の報酬を受け取りました。%s'):format(result.quests,result.bonuses,table.concat(money,' / ')),
        })
    end
    if result.pending>0 then
        TriggerClientEvent('ox_lib:notify',source,{
            title='デイリー報酬の確認待ち',type='warning',
            description='一部の報酬は成否の確認待ちになりました。重複配布を避けるため自動再配布はしません。',
        })
    end
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
        assert(row.reward_type == 'bank' or row.reward_type == 'cash', 'Invalid saved reward type')
        if not current(source, session) then return { ok = false, error = 'player_unavailable' } end
        if not DQStore.reserve(session.citizenid, row.id, os.time()) then
            return { ok = false, error = 'claim_unavailable' }
        end
        return deliverReserved(source,session,row,'quest')
    end)
end


lib.callback.register(prefix..'claimBonus',function(source,periodStart)
    if not rateLimit(source,'claimBonus') then return {ok=false,error='rate_limited'} end
    if not DQ.integer(periodStart,0,4102444800) then return {ok=false,error='invalid_request'} end
    return run(source,function(session,now)
        if DQ.period('daily',now,Config.Reset).start~=periodStart then return {ok=false,error='expired'} end
        local row=DQStore.bonusState(session.citizenid,periodStart)
        if not row then return {ok=false,error='incomplete'} end
        if row.status=='pending' then return {ok=false,error='pending',claimId='bonus:'..row.id} end
        if row.status=='claimed' then return {ok=false,error='claimed'} end
        if tonumber(row.assigned_count)~=tonumber(row.required_count)
            or tonumber(row.completed_count)~=tonumber(row.required_count) then return {ok=false,error='incomplete'} end
        assert(DQ.integer(tonumber(row.required_count),1,20),'Invalid saved bonus requirement')
        assert(DQ.integer(row.reward_amount,1,10000000),'Invalid saved bonus amount')
        assert(row.reward_type=='bank' or row.reward_type=='cash','Invalid saved bonus account')
        if not current(source,session) then return {ok=false,error='player_unavailable'} end
        if not DQStore.reserveBonus(session.citizenid,row.id,os.time()) then return {ok=false,error='claim_unavailable'} end
        return deliverReserved(source,session,row,'daily_bonus')
    end)
end)

lib.callback.register(prefix .. 'list', function(source)
    if not rateLimit(source, 'list') then return { ok = false, error = 'rate_limited' } end
    return snapshot(source)
end)

-- Every read and mutation checks authorization on the server, including direct callback calls.
lib.callback.register(prefix..'debug',function(source,action,id,enabled)
    if not DQDebug.allowed(source) then return {ok=false,error='forbidden'} end
    if not rateLimit(source,'debug') then return {ok=false,error='rate_limited'} end
    if action~='list' and action~='start' and action~='stop' and action~='reset' and action~='pool' then
        return {ok=false,error='invalid_request'}
    end
    if (action=='pool' or action=='reset' and id~=nil) and (type(id)~='string' or not definitions[id]) then
        return {ok=false,error='invalid_request'}
    end
    if action=='pool' and type(enabled)~='boolean' then return {ok=false,error='invalid_request'} end
    return run(source,function(session,now)
        local function valid() return current(source,session) and DQDebug.allowed(source) end
        if not valid() then return {ok=false,error='forbidden'} end
        DQDebug.flush(session,now)
        if not valid() then session.debug=nil;return {ok=false,error='forbidden'} end
        if action=='start' then
            if not DQDebug.start(session,valid) then return {ok=false,error='forbidden'} end
            DQDebug.flush(session,os.time())
        elseif action=='stop' then session.debug=nil
        elseif action=='reset' then DQDebug.reset(session,id)
        elseif action=='pool' then
            local ok,err=DQDebug.setPool(id,enabled)
            if not ok then return {ok=false,error=err} end
            log(('Quest pool %s = %s by %s'):format(id,tostring(enabled),session.citizenid))
        end
        if not valid() then session.debug=nil;return {ok=false,error='forbidden'} end
        local result=DQDebug.snapshot(session)
        if not valid() then session.debug=nil;return {ok=false,error='forbidden'} end
        return result
    end,true,true)
end)

lib.callback.register(prefix .. 'claim', function(source, questId, periodStart)
    if not rateLimit(source, 'claim') then return { ok = false, error = 'rate_limited' } end
    return claim(source, questId, periodStart)
end)


lib.callback.register(prefix..'preferences',function(source,exclusions)
    if not rateLimit(source,'preferences') then return {ok=false,error='rate_limited'} end
    local prefs=DQSelection.preferences(exclusions)
    if not prefs then return {ok=false,error='invalid_request'} end
    return run(source,function(session,now)
        DQStore.savePreferences(session.citizenid,prefs,now)
        session.preferences,session.day=prefs,nil
        return {ok=true}
    end,true,true)
end)

lib.callback.register(prefix..'reroll',function(source,questId,periodStart)
    if not rateLimit(source,'reroll') then return {ok=false,error='rate_limited'} end
    local quest=type(questId)=='string' and definitions[questId]
    if not quest or not DQ.integer(periodStart,0,4102444800) then return {ok=false,error='invalid_request'} end
    return run(source,function(session,now)
        if DQ.period(quest.period,now,Config.Reset).start~=periodStart then return {ok=false,error='expired'} end
        flushTime(session,now)
        if not current(source,session) then return {ok=false,error='player_unavailable'} end
        local data=exports.qbx_core:GetPlayer(source).PlayerData
        local ok,result=DQStore.reroll(session.citizenid,quest,session.preferences,data,GetResourceState,os.time(),definitions)
        if not ok then return {ok=false,error=result} end
        reloadAssignments(session,os.time())
        if session.tracking then
            for key,entry in pairs(session.tracking.pending) do
                if entry.quest.id==quest.id or entry.quest.id==result then session.tracking.pending[key]=nil end
            end
        end
        return {ok=true}
    end)
end)

-- Local server event ONLY. Never RegisterNetEvent this event or trust client completion reports.
AddEventHandler('ox_inventory:usedItem', function(sourceId, itemName)
    if not Config.Consumables[itemName] or GetInvokingResource() ~= 'ox_inventory' then return end
    local now = GetGameTimer()
    local previous = consumption[sourceId]
    if previous and now >= previous and now - previous < Config.ConsumeCooldownSeconds * 1000 then return end
    consumption[sourceId] = now
    run(sourceId, function(session, timestamp)
        DQStore.consume(session.citizenid, timestamp, DQDebug.active(sourceId,session))
    end,sessions[sourceId] and DQDebug.active(sourceId,sessions[sourceId]))
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

-- Console only: no player ACE, network event or public endpoint exposes other characters.
RegisterCommand('dailyquest_pending', function(source)
    if source ~= 0 then return end
    if not ready then log('Database is not ready.'); return end
    local ok, rows = pcall(DQStore.pending)
    if not ok then log('Could not read pending claims.'); return end
    log('Pending claims (up to 50): ' .. json.encode(rows))
end, true)

MySQL.ready(function()
    CreateThread(function()
        while not ready do
            local ok, err = pcall(DQStore.init)
            ready = ok
            if not ok then log('Database initialization failed; retrying in 30s: ' .. tostring(err)); Wait(30000) end
        end
        log('Ready. Command: /' .. Config.Command)
    end)
end)

CreateThread(function()
    while true do
        Wait(Config.TickSeconds * 1000)
        if ready then
            for _, id in ipairs(GetPlayers()) do
                local sourceId = tonumber(id)
                run(sourceId, function(session, now)
                    flushTime(session,now)
                end,sessions[sourceId] and DQDebug.active(sourceId,sessions[sourceId]))
            end
        end
    end
end)

CreateThread(function()
    while true do
        Wait(Config.Tracking.sampleSeconds * 1000)
        if ready then
            for sourceId, session in pairs(sessions) do
                if current(sourceId, session) then
                    local player = exports.qbx_core:GetPlayer(sourceId)
                    if player and player.PlayerData.citizenid == session.citizenid then
                        local ok, frame = pcall(DQTracking.frame, sourceId, player.PlayerData)
                        if ok then
                            DQTracking.sample(session, frame)
                            if not locks[session.citizenid] and DQDebug.active(sourceId,session) then DQDebug.sample(session,frame) end
                        else session.tracking = nil; log('Tracking sample failed: ' .. tostring(frame)) end
                    else session.tracking = nil end
                end
            end
        else
            for _, session in pairs(sessions) do session.tracking = nil end
        end
    end
end)
