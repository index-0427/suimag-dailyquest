dofile('config.lua')
dofile('server/domain.lua')
dofile('server/tracking.lua')
dofile('server/selection.lua')
local count, callbacks, handlers, commands, threads = 0, {}, {}, {}, {}
local now, timer, invoking = 1793736100, 1000, nil
local players, records, visits, resourceStates = {}, {}, {}, {}
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
            local coin,coinAmount=DQ.coins(q)
            records[k] = {
                id=nextId, citizenid=cid, quest_id=q.id, period_kind=q.period,
                period_start=period.start, ends_at=period.finish, target=q.target, progress=0,
                reward_type=DQ.reward(q.period).type, reward_amount=DQ.reward(q.period).amount,
                reward_coin=coin,reward_coin_amount=coinAmount,
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
    expiredDaily = function() return {} end,
    bonusState = function() return nil end,
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
    pending = function() local result={};for _,r in pairs(records) do if r.status=='pending' then result[#result+1]=copy(r) end end;return result end,
}

-- Full-catalog assignment fixture keeps the historical reward/lifecycle regression tests focused.
-- The production random planner and SQL quotas are exercised in selection_spec/sql_spec.
local preferences={}
DQStore.preferences=function(cid)
    if preferences[cid]==false then return nil end
    return preferences[cid] or {crime=false,employment=false}
end
DQStore.savePreferences=function(cid,value) preferences[cid]=copy(value) end
DQStore.ensureBoards=function(cid,prefs,data,state,timestamp) open(cid,timestamp);return true end
DQStore.boardState=function(cid,timestamp)
    local boards,assignments={},{}
    for _,kind in ipairs({'daily','weekly'}) do
        local p=DQ.period(kind,timestamp,Config.Reset)
        boards[kind]={period_start=p.start,ends_at=p.finish,rerolls_used=0}
    end
    for slot,q in ipairs(Config.Quests) do
        local p=DQ.period(q.period,timestamp,Config.Reset)
        assignments[#assignments+1]={quest_id=q.id,period_kind=q.period,period_start=p.start,assigned_at=p.start,active=1,slot=slot}
    end
    return boards,assignments
end

GetCurrentResourceName = function() return 'custom-dailyquest' end
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
exports = {
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
}
local coins={}
exports.ox_inventory={
    Items=function(_,name)
        if hooks.missingItem then return nil end
        if name=='fle_token' then return {label='FLEトークン'} end
        if name=='black_coin' or name=='white_coin' then return {label=name=='black_coin' and '黒コイン' or '白コイン'} end
    end,
    CanCarryItem=function() hook('capacity');return not hooks.full end,
    AddItem=function(_,id,name,amount)
        if hooks.coinReject then return false end
        coins[#coins+1]={id=id,cid=players[id].PlayerData.citizenid,name=name,amount=amount}
        hook('afterCoin')
        return true
    end,
}
local logs={}
print=function(message) logs[#logs+1]=message end
initFailures=1
dofile('server/autoclaim.lua')
TriggerClientEvent=function(...) notifications[#notifications+1]={...} end
DQStore.sql={}
local ace={}
IsPlayerAceAllowed=function(id) return ace[tonumber(id)]==true end
dofile('server/debug.lua')
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
eq(view.ok,true);eq(#view.quests,48)
eq(row('ALPHA','daily_visit').progress,1)
eq(row('ALPHA','weekly_visits').progress,1)
eq(callbacks['suimag-dailyquest:list'](1).error,'rate_limited')
list()
eq(row('ALPHA','weekly_visits').progress,1,'same day does not count twice')
eq(claim(1,'daily_time').error,'incomplete')
eq(claim(1,'daily_visit').ok,true)
eq(#payments,1);eq(payments[1].cid,'ALPHA');eq(payments[1].amount,150000)
eq(claim(1,'daily_visit').error,'claimed');eq(#payments,1)
advance(2)
eq(callbacks['suimag-dailyquest:claim'](1,{},0).error,'invalid_request')
advance(2)
eq(callbacks['suimag-dailyquest:claim'](1,'daily_time',0/0).error,'invalid_request')
eq(claim(1,'daily_time',now-86400).error,'expired')
-- Persisted reward and target do not change within an existing period.
Config.Rewards.daily=999999
player(2,'BETA');list(2)
eq(row('BETA','daily_visit').reward_amount,999999)
eq(row('ALPHA','daily_visit').reward_amount,150000)
Config.Rewards.daily=150000
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
eq(row('CLOCK','daily_time').progress,0,'new daily tasks do not receive pre-draw time')
eq(row('CLOCK','weekly_time').progress,30)
-- Legacy battlepasses do not block menus, progress or rewards in either startup state.
for _,state in ipairs({'starting','started'}) do
    for _,name in ipairs({'noob_battlepass','sky_battlepass','skybp_events'}) do
        resourceStates[name]=state
    end
    local previous,previousTime=row('CLOCK','daily_time').progress,now
    eq(list(7).ok,true)
    advance(15);resume(threads[2])
    eq(row('CLOCK','daily_time').progress,previous+now-previousTime)
end
before=#payments;eq(claim(7,'daily_visit').ok,true);eq(#payments,before+1)
eq(claim(7,'daily_visit').error,'claimed');eq(#payments,before+1)
-- Keep them started for the sampler, bonus and automatic-settlement scenarios below.
-- Console diagnostics are not accessible to players.
local logCount=#logs;commands.dailyquest_pending(7);eq(#logs,logCount)
commands.dailyquest_pending(0);eq(#logs,logCount+1)
_G.source=7;handlers.playerDropped()
players[7]=nil
eq(list(7).error,'player_unavailable')

-- Runtime bridge binds identity and routes only the intended activity into storage.
player(8,'BRIDGE');list(8)
local signals={}
DQStore.signal=function(cid,activity,timestamp) signals[#signals+1]={cid=cid,activity=activity,at=timestamp} end
eq(DQRuntime.signal(8,'OLD','bus').error,'player_unavailable')
eq(#signals,0)
eq(DQRuntime.signal(8,'BRIDGE','bus').ok,true)
eq(signals[1].cid,'BRIDGE');eq(signals[1].activity,'bus')
-- The actual sampler thread hands movement/duty to the normal DB flush exactly once.
players={ [8]=players[8] }
local captured={}
DQStore.tracked=function(cid,entries) captured[#captured+1]={cid=cid,entries=entries} end
local position=0
DQTracking.frame=function()
    return {ped=8,vehicle=0,bucket=0,x=position,y=0,z=30,mode='walk',alive=true,duty=true,job='police',wall=now,timer=timer}
end
eq(resume(threads[3]),5000)
resume(threads[3])
advance(5);position=10;resume(threads[3])
resume(threads[2])
eq(#captured,1)
eq(captured[1].cid,'BRIDGE')
local sampled={}
for _,entry in ipairs(captured[1].entries) do sampled[entry.quest.id]=entry.amount end
eq(sampled.daily_walk,10);eq(sampled.weekly_walk,10)
eq(sampled.daily_duty,5);eq(sampled.weekly_duty,5)
advance(15);resume(threads[2]);eq(#captured,1,'flushed tracking cannot repeat')

-- Onboarding and settings are source-scoped; gameplay cannot progress before setup.
preferences.SETUP=false
player(9,'SETUP')
local setup=list(9)
eq(setup.needsSetup,true);eq(#setup.quests,0)
eq(DQRuntime.signal(9,'SETUP','bus').error,'setup_required')
advance(2)
eq(callbacks['suimag-dailyquest:preferences'](9,{crime=1,employment=false}).error,'invalid_request')
advance(2)
eq(callbacks['suimag-dailyquest:preferences'](9,{crime=true,employment=true}).ok,true)
eq(list(9).preferences.crime,true);eq(preferences.SETUP.employment,true)
local beforeValue=row('SETUP','daily_visit').progress
advance(2)
eq(callbacks['suimag-dailyquest:preferences'](9,{crime=false,employment=false}).ok,true)
eq(list(9).preferences.crime,false);eq(row('SETUP','daily_visit').progress,beforeValue)
local rerollCall
DQStore.reroll=function(cid,quest,prefs,data,state,timestamp,defs)
    rerollCall={cid=cid,id=quest.id,prefs=prefs}
    return false,'no_candidates'
end
advance(2)
eq(callbacks['suimag-dailyquest:reroll'](9,'daily_walk',DQ.period('daily',now,Config.Reset).start).error,'no_candidates')
eq(rerollCall.cid,'SETUP');eq(rerollCall.id,'daily_walk');eq(rerollCall.prefs.crime,false)
advance(2)
eq(callbacks['suimag-dailyquest:reroll'](9,'daily_walk',0).error,'expired')
advance(2)
eq(callbacks['suimag-dailyquest:reroll'](9,'unknown',0).error,'invalid_request')



-- Daily all-clear bonus uses its own durable reservation and the same payout failure handling.
local bonusRecords,bonusId={},100
local function makeBonus(cid,completed)
    bonusId=bonusId+1
    local p=DQ.period('daily',now,Config.Reset)
    local row={id=bonusId,citizenid=cid,period_start=p.start,ends_at=p.finish,
        required_count=3,assigned_count=3,completed_count=completed,status='active',
        reward_type='bank',reward_amount=200000,reward_coin='fle_token',reward_coin_amount=1}
    bonusRecords[cid]=row
    return row
end
local function bonusById(id)
    for _,record in pairs(bonusRecords) do if record.id==id then return record end end
end
DQStore.bonusState=function(cid,start)
    local record=bonusRecords[cid]
    if record and record.period_start==start then return copy(record) end
end
DQStore.reserveBonus=function(cid,id,timestamp)
    local record=bonusById(id)
    if not record or record.citizenid~=cid or record.status~='active' or record.ends_at<=timestamp
        or record.completed_count~=record.required_count or record.assigned_count~=record.required_count then return false end
    record.status='pending';hook('reserveBonus',record);return true
end
DQStore.releaseBonus=function(id) bonusById(id).status='active' end
DQStore.finishBonus=function(id) hook('finishBonus');bonusById(id).status='claimed' end
local function claimBonus(id,start)
    advance(2)
    return callbacks['suimag-dailyquest:claimBonus'](id,start or DQ.period('daily',now,Config.Reset).start)
end
player(11,'BONUS');local b=makeBonus('BONUS',2)
eq(list(11).dailyBonus.canClaim,false)
before=#payments;eq(claimBonus(11).error,'incomplete');eq(#payments,before)
b.completed_count=3;eq(list(11).dailyBonus.canClaim,true)
eq(list(11).dailyBonus.reward:find('FLEトークン × 1',1,true)~=nil,true)
eq(claimBonus(11).ok,true);eq(payments[#payments].amount,200000)
eq(coins[#coins].name,'fle_token');eq(coins[#coins].amount,1)
eq(payments[#payments].reason,'dailyquest:bonus:'..b.id)
before=#payments;eq(claimBonus(11).error,'claimed');eq(#payments,before)
eq(claimBonus(11,0).error,'expired')
advance(2);eq(callbacks['suimag-dailyquest:claimBonus'](11,0/0).error,'invalid_request')
-- Token failures preserve all-clear claim safety.
player(16,'BONUS_TOKEN');local tokenBonus=makeBonus('BONUS_TOKEN',3)
local tokenMoney,tokenCoins=#payments,#coins
hooks.missingItem=true;eq(claimBonus(16).error,'invalid_item');hooks.missingItem=nil
hooks.full=true;eq(claimBonus(16).error,'inventory_full');hooks.full=nil
eq(tokenBonus.status,'active');eq(#payments,tokenMoney);eq(#coins,tokenCoins)
hooks.coinReject=true;eq(claimBonus(16).error,'pending');hooks.coinReject=nil
eq(tokenBonus.status,'pending');eq(#payments,tokenMoney+1);eq(#coins,tokenCoins)
eq(claimBonus(16).error,'pending');eq(#payments,tokenMoney+1)
-- Per-quest and all-clear totals: 3 x 150,000 + 200,000; 2 x 500,000 weekly.
player(12,'TOTALS');list(12);makeBonus('TOTALS',3)
local firstPayment=#payments
for _,quest in ipairs({'daily_visit','daily_time','daily_meals'}) do
    row('TOTALS',quest).progress=row('TOTALS',quest).target
    eq(claim(12,quest).ok,true)
end
eq(claimBonus(12).ok,true)
local sum=0;for i=firstPayment+1,#payments do sum=sum+payments[i].amount end
eq(sum,650000,'daily total')
firstPayment=#payments
for _,quest in ipairs({'weekly_visits','weekly_time'}) do
    row('TOTALS',quest).progress=row('TOTALS',quest).target
    eq(claim(12,quest).ok,true)
end
sum=0;for i=firstPayment+1,#payments do sum=sum+payments[i].amount end
eq(sum,1000000,'weekly total')
-- Same bonus under overlapping calls still pays once.
player(13,'BONUS_RACE');makeBonus('BONUS_RACE',3);list(13)
hooks.reserveBonus=function() coroutine.yield('bonus-db') end
local r1,r2
local a=coroutine.create(function() r1=claimBonus(13) end)
eq(resume(a),'bonus-db')
local z=coroutine.create(function() r2=claimBonus(13) end)
eq(resume(z),25)
before=#payments;hooks.reserveBonus=nil;resume(a);resume(z)
eq(r1.ok,true);eq(r2.error,'claimed');eq(#payments,before+1)
-- A failed payout is retryable; an unknown payout or failed finalization stays pending.
player(14,'BONUS_FAILED');b=makeBonus('BONUS_FAILED',3)
hooks.grant=function() return false end
eq(claimBonus(14).error,'reward_failed');eq(b.status,'active')
hooks.grant=nil;hooks.afterGrant=function() error('bonus outcome unknown') end
before=#payments
eq(claimBonus(14).error,'pending');eq(b.status,'pending');eq(#payments,before+1)
hooks.afterGrant=nil;before=#payments
eq(claimBonus(14).error,'pending');eq(#payments,before)
player(15,'BONUS_DBFAIL');b=makeBonus('BONUS_DBFAIL',3)
hooks.finishBonus=function() error('bonus SQL failure') end
eq(claimBonus(15).error,'pending');eq(b.status,'pending')
before=#payments;hooks.finishBonus=nil
eq(claimBonus(15).error,'pending');eq(#payments,before)
-- Identity is checked again after the bonus reservation yielded.
player(16,'BONUS_OLD');b=makeBonus('BONUS_OLD',3)
hooks.reserveBonus=function() player(16,'BONUS_NEW') end
before=#payments;eq(claimBonus(16).error,'claim_unavailable')
eq(#payments,before);eq(b.status,'active');hooks.reserveBonus=nil
-- Reservation crossing the daily deadline is released without paying.
player(17,'BONUS_EXPIRED');b=makeBonus('BONUS_EXPIRED',3)
hooks.reserveBonus=function(record) timer=timer+(record.ends_at-now)*1000;now=record.ends_at end
before=#payments;eq(claimBonus(17).error,'claim_unavailable');eq(#payments,before)
eq(b.status,'active');hooks.reserveBonus=nil
-- The next day has a separate bonus record and allowance.
player(11,'BONUS');makeBonus('BONUS',3)
eq(claimBonus(11).ok,true)

-- Automatic settlement is server-only, runs at rollover/login, and shares the payout ledger.
local eligibleAuto={}
local autoAfter=DQ.period('daily',now,Config.Reset).finish
local function allowAuto(record,kind)
    eligibleAuto[(kind or 'quest')..':'..record.id]={record=record,kind=kind or 'quest'}
end
DQStore.expiredDaily=function(cid,timestamp)
    local result={}
    for _,entry in pairs(eligibleAuto) do
        local r=entry.record
        local complete=entry.kind=='daily_bonus' and r.completed_count==r.required_count and r.assigned_count==r.required_count
            or entry.kind=='quest' and r.progress>=r.target
        if r.citizenid==cid and r.status=='active' and r.ends_at<=timestamp and r.ends_at>=autoAfter
            and (entry.kind=='daily_bonus' or r.period_kind=='daily') and complete and r.selected~=false then
            local out=copy(r);out.claim_kind=entry.kind;out.period_kind='daily';result[#result+1]=out
        end
    end
    return result
end
DQStore.reserveExpired=function(cid,candidate,timestamp)
    local entry=eligibleAuto[candidate.claim_kind..':'..candidate.id]
    if not entry then return false end
    local r=entry.record
    if r.citizenid~=cid or r.status~='active' or r.ends_at>timestamp or r.ends_at<autoAfter then return false end
    r.status='pending';hook('reserveExpired',r);return true
end
player(30,'AUTO');list(30)
local autoPeriod=DQ.period('daily',now,Config.Reset).start
for _,id in ipairs({'daily_visit','daily_time','daily_meals'}) do
    local r=row('AUTO',id);r.progress=r.target;allowAuto(r)
end
local autoBonus=makeBonus('AUTO',3);allowAuto(autoBonus,'daily_bonus')
local weeklyAuto=row('AUTO','weekly_time');weeklyAuto.progress=weeklyAuto.target;weeklyAuto.ends_at=autoAfter;allowAuto(weeklyAuto)
local unselected=row('AUTO','daily_house');unselected.progress=unselected.target;unselected.selected=false;allowAuto(unselected)
players={ [30]=players[30] }
before=#payments
advance(autoAfter-now);resume(threads[2])
eq(#payments,before+4,'three daily rewards and the full-clear bonus are automatic')
sum=0;for i=before+1,#payments do sum=sum+payments[i].amount end
eq(sum,650000);eq(autoBonus.status,'claimed');eq(weeklyAuto.status,'active');eq(unselected.status,'active')
eq(notifications[#notifications][1],'ox_lib:notify')
before=#payments;advance(31);list(30)
eq(#payments,before,'automatic settlement never repeats paid rewards')
eq(claim(30,'daily_visit',autoPeriod).error,'expired','manual expiry guard remains')
eq(claimBonus(30,autoPeriod).error,'expired')
-- No offline money mutation: persistent claims are picked up automatically on the next login.
player(31,'AUTO_OFFLINE');list(31)
for _,id in ipairs({'daily_visit','daily_time','daily_meals'}) do local r=row('AUTO_OFFLINE',id);r.progress=r.target;allowAuto(r) end
local offlineBonus=makeBonus('AUTO_OFFLINE',3);allowAuto(offlineBonus,'daily_bonus')
_G.source=31;handlers.playerDropped();players={}
before=#payments;advance(offlineBonus.ends_at-now);resume(threads[2])
eq(#payments,before,'offline player is not paid through an unsafe offline API')
player(31,'AUTO_OFFLINE');resume(threads[2])
eq(#payments,before+4,'login catches up without opening the quest menu')
player(31,'AUTO_OFFLINE');resume(threads[2]);eq(#payments,before+4,'fresh session preserves claim status')
-- Work observed just before reset is flushed before auto-claim eligibility is queried.
now=DQ.period('daily',now,Config.Reset).finish-15;timer=timer+1000000
player(32,'AUTO_TIME');list(32)
local timed=row('AUTO_TIME','daily_time');timed.progress=timed.target-10;allowAuto(timed)
players={ [32]=players[32] }
before=#payments;advance(15);resume(threads[2])
eq(timed.status,'claimed');eq(#payments,before+1,'last interval can finish and settle yesterday')
-- Unknown provider outcome stays pending; explicit rejection retries after the interval.
local function pastReward(id,cid)
    player(id,cid)
    open(cid,now-86400)
    local r=row(cid,'daily_time',-86400);r.progress=r.target;allowAuto(r)
    return r
end
local unknown=pastReward(33,'AUTO_UNKNOWN')
hooks.afterGrant=function() error('unknown automatic payout') end
before=#payments;list(33)
eq(unknown.status,'pending');eq(#payments,before+1)
hooks.afterGrant=nil;advance(31);list(33);eq(#payments,before+1,'pending is never retried automatically')
local retry=pastReward(34,'AUTO_RETRY')
hooks.grant=function() return false end
before=#payments;list(34);eq(retry.status,'active');eq(#payments,before)
hooks.grant=nil;advance(31);list(34)
eq(retry.status,'claimed');eq(#payments,before+1)
local switched=pastReward(35,'AUTO_OLD')
hooks.reserveExpired=function() player(35,'AUTO_NEW') end
before=#payments;list(35)
eq(switched.status,'active');eq(#payments,before,'source reuse cannot redirect an automatic reward')
hooks.reserveExpired=nil
-- Each tag/period pays its saved coin quantity alongside money, exactly once.
player(40,'COINS');local coinView=list(40)
local labels={};for _,q in ipairs(coinView.quests) do labels[q.id]=q.reward end
for _,entry in ipairs({
    {'daily_house','black_coin',1,150000},{'daily_boosting','black_coin',1,150000},
    {'daily_duty','white_coin',1,150000},{'weekly_house','black_coin',3,500000},
    {'weekly_boosting','black_coin',3,500000},{'weekly_duty','white_coin',3,500000},
}) do
    local id,item,amount,money=table.unpack(entry)
    local r=row('COINS',id);r.progress=r.target
    local priorMoney,priorCoins=#payments,#coins
    eq(claim(40,id).ok,true);eq(#payments,priorMoney+1);eq(payments[#payments].amount,money)
    eq(#coins,priorCoins+1);eq(coins[#coins].name,item);eq(coins[#coins].amount,amount)
    eq(labels[id]:find(item=='black_coin' and '黒コイン' or '白コイン',1,true)~=nil,true)
    eq(claim(40,id).error,'claimed');eq(#payments,priorMoney+1);eq(#coins,priorCoins+1)
end
local noCoinBefore=#coins;eq(claim(40,'daily_visit').ok,true);eq(#coins,noCoinBefore,'untagged quests have no coins')
-- Inventory and configuration failures occur before money is paid and preserve the claim.
player(41,'CAPACITY');list(41)
local capacity=row('CAPACITY','daily_house');capacity.progress=capacity.target
local priorMoney,priorCoins=#payments,#coins
hooks.missingItem=true;eq(claim(41,'daily_house').error,'invalid_item');hooks.missingItem=nil
eq(capacity.status,'active');eq(#payments,priorMoney);eq(#coins,priorCoins)
hooks.reserve=function() hooks.full=true end
eq(claim(41,'daily_house').error,'inventory_full');hooks.reserve=nil;hooks.full=nil
eq(capacity.status,'active');eq(#payments,priorMoney);eq(#coins,priorCoins)
hooks.grant=function() return false end
eq(claim(41,'daily_house').error,'reward_failed');hooks.grant=nil
eq(capacity.status,'active');eq(#coins,priorCoins)
-- Partial or unknown delivery stays pending; retries never duplicate the money or coins.
hooks.coinReject=true;eq(claim(41,'daily_house').error,'pending');hooks.coinReject=nil
eq(capacity.status,'pending');eq(#payments,priorMoney+1);eq(#coins,priorCoins)
eq(claim(41,'daily_house').error,'pending');eq(#payments,priorMoney+1);eq(#coins,priorCoins)
local uncertain=row('CAPACITY','daily_duty');uncertain.progress=uncertain.target
hooks.afterCoin=function() error('unknown coin outcome') end
priorMoney,priorCoins=#payments,#coins
eq(claim(41,'daily_duty').error,'pending');hooks.afterCoin=nil
eq(#payments,priorMoney+1);eq(#coins,priorCoins+1)
eq(claim(41,'daily_duty').error,'pending');eq(#payments,priorMoney+1);eq(#coins,priorCoins+1)
-- Switching characters after the money provider yields cannot send coins to the replacement.
player(42,'COIN_OLD');list(42)
local switchedCoin=row('COIN_OLD','daily_house');switchedCoin.progress=switchedCoin.target
hooks.afterGrant=function() player(42,'COIN_NEW') end
priorCoins=#coins
eq(claim(42,'daily_house').error,'pending');hooks.afterGrant=nil
eq(switchedCoin.status,'pending');eq(#coins,priorCoins)
-- Concurrent requests share the reservation for both components.
player(43,'COIN_RACE');list(43)
local raced=row('COIN_RACE','daily_house');raced.progress=raced.target
hooks.reserve=function() coroutine.yield('coin-db') end
local coinFirst,coinSecond
local ca=coroutine.create(function() coinFirst=claim(43,'daily_house') end)
eq(resume(ca),'coin-db')
local cb=coroutine.create(function() coinSecond=claim(43,'daily_house') end)
eq(resume(cb),25)
priorMoney,priorCoins=#payments,#coins
hooks.reserve=nil;resume(ca);resume(cb)
eq(coinFirst.ok,true);eq(coinSecond.error,'claimed');eq(#payments,priorMoney+1);eq(#coins,priorCoins+1)
-- Expired daily coin rewards retry after inventory space is freed and keep the saved item.
for index,quest in ipairs({'daily_house','daily_duty'}) do
    local sourceId,cid=43+index,'AUTO_COIN_'..index
    player(sourceId,cid);open(cid,now-86400)
    local r=row(cid,quest,-86400);r.progress=r.target;allowAuto(r)
    priorMoney,priorCoins=#payments,#coins
    hooks.full=true;list(sourceId);hooks.full=nil
    eq(r.status,'active');eq(#payments,priorMoney);eq(#coins,priorCoins)
    advance(31);list(sourceId)
    eq(r.status,'claimed');eq(#payments,priorMoney+1);eq(#coins,priorCoins+1)
    eq(coins[#coins].name,index==1 and 'black_coin' or 'white_coin');eq(coins[#coins].amount,1)
    advance(31);list(sourceId);eq(#payments,priorMoney+1);eq(#coins,priorCoins+1)
end
-- A coin capacity check crossing the deadline cannot pay an expired manual claim.
player(46,'COIN_EXPIRED');list(46)
local expiring=row('COIN_EXPIRED','daily_house');expiring.progress=expiring.target
hooks.capacity=function() advance(expiring.ends_at-now) end
priorMoney,priorCoins=#payments,#coins
eq(claim(46,'daily_house').error,'claim_unavailable');hooks.capacity=nil
eq(expiring.status,'active');eq(#payments,priorMoney);eq(#coins,priorCoins)
-- A shortage still exposes preferences instead of locking the user out of setup.
local oldState,oldEnsure=DQStore.boardState,DQStore.ensureBoards
DQStore.ensureBoards=function() return false,'no_candidates' end
DQStore.boardState=function() return {},{} end
player(10,'SHORTAGE')
local shortage=list(10)
eq(shortage.ok,true);eq(shortage.drawError,'no_candidates');eq(#shortage.quests,0)
eq(type(shortage.preferences),'table')
advance(2)
eq(callbacks['suimag-dailyquest:preferences'](10,{crime=false,employment=false}).ok,true,'settings save without a pre-save draw')
DQStore.boardState,DQStore.ensureBoards=oldState,oldEnsure
-- Debug authorization is enforced even for callers bypassing the GUI.
local debugQueries={}
MySQL.transaction={await=function(queries)
    for _,q in ipairs(queries) do debugQueries[#debugQueries+1]=q end
    hook('debugTransaction');return true
end}
MySQL.update={await=function(query,values) debugQueries[#debugQueries+1]={query=query,values=values};return 1 end}
MySQL.query={await=function() hook('debugRead');return {} end}
local function debugCall(id,action,quest,enabled)
    advance(2);return callbacks['suimag-dailyquest:debug'](id,action,quest,enabled)
end
player(50,'DEBUG');preferences.DEBUG=false
local beforeDebug=#debugQueries
for _,op in ipairs({'list','start','stop','reset','pool'}) do eq(debugCall(50,op,'daily_bus',false).error,'forbidden') end
eq(#debugQueries,beforeDebug,'denied operations never touch storage')
eq(list(50).canDebug,false)
ace[50]=true
eq(list(50).canDebug,true)
local moneyBefore=#payments
local diagnostic=debugCall(50,'start')
eq(diagnostic.ok,true);eq(diagnostic.enabled,true);eq(#diagnostic.quests,#Config.Quests)
eq(#payments,moneyBefore,'debug cannot pay rewards')
eq(debugCall(50,'pool','daily_bus',false).ok,true);eq(DQSelection.disabled.daily_bus,true)
eq(debugCall(50,'pool','daily_bus',true).ok,true);eq(DQSelection.disabled.daily_bus,nil)
eq(debugCall(50,'pool','daily_bus',1).error,'invalid_request')
eq(debugCall(50,'reset','unknown').error,'invalid_request')
eq(debugCall(50,'progress','daily_bus',999).error,'invalid_request','no arbitrary increment endpoint')
eq(debugCall(50,'reset','daily_bus').ok,true)
local resetQuery=debugQueries[#debugQueries]
eq(resetQuery.query,DQStore.sql.debugReset);eq(resetQuery.values[1],'DEBUG');eq(resetQuery.values[2],'daily_bus')
eq(debugCall(50,'stop').enabled,false)
hooks.debugRead=function() ace[50]=false end
eq(debugCall(50,'list').error,'forbidden','permission revoked during storage read')
hooks.debugRead=nil
-- Admin job works without ACE, even off duty; removing both permissions stops diagnostics.
players[50].PlayerData.job={name='admin',onduty=false}
eq(list(50).canDebug,true,'admin job grants access without ACE')
eq(debugCall(50,'start').enabled,true)
players[50].PlayerData.job.name='police'
eq(list(50).canDebug,false,'non-admin job without ACE loses access')
eq(debugCall(50,'list').error,'forbidden')
ace[50]=true
eq(debugCall(50,'list').enabled,false,'ACE grants access for other jobs; revoked measurement stays stopped')
hooks.debugTransaction=function() player(50,'DEBUG_REPLACEMENT') end
eq(debugCall(50,'start').error,'forbidden','character switch during start cannot enable measurement')
hooks.debugTransaction=nil
-- Persisted pool exclusions are restored before the server becomes ready.
MySQL.query.await=function(query) return query==DQStore.sql.poolList and {{quest_id='daily_bus',enabled=0}} or {} end
DQDebug.init();eq(DQSelection.disabled.daily_bus,true)
DQSelection.disabled={}
player(51,'LOOT_AVAILABILITY')
for _,activity in ipairs({'atm','store','uride','cargo'}) do resourceStates[Config.Activities[activity].resource]='started' end
resourceStates.satou_logging='stopped'
for _,quests in ipairs({list(51).quests,DQDebug.snapshot({citizenid='LOOT_AVAILABILITY'}).quests}) do
    local availability={}
    for _,quest in ipairs(quests) do availability[quest.id]=quest.available end
    eq(availability.daily_atm,false,'normal/debug: inventory observer stopped')
    eq(availability.weekly_store,false,'normal/debug: inventory observer stopped')
    eq(availability.daily_uride,true,'Uride does not require inventory observer')
    eq(availability.daily_cargo,true,'cargo does not require inventory observer')
end
resourceStates.satou_logging='started'
for _,quests in ipairs({list(51).quests,DQDebug.snapshot({citizenid='LOOT_AVAILABILITY'}).quests}) do
    local availability={}
    for _,quest in ipairs(quests) do availability[quest.id]=quest.available end
    eq(availability.daily_atm,true,'normal/debug: observer restored')
    eq(availability.weekly_store,true,'normal/debug: observer restored')
end
io.write(('server: %d assertions passed\n'):format(count))
