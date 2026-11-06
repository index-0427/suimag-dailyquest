-- Admin-job or ACE-authorized diagnostics. Never creates assignments, rewards or client progress events.
DQDebug = {}
local D, S = DQDebug, DQStore
local poolBusy = false
S.sql.debugEnsure = [[INSERT INTO suimag_dailyquest_debug_progress (citizenid,quest_id,target)
    VALUES (?,?,?) ON DUPLICATE KEY UPDATE target=VALUES(target), progress=LEAST(progress,VALUES(target))]]
S.sql.debugList = [[SELECT quest_id,target,progress,updated_at FROM suimag_dailyquest_debug_progress WHERE citizenid=?]]
S.sql.debugAdvance = [[UPDATE suimag_dailyquest_debug_progress SET updated_at=IF(progress<target,?,updated_at),
    progress=LEAST(target,progress+?) WHERE citizenid=? AND quest_id=?]]
S.sql.debugAttendance = [[UPDATE suimag_dailyquest_debug_progress SET updated_at=IF(progress<target,?,updated_at),
    progress=LEAST(target,progress+1),last_day=? WHERE citizenid=? AND quest_id=? AND (last_day IS NULL OR last_day<>?)]]
S.sql.debugReset = [[UPDATE suimag_dailyquest_debug_progress SET progress=0,last_day=NULL,updated_at=NULL WHERE citizenid=? AND quest_id=?]]
S.sql.debugResetAll = [[UPDATE suimag_dailyquest_debug_progress SET progress=0,last_day=NULL,updated_at=NULL WHERE citizenid=?]]
S.sql.debugSignal = S.sql.debugAdvance .. [[ AND EXISTS (SELECT 1 FROM suimag_dailyquest_signal_gates
    WHERE citizenid=? AND activity=? AND token=?)]]
S.sql.poolList = [[SELECT quest_id,enabled FROM suimag_dailyquest_pool]]
S.sql.poolSave = [[INSERT INTO suimag_dailyquest_pool (quest_id,enabled) VALUES (?,?) ON DUPLICATE KEY UPDATE enabled=VALUES(enabled)]]
local function q(name,values) return {query=S.sql[name],values=values} end
local function transact(queries)
    if #queries>0 then assert(MySQL.transaction.await(queries),'Debug transaction failed') end
end
function D.allowed(source)
    local sourceId=tonumber(source)
    if not DQ.integer(sourceId,1) then return false end
    if IsPlayerAceAllowed(tostring(sourceId),Config.DebugAce)==true then return true end
    local player=exports.qbx_core:GetPlayer(sourceId)
    local job=player and player.PlayerData.job
    return job~=nil and job.name=='admin'
end
function D.active(source,session)
    if session.debug and not D.allowed(source) then session.debug=nil end
    return session.debug~=nil
end
function D.init()
    MySQL.query.await('SELECT citizenid,quest_id,target,progress,last_day,updated_at FROM suimag_dailyquest_debug_progress LIMIT 0')
    local disabled={}
    for _,row in ipairs(MySQL.query.await(S.sql.poolList)) do
        if tonumber(row.enabled)==0 then disabled[row.quest_id]=true end
    end
    DQSelection.disabled=disabled
end
function D.setPool(id,enabled)
    if poolBusy then return false,'busy' end
    poolBusy=true
    local ok,err=pcall(function()
        MySQL.update.await(S.sql.poolSave,{id,enabled and 1 or 0})
        DQSelection.disabled[id]=not enabled or nil
    end)
    poolBusy=false
    if not ok then error(err) end
    return true
end
function D.start(session,valid)
    if session.debug then return true end
    local queries={}
    for _,quest in ipairs(Config.Quests) do queries[#queries+1]=q('debugEnsure',{session.citizenid,quest.id,quest.target}) end
    transact(queries)
    if not valid() then return false end
    session.debug={wall=os.time(),timer=GetGameTimer(),since=os.time(),trackingAssignments={}}
    return true
end
function D.sample(session,frame)
    local state=session.debug
    if not state then return end
    if frame then
        state.trackingAssignments={}
        for _,quest in ipairs(Config.Quests) do
            if quest.metric=='distance' or quest.metric=='duty' then
                for _,segment in ipairs(DQ.segments(quest.period,frame.wall-Config.Tracking.sampleSeconds*2,frame.wall,Config.Reset)) do
                    state.trackingAssignments[quest.id..':'..segment.period.start]={period_start=segment.period.start,assigned_at=state.since}
                end
            end
        end
    end
    -- Use exactly the same movement, duty, timing and teleport rejection rules.
    DQTracking.sample(state,frame)
end
function D.flush(session,now)
    local state=session.debug
    if not state then return end
    local seconds=DQ.elapsed(state,now,GetGameTimer(),Config.TickSeconds*2)
    state.wall,state.timer=now,GetGameTimer()
    local queries,day={},DQ.period('daily',now,Config.Reset).start
    for _,quest in ipairs(Config.Quests) do
        if quest.metric=='attendance' then
            queries[#queries+1]=q('debugAttendance',{now,day,session.citizenid,quest.id,day})
        elseif quest.metric=='playtime' and seconds and seconds>0 then
            queries[#queries+1]=q('debugAdvance',{now,seconds,session.citizenid,quest.id})
        end
    end
    for _,entry in ipairs(DQTracking.drain(state)) do
        queries[#queries+1]=q('debugAdvance',{now,entry.amount,session.citizenid,entry.quest.id})
    end
    transact(queries)
end
function D.eventQueries(queries,cid,metric,activity,now,token)
    for _,quest in ipairs(Config.Quests) do
        if quest.metric==metric and (metric~='activity' or quest.activity==activity) then
            local values={now,1,cid,quest.id}
            if token then values[5],values[6],values[7]=cid,activity,token end
            queries[#queries+1]=q(token and 'debugSignal' or 'debugAdvance',values)
        end
    end
end
function D.reset(session,id)
    -- Call after flushing and under the character lock. Sampling also respects that lock.
    MySQL.update.await(id and S.sql.debugReset or S.sql.debugResetAll,id and {session.citizenid,id} or {session.citizenid})
    local state=session.debug
    if state and state.tracking then
        for key,entry in pairs(state.tracking.pending) do
            if not id or entry.quest.id==id then state.tracking.pending[key]=nil end
        end
        state.tracking.last=nil
    end
end
function D.snapshot(session)
    local rows={}
    for _,row in ipairs(MySQL.query.await(S.sql.debugList,{session.citizenid})) do rows[row.quest_id]=row end
    local quests={}
    for _,quest in ipairs(Config.Quests) do
        local row=rows[quest.id]
        quests[#quests+1]={
            id=quest.id,period=quest.period,title=quest.title,description=quest.description,
            metric=quest.metric,activity=quest.activity,mode=quest.mode,
            target=row and tonumber(row.target) or quest.target,value=row and tonumber(row.progress) or 0,
            updatedAt=row and tonumber(row.updated_at) or nil,
            enabled=not DQSelection.disabled[quest.id],
            available=quest.metric~='activity' or GetResourceState(Config.Activities[quest.activity].resource)=='started',
            source=quest.metric=='activity' and Config.Activities[quest.activity].resource or nil,
            unit=(quest.metric=='playtime' or quest.metric=='duty') and '秒' or quest.metric=='distance' and 'm' or (quest.unit or '回'),
        }
    end
    return {ok=true,enabled=session.debug~=nil,quests=quests}
end
