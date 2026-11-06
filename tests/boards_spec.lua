dofile('config.lua')
dofile('server/domain.lua')
dofile('server/selection.lua')
dofile('server/store.lua')
dofile('server/boards.lua')
local S=DQStore
S.bootId='unit'
local count,transactions,boardReads,assignmentReads=0,0,0,0
local function eq(a,b,label) count=count+1;assert(a==b,(label or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local now=1793736100
local defs=DQ.validate(Config)
local prefs={crime=true,employment=true}
local data={job={name='unemployed',grade=0}}
local period=DQ.period('daily',now,Config.Reset)
local boards={daily={period_start=period.start,ends_at=period.finish,rerolls_used=0}}
local assignments={}
local row={status='active',progress=0,target=3}
MySQL={
    query={await=function(sql)
        if sql==S.sql.boards then
            boardReads=boardReads+1
            local rows={}
            for kind,board in pairs(boards) do
                local copy={period_kind=kind}
                for key,value in pairs(board) do copy[key]=value end
                rows[#rows+1]=copy
            end
            return rows
        end
        if sql==S.sql.assignments then assignmentReads=assignmentReads+1;return assignments end
        return {}
    end},
    transaction={await=function() transactions=transactions+1;return true end},
    update={await=function() return 0 end},
}
S.row=function() return row end
for slot,q in ipairs(Config.Quests) do
    if q.period=='daily' then
        assignments[#assignments+1]={quest_id=q.id,slot=slot,period_kind='daily',period_start=period.start,active=1,assigned_at=now}
    end
end
local ok,err=S.reroll('ONE',defs.daily_meals,prefs,data,function() return 'started' end,now,defs)
eq(ok,false);eq(err,'no_candidates');eq(transactions,0,'no candidate does not reserve allowance')
for _,status in ipairs({'claimed','pending'}) do
    row.status=status
    ok,err=S.reroll('ONE',defs.daily_meals,prefs,data,function() return 'started' end,now,defs)
    eq(err,'reroll_completed');eq(transactions,0)
end
row.status='active';row.progress=3
ok,err=S.reroll('ONE',defs.daily_meals,prefs,data,function() return 'started' end,now,defs)
eq(err,'reroll_completed');eq(transactions,0)
row.progress=0;boards.daily.rerolls_used=1
ok,err=S.reroll('ONE',defs.daily_meals,prefs,data,function() return 'started' end,now,defs)
eq(err,'reroll_used');eq(transactions,0)
boards.daily.rerolls_used=0;assignments={}
ok,err=S.reroll('ONE',defs.daily_meals,prefs,data,function() return 'started' end,now,defs)
eq(err,'not_assigned');eq(transactions,0)
boards.weekly={period_start=DQ.period('weekly',now,Config.Reset).start,ends_at=now+86400,rerolls_used=1}
local previousBoards,previousAssignments=boardReads,assignmentReads
eq(S.ensureBoards('ONE',prefs,data,function() return 'missing' end,now),true)
eq(boardReads-previousBoards,1,'existing boards require only one lookup')
eq(assignmentReads,previousAssignments,'ensureBoards does not fetch unused assignments')
eq(transactions,0,'stored boards survive resource shutdown and preference changes')
-- Partial availability cannot create half a new board.
boards={}
local original=Config.Quests
Config.Quests={defs.daily_meals,defs.weekly_meals}
ok,err=S.ensureBoards('ONE',prefs,data,function() return 'started' end,now)
eq(ok,false);eq(err,'no_candidates');eq(transactions,0)
Config.Quests=original
-- A successful reroll reloads assignments without repeating the board lookup.
boards={daily={period_start=period.start,ends_at=period.finish,rerolls_used=0}}
assignments={{quest_id='daily_time',slot=1,period_kind='daily',period_start=period.start,active=1,assigned_at=now}}
MySQL.transaction.await=function(queries)
    transactions=transactions+1
    for _,entry in ipairs(queries) do
        if entry.query==S.sql.assign then
            local v=entry.values
            assignments[1].active=0
            assignments[2]={quest_id=v[1],slot=v[2],assigned_at=v[3],assigned_token=v[4],
                period_kind=v[6],period_start=v[7],active=1}
        end
    end
    boards.daily.rerolls_used=1
    return true
end
previousBoards,previousAssignments=boardReads,assignmentReads
ok,err=S.reroll('ONE',defs.daily_time,prefs,data,function() return 'started' end,now,defs)
eq(ok,true);eq(err,assignments[2].quest_id)
eq(boardReads-previousBoards,1,'reroll does not reload unused boards')
eq(assignmentReads-previousAssignments,2,'reroll reads assignments before and after its transaction')
print(('boards: %d assertions passed'):format(count))
