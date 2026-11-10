DQDebugTravel = { busy=false }
local T=DQDebugTravel
function T.cancel(restore)
    local wasMoving=T.frozen~=nil
    if T.frozen and DoesEntityExist(T.frozen) then
        if restore and T.origin then
            local c=T.origin
            SetEntityCoords(T.frozen,c.x,c.y,c.z,false,false,false,false)
        end
        FreezeEntityPosition(T.frozen,false)
    end
    if wasMoving then DoScreenFadeIn(0) end
    T.frozen,T.origin,T.busy=nil,nil,false
end

-- This existing callback checks normal conditions; it never starts or completes a robbery.
function T.checkHouse(houseId, valid)
    if not valid() then return nil end
    local ok,allowed,reason=pcall(lib.callback.await,'satou_houserobbery:canStart',false,houseId)
    if not valid() then return nil end
    if not ok or type(allowed)~='boolean' then
        return {message='開始条件を取得できませんでした。結果確認で再試行してください。'}
    end
    return {allowed=allowed,message=allowed and '通常の開始条件を満たしています。玄関から解錠してください。'
        or type(reason)=='string' and reason or '現在は開始できません。'}
end

-- Every destination comes from an authorized server response, or the admin's explicit waypoint action.
function T.move(plan, valid)
    if not plan.coords and not plan.waypoint then
        if plan.open=='boosting' and valid() then TriggerEvent('gg_boosting:client:open_tablet') end
        local ok=valid()
        return ok,not ok and 'cancelled' or nil
    end
    local ped=PlayerPedId()
    local entity=ped
    local occupied=GetVehiclePedIsIn(ped,false)
    if occupied~=0 then
        if not plan.waypoint or GetPedInVehicleSeat(occupied,-1)~=ped then return false,'on_foot_required' end
        for seat=-1,GetVehicleMaxNumberOfPassengers(occupied)-1 do
            local passenger=GetPedInVehicleSeat(occupied,seat)
            if passenger~=0 and passenger~=ped and IsPedAPlayer(passenger) then return false,'other_passengers' end
        end
        entity=occupied
    end
    local target=plan.coords
    if plan.waypoint then
        local blip=GetFirstBlipInfoId(8)
        if not DoesBlipExist(blip) then return false,'no_waypoint' end
        local c=GetBlipInfoIdCoord(blip)
        target={c.x,c.y,0.0,GetEntityHeading(entity)}
    end
    local deadline=GetGameTimer()+10000
    local function waitFor(test)
        while valid() and GetGameTimer()<deadline do
            if test() then return true end
            Wait(50)
        end
        return false
    end
    -- Let the normal house exit finish its own fade and teleport before starting ours.
    if not waitFor(IsScreenFadedIn) then return false,valid() and 'travel_failed' or 'cancelled' end
    if not DoesEntityExist(entity) then return false,'travel_failed' end
    local origin=GetEntityCoords(entity)
    local heading=GetEntityHeading(entity)
    T.frozen,T.origin=entity,origin
    FreezeEntityPosition(entity,true)
    DoScreenFadeOut(200)
    local ok,err=pcall(function()
        if not waitFor(IsScreenFadedOut) then error('cancelled') end
        if plan.waypoint then
            local found=false
            for height=1000,0,-50 do
                if not valid() then error('cancelled') end
                SetEntityCoords(entity,target[1],target[2],height,false,false,false,false)
                RequestCollisionAtCoord(target[1],target[2],height)
                Wait(100)
                local ground,z=GetGroundZFor_3dCoord(target[1],target[2],height,false)
                if ground then target[3]=z+1.0;found=true;break end
            end
            if not found then error('travel_failed') end
        end
        if not valid() then error('cancelled') end
        RequestCollisionAtCoord(target[1],target[2],target[3])
        SetEntityCoords(entity,target[1],target[2],target[3],false,false,false,false)
        SetEntityHeading(entity,target[4] or heading)
        if not waitFor(function() return HasCollisionLoadedAroundEntity(ped) end) then error('travel_failed') end
        if plan.vehicle then
            if not waitFor(function() return NetworkDoesEntityExistWithNetworkId(plan.vehicle) end) then error('travel_failed') end
            local vehicle=NetToVeh(plan.vehicle)
            if vehicle==0 then error('travel_failed') end
            SetVehicleOnGroundProperly(vehicle)
            SetVehicleDoorsLocked(vehicle,1)
            SetVehicleFuelLevel(vehicle,100.0)
            TaskWarpPedIntoVehicle(ped,vehicle,-1)
            if not waitFor(function() return GetVehiclePedIsIn(ped,false)==vehicle end) then error('travel_failed') end
        end
    end)
    if not ok and valid() and DoesEntityExist(entity) then
        SetEntityCoords(entity,origin.x,origin.y,origin.z,false,false,false,false)
        SetEntityHeading(entity,heading)
    end
    if DoesEntityExist(entity) then FreezeEntityPosition(entity,false) end
    if T.frozen==entity then T.frozen,T.origin=nil,nil end
    DoScreenFadeIn(200)
    if not valid() then return false,'cancelled' end
    return ok,ok and nil or 'travel_failed'
end
