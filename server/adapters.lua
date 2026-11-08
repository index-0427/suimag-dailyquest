-- Observes existing local server events. It neither replaces handlers nor cancels them.
-- All source-resource checks happen before an await; no network progress endpoints.
local credits = {}

local function identity(source)
    return DQRuntime.identity(tonumber(source))
end

AddEventHandler('QBCore:Server:OnMoneyChange', function(source, account, amount, operation, reason)
    if GetInvokingResource() ~= 'qbx_core' or operation ~= 'add'
        or (account ~= 'cash' and account ~= 'bank') or not DQ.integer(amount, 1, 1000000000) then return end
    if type(reason) == 'string' and reason:sub(1, 11) == 'dailyquest:' then return end
    local cid = identity(source)
    if not cid then return end
    local now, queue = GetGameTimer(), credits[source] or {}
    local fresh = {}
    for _, credit in ipairs(queue) do
        if credit.cid == cid and now >= credit.at and now - credit.at <= 2000 then fresh[#fresh+1] = credit end
    end
    fresh[#fresh+1] = { cid=cid, amount=amount, reason=reason, at=now }
    if #fresh > 16 then table.remove(fresh, 1) end
    credits[source] = fresh
end)

local function takeCredit(source, cid, amount, rule)
    local queue = credits[source] or {}
    local now = GetGameTimer()
    for i = #queue, 1, -1 do
        local credit = queue[i]
        if credit.cid == cid and credit.amount == amount and now >= credit.at and now - credit.at <= 2000
            and (not rule.reasons or rule.reasons[credit.reason]) then
            table.remove(queue, i)
            return true
        end
    end
    return false
end

local function findRule(signal, caller)
    if not caller then return end
    for activity, rule in pairs(Config.Activities) do
        if rule.signal == signal and rule.resource == caller
            and DQ.activityAvailable(rule, GetResourceState) then return activity, rule end
    end
end

AddEventHandler('pv_poe:job:complete', function(source, job, amount)
    local caller = GetInvokingResource()
    local activity, rule = findRule('job', caller)
    if not rule or job ~= caller or not DQ.integer(source, 1) then return end
    local cid = identity(source)
    if not cid then return end
    if rule.payment then
        -- Qbox rounds positive payouts before its money event; the legacy job may send the unrounded amount.
        if type(amount) ~= 'number' or amount ~= amount or amount < 0.5 or amount > 1000000000 then return end
        if not takeCredit(source, cid, math.floor(amount + 0.5), rule) then return end
    end
    DQRuntime.signal(source, cid, activity)
end)

local function simple(signal, source)
    local activity = findRule(signal, GetInvokingResource())
    if not activity or not DQ.integer(source, 1) then return end
    local cid = identity(source)
    if cid then DQRuntime.signal(source, cid, activity) end
end

-- These notifications are emitted by the job resource itself, even with skybp_events stopped.
AddEventHandler('skybp:mining:done', function(source) simple('recycle', source) end)
AddEventHandler('skybp:boostComplete', function(source) simple('boosting', source) end)

AddEventHandler('satou_houserobbery:server:completed', function(houseId, tier, host, members)
    local activity = findRule('house', GetInvokingResource())
    if not activity or type(members) ~= 'table' or #members > 128
        or (type(houseId) ~= 'number' and type(houseId) ~= 'string') then return end
    local identities = {}
    -- Bind all participants before the first DB yield; source IDs can be reused on disconnect.
    for _, source in ipairs(members) do
        if DQ.integer(source, 1) and not identities[source] then identities[source] = identity(source) end
    end
    for source, cid in pairs(identities) do DQRuntime.signal(source, cid, activity) end
end)

AddEventHandler('lunar_contracts:heistCompleted', function(contractIndex, contractName, owner, members)
    local activity = findRule('cargo', GetInvokingResource())
    if not activity or contractName ~= 'cargo' or not DQ.integer(contractIndex, 0)
        or type(members) ~= 'table' or #members > 128 then return end
    local identities = {}
    -- Lunar sends citizenids; resolve every connected participant before the first DB yield.
    for _, cid in ipairs(members) do
        if DQ.identifier(cid) then
            local player = exports.qbx_core:GetPlayerByCitizenId(cid)
            local sourceId = player and player.PlayerData and player.PlayerData.source
            if DQ.integer(sourceId, 1) and identity(sourceId) == cid then identities[sourceId] = cid end
        end
    end
    for sourceId, cid in pairs(identities) do DQRuntime.signal(sourceId, cid, activity) end
end)

-- The installed inventory bridge reports successful grants, with the original resource and recipient.
AddEventHandler('satou_logging:inventory', function(op)
    if GetInvokingResource() ~= 'ox_inventory' or type(op) ~= 'table' or op.action ~= 'add' then return end
    local activity, rule = findRule('loot', op.resource)
    if not rule or type(op.actor) ~= 'table' or not DQ.integer(op.actor.src, 1)
        or type(op.parts) ~= 'table' or #op.parts ~= 1 then return end
    local sourceId = op.actor.src
    local cid = identity(sourceId)
    if not cid or op.actor.cid ~= cid then return end
    local part = op.parts[1]
    if type(part) ~= 'table' or part.from ~= nil or type(part.to) ~= 'table'
        or part.to.type ~= 'player' or part.to.owner ~= cid
        or type(part.rows) ~= 'table' or #part.rows > 128 then return end
    for _, row in ipairs(part.rows) do
        if type(row) == 'table' and row.item == rule.item and DQ.integer(row.count, 1, 1000000000) then
            DQRuntime.signal(sourceId, cid, activity)
            return
        end
    end
end)

local function clear(sourceId)
    sourceId = tonumber(sourceId)
    if sourceId then credits[sourceId] = nil end
end
AddEventHandler('playerDropped', function() clear(source) end)
AddEventHandler('QBCore:Server:OnPlayerUnload', function(sourceId)
    if GetInvokingResource() == 'qbx_core' then clear(sourceId) end
end)
AddEventHandler('QBCore:Server:PlayerLoaded', function(player)
    if GetInvokingResource() == 'qbx_core' and type(player) == 'table' and player.PlayerData then clear(player.PlayerData.source) end
end)
