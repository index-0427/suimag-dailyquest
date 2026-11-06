-- Export the actual store queries and transaction plans for the isolated DB test.
dofile('config.lua')
dofile('server/domain.lua')
dofile('server/store.lua')
dofile('server/selection.lua')
dofile('server/boards.lua')
dofile('server/bonuses.lua')
dofile('server/settlement.lua')
-- Test-only insertion helper for unassigned and pre-existing fixture rows.
local fixtureSql={ensure=[[INSERT INTO suimag_dailyquest_progress
    (citizenid, quest_id, period_kind, period_start, ends_at, target, reward_type, reward_amount)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE id=id]]}
local plans, selected = {}, nil
MySQL={transaction={await=function(queries) plans[selected]=plans[selected] or {};for _,q in ipairs(queries) do plans[selected][#plans[selected]+1]=q end;return true end}}
local function plan(name,fn) selected=name;fn() end

-- Collector fixtures intentionally assign the complete catalog to isolate each metric.
-- Production 3/2 selection and reroll quotas are tested separately below.
local realOpen=DQStore.open
DQStore.open=function(cid,now)
    local queries,assignments={},{}
    for _,kind in ipairs({'daily','weekly'}) do
        local period=DQ.period(kind,now,Config.Reset)
        local nonce='fixture-'..cid..'-'..kind..'-'..period.start
        queries[#queries+1]={query=DQStore.sql.makeBoard,values={cid,kind,period.start,period.finish,nonce}}
        local slot=0
        for _,quest in ipairs(Config.Quests) do
            if quest.period==kind then
                slot=slot+1
                queries[#queries+1]={query=DQStore.sql.assign,values={quest.id,slot,period.start,nonce,cid,kind,period.start,nonce}}
                local coin,coinAmount=DQ.coins(quest)
                queries[#queries+1]={query=DQStore.sql.ensureAssigned,values={
                    cid,quest.id,kind,period.start,period.finish,quest.target,DQ.reward(quest.period).type,DQ.reward(quest.period).amount,coin,coinAmount,
                    cid,kind,period.start,nonce}}
                assignments[quest.id]={period_start=period.start,assigned_at=period.start}
            end
        end
        queries[#queries+1]={query=DQStore.sql.clearBoardToken,values={cid,kind,period.start,nonce}}
    end
    MySQL.transaction.await(queries)
    realOpen(cid,now,assignments)
end

local now=1793736100
plan('open',function() DQStore.open('SQLTEST',now) end)
plan('next_day',function() DQStore.open('SQLTEST',now+86400) end)
plan('next_week',function() DQStore.open('SQLTEST',now+604800) end)
plan('consume',function() DQStore.consume('SQLTEST',now) end)
plan('time',function() DQStore.addTime('SQLTEST',1793822393,1793822408) end)

DQStore.bootId='test-boot'
plan('gate_open',function() DQStore.open('GATES',now) end)
for activity in pairs(Config.Activities) do
    if Config.Activities[activity].signal then
        plan('signal_'..activity,function() DQStore.signal('GATES',activity,now) end)
    end
end
plan('signal_duplicate',function() DQStore.signal('GATES','bus',now+1) end)
DQStore.bootId='new-boot'
plan('signal_restarted',function() DQStore.signal('GATES','bus',now+2) end)
plan('signal_later',function() DQStore.signal('GATES','bus',now+30) end)
plan('signal_rollback',function() DQStore.signal('GATES','garbage',now+30) end)
local boundary=DQ.period('daily',now,Config.Reset).finish
plan('signal_before_reset',function() DQStore.signal('GATES','bus',boundary-5) end)
plan('gate_next_day',function() DQStore.open('GATES',boundary+5) end)
plan('signal_after_reset',function() DQStore.signal('GATES','bus',boundary+5) end)
plan('signal_after_cooldown',function() DQStore.signal('GATES','bus',boundary+30) end)
dofile('server/tracking.lua')
local tracked={trackingAssignments={}}
for _,quest in ipairs(Config.Quests) do
    for _,at in ipairs({boundary-2,boundary+3}) do
        local start=DQ.period(quest.period,at,Config.Reset).start
        tracked.trackingAssignments[quest.id..':'..start]={period_start=start,assigned_at=start}
    end
end
DQTracking.sample(tracked,{ped=1,vehicle=0,bucket=0,x=0,y=0,z=30,mode='walk',alive=true,duty=true,job='police',wall=boundary-2,timer=1000})
DQTracking.sample(tracked,{ped=1,vehicle=0,bucket=0,x=25,y=0,z=30,mode='walk',alive=true,duty=true,job='police',wall=boundary+3,timer=6000})
plan('tracked',function() DQStore.tracked('SQLTEST',DQTracking.drain(tracked)) end)

-- Generate production board transactions with the actual selector and store methods.
local function clone(value)
    if type(value)~='table' then return value end
    local out={};for k,v in pairs(value) do out[k]=clone(v) end;return out
end
local fakeBoards,fakeAssignments={},{}
DQStore.boards=function() return clone(fakeBoards) end
DQStore.assignments=function() return clone(fakeAssignments) end
MySQL.query={await=function() return {} end}
MySQL.update={await=function(sql,values)
    plans[selected]=plans[selected] or {};plans[selected][#plans[selected]+1]={query=sql,values=values};return 1
end}
local capture=MySQL.transaction.await
MySQL.transaction.await=function(queries)
    capture(queries)
    for _,entry in ipairs(queries) do
        local v=entry.values
        if entry.query==DQStore.sql.makeBoard then
            fakeBoards[v[2]]={citizenid=v[1],period_kind=v[2],period_start=v[3],ends_at=v[4],rerolls_used=0}
        elseif entry.query==DQStore.sql.assign then
            fakeAssignments[#fakeAssignments+1]={
                quest_id=v[1],slot=v[2],assigned_at=v[3],assigned_token=v[4],
                citizenid=v[5],period_kind=v[6],period_start=v[7],active=1,
            }
        elseif entry.query==DQStore.sql.takeReroll then fakeBoards[v[3]].rerolls_used=1
        elseif entry.query==DQStore.sql.retire then
            for _,a in ipairs(fakeAssignments) do if a.quest_id==v[4] then a.active=0 end end
        end
    end
    return true
end
math.random=function(n) return math.min(2,n) end
local prefs={crime=true,employment=true}
local data={job={name='unemployed',grade={level=0}}}
local state=function() return 'started' end
local defs=DQ.validate(Config)
plan('board_prefs',function() DQStore.savePreferences('DRAW',prefs,now) end)
plan('board_draw',function() assert(DQStore.ensureBoards('DRAW',prefs,data,state,now)) end)
local selectedDaily,selectedWeekly
for _,a in ipairs(fakeAssignments) do
    if a.period_kind=='daily' and a.slot==1 then selectedDaily=a.quest_id end
    if a.period_kind=='weekly' and a.slot==1 then selectedWeekly=a.quest_id end
end
plans.board_draw_again={}
plan('board_draw_again',function() assert(DQStore.ensureBoards('DRAW',prefs,data,state,now)) end)
plan('board_prefs_change',function() DQStore.savePreferences('DRAW',{crime=false,employment=false},now+1) end)
DQStore.row=function(cid,id,start)
    return {status='active',progress=0,target=defs[id].target}
end
local replacementDaily,replacementWeekly
plan('board_reroll_daily',function()
    local ok,id=DQStore.reroll('DRAW',defs[selectedDaily],prefs,data,state,now+10,defs)
    assert(ok,id);replacementDaily=id
end)
plan('board_reroll_weekly',function()
    local ok,id=DQStore.reroll('DRAW',defs[selectedWeekly],prefs,data,state,now+10,defs)
    assert(ok,id);replacementWeekly=id
end)

-- New periods get a new board and allowance; the other period's board stays untouched.
fakeBoards.daily=nil
plan('board_next_day',function() assert(DQStore.ensureBoards('DRAW',prefs,data,state,now+86400)) end)
fakeBoards={}
plan('board_next_week',function() assert(DQStore.ensureBoards('DRAW',prefs,data,state,now+604800)) end)
plan('board_open_rewards',function()
    local assignments={}
    realOpen('DRAW',now,assignments)
end)
plan('board_open_rewards_next_day',function() realOpen('DRAW',now+86400,{}) end)
local boardMeta={daily=selectedDaily,weekly=selectedWeekly,dailyReplacement=replacementDaily,weeklyReplacement=replacementWeekly}
local function encode(v)
    if type(v)=='number' then return tostring(v) end
    if type(v)=='string' then
        return '"'..v:gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n'):gsub('\r','\\r'):gsub('\t','\\t')..'"'
    end
    if type(v)=='table' then
        local values={}
        if #v>0 then
            for _,item in ipairs(v) do values[#values+1]=encode(item) end
            return '['..table.concat(values,',')..']'
        end
        for k,item in pairs(v) do values[#values+1]=encode(k)..':'..encode(item) end
        return '{'..table.concat(values,',')..'}'
    end
    error('unsupported type')
end
io.write(encode({sql=DQStore.sql,fixtures=fixtureSql,plans=plans,boardMeta=boardMeta}))
