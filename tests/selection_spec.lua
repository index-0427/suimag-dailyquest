dofile('config.lua')
dofile('server/domain.lua')
dofile('server/selection.lua')
local P=DQSelection
local count=0
local function eq(a,b,label) count=count+1;assert(a==b,(label or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local defs=DQ.validate(Config)
local now=1793736100
local all=function() return 'started' end
local none=function() return 'missing' end
local unemployed={job={name='unemployed',grade={level=0}}}
local police={job={name='police',type='leo',grade={level=2}}}
eq(P.preferences({crime=true,employment=false}).crime,true)
for _,invalid in ipairs({{}, {crime=1,employment=false},{crime=false,employment=true,extra=true},'bad'}) do eq(P.preferences(invalid),nil) end
eq(P.eligible(defs.daily_house,{crime=true,employment=false},police,all,now),false)
eq(P.eligible(defs.daily_duty,{crime=false,employment=false},unemployed,all,now),false)
eq(P.eligible(defs.daily_duty,{crime=false,employment=true},police,all,now),false)
eq(P.eligible(defs.daily_duty,{crime=false,employment=false},police,all,now),true)
eq(P.eligible(defs.daily_bus,{crime=false,employment=true},unemployed,all,now),true,'public work is not employment-only')
eq(P.eligible(defs.daily_bus,{crime=false,employment=false},police,none,now),false)
local custom={period='daily',metric='duty',target=60,tags={employment=true},requirements={jobs={police=2},types={leo=true}}}
eq(P.eligible(custom,{crime=false,employment=false},police,all,now),true)
eq(P.eligible(custom,{crime=false,employment=false},{job={name='police',type='leo',grade={level=1}}},all,now),false)
eq(P.eligible(custom,{crime=false,employment=false},{job={name='mechanic',type='mechanic',grade={level=5}}},all,now),false)
for seed=1,300 do
    math.randomseed(seed)
    for _,prefs in ipairs({{crime=false,employment=false},{crime=true,employment=false},{crime=true,employment=true}}) do
        for _,data in ipairs({unemployed,police}) do
            for _,state in ipairs({all,none}) do
                local day=P.pick('daily',3,prefs,data,state,now,{},true,false)
                local week=P.pick('weekly',2,prefs,data,state,now,{},false,false)
                eq(#day,3);eq(#week,2)
                local seen,quick={},false
                for _,quest in ipairs(day) do
                    eq(seen[quest.id],nil);seen[quest.id]=true
                    eq(P.eligible(quest,prefs,data,state,now),true)
                    quick=quick or quest.quick
                end
                eq(quick,true)
                for _,quest in ipairs(week) do
                    eq(seen[quest.id],nil);seen[quest.id]=true
                    eq(P.eligible(quest,prefs,data,state,now),true)
                end
            end
        end
    end
end
local replacement=P.pick('daily',1,{crime=true,employment=true},unemployed,none,now,
    {daily_meals=true,daily_walk=true,daily_time=true},true,true)
eq(#replacement,1);eq(replacement[1].id,'daily_cycle','preserve sole quick slot')
local no,err=P.pick('daily',1,{crime=true,employment=true},unemployed,none,now,
    {daily_meals=true,daily_walk=true,daily_cycle=true},true,true)
eq(no,nil);eq(err,'no_candidates','no fallback that violates exclusions')
eq(P.eligible(defs.daily_visit,{crime=false,employment=false},police,all,now,true),false,'reroll cannot count an earlier login')
local sunday=DQ.period('weekly',now,Config.Reset).finish-3600
eq(P.eligible(defs.weekly_visits,{crime=false,employment=false},police,all,sunday),false,'not enough remaining days')
eq(P.eligible(defs.weekly_time,{crime=false,employment=false},police,all,sunday),false,'not enough remaining time')
print(('selection: %d assertions passed'):format(count))
