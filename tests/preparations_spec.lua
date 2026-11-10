dofile('config.lua')
dofile('server/domain.lua')
dofile('server/preparation_plans.lua')
local checks=0
local function eq(a,b,label) checks=checks+1;assert(a==b,(label or '')..': '..tostring(a)..' ~= '..tostring(b)) end
local now, bucket, occupied, allowed = 1000,0,0,true
local player={PlayerData={source=1,citizenid='ALPHA',job={name='admin',onduty=false},metadata={}}}
local states, stock, entities, marks, log = {}, {}, {}, {}, {}
local failItem, grantHook, lastGate, keyFailure, swapHook
GetResourceState=function(name)return states[name] or 'started' end
GetPlayerPed=function()return 1 end
GetVehiclePedIsIn=function()return occupied end
GetPlayerRoutingBucket=function()return bucket end
GetEntityHealth=function()return 200 end
DoesEntityExist=function(id)return id==1 or entities[id]==true end
GetEntityHeading=function()return 90 end
GetEntityCoords=function(id)return id==1 and {x=10,y=20,z=30} or {x=457.56,y=-654.52,z=28.64} end
GetAllVehicles=function()local out={};for id,exists in pairs(entities) do if exists then out[#out+1]=id end end;return out end
GetHashKey=function(name)return name end
CreateVehicleServerSetter=function(model,kind)eq(model,'blista');eq(kind,'automobile');entities[77]=true;return 77 end
SetEntityOrphanMode=function()end
SetEntityRoutingBucket=function()end
NetworkGetNetworkIdFromEntity=function(id)return id+100 end
DeleteEntity=function(id)entities[id]=false;log[#log+1]='delete' end
Entity=function(id)
    marks[id]=marks[id] or {}
    marks[id].set=function(self,key,value)self[key]=value end
    return {state=marks[id]}
end
os.time=function()return now end
DQStore={bootId='test-boot'}
MySQL={scalar={await=function()return lastGate end}}
exports={
    qbx_core={GetPlayer=function()return player end,SetJobDuty=function(_,_,value)player.PlayerData.job.onduty=value end},
    ox_inventory={
        registerHook=function(_,event,fn)eq(event,'swapItems');swapHook=fn end,
        Items=function(_,name)return name~='missing' and {label=name} or nil end,
        GetItemCount=function(_,_,name)local n=0;for _,v in ipairs(stock[name] or {}) do n=n+v.count end;return n end,
        CanCarryItem=function()return true end,
        AddItem=function(_,_,name,count,meta)
            if name==failItem then return false end
            stock[name]=stock[name] or {};stock[name][#stock[name]+1]={count=count,meta=meta}
            if grantHook then grantHook() end
            return true
        end,
        RemoveItem=function(_,_,name,count,meta,slot,ignoreTotal,strict)
            eq(slot,nil);eq(ignoreTotal,true);eq(strict,false)
            for _,v in ipairs(stock[name] or {}) do
                if v.meta and v.meta.dailyquestTest==meta.dailyquestTest then v.count=math.max(0,v.count-count) end
            end
        end,
    },
    qbx_vehiclekeys={GiveKeys=function()log[#log+1]='keys' end,RemoveKeys=function()if keyFailure then error('keys unavailable') end end},
}
dofile('server/preparations.lua')
local P=DQPreparation
local defs=DQ.validate(Config)
local session={source=1,citizenid='ALPHA',tracking={last={}},debug={tracking={last={}}}}
local function valid()return allowed and player.PlayerData.citizenid==session.citizenid end
for _,quest in ipairs(Config.Quests) do
    local plan=P.describe(quest)
    eq(type(plan),'table',quest.id);eq(type(plan.help),'string');eq(type(plan.label),'string')
end
eq(P.describe(defs.daily_house).available,true,'unmodified house resource is supported')
states.satou_logging='stopped';eq(P.describe(defs.daily_atm).available,false);states.satou_logging=nil
states.qbx_vehiclekeys='stopped';eq(P.describe(defs.daily_drive).available,false);states.qbx_vehiclekeys=nil
occupied=22;local ok,err=P.precheck(session,defs.daily_meals);eq(ok,false);eq(err,'on_foot_required');occupied=0
bucket=3;ok,err=P.precheck(session,defs.daily_meals);eq(err,'world_required');bucket=0
player.PlayerData.metadata.isdead=true;ok,err=P.precheck(session,defs.daily_meals);eq(err,'alive_required');player.PlayerData.metadata.isdead=nil
player.PlayerData.job.name='unemployed';ok,err=P.precheck(session,defs.daily_duty);eq(err,'not_employed');player.PlayerData.job.name='admin'
entities[88]=true;ok,err=P.precheck(session,defs.daily_drive);eq(err,'spawn_busy');entities[88]=nil

ok,err=P.start(session,defs.daily_fishing,valid);eq(ok,true)
eq(err.coords[1],-1822.32);eq(P.moving(session),true)
eq(session.tracking.last,nil);eq(session.debug.tracking.last,nil)
local oldTag=session.preparation.tag
local tagged={metadata={dailyquestTest=oldTag}}
eq(swapHook({fromInventory=1,toInventory=2,fromSlot=tagged}),false,'loan cannot be given away')
eq(swapHook({fromInventory=1,toInventory='stash',toSlot=tagged}),false,'loan cannot move through swaps')
eq(swapHook({fromInventory=1,toInventory=1,fromSlot=tagged}),nil,'sorting within own inventory remains allowed')
eq(swapHook({fromInventory=1,toInventory=2,fromSlot={metadata={}}}),nil,'normal items are unaffected')
eq(P.precheck(session,defs.daily_meals),false,'one active preparation')
eq(P.ready(session,'wrong',true),false)
eq(P.ready(session,'daily_fishing',true),true);eq(P.moving(session),false)
lastGate=990;eq(P.snapshot(session).cooldown,20)
local travel=P.waypoint(session,'daily_fishing');eq(travel.waypoint,true);eq(P.moving(session),true)
eq(P.ready(session,'daily_fishing',false),true);eq(P.snapshot(session).failed,true)
ok,travel=P.finish(session,'daily_fishing');eq(ok,true);eq(travel.coords[1],10)
eq(stock.fish[1].count,0,'unused loan is removed');eq(session.preparation,nil)
eq(P.moving(session),true,'return movement excluded');eq(P.ready(session,'daily_fishing',true),true)

stock.lockpick={{count=1}}
ok=P.start(session,defs.daily_boosting,valid);eq(ok,true)
eq(stock.lockpick[1].meta,nil,'existing tool is preserved')
P.cleanup(session);eq(stock.lockpick[1].count,1)
failItem='cargo_all'
ok,err=P.start(session,defs.daily_cargo,valid);eq(ok,false);eq(err,'inventory_full')
eq(stock.luner_contracts_tablet[1].count,0,'partial grant rolled back');eq(session.preparation,nil)
failItem=nil
grantHook=function()allowed=false end
ok,err=P.start(session,defs.daily_cargo,valid);eq(ok,false);eq(err,'forbidden')
eq(session.preparation,nil);grantHook=nil;allowed=true

ok=P.start(session,defs.daily_duty,valid);eq(ok,true);eq(player.PlayerData.job.onduty,true)
P.cleanup(session);eq(player.PlayerData.job.onduty,false)
ok=P.start(session,defs.daily_duty,valid);eq(ok,true)
player.PlayerData.job={name='police',onduty=true}
P.cleanup(session);eq(player.PlayerData.job.onduty,true,'do not overwrite a different job')
player.PlayerData.job={name='admin',onduty=false}

ok,travel=P.start(session,defs.daily_drive,valid);eq(ok,true);eq(travel.vehicle,177)
eq(marks[77].dailyquestTest,session.preparation.tag);eq(log[#log],'keys')
keyFailure=true;P.cleanup(session);keyFailure=false
eq(entities[77],false,'vehicle still deleted if key removal fails')
ok,travel=P.start(session,defs.daily_house,valid);eq(ok,true)
eq(travel.coords[1],-64.252);eq(P.snapshot(session).houseId,1)
eq(stock.advancedlockpick[1].count,1,'only missing lockpick supplied')
eq(P.waypoint(session,'daily_house'),nil,'house uses explicit candidates')
P.ready(session,'daily_house',true)
bucket=60001
eq(P.snapshot(session).returnBlocked,true)
ok,err=P.finish(session,'daily_house');eq(ok,false);eq(err,'exit_required')
eq(session.preparation.id,'daily_house','blocked return preserves the active trial')
eq(stock.advancedlockpick[1].count,1,'blocked return does not remove tools during a robbery')
travel,err=P.nextHouse(session,'daily_house');eq(travel,nil);eq(err,'exit_required')
bucket=0
travel=P.nextHouse(session,'daily_house');eq(travel.coords[1],-45.774);eq(P.snapshot(session).houseId,2)
P.ready(session,'daily_house',true)
P.nextHouse(session,'daily_house');eq(P.snapshot(session).houseId,3)
P.ready(session,'daily_house',true)
P.nextHouse(session,'daily_house');eq(P.snapshot(session).houseId,1,'candidates wrap')
P.ready(session,'daily_house',true)
ok,travel=P.finish(session,'daily_house');eq(ok,true);eq(travel.coords[1],10)
eq(stock.advancedlockpick[1].count,0)
P.ready(session,'daily_house',true)
ok=P.start(session,defs.daily_house,valid);eq(ok,true)
bucket=60001;P.cleanup(session);eq(bucket,60001,'cleanup never changes house internal state or bucket');bucket=0

ok=P.start(session,defs.daily_meals,valid);eq(ok,true)
eq(session.preparation.tag==oldTag,false,'new loan has a distinct tag')
now=now+31;eq(P.moving(session),false);eq(session.preparation.failed,true)
P.cleanup(session)
ok=P.start(session,defs.daily_meals,valid);eq(ok,true)
local water=stock.water[#stock.water]
player.PlayerData.citizenid='BETA'
P.cleanup(session)
eq(water.count,1,'cleanup never removes another character inventory')
print(('preparations: %d assertions passed'):format(checks))
