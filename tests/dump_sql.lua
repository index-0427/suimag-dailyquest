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
