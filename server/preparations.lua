DQPreparation = {}
local P = DQPreparation
local sequence = 0

local function loaned(slot)
    local tag=type(slot)=='table' and type(slot.metadata)=='table' and slot.metadata.dailyquestTest
    return type(tag)=='string' and tag:sub(1,7)=='dqprep:'
end

exports.ox_inventory:registerHook('swapItems', function(payload)
    if payload.fromInventory~=payload.toInventory and (loaned(payload.fromSlot) or loaned(payload.toSlot)) then return false end
end)

function P.key(quest)
    return quest.activity or quest.mode or quest.metric
end

function P.describe(quest)
    local plan = DQPreparationPlans[P.key(quest)]
    if not plan then return nil end
    local available, reason = true, nil
    if quest.metric == 'activity' and not DQ.activityAvailable(Config.Activities[quest.activity], GetResourceState) then
        available, reason = false, '連携元が未起動'
    elseif plan.vehicle and plan.vehicle[2] == 'automobile' and GetResourceState('qbx_vehiclekeys') ~= 'started' then
        available, reason = false, '車両キー連携が未起動'
    end
    return {label=plan.label,help=plan.help,available=available,reason=reason}
end

local function playerFor(session)
    local player = exports.qbx_core:GetPlayer(session.source)
    return player and not player.Offline and player.PlayerData.source == session.source
        and player.PlayerData.citizenid == session.citizenid and player or nil
end

local function clearSamples(session)
    if session.tracking then session.tracking.last = nil end
    if session.debug and session.debug.tracking then session.debug.tracking.last = nil end
end

function P.moving(session)
    if not session.debugMovingUntil then return false end
    if os.time() > session.debugMovingUntil then
        session.debugMovingUntil,session.debugMoveId=nil,nil
        if session.preparation then session.preparation.failed=true end
        clearSamples(session)
        return false
    end
    return true
end

local function attempt(label, fn)
    local ok, err = pcall(fn)
    if not ok then print(('[suimag-dailyquest] Preparation cleanup %s failed: %s'):format(label,tostring(err))) end
end

function P.cleanup(session)
    local trial = session and session.preparation
    if not trial then return end
    session.preparation = nil
    session.debugMovingUntil,session.debugMoveId=nil,nil
    clearSamples(session)
    if trial.vehicle then
        attempt('vehicle', function()
            if DoesEntityExist(trial.vehicle) and Entity(trial.vehicle).state.dailyquestTest == trial.tag then
                if GetResourceState('qbx_vehiclekeys') == 'started' and playerFor(session) then
                    attempt('keys', function() exports.qbx_vehiclekeys:RemoveKeys(session.source, trial.vehicle, true) end)
                end
                DeleteEntity(trial.vehicle)
            end
        end)
    end
    -- shortcut: offline inventories need manual loan recovery; add login recovery if that becomes routine.
    local player = playerFor(session)
    if player then
        for _, item in ipairs(trial.items) do
            attempt('items', function()
                -- Partial metadata matching preserves every pre-existing item.
                exports.ox_inventory:RemoveItem(session.source,item[1],item[2],{dailyquestTest=trial.tag},nil,true,false)
            end)
        end
        local job = player.PlayerData.job
        if trial.duty and job and job.name == trial.duty.name and job.onduty == true then
            attempt('duty', function() exports.qbx_core:SetJobDuty(session.source,trial.duty.onduty) end)
        end
    end
    return trial
end

function P.precheck(session, quest)
    if session.preparation then return false, 'preparation_active' end
    local descriptor = P.describe(quest)
    if not descriptor or not descriptor.available then return false, 'prepare_unavailable' end
    local player = playerFor(session)
    local ped = GetPlayerPed(session.source)
    if not player or ped == 0 or not DoesEntityExist(ped) then return false, 'player_unavailable' end
    local meta = player.PlayerData.metadata or {}
    if meta.isdead or meta.inlaststand or GetEntityHealth(ped) <= 0 then return false, 'alive_required' end
    if GetVehiclePedIsIn(ped,false) ~= 0 then return false, 'on_foot_required' end
    if GetPlayerRoutingBucket(session.source) ~= 0 then return false, 'world_required' end
    local plan = DQPreparationPlans[P.key(quest)]
    local job = player.PlayerData.job
    if plan.vehicle then
        local c=plan.coords
        for _,vehicle in ipairs(GetAllVehicles()) do
            if DoesEntityExist(vehicle) then
                local pos=GetEntityCoords(vehicle)
                if (pos.x-c[1])^2+(pos.y-c[2])^2<16 and math.abs(pos.z-c[3])<3 then return false,'spawn_busy' end
            end
        end
    end
    if plan.duty and (not job or not job.name or Config.Tracking.excludedJobs[job.name]) then return false, 'not_employed' end
    for _, item in ipairs(plan.items or {}) do
        if not exports.ox_inventory:Items(item[1]) then return false, 'invalid_item' end
    end
    return true
end

function P.start(session, quest, valid)
    local ok, err = P.precheck(session,quest)
    if not ok then return false, err end
    local plan, source = DQPreparationPlans[P.key(quest)], session.source
    local ped = GetPlayerPed(source)
    local pos = GetEntityCoords(ped)
    local coords=plan.houses and plan.houses[1].coords or plan.coords
    sequence = sequence + 1
    local trial = {
        id=quest.id,key=P.key(quest),title=quest.title,help=plan.help,startedAt=os.time(),
        origin={pos.x,pos.y,pos.z,GetEntityHeading(ped)},items={},
        tag='dqprep:'..tostring(DQStore.bootId)..':'..sequence,
        moved=coords~=nil,houseIndex=plan.houses and 1 or nil,
    }
    session.preparation = trial
    session.debugMovingUntil,session.debugMoveId=os.time()+30,quest.id
    clearSamples(session)
    local travel = {coords=coords,open=plan.open}
    local failure = 'prepare_failed'
    local success, detail = pcall(function()
        for _, item in ipairs(plan.items or {}) do
            if not valid() then failure='forbidden';error(failure) end
            local count = math.max(0,item[2]-exports.ox_inventory:GetItemCount(source,item[1]))
            if count > 0 then
                if not exports.ox_inventory:CanCarryItem(source,item[1],count) then failure='inventory_full';error(failure) end
                if not exports.ox_inventory:AddItem(source,item[1],count,{dailyquestTest=trial.tag}) then
                    failure='inventory_full';error(failure)
                end
                trial.items[#trial.items+1]={item[1],count}
            end
        end
        if not valid() then failure='forbidden';error(failure) end
        if plan.duty then
            local job = playerFor(session).PlayerData.job
            trial.duty={name=job.name,onduty=job.onduty==true}
            exports.qbx_core:SetJobDuty(source,true)
        end
        if plan.vehicle then
            local c=plan.coords
            trial.vehicle=CreateVehicleServerSetter(GetHashKey(plan.vehicle[1]),plan.vehicle[2],c[1],c[2],c[3],c[4])
            if not trial.vehicle or trial.vehicle==0 or not DoesEntityExist(trial.vehicle) then error('vehicle unavailable') end
            Entity(trial.vehicle).state:set('dailyquestTest',trial.tag,false)
            SetEntityOrphanMode(trial.vehicle,2)
            SetEntityRoutingBucket(trial.vehicle,0)
            if plan.vehicle[2]=='automobile' then
                exports.qbx_vehiclekeys:GiveKeys(source,trial.vehicle,true)
            end
            travel.vehicle=NetworkGetNetworkIdFromEntity(trial.vehicle)
        end
        if not valid() then failure='forbidden';error(failure) end
    end)
    if not success then
        P.cleanup(session)
        print(('[suimag-dailyquest] Preparation failed: %s'):format(tostring(detail)))
        return false, failure
    end
    return true, travel
end

function P.ready(session, id, success)
    local trial=session.preparation
    if session.debugMoveId~=id or type(success)~='boolean' then return false end
    session.debugMovingUntil,session.debugMoveId=nil,nil
    if trial then trial.failed=not success end
    clearSamples(session)
    return true
end

function P.waypoint(session,id)
    local trial=session.preparation
    if not trial or trial.id~=id or trial.houseIndex then return nil end
    if GetPlayerRoutingBucket(session.source)~=0 then return nil,'world_required' end
    trial.moved,trial.failed=true,false
    session.debugMovingUntil,session.debugMoveId=os.time()+30,id
    clearSamples(session)
    return {waypoint=true}
end

function P.nextHouse(session,id)
    local trial=session.preparation
    if not trial or trial.id~=id or not trial.houseIndex then return nil,'invalid_request' end
    if GetPlayerRoutingBucket(session.source)~=0 then return nil,'exit_required' end
    local ped=GetPlayerPed(session.source)
    if ped==0 or GetVehiclePedIsIn(ped,false)~=0 then return nil,'on_foot_required' end
    local houses=DQPreparationPlans[trial.key].houses
    trial.houseIndex=trial.houseIndex % #houses+1
    trial.failed=false
    session.debugMovingUntil,session.debugMoveId=os.time()+30,id
    clearSamples(session)
    return {coords=houses[trial.houseIndex].coords}
end

function P.finish(session,id)
    local trial=session.preparation
    if not trial or trial.id~=id then return false,'invalid_request' end
    if GetPlayerRoutingBucket(session.source)~=0 then return false,'exit_required' end
    local ped=GetPlayerPed(session.source)
    if ped~=0 and GetVehiclePedIsIn(ped,false)~=0 then return false,'on_foot_required' end
    trial=P.cleanup(session)
    session.debugMovingUntil,session.debugMoveId=os.time()+30,id
    return true, trial.moved and {coords=trial.origin} or {}
end

function P.snapshot(session)
    local trial=session.preparation
    if not trial then return nil end
    local rule=Config.Activities[trial.key]
    local cooldown=0
    if rule then
        local last=tonumber(MySQL.scalar.await('SELECT last_at FROM suimag_dailyquest_signal_gates WHERE citizenid=? AND activity=?',
            {session.citizenid,trial.key}))
        if last then cooldown=math.max(0,last+rule.cooldown-os.time()) end
    end
    local house=trial.houseIndex and DQPreparationPlans[trial.key].houses[trial.houseIndex]
    return {id=trial.id,title=trial.title,help=trial.help,startedAt=trial.startedAt,cooldown=cooldown,
        houseId=house and house.id or nil,returnBlocked=GetPlayerRoutingBucket(session.source)~=0,
        moving=P.moving(session),failed=trial.failed==true,waypoint=not house}
end
