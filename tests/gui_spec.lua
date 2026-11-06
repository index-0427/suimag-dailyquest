dofile('config.lua')
local commands, handlers, callbacks, threads, messages, requests = {}, {}, {}, {}, {}, {}
local clock, focused, focusCalls, delayed, notices = 10000, false, 0, false, {}
local view={ok=true, preferences={crime=true,employment=false}, rerolls={daily=1,weekly=1},
    serverNow=1000,dailyResetAt=2000,dailyReset='tomorrow',weeklyReset='monday',quests={
        {id='ready',period='daily',periodStart=123,value=1,target=1,status='active',reward='銀行 $150000'},
        {id='progress',period='daily',periodStart=123,value=0,target=1,status='active',canReroll=true,title='Walk'},
        {id='pending',period='weekly',periodStart=123,value=1,target=1,status='pending'},
    },dailyBonus={periodStart=123,canClaim=true,reward='銀行 $200000'}}
local count=0
local function eq(a,b,label) count=count+1;assert(a==b,(label or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
GetGameTimer=function() return clock end
GetCurrentResourceName=function() return 'suimag-dailyquest' end
Wait=function(ms) clock=clock+ms;coroutine.yield(ms) end
CreateThread=function(fn) threads[#threads+1]=coroutine.create(fn) end
RegisterNUICallback=function(name,fn) callbacks[name]=fn end
SendNUIMessage=function(data) messages[#messages+1]=data end
SetNuiFocus=function(mouse,keyboard) eq(mouse,keyboard);focused=mouse;focusCalls=focusCalls+1 end
RegisterCommand=function(name,fn) commands[name]=fn end
RegisterKeyMapping=function() end
RegisterNetEvent=function(name,fn) handlers[name]=fn end
AddEventHandler=function(name,fn) handlers[name]=fn end
exports=setmetatable({},{__call=function() end})
local choice='cancel'
lib={callback={await=function(name,_,...)
    requests[#requests+1]={name=name,args={...}}
    if delayed then coroutine.yield('await') end
    return name=='suimag-dailyquest:list' and view or {ok=true}
end},notify=function(data) notices[#notices+1]=data end,getOpenContextMenu=function() return nil end,
inputDialog=function() eq(focused,false,'release focus for ox_lib');return {false,true} end,
alertDialog=function() eq(focused,false,'release focus for confirmation');return choice end,
closeInputDialog=function() end,closeAlertDialog=function() end}
dofile('client/main.lua')
local function run(fn)
    local co=coroutine.create(fn)
    while coroutine.status(co)~='dead' do local ok,result=coroutine.resume(co);assert(ok,result) end
end
local function action(kind,extra)
    local data=extra or {};data.action=kind
    run(function() callbacks.questAction(data,function(r) eq(r.ok,true,'acknowledge NUI') end) end)
end
local function guiMessage()
    for i=#messages,1,-1 do if messages[i].action=='suimag-dailyquest:gui' then return messages[i] end end
end
run(commands.dailyquest)
eq(focused,false,'never capture input until the GUI is ready')
callbacks.questReady({},function() end)
eq(focused,true);eq(guiMessage().visible,true)
local before=#requests
for _,kind in ipairs({'unknown','claim','reroll'}) do action(kind,{id='forged',periodStart=999}) end
action('claim',{id='pending'});action('claim',{id='progress'})
eq(#requests,before,'unknown and ineligible actions never reach server')
action('claim',{id='ready',periodStart=999,reward=999999})
eq(requests[before+1].name,'suimag-dailyquest:claim')
eq(requests[before+1].args[2],123,'use the cached server period, ignore browser amounts and period')
eq(guiMessage().selected,'daily')
before=#requests;action('bonus');eq(requests[before+1].name,'suimag-dailyquest:claimBonus')
eq(requests[before+1].args[1],123)
before=#requests;action('reroll',{id='progress'})
eq(#requests,before+1,'cancel only refreshes the board')
choice='confirm';before=#requests;action('reroll',{id='progress'})
eq(requests[before+1].name,'suimag-dailyquest:reroll');eq(focused,true)
before=#requests;action('preferences')
eq(requests[before+1].args[1].crime,false);eq(requests[before+1].args[1].employment,true)
eq(focused,true,'restore board focus after preference dialog')
-- Close while a server reply is pending: no reopening or lock corruption.
clock=clock+2000;delayed=true
local old=coroutine.create(function() callbacks.questAction({action='refresh'},function() end) end)
local ok,result=coroutine.resume(old);assert(ok,result);eq(result,'await')
before=#requests;action('claim',{id='ready'});eq(#requests,before,'suppress duplicate actions')
action('close');eq(focused,false);eq(guiMessage().visible,false)
delayed=false;ok,result=coroutine.resume(old);assert(ok,result)
eq(guiMessage().visible,false,'stale refresh cannot reopen closed GUI')
before=focusCalls;handlers['QBCore:Client:OnPlayerUnload']()
eq(focusCalls,before,'do not release another resource focus when already closed')
-- Expiry refresh runs with no ox_lib context menu at all.
view.serverNow=2000;view.dailyResetAt=2000
run(commands.dailyquest)
local function tick() local success,value=coroutine.resume(threads[1]);assert(success,value);return value end
tick();clock=clock+6000;tick()
eq(guiMessage().visible,true,'automatic refresh stays in GUI without nil-context crash')
-- An in-flight automatic refresh is invalidated by character unload.
delayed=true;clock=clock+6000
repeat result=tick() until result=='await'
handlers['QBCore:Client:OnPlayerUnload']();delayed=false;tick()
eq(guiMessage().visible,false);eq(focused,false)
run(commands.dailyquest);handlers.onResourceStop('other-resource');eq(focused,true)
handlers.onResourceStop('suimag-dailyquest');eq(focused,false)
io.write(('gui: %d assertions passed\n'):format(count))
