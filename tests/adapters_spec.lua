dofile('config.lua')
dofile('server/domain.lua')
local handlers,calls,players,states={}, {}, {[1]='ONE',[2]='TWO'}, {}
local timer,caller,count=1000,nil,0
local function eq(a,b,label) count=count+1;assert(a==b,(label or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
AddEventHandler=function(name,fn) handlers[name]=fn end
RegisterNetEvent=function() error('Adapter must not expose network progress') end
GetInvokingResource=function() return caller end
GetGameTimer=function() return timer end
GetResourceState=function(name) return states[name] or 'started' end
DQRuntime={
    identity=function(source) return players[source] end,
    signal=function(source,cid,activity) calls[#calls+1]={source=source,cid=cid,activity=activity} end,
}
dofile('server/adapters.lua')
local function event(name,resource,...)
    caller=resource;handlers[name](...)
end
local function money(source,amount,reason)
    event('QBCore:Server:OnMoneyChange','qbx_core',source,'bank',amount,'add',reason)
end
local total=0
for activity,rule in pairs(Config.Activities) do
    if rule.signal=='job' then
        local reason='job-pay'
        if rule.reasons then for value in pairs(rule.reasons) do reason=value;break end end
        if rule.payment then money(1,1000,reason) end
        event('pv_poe:job:complete',rule.resource,1,rule.resource,rule.payment and 1000 or nil)
        total=total+1
        eq(#calls,total,'working adapter '..activity)
        eq(calls[#calls].activity,activity)
        if rule.payment then
            event('pv_poe:job:complete',rule.resource,1,rule.resource,1000)
            eq(#calls,total,'same payment cannot count twice')
        end
    end
end
event('skybp:mining:done','jim-recycle',1);total=total+1;eq(calls[total].activity,'recycle')
event('skybp:boostComplete','gg_boosting',1);total=total+1;eq(calls[total].activity,'boosting')
event('satou_houserobbery:server:completed','satou_houserobbery',1,1,1,{1,1,2})
total=total+2;eq(#calls,total,'house participants deduplicated')
local before=#calls
-- Untrusted network origin, forged job key and non-allowlisted resource.
money(1,2000,'job-pay')
event('pv_poe:job:complete',nil,1,'gg_busjob',2000)
event('pv_poe:job:complete','evil',1,'gg_busjob',2000)
event('pv_poe:job:complete','gg_busjob',1,'gg_garbagejob',2000)
event('skybp:mining:done',nil,1)
event('skybp:boostComplete','skybp_events',1)
event('satou_houserobbery:server:completed',nil,1,1,1,{1,2})
eq(#calls,before)
event('pv_poe:job:complete','gg_busjob',1,'gg_busjob',2000);before=before+1;eq(#calls,before)
money(1,3000,'job-pay');timer=timer+2001
event('pv_poe:job:complete','gg_busjob',1,'gg_busjob',3000);eq(#calls,before,'expired payment')
money(1,4000,'dailyquest:42')
event('pv_poe:job:complete','gg_busjob',1,'gg_busjob',4000);eq(#calls,before,'quest rewards excluded')
event('QBCore:Server:OnMoneyChange',nil,1,'bank',5000,'add','job-pay')
event('pv_poe:job:complete','gg_busjob',1,'gg_busjob',5000);eq(#calls,before,'network money spoof')
money(1,6000,'sell-gems')
event('pv_poe:job:complete','pug-fishing',1,'pug-fishing',6000);eq(#calls,before,'gem sales not fishing')
money(1,6001,'sell-crabs')
event('pv_poe:job:complete','pug-fishing',1,'pug-fishing',6001);before=before+1;eq(#calls,before)
money(1,7000,'job-pay');players[1]='OTHER'
event('pv_poe:job:complete','gg_busjob',1,'gg_busjob',7000);eq(#calls,before,'source reuse')
money(1,8000,'job-pay')
event('QBCore:Server:OnPlayerUnload','qbx_core',1)
event('pv_poe:job:complete','gg_busjob',1,'gg_busjob',8000);eq(#calls,before,'logout clears credits')
money(1,9000,'job-pay')
event('QBCore:Server:PlayerLoaded','qbx_core',{PlayerData={source=1}})
event('pv_poe:job:complete','gg_busjob',1,'gg_busjob',9000);eq(#calls,before,'reload clears credits')
states['jim-recycle']='stopped'
event('skybp:mining:done','jim-recycle',1);eq(#calls,before,'stopped resource')
-- No job progress from removal/set/zero/fractional/NaN monetary data.
for _,amount in ipairs({0,-1,1.5,0/0}) do
    money(1,amount,'job-pay')
    event('pv_poe:job:complete','gg_busjob',1,'gg_busjob',amount)
end
eq(#calls,before)
money(1,2,'job-pay')
event('pv_poe:job:complete','gg_busjob',1,'gg_busjob',1.5)
before=before+1;eq(#calls,before,'unrounded job payout matches Qbox rounding')
-- Capture all member identities before a yielding operation can recycle another member source.
local original=DQRuntime.signal
DQRuntime.signal=function(source,cid,activity)
    original(source,cid,activity)
    players[1],players[2]='REPLACED','REPLACED'
end
players[1],players[2]='A','B'
event('satou_houserobbery:server:completed','satou_houserobbery',1,1,1,{1,2})
local cids={[calls[#calls].cid]=true,[calls[#calls-1].cid]=true}
eq(cids.A,true);eq(cids.B,true)
print(('adapters: %d assertions passed'):format(count))
