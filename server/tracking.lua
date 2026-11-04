DQTracking = {}
local T = DQTracking
local bicycleHashes

local function finite(n)
    return type(n) == 'number' and n == n and math.abs(n) < 10000000
end

function T.frame(source, data)
    local ped = GetPlayerPed(source)
    if ped == 0 or not DoesEntityExist(ped) then return nil end
    local coords = GetEntityCoords(ped)
    if not finite(coords.x) or not finite(coords.y) or not finite(coords.z) then return nil end
    local meta = data.metadata or {}
    local alive = not meta.isdead and not meta.inlaststand and GetEntityHealth(ped) > 0
    local vehicle = GetVehiclePedIsIn(ped, false)
    local mode
    if vehicle == 0 then
        mode = 'walk'
    elseif DoesEntityExist(vehicle) and GetPedInVehicleSeat(vehicle, -1) == ped then
        if not bicycleHashes then
            bicycleHashes = {}
            for _, model in ipairs(Config.Tracking.bicycles) do bicycleHashes[GetHashKey(model)] = true end
        end
        if bicycleHashes[GetEntityModel(vehicle)] then mode = 'cycle'
        elseif GetVehicleType(vehicle) == 'automobile' then mode = 'drive' end
    end
    local job = data.job or {}
    return {
        ped=ped, vehicle=vehicle, bucket=GetPlayerRoutingBucket(source),
        x=coords.x, y=coords.y, z=coords.z, mode=mode, alive=alive,
        duty=job.onduty == true and type(job.name) == 'string' and not Config.Tracking.excludedJobs[job.name],
        job=job.name, wall=os.time(), timer=GetGameTimer(),
    }
end

-- Pure comparison, also used by tests. No client-supplied coordinates or progress.
function T.measure(previous, frame)
    if not previous or not frame or not previous.alive or not frame.alive
        or previous.ped ~= frame.ped or previous.bucket ~= frame.bucket then return nil end
    local seconds = DQ.elapsed(previous, frame.wall, frame.timer, Config.Tracking.sampleSeconds * 2)
    if not seconds or seconds <= 0 then return nil end
    local result = { seconds=seconds, duty=0, distance=0 }
    if previous.duty and frame.duty and previous.job == frame.job then result.duty = seconds end
    if previous.mode and previous.mode == frame.mode and previous.vehicle == frame.vehicle then
        local dx, dy, dz = frame.x - previous.x, frame.y - previous.y, frame.z - previous.z
        local distance = math.sqrt(dx * dx + dy * dy)
        -- Reject implausible movement, vertical warps, seat changes and transport changes.
        if distance >= 0.5 and distance <= Config.Tracking.maxSpeed[frame.mode] * seconds
            and math.abs(dz) <= (frame.mode == 'walk' and 3 or 15) * seconds then
            result.distance, result.mode = distance, frame.mode
        end
    end
    return result
end

function T.sample(session, frame)
    local state = session.tracking or { pending={} }
    session.tracking = state
    local measurement = T.measure(state.last, frame)
    state.last = frame
    if not measurement then return end
    for _, quest in ipairs(Config.Quests) do
        local amount = 0
        if quest.metric == 'duty' then amount = measurement.duty
        elseif quest.metric == 'distance' and quest.mode == measurement.mode then amount = measurement.distance end
        if amount > 0 then
            for _, segment in ipairs(DQ.segments(quest.period, frame.wall - measurement.seconds, frame.wall, Config.Reset)) do
                local key = quest.id .. ':' .. segment.period.start
                local entry = state.pending[key] or { quest=quest, period=segment.period, amount=0 }
                entry.amount = math.min(quest.target, entry.amount + amount * segment.amount / measurement.seconds)
                state.pending[key] = entry
            end
        end
    end
    -- Drop stale fractional remainders after their period ends. Whole progress is still flushed.
    for key, entry in pairs(state.pending) do
        if entry.period.finish <= frame.wall and entry.amount < 1 then state.pending[key] = nil end
    end
end

function T.drain(session)
    local result = {}
    local state = session.tracking
    if not state then return result end
    for key, entry in pairs(state.pending) do
        local whole = math.floor(entry.amount + 0.000001)
        if whole > 0 then
            result[#result + 1] = { quest=entry.quest, period=entry.period, amount=whole }
            entry.amount = math.max(0, entry.amount - whole)
        end
        if entry.amount == 0 then state.pending[key] = nil end
    end
    -- Stable lock ordering reduces deadlock risk when different paths update the same rows.
    table.sort(result, function(a,b)
        if a.quest.id == b.quest.id then return a.period.start < b.period.start end
        return a.quest.id < b.quest.id
    end)
    return result
end
