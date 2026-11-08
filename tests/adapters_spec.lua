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
exports={qbx_core={GetPlayerByCitizenId=function(_,cid)
    for source,currentCid in pairs(players) do
        if currentCid==cid then return {PlayerData={source=source,citizenid=cid}} end
    end
end}}
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
DQRuntime.signal=original
players[1],players[2]='ONE','TWO'

-- Uride counts only driver payouts from its own server, including NPC missions.
for i,reason in ipairs({'rideshare-earning','npc-mission-reward'}) do
    before=#calls
    money(1,10000+i,reason)
    eq(#calls,before,'money alone is not a trip')
    event('pv_poe:job:complete','fr-ride',1,'fr-ride',10000+i)
    eq(#calls,before+1,reason);eq(calls[#calls].activity,'uride')
end
before=#calls
money(1,11000,'rideshare-fare')
event('pv_poe:job:complete','fr-ride',1,'fr-ride',11000)
event('pv_poe:job:complete','fr-ride',1,'fr-ride',12000)
event('pv_poe:job:complete',nil,1,'fr-ride',12000)
eq(#calls,before,'passenger payments, missing credits and network reports are excluded')
eq(handlers['rideshare:npc:completeMission'],nil,'no client mission subscription')
eq(handlers['projectx-atmrobbery:server:AddExperience'],nil,'no client minigame subscription')

local function loot(resource)
    return {action='add',resource=resource,actor={src=1,cid='ONE'},
        parts={{to={type='player',id='ONE',owner='ONE'},rows={{item='black_money',count=15000}}}}}
end
for _,activity in ipairs({'atm','store'}) do
    local resource=Config.Activities[activity].resource
    local op=loot(resource)
    op.parts[1].rows[2]={item='black_money',count=5000}
    before=#calls
    event('satou_logging:inventory','ox_inventory',op)
    eq(#calls,before+1,'multiple slots in one grant count once')
    eq(calls[#calls].activity,activity)
    states[resource]='stopped'
    event('satou_logging:inventory','ox_inventory',op)
    eq(#calls,before+1,'stopped robbery resource')
    states[resource]=nil
end
before=#calls
for _,resource in ipairs({'satou_logging','projectx-atmrobbery','evil'}) do
    event('satou_logging:inventory',resource,loot('projectx-atmrobbery'))
end
event('satou_logging:inventory',nil,loot('projectx-atmrobbery'))
for _,action in ipairs({'remove','set','give','admin','craft','buy'}) do
    local op=loot('projectx-atmrobbery');op.action=action
    event('satou_logging:inventory','ox_inventory',op)
end
for _,mutate in ipairs({
    function(op) op.resource='qbx_core' end,
    function(op) op.resource='projectx-storerobbery' end,
    function(op) op.actor=nil end,
    function(op) op.actor.src='1' end,
    function(op) op.actor.cid='OTHER' end,
    function(op) op.parts={} end,
    function(op) op.parts[1].to.type='stash' end,
    function(op) op.parts[1].to.owner='OTHER' end,
    function(op) op.parts[1].from={type='player'} end,
    function(op) op.parts[1].rows={} end,
    function(op) op.parts[1].rows[1].item='atmmotherboard' end,
    function(op) op.parts[1].rows[1].item='black_coin' end,
    function(op) op.parts[1].rows[1].count=0 end,
    function(op) op.parts[1].rows[1].count=-1 end,
    function(op) op.parts[1].rows[1].count=0/0 end,
    function(op) op.parts[1].rows[1].count=1.5 end,
}) do
    local op=loot('projectx-atmrobbery');mutate(op)
    event('satou_logging:inventory','ox_inventory',op)
    eq(#calls,before,'invalid inventory grant')
end
event('satou_logging:inventory','ox_inventory',false)
states.satou_logging='stopped'
event('satou_logging:inventory','ox_inventory',loot('projectx-atmrobbery'))
states.satou_logging=nil
players[1]='REPLACED'
event('satou_logging:inventory','ox_inventory',loot('projectx-atmrobbery'))
eq(#calls,before,'observer unavailable and source reuse')
-- Cargo contracts identify members by citizenid, not network source.
players[1],players[2],players[3]='ONE','TWO','OWNER'
before=#calls
event('lunar_contracts:heistCompleted','lunar_heistcontracts',11,'cargo','OWNER',{'ONE','ONE','TWO','OFFLINE'})
eq(#calls,before+2,'cargo deduplicates members and ignores offline identifiers')
local cargoSources={}
for i=before+1,#calls do cargoSources[calls[i].source]=true;eq(calls[i].activity,'cargo') end
eq(cargoSources[1],true);eq(cargoSources[2],true);eq(cargoSources[3],nil,'ownership alone is not participation')
before=#calls
for _,name in ipairs({'house','fleeca','boosting','Cargo'}) do
    event('lunar_contracts:heistCompleted','lunar_heistcontracts',11,name,'ONE',{'ONE'})
end
for _,resource in ipairs({'evil','lunar_bridge','lunar_contracts'}) do
    event('lunar_contracts:heistCompleted',resource,11,'cargo','ONE',{'ONE'})
end
event('lunar_contracts:heistCompleted',nil,11,'cargo','ONE',{'ONE'})
for _,index in ipairs({'11',-1,0/0}) do
    event('lunar_contracts:heistCompleted','lunar_heistcontracts',index,'cargo','ONE',{'ONE'})
end
event('lunar_contracts:heistCompleted','lunar_heistcontracts',11,'cargo','ONE',false)
event('lunar_contracts:heistCompleted','lunar_heistcontracts',11,'cargo','ONE',{false,{},1,'license:example'})
local oversized={}
for i=1,129 do oversized[i]='ONE' end
event('lunar_contracts:heistCompleted','lunar_heistcontracts',11,'cargo','ONE',oversized)
states.lunar_heistcontracts='stopped'
event('lunar_contracts:heistCompleted','lunar_heistcontracts',11,'cargo','ONE',{'ONE'})
states.lunar_heistcontracts=nil
eq(#calls,before,'cargo rejects other contracts, spoofed origins and malformed members')
local getByCid=exports.qbx_core.GetPlayerByCitizenId
exports.qbx_core.GetPlayerByCitizenId=function() return {PlayerData={source=1}} end
event('lunar_contracts:heistCompleted','lunar_heistcontracts',11,'cargo','OLD',{'OLD'})
eq(#calls,before,'stale identifier lookup cannot credit a replacement')
exports.qbx_core.GetPlayerByCitizenId=getByCid
DQRuntime.signal=function(source,cid,activity)
    original(source,cid,activity)
    players[1],players[2]='REPLACED','REPLACED'
end
event('lunar_contracts:heistCompleted','lunar_heistcontracts',12,'cargo','ONE',{'ONE','TWO'})
eq(#calls,before+2,'all cargo identities captured before storage can yield')
local captured={[calls[#calls].cid]=true,[calls[#calls-1].cid]=true}
eq(captured.ONE,true);eq(captured.TWO,true)
DQRuntime.signal=original
print(('adapters: %d assertions passed'):format(count))
