-- Export the actual store queries and transaction plans for the isolated DB test.
dofile('config.lua')
dofile('server/domain.lua')
Config.Activities.delivery={resources={['delivery-job']=true},maxAmount=1}
for _,period in ipairs({'daily','weekly'}) do
    Config.Quests[#Config.Quests+1]={
        id=period..'_delivery',period=period,metric='activity',activity='delivery',target=3,
        title='delivery',description='delivery',reward={type='item',name='water',amount=2},
    }
end
dofile('server/store.lua')
local plans, selected = {}, nil
MySQL={transaction={await=function(queries) plans[selected]=queries;return true end}}
local function plan(name,fn) selected=name;fn() end
local now=1793736100
plan('open',function() DQStore.open('SQLTEST',now) end)
plan('next_day',function() DQStore.open('SQLTEST',now+86400) end)
plan('next_week',function() DQStore.open('SQLTEST',now+604800) end)
plan('consume',function() DQStore.consume('SQLTEST',now) end)
plan('activity',function() DQStore.activity('SQLTEST','delivery','delivery-1',1,now) end)
plan('repeat_next_week',function() DQStore.activity('SQLTEST','delivery','delivery-1',1,now+604800) end)
plan('new_next_week',function() DQStore.activity('SQLTEST','delivery','delivery-2',1,now+604800) end)
plan('time',function() DQStore.addTime('SQLTEST',1793822393,1793822408) end)

DQStore.bootId='test-boot'
plan('gate_open',function() DQStore.open('GATES',now) end)
for activity in pairs(Config.Activities) do
    if Config.Activities[activity].signal then
        plan('signal_'..activity,function() DQStore.signal('GATES',activity,now) end)
    end
end
plan('signal_duplicate',function() DQStore.signal('GATES','bus',now+1) end)
DQStore.bootId='new-boot'
plan('signal_restarted',function() DQStore.signal('GATES','bus',now+2) end)
plan('signal_later',function() DQStore.signal('GATES','bus',now+30) end)
plan('signal_rollback',function() DQStore.signal('GATES','garbage',now+30) end)
local boundary=DQ.period('daily',now,Config.Reset).finish
plan('signal_before_reset',function() DQStore.signal('GATES','bus',boundary-5) end)
plan('gate_next_day',function() DQStore.open('GATES',boundary+5) end)
plan('signal_after_reset',function() DQStore.signal('GATES','bus',boundary+5) end)
plan('signal_after_cooldown',function() DQStore.signal('GATES','bus',boundary+30) end)
dofile('server/tracking.lua')
local tracked={}
DQTracking.sample(tracked,{ped=1,vehicle=0,bucket=0,x=0,y=0,z=30,mode='walk',alive=true,duty=true,job='police',wall=boundary-2,timer=1000})
DQTracking.sample(tracked,{ped=1,vehicle=0,bucket=0,x=25,y=0,z=30,mode='walk',alive=true,duty=true,job='police',wall=boundary+3,timer=6000})
plan('tracked',function() DQStore.tracked('SQLTEST',DQTracking.drain(tracked)) end)
local function encode(v)
    if type(v)=='number' then return tostring(v) end
    if type(v)=='string' then
        return '"'..v:gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n'):gsub('\r','\\r'):gsub('\t','\\t')..'"'
    end
    if type(v)=='table' then
        local values={}
        if #v>0 then
            for _,item in ipairs(v) do values[#values+1]=encode(item) end
            return '['..table.concat(values,',')..']'
        end
        for k,item in pairs(v) do values[#values+1]=encode(k)..':'..encode(item) end
        return '{'..table.concat(values,',')..'}'
    end
    error('unsupported type')
end
io.write(encode({sql=DQStore.sql,plans=plans}))
