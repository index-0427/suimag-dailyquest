dofile('config.lua')
dofile('server/domain.lua')
dofile('server/store.lua')
dofile('server/bonuses.lua')
dofile('server/settlement.lua')
local now=1793736100
local saved,updates
os.time=function() return now end
MySQL={
    update={await=function(sql,values)
        assert(sql==DQStore.sql.initSettlement)
        updates=(updates or 0)+1
        saved=saved or values[1]
        return 1
    end},
    scalar={await=function(sql) assert(sql==DQStore.sql.settlementStart);return saved end},
}
DQStore.initSettlement()
assert(DQStore.settlementAfter==1793822400)
now=now+86400*3
DQStore.initSettlement()
assert(DQStore.settlementAfter==1793822400 and updates==2)
saved=nil
DQStore.initSettlement()
assert(DQStore.settlementAfter==DQ.period('daily',now,Config.Reset).finish)
print('settlement: activation begins at next reset and survives resource restarts')
