dofile('config.lua')
dofile('server/domain.lua')
local definitions=DQ.validate(Config)
local counts={daily=0,weekly=0}
local themes={daily={},weekly={}}
local supported={attendance=true,playtime=true,consume=true,distance=true,duty=true,activity=true}
local sums={daily=0,weekly=0}
for _,quest in ipairs(Config.Quests) do
    assert(quest.reward==nil,'Individual rewards are not supported')
    assert(supported[quest.metric],quest.id..': missing collector')
    local theme=quest.metric=='activity' and quest.activity or quest.metric=='distance' and quest.mode or quest.metric
    assert(not themes[quest.period][theme],quest.id..': duplicate theme')
    themes[quest.period][theme]=true
    counts[quest.period]=counts[quest.period]+1
    sums[quest.period]=sums[quest.period]+DQ.reward(quest.period).amount
    if quest.metric=='activity' then
        local rule=Config.Activities[quest.activity]
        assert(rule.signal and rule.resource,quest.id..': no automatic adapter')
    end
end
assert(counts.daily==20 and counts.weekly==20,'Expected 20 daily and 20 weekly quests')
for theme in pairs(themes.daily) do assert(themes.weekly[theme],'Missing weekly counterpart: '..theme) end
assert(definitions.daily_visit.target==1 and definitions.daily_time.target==1800 and definitions.daily_meals.target==3)
assert(definitions.weekly_visits.target==3 and definitions.weekly_time.target==10800 and definitions.weekly_meals.target==15)
assert(Config.Rewards.daily==150000 and Config.Rewards.dailyComplete==200000 and Config.Rewards.weekly==500000)
assert(Config.Draw.daily*Config.Rewards.daily+Config.Rewards.dailyComplete==650000)
assert(Config.Draw.weekly*Config.Rewards.weekly==1000000)
assert(sums.daily==3000000 and sums.weekly==10000000,'All catalog rewards are uniform')
print(('catalog: %d daily / %d weekly candidates; payout totals: daily=650000, weekly=1000000'):format(counts.daily,counts.weekly))
