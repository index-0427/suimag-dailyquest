local checks=0
local function eq(a,b,label)checks=checks+1;assert(a==b,(label or '')..': '..tostring(a)..' ~= '..tostring(b))end
local clock, occupied, passenger, blip, ground, collision, network, valid = 0,0,0,true,true,true,true,true
local positions={[1]={x=10,y=20,z=30},[5]={x=10,y=20,z=30}}
local frozen,events,warps,fadeIns={}, {},0,0
local externalFadeUntil,exitAt=0,nil
GetGameTimer=function()return clock end
Wait=function(ms)clock=clock+ms;if exitAt and clock>=exitAt then positions[1]={x=111,y=222,z=30};exitAt=nil end end
PlayerPedId=function()return 1 end
GetVehiclePedIsIn=function()return occupied end
GetPedInVehicleSeat=function(_,seat)return seat==-1 and 1 or passenger end
GetVehicleMaxNumberOfPassengers=function()return 1 end
IsPedAPlayer=function(id)return id==2 end
GetFirstBlipInfoId=function()return 8 end
DoesBlipExist=function()return blip end
GetBlipInfoIdCoord=function()return {x=100,y=200} end
GetEntityHeading=function()return 90 end
GetEntityCoords=function(id)local c=positions[id];return {x=c.x,y=c.y,z=c.z} end
DoesEntityExist=function(id)return positions[id]~=nil end
FreezeEntityPosition=function(id,value)frozen[id]=value end
DoScreenFadeOut=function()end
DoScreenFadeIn=function()fadeIns=fadeIns+1 end
IsScreenFadedOut=function()return true end
IsScreenFadedIn=function()return clock>=externalFadeUntil end
SetEntityCoords=function(id,x,y,z)positions[id]={x=x,y=y,z=z} end
SetEntityHeading=function()end
RequestCollisionAtCoord=function()end
GetGroundZFor_3dCoord=function()return ground,15 end
HasCollisionLoadedAroundEntity=function()return collision end
NetworkDoesEntityExistWithNetworkId=function()return network end
NetToVeh=function()return 5 end
SetVehicleOnGroundProperly=function()end
SetVehicleDoorsLocked=function()end
SetVehicleFuelLevel=function(_,amount)eq(amount,100)end
TaskWarpPedIntoVehicle=function()occupied=5;warps=warps+1 end
TriggerEvent=function(name)events[#events+1]=name end
dofile('client/preparations.lua')
local T=DQDebugTravel
local function alive()return valid end
local ok,err=T.move({coords={20,30,40,0}},alive)
eq(ok,true);eq(positions[1].x,20);eq(frozen[1],false)
collision=false
ok,err=T.move({coords={50,60,70,0}},alive)
eq(ok,false);eq(err,'travel_failed');eq(positions[1].x,20,'failed collision load restores position');eq(frozen[1],false)
collision=true
blip=false
ok,err=T.move({waypoint=true},alive);eq(ok,false);eq(err,'no_waypoint')
blip=true;ground=false
ok=T.move({waypoint=true},alive);eq(ok,false);eq(positions[1].x,20)
ground=true
ok=T.move({waypoint=true},alive);eq(ok,true);eq(positions[1].x,100);eq(positions[1].z,16)
occupied=5;passenger=2
ok,err=T.move({waypoint=true},alive);eq(ok,false);eq(err,'other_passengers')
passenger=3
ok=T.move({waypoint=true},alive);eq(ok,true,'NPC passengers can travel with the driver')
occupied=0;passenger=0;network=false
ok=T.move({coords={400,500,30,0},vehicle=177},alive);eq(ok,false);eq(positions[1].x,100);eq(warps,0)
network=true
ok=T.move({coords={400,500,30,0},vehicle=177},alive);eq(ok,true);eq(warps,1);eq(occupied,5)
occupied=0
valid=false
ok,err=T.move({coords={900,900,30,0}},alive);eq(ok,false);eq(err,'cancelled');eq(frozen[1],false)
valid=true
T.move({open='boosting'},alive);eq(events[#events],'gg_boosting:client:open_tablet')
T.frozen=1;T.origin={x=10,y=20,z=30};frozen[1]=true;T.busy=true
T.cancel(true);eq(positions[1].x,10);eq(frozen[1],false);eq(T.busy,false)
local fadesBefore=fadeIns
T.frozen=999
T.cancel(true)
eq(fadeIns,fadesBefore+1,'stopping after entity deletion still clears the fade')
externalFadeUntil=clock+150;exitAt=externalFadeUntil;collision=false
ok=T.move({coords={900,900,30,0}},alive)
eq(ok,false);eq(positions[1].x,111,'rollback captures position after normal house exit')
collision=true
local conditionCalls,conditionAllowed,conditionReason,conditionFail=0,true,nil,false
lib={callback={await=function(name,delay,houseId)
    eq(name,'satou_houserobbery:canStart');eq(delay,false);eq(houseId,2)
    conditionCalls=conditionCalls+1
    if conditionFail then error('unavailable') end
    return conditionAllowed,conditionReason
end}}
local condition=T.checkHouse(2,alive);eq(condition.allowed,true)
conditionAllowed,conditionReason=false,'警察の人数が不足している(0/1人)'
condition=T.checkHouse(2,alive);eq(condition.allowed,false);eq(condition.message,conditionReason)
conditionReason='この家は最近荒らされたばかりだ'
condition=T.checkHouse(2,alive);eq(condition.message,conditionReason)
conditionFail=true
condition=T.checkHouse(2,alive);eq(condition.allowed,nil)
valid=false;eq(T.checkHouse(2,alive),nil);eq(conditionCalls,4,'cancelled checks make no request')
eq(#events,1,'condition checks never start or complete robberies')
print(('preparation client: %d assertions passed'):format(checks))
