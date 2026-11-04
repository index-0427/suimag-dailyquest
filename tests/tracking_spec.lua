dofile('config.lua')
dofile('server/domain.lua')
dofile('server/tracking.lua')
local count = 0
local function eq(a,b,label) count=count+1;assert(a==b,(label or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function frame(change)
    local value={ped=1,vehicle=0,bucket=0,x=0,y=0,z=30,mode='walk',alive=true,duty=true,job='police',wall=1793736100,timer=1000}
    for key,v in pairs(change or {}) do value[key]=v end
    return value
end
local base=frame()
local nextFrame=frame({x=10,wall=1793736105,timer=6000})
eq(DQTracking.measure(base,nextFrame).distance,10)
eq(DQTracking.measure(base,nextFrame).duty,5)
for _,change in ipairs({{ped=2},{bucket=2},{alive=false},{wall=1793736100,timer=500},{wall=1793736200,timer=101000}}) do
    local f=frame({x=10,wall=1793736105,timer=6000});for k,v in pairs(change) do f[k]=v end
    eq(DQTracking.measure(base,f),nil,'invalid interval')
end
eq(DQTracking.measure(base,frame({x=1000,wall=1793736105,timer=6000})).distance,0,'warp excluded')
eq(DQTracking.measure(base,frame({x=10,z=100,wall=1793736105,timer=6000})).distance,0,'fall excluded')
eq(DQTracking.measure(base,frame({wall=1793736105,timer=6000})).distance,0,'stationary')
eq(DQTracking.measure(base,frame({x=10,duty=false,wall=1793736105,timer=6000})).duty,0,'off duty')
eq(DQTracking.measure(base,frame({x=10,job='ambulance',wall=1793736105,timer=6000})).duty,0,'job switch')
eq(DQTracking.measure(base,frame({vehicle=10,mode='drive',x=10,wall=1793736105,timer=6000})).distance,0,'boarding')
local drive=frame({vehicle=10,mode='drive'})
eq(DQTracking.measure(drive,frame({vehicle=11,mode='drive',x=10,wall=1793736105,timer=6000})).distance,0,'vehicle switch')
eq(DQTracking.measure(drive,frame({vehicle=10,mode=false,x=10,wall=1793736105,timer=6000})).distance,0,'passenger')
eq(DQTracking.measure(drive,frame({vehicle=10,mode='drive',x=200,wall=1793736105,timer=6000})).distance,200)
-- A sample spanning reset apportions distance and duty into both periods.
local session={}
DQTracking.sample(session,frame({wall=1793735998,timer=1000}))
DQTracking.sample(session,frame({x=25,wall=1793736003,timer=6000}))
local drained=DQTracking.drain(session)
local totals={}
for _,entry in ipairs(drained) do totals[entry.quest.id..':'..entry.period.start]=entry.amount end
eq(totals['daily_walk:1793649600'],10)
eq(totals['daily_walk:1793736000'],15)
eq(totals['daily_duty:1793649600'],2)
eq(totals['daily_duty:1793736000'],3)
eq(totals['weekly_walk:1793563200'],25)
eq(totals['weekly_duty:1793563200'],5)
eq(#DQTracking.drain(session),0,'drain never replays an ambiguous write')
-- Fractional metres survive consecutive successful flushes.
session={}
DQTracking.sample(session,frame())
DQTracking.sample(session,frame({x=0.6,wall=1793736105,timer=6000}))
local function sum(id,entries) local n=0;for _,v in ipairs(entries) do if v.quest.id==id then n=n+v.amount end end;return n end
eq(sum('daily_walk',DQTracking.drain(session)),0)
DQTracking.sample(session,frame({x=1.2,wall=1793736110,timer=11000}))
eq(sum('daily_walk',DQTracking.drain(session)),1)
-- Runtime server-native adapter: classify only the driver's car or configured bicycle.
local vehicle,seat,model,vehicleType,health,ped,bucket=0,1,100,'automobile',200,1,0
GetPlayerPed=function() return ped end
DoesEntityExist=function() return true end
GetEntityCoords=function() return {x=1,y=2,z=30} end
GetEntityHealth=function() return health end
GetVehiclePedIsIn=function() return vehicle end
GetPedInVehicleSeat=function(_,index) eq(index,-1);return seat end
GetHashKey=function(name) return name=='bmx' and 100 or 200 end
GetEntityModel=function() return model end
GetVehicleType=function() return vehicleType end
GetPlayerRoutingBucket=function() return bucket end
GetGameTimer=function() return 1000 end
local data={job={name='police',onduty=true},metadata={}}
eq(DQTracking.frame(1,data).mode,'walk')
vehicle=10;eq(DQTracking.frame(1,data).mode,'cycle')
model=999;eq(DQTracking.frame(1,data).mode,'drive')
seat=2;eq(DQTracking.frame(1,data).mode,nil)
seat=1;vehicleType='bike';eq(DQTracking.frame(1,data).mode,nil,'motorbike excluded')
vehicleType='plane';eq(DQTracking.frame(1,data).mode,nil,'plane excluded')
data.job.name='unemployed';eq(DQTracking.frame(1,data).duty,false)
data.job.name='police';data.job.onduty=false;eq(DQTracking.frame(1,data).duty,false)
data.metadata.isdead=true;eq(DQTracking.frame(1,data).alive,false)
data.metadata.isdead=false;health=0;eq(DQTracking.frame(1,data).alive,false)
ped=0;eq(DQTracking.frame(1,data),nil)
print(('tracking: %d assertions passed'):format(count))
