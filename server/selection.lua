DQSelection = {}
local P = DQSelection
P.disabled = {}

function P.preferences(value)
    if type(value) ~= 'table' or type(value.crime) ~= 'boolean' or type(value.employment) ~= 'boolean' then return nil end
    for key in pairs(value) do if key ~= 'crime' and key ~= 'employment' then return nil end end
    return { crime=value.crime, employment=value.employment }
end

function P.eligible(quest, prefs, data, state, now, reroll)
    if not prefs or P.disabled[quest.id] then return false end
    for tag in pairs(quest.tags or {}) do if prefs[tag] then return false end end
    local job = data.job or {}
    local employed = DQ.identifier(job.name) and not Config.Tracking.excludedJobs[job.name]
    local requirements = quest.requirements or {}
    if requirements.employed and not employed then return false end
    local grade = tonumber(type(job.grade) == 'table' and job.grade.level or job.grade) or 0
    if requirements.jobs then
        local minimum = requirements.jobs[job.name]
        if not minimum or grade < minimum then return false end
    end
    if requirements.types and not requirements.types[job.type] then return false end
    if quest.metric == 'activity' then
        local rule = Config.Activities[quest.activity]
        if not DQ.activityAvailable(rule,state) then return false end
    end
    local period = DQ.period(quest.period, now, Config.Reset)
    if quest.metric == 'attendance' then
        -- A reroll must start at zero, so do not replace it with today's already-observed login.
        if reroll then return false end
        local day = DQ.period('daily', now, Config.Reset)
        if quest.target > (period.finish - day.start) / 86400 then return false end
    elseif quest.metric == 'playtime' or quest.metric == 'duty' then
        if quest.target > period.finish - now then return false end
    end
    return true
end

function P.pick(kind, count, prefs, data, state, now, used, requireQuick, reroll, random)
    local pool, quick = {}, {}
    for _, quest in ipairs(Config.Quests) do
        if quest.period == kind and not (used or {})[quest.id] and P.eligible(quest,prefs,data,state,now,reroll) then
            pool[#pool+1] = quest
            if quest.quick then quick[#quick+1] = quest end
        end
    end
    if #pool < count or (requireQuick and #quick == 0) then return nil, 'no_candidates' end
    random = random or math.random
    local result, chosen = {}, {}
    if requireQuick then
        local first = quick[random(#quick)]
        result[1], chosen[first.id] = first, true
    end
    local remaining = {}
    for _, quest in ipairs(pool) do if not chosen[quest.id] then remaining[#remaining+1] = quest end end
    while #result < count do result[#result+1] = table.remove(remaining, random(#remaining)) end
    return result
end
