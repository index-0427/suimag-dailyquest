dofile('config.lua')
dofile('server/domain.lua')
local count, callbacks, handlers, commands, exposed, threads = 0, {}, {}, {}, {}, {}
local now, timer, invoking = 1793736100, 1000, nil
local players, records, visits, receipts, resourceStates = {}, {}, {}, {}, {}
local hooks, payments, notifications, initFailures = {}, {}, {}, 0
local function eq(a, b, message)
    count = count + 1
    assert(a == b, (message or 'mismatch') .. ': ' .. tostring(a) .. ' ~= ' .. tostring(b))
end
local function copy(value)
    if type(value) ~= 'table' then return value end
    local result = {}; for k,v in pairs(value) do result[k] = copy(v) end; return result
end
local function hook(name, ...)
    local fn = hooks[name]
    if fn then return fn(...) end
end
local function advance(seconds) now = now + seconds; timer = timer + seconds * 1000 end
local function key(cid, id, start) return cid .. ':' .. id .. ':' .. start end
local nextId = 0
local function open(cid, timestamp)
    visits[cid] = visits[cid] or {}
    visits[cid][DQ.period('daily', timestamp, Config.Reset).start] = true
    for _, q in ipairs(Config.Quests) do
        local period = DQ.period(q.period, timestamp, Config.Reset)
        local k = key(cid, q.id, period.start)
        if not records[k] then
            nextId = nextId + 1
            records[k] = {
                id=nextId, citizenid=cid, quest_id=q.id, period_kind=q.period,
                period_start=period.start, ends_at=period.finish, target=q.target, progress=0,
                reward_type=q.reward.type, reward_name=q.reward.name or '', reward_amount=q.reward.amount,
                status='active',
            }
        end
        local r = records[k]
        if q.metric == 'attendance' and r.status == 'active' then
            local days=0
            for day in pairs(visits[cid]) do if day >= period.start and day < period.finish then days=days+1 end end
            r.progress=math.min(r.target,days)
        end
    end
    hook('open')
end
local function byId(id)
    for _, r in pairs(records) do if r.id == id then return r end end
end
local function add(cid, metric, amount, timestamp)
    for _,q in ipairs(Config.Quests) do
        if q.metric == metric then
            local r = records[key(cid, q.id, DQ.period(q.period, timestamp, Config.Reset).start)]
            if r and r.status == 'active' then r.progress = math.min(r.target, r.progress+amount) end
        end
    end
end
DQStore = {
    init = function() if initFailures > 0 then initFailures=initFailures-1; error('init unavailable') end end,
    open = open,
    list = function(cid, timestamp)
        local result={}
        for _,r in pairs(records) do
            if r.citizenid == cid and r.period_start <= timestamp and r.ends_at > timestamp then local clone=copy(r); clone.period_start=clone.period_start+0.0; result[#result+1]=clone end
        end
        hook('list')
        return result
    end,
    row = function(cid,id,start)
        local result=copy(records[key(cid,id,start)])
        hook('row')
        return result
    end,
    reserve = function(cid,id,timestamp)
        local r=byId(id)
        if r.citizenid ~= cid or r.status ~= 'active' or r.progress < r.target or r.ends_at <= timestamp then return false end
        r.status='pending';r.attempted_at=timestamp
        hook('reserve')
        return true
    end,
    release = function(id) hook('release'); byId(id).status='active' end,
    finish = function(id,timestamp) hook('finish');byId(id).status='claimed';byId(id).claimed_at=timestamp end,
    consume = function(cid,timestamp) hook('consume');add(cid,'consume',1,timestamp) end,
    addTime = function(cid,from,to)
        for _,q in ipairs(Config.Quests) do
            if q.metric=='playtime' then
                for _,seg in ipairs(DQ.segments(q.period,from,to,Config.Reset)) do
                    local r=records[key(cid,q.id,seg.period.start)]
                    if r and r.status=='active' then r.progress=math.min(r.target,r.progress+seg.amount) end
                end
            end
        end
    end,
    activity = function(cid,activity,receipt,amount,timestamp)
        local k=key(cid,activity,receipt)
        if receipts[k] then return end
        receipts[k]=true
        for _,q in ipairs(Config.Quests) do
            if q.metric=='activity' and q.activity==activity then
                local r=records[key(cid,q.id,DQ.period(q.period,timestamp,Config.Reset).start)]
                r.progress=math.min(r.target,r.progress+amount)
            end
        end
    end,
    pending = function() local result={};for _,r in pairs(records) do if r.status=='pending' then result[#result+1]=copy(r) end end;return result end,
}
GetCurrentResourceName = function() return 'suimag-dailyquest' end
GetResourceState = function(name) return resourceStates[name] or 'started-dependency' end
GetGameTimer = function() return timer end
GetInvokingResource = function() return invoking end
GetPlayers = function() local result={};for id in pairs(players) do result[#result+1]=tostring(id) end;return result end
os.time = function() return now end
Wait = function(ms) coroutine.yield(ms) end
CreateThread = function(fn) threads[#threads+1]=coroutine.create(fn) end
AddEventHandler = function(name,fn) handlers[name]=fn end
RegisterNetEvent = function() error('Server progress must not use RegisterNetEvent') end
RegisterCommand = function(name,fn) commands[name]=fn end
lib={callback={register=function(name,fn) callbacks[name]=fn end}}
MySQL={ready=function(fn) fn() end}
json={encode=function() return '[]' end}
exports = setmetatable({
    qbx_core = {
        GetPlayer=function(_,id) return copy(players[id]) end,
        AddMoney=function(_,id,kind,amount,reason)
            local result=hook('grant', id)
            if result == false then return false end
            payments[#payments+1]={id=id,cid=players[id].PlayerData.citizenid,amount=amount,kind=kind,reason=reason}
            hook('afterGrant')
            return true
        end,
    },
    ox_inventory = {
        Items=function(_,name) if name=='water' or name=='burger' then return {label=name} end end,
        CanCarryItem=function() return hooks.full ~= true end,
        AddItem=function(_,id,name,amount)
            if hooks.itemReject then return false end
            payments[#payments+1]={id=id,item=name,amount=amount};hook('afterGrant');return true
        end,
    },
},{__call=function(_,name,fn) exposed[name]=fn end})
local logs={}
print=function(message) logs[#logs+1]=message end
Config.Activities.delivery={resources={['delivery-job']=true},maxAmount=1}
Config.Quests[#Config.Quests+1]={
    id='delivery',period='daily',metric='activity',activity='delivery',target=3,
    title='delivery',description='delivery',reward={type='item',name='water',amount=2},
}
initFailures=1
dofile('server/main.lua')
local function resume(co)
    local ok,result=coroutine.resume(co);assert(ok,result);return result
end
eq(callbacks['suimag-dailyquest:list'](1).error, 'not_ready')
eq(resume(threads[1]),30000,'init failure retries')
resume(threads[1])
eq(coroutine.status(threads[1]),'dead')
eq(resume(threads[2]),15000)
local function player(id,cid)
    players[id]={PlayerData={citizenid=cid,source=id}}
    local previous=invoking;invoking='qbx_core'
    handlers['QBCore:Server:PlayerLoaded'](copy(players[id]))
    invoking=previous
end
local function list(id)
    advance(2)
    return callbacks['suimag-dailyquest:list'](id or 1)
end
local function row(cid,id,offset)
    local q
    for _,v in ipairs(Config.Quests) do if v.id==id then q=v end end
    return records[key(cid,id,DQ.period(q.period,now+(offset or 0),Config.Reset).start)]
end
local function claim(id,quest,start)
    advance(2)
    local q
    for _,v in ipairs(Config.Quests) do if v.id==quest then q=v end end
    return callbacks['suimag-dailyquest:claim'](id,quest,start or DQ.period(q.period,now,Config.Reset).start)
end
player(1,'ALPHA')
local view=list()
eq(view.ok,true);eq(#view.quests,7)
eq(row('ALPHA','daily_visit').progress,1)
eq(row('ALPHA','weekly_visits').progress,1)
eq(callbacks['suimag-dailyquest:list'](1).error,'rate_limited')
list()
eq(row('ALPHA','weekly_visits').progress,1,'same day does not count twice')
eq(claim(1,'daily_time').error,'incomplete')
eq(claim(1,'daily_visit').ok,true)
eq(#payments,1);eq(payments[1].cid,'ALPHA');eq(payments[1].amount,1000)
eq(claim(1,'daily_visit').error,'claimed');eq(#payments,1)
advance(2)
eq(callbacks['suimag-dailyquest:claim'](1,{},0).error,'invalid_request')
advance(2)
eq(callbacks['suimag-dailyquest:claim'](1,'daily_time',0/0).error,'invalid_request')
eq(claim(1,'daily_time',now-86400).error,'expired')
-- Persisted reward and target do not change within an existing period.
Config.Quests[1].reward.amount=999999
player(2,'BETA');list(2)
eq(row('BETA','daily_visit').reward_amount,999999)
eq(row('ALPHA','daily_visit').reward_amount,1000)
Config.Quests[1].reward.amount=1000
-- Item-use events are local, scoped to Ox, allowlisted and rate limited.
invoking='evil';handlers['ox_inventory:usedItem'](1,'water')
eq(row('ALPHA','daily_meals').progress,0)
invoking='ox_inventory';handlers['ox_inventory:usedItem'](1,'unknown')
eq(row('ALPHA','daily_meals').progress,0)
handlers['ox_inventory:usedItem'](1,'water');handlers['ox_inventory:usedItem'](1,'water')
eq(row('ALPHA','daily_meals').progress,1)
advance(3);handlers['ox_inventory:usedItem'](1,'burger')
eq(row('ALPHA','daily_meals').progress,2)
-- First item use before menu/timer must still have a cooldown.
player(3,'FIRSTITEM');handlers['ox_inventory:usedItem'](3,'water');handlers['ox_inventory:usedItem'](3,'water')
eq(row('FIRSTITEM','daily_meals').progress,1)
-- Export permissions, bounds and durable receipt deduplication.
invoking='evil';eq(exposed.RecordActivity(1,'delivery',1,'ride-1'),false)
invoking='delivery-job';eq(exposed.RecordActivity(1,'delivery',-1,'ride-1'),false)
eq(exposed.RecordActivity(1,'delivery',1,'bad receipt'),false)
eq(exposed.RecordActivity(1,'delivery',2,'ride-1'),false)
eq(exposed.RecordActivity(1,'delivery',1,'ride-1'),true)
eq(exposed.RecordActivity(1,'delivery',1,'ride-1'),true)
eq(row('ALPHA','delivery').progress,1)
eq(exposed.RecordActivity(1,'delivery',1,'ride-2'),true)
eq(exposed.RecordActivity(1,'delivery',1,'ride-3'),true)
hooks.full=true;eq(claim(1,'delivery').error,'inventory_full')
eq(row('ALPHA','delivery').status,'active')
hooks.full=nil;hooks.itemReject=true;eq(claim(1,'delivery').error,'reward_failed')
eq(row('ALPHA','delivery').status,'active')
hooks.itemReject=nil;eq(claim(1,'delivery').ok,true)
eq(payments[#payments].item,'water')
-- Explicit provider failure is retryable; exceptions after delivery are quarantined.
hooks.grant=function() return false end
eq(claim(2,'daily_visit').error,'reward_failed');eq(row('BETA','daily_visit').status,'active')
hooks.grant=nil;hooks.afterGrant=function() error('uncertain reward result') end
local before=#payments
eq(claim(2,'daily_visit').error,'pending');eq(#payments,before+1)
hooks.afterGrant=nil
eq(claim(2,'daily_visit').error,'pending');eq(#payments,before+1)
-- A DB failure after successful delivery must never grant again.
hooks.finish=function() error('database disconnected') end
eq(claim(3,'daily_visit').error,'pending')
before=#payments;hooks.finish=nil
eq(claim(3,'daily_visit').error,'pending');eq(#payments,before)
-- Disconnect / switch during a DB yield releases reservation without paying the new character.
player(4,'OLD');list(4)
hooks.reserve=function() player(4,'NEW') end
before=#payments
eq(claim(4,'daily_visit').error,'claim_unavailable');eq(#payments,before)
eq(row('OLD','daily_visit').status,'active');hooks.reserve=nil
list(4);eq(row('NEW','daily_visit').progress,1)
-- Unload event ignores network/local impostors and blocks Qbox's 200ms logout window.
invoking='evil';handlers['QBCore:Server:OnPlayerUnload'](4);eq(list(4).ok,true)
invoking='qbx_core';handlers['QBCore:Server:OnPlayerUnload'](4)
eq(list(4).error,'player_unavailable')
invoking=nil;handlers['QBCore:Server:PlayerLoaded'](copy(players[4]))
eq(list(4).error,'player_unavailable','untrusted load cannot unblock a logged-out character')
player(4,'NEW');eq(list(4).ok,true)
-- Identity change after SELECT does not return the old character's list.
hooks.list=function() player(4,'OTHER') end
eq(list(4).error,'player_unavailable');hooks.list=nil
-- Expiry while the reservation awaits DB: no payout.
player(5,'EXPIRY');list(5)
local endTime=row('EXPIRY','daily_visit').ends_at
hooks.reserve=function() timer=timer+(endTime-now)*1000;now=endTime end
before=#payments
eq(claim(5,'daily_visit').error,'claim_unavailable');eq(#payments,before);hooks.reserve=nil
list(5);eq(row('EXPIRY','daily_visit').progress,1)
eq(row('EXPIRY','weekly_visits').progress,2,'continuous connection counts a new day')
-- Actual overlap: second claim waits for first; only one reward is issued.
player(6,'RACE');list(6)
hooks.reserve=function() coroutine.yield('database-wait') end
local result1,result2
local first=coroutine.create(function() result1=claim(6,'daily_visit') end)
eq(resume(first),'database-wait')
local second=coroutine.create(function() result2=claim(6,'daily_visit') end)
eq(resume(second),25)
before=#payments
hooks.reserve=nil;resume(first);resume(second)
eq(result1.ok,true);eq(result2.error,'claimed');eq(#payments,before+1)
-- Timer accounts online time only; restart/reconnect gaps are not credited.
players={};player(7,'CLOCK');list(7)
advance(15);resume(threads[2])
eq(row('CLOCK','daily_time').progress,15)
advance(300);resume(threads[2])
eq(row('CLOCK','daily_time').progress,15,'stall discarded')
-- Split a normal 15-second tick at the daily boundary.
now=DQ.period('daily',now,Config.Reset).finish-7
timer=timer+1000000
resume(threads[2]) -- discard jump, establish baseline
local oldStart=DQ.period('daily',now,Config.Reset).start
advance(15);resume(threads[2])
eq(records[key('CLOCK','daily_time',oldStart)].progress,22)
eq(row('CLOCK','daily_time').progress,8)
eq(row('CLOCK','weekly_time').progress,30)
-- Conflicts suspend progress and claims; stopping them resumes without restart.
resourceStates.sky_battlepass='started'
eq(list(7).error,'conflict')
before=#payments;eq(claim(7,'daily_visit').error,'conflict');eq(#payments,before)
resourceStates.sky_battlepass='stopped'
eq(list(7).ok,true)
-- Console diagnostics are not accessible to players.
local logCount=#logs;commands.dailyquest_pending(7);eq(#logs,logCount)
commands.dailyquest_pending(0);eq(#logs,logCount+1)
_G.source=7;handlers.playerDropped()
players[7]=nil
eq(list(7).error,'player_unavailable')
io.write(('server: %d assertions passed\n'):format(count))
