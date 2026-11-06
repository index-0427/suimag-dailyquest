dofile('config.lua')
local commands, handlers, callbacks, threads, messages, requests = {}, {}, {}, {}, {}, {}
local clock, focused, focusCalls, delayed, notices = 10000, false, 0, false, {}
local view={ok=true, preferences={crime=true,employment=false}, rerolls={daily=1,weekly=1},
    serverNow=1000,dailyResetAt=2000,dailyReset='tomorrow',weeklyReset='monday',quests={
        {id='ready',period='daily',periodStart=123,value=1,target=1,status='active',reward='銀行 $150000 + 黒コイン × 1'},
        {id='progress',period='daily',periodStart=123,value=0,target=1,status='active',canReroll=true,title='Walk'},
        {id='pending',period='weekly',periodStart=123,value=1,target=1,status='pending'},
    },dailyBonus={periodStart=123,canClaim=true,reward='銀行 $200000'}}
local count=0
local function eq(a,b,label) count=count+1;assert(a==b,(label or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local exposed, registeredKey={}
GetGameTimer=function() return clock end
GetCurrentResourceName=function() return 'suimag-dailyquest' end
Wait=function(ms) clock=clock+ms;coroutine.yield(ms) end
CreateThread=function(fn) threads[#threads+1]=coroutine.create(fn) end
RegisterNUICallback=function(name,fn) callbacks[name]=fn end
SendNUIMessage=function(data) messages[#messages+1]=data end
SetNuiFocus=function(mouse,keyboard) eq(mouse,keyboard);focused=mouse;focusCalls=focusCalls+1 end
RegisterCommand=function(name,fn) commands[name]=fn end
RegisterKeyMapping=function(_,_,_,key) registeredKey=key end
RegisterNetEvent=function(name,fn) handlers[name]=fn end
AddEventHandler=function(name,fn) handlers[name]=fn end
exports=setmetatable({},{__call=function(_,name,fn) exposed[name]=fn end})
local choice, dialogDelayed, alertClosed='cancel', false, 0
local responseMode='ok'
lib={callback={await=function(name,_,...)
    requests[#requests+1]={name=name,args={...}}
    if delayed then coroutine.yield('await') end
    if responseMode=='throw' then error('timeout') end
    if responseMode=='nil' then return nil end
    if responseMode=='not_ready' then return {ok=false,error='not_ready'} end
    if responseMode=='pending' and name=='suimag-dailyquest:claim' then return {ok=false,error='pending',claimId=42} end
    if name=='suimag-dailyquest:preferences' then view.preferences=({...})[1];view.needsSetup=false end
    return name=='suimag-dailyquest:list' and view or {ok=true}
end},notify=function(data) notices[#notices+1]=data end,
alertDialog=function()
    eq(focused,false,'release focus for confirmation')
    if dialogDelayed then coroutine.yield('dialog') end
    return choice
end,
closeAlertDialog=function() alertClosed=alertClosed+1 end}
dofile('client/main.lua')
local function run(fn)
    local co=type(fn)=='thread' and fn or coroutine.create(fn)
    while coroutine.status(co)~='dead' do local ok,result=coroutine.resume(co);assert(ok,result) end
end
local function action(kind,extra)
    local data=extra or {};data.action=kind
    run(function() callbacks.questAction(data,function(r) eq(r.ok,true,'acknowledge NUI') end) end)
end
local function guiMessage()
    for i=#messages,1,-1 do if messages[i].action=='suimag-dailyquest:gui' then return messages[i] end end
end
eq(registeredKey,'F10')
run(commands.dailyquest)
eq(focused,false,'never capture input until the GUI is ready')
callbacks.questReady({},function() end)
eq(focused,true);eq(guiMessage().visible,true)
local before=focusCalls
run(commands.dailyquest);eq(focusCalls,before,'refresh must not steal focus')
before=#requests
for _,kind in ipairs({'unknown','claim','reroll'}) do action(kind,{id='forged',periodStart=999}) end
action('claim',{id='pending'});action('claim',{id='progress'})
eq(#requests,before,'unknown and ineligible actions never reach server')
local messageStart=#messages
action('claim',{id='ready',periodStart=999,reward=999999})
local operations={}
for i=messageStart+1,#messages do
    if messages[i].action=='suimag-dailyquest:busy' and messages[i].busy then
        operations[#operations+1]=messages[i].operation
    end
end
eq(table.concat(operations,','),'claim,list','GUI distinguishes reward processing from the following list refresh')
eq(requests[before+1].name,'suimag-dailyquest:claim')
eq(requests[before+1].args[2],123,'use the cached server period, ignore browser amounts and period')
eq(guiMessage().selected,'daily')
eq(guiMessage().data.quests[1].reward,'銀行 $150000 + 黒コイン × 1','GUI receives combined reward')
eq(notices[#notices].description,'銀行 $150000 + 黒コイン × 1 を受け取りました。')
responseMode='pending';action('claim',{id='ready'})
eq(notices[#notices].description:find('42',1,true)~=nil,true,'pending claim reference is visible')
responseMode='ok'
before=#requests;action('bonus');eq(requests[before+1].name,'suimag-dailyquest:claimBonus')
eq(requests[before+1].args[1],123)
view.dailyBonus.canClaim=false;before=#requests;action('bonus');eq(#requests,before,'disable unavailable bonus')
before=#requests;action('reroll',{id='progress'})
eq(#requests,before+1,'cancel only refreshes the board')
choice='confirm';before=#requests;action('reroll',{id='progress'})
eq(requests[before+1].name,'suimag-dailyquest:reroll');eq(focused,true)
before=#requests
local focusBefore=focusCalls
action('preferences',{preferences={crime=false,employment=true}})
eq(requests[before+1].args[1].crime,false);eq(requests[before+1].args[1].employment,true)
eq(focusCalls,focusBefore,'saving native settings keeps GUI focus')
for _,prefs in ipairs({false,{crime='yes',employment=false},{crime=true}}) do
    before=#requests;action('preferences',{preferences=prefs})
    eq(#requests,before,'invalid preference payload never reaches server')
    eq(messages[#messages].action,'suimag-dailyquest:preferencesResult');eq(messages[#messages].ok,false)
end
responseMode='not_ready';before=#requests
action('preferences',{preferences={crime=true,employment=false}})
eq(#requests,before+1,'failed save does not refresh away the draft')
eq(messages[#messages].ok,false);eq(focused,true)
responseMode='ok'
view.needsSetup=true;run(commands.dailyquest)
before=#requests;action('close');eq(#requests,before,'cancel setup without saving preferences')
view.needsSetup=false;run(commands.dailyquest)
-- A save already sent may complete, but its late response must not reopen the UI.
delayed=true
local save=coroutine.create(function() callbacks.questAction({action='preferences',preferences={crime=true,employment=false}},function() end) end)
local success,value=coroutine.resume(save);assert(success,value);eq(value,'await')
action('close');before=#messages;delayed=false
success,value=coroutine.resume(save);assert(success,value)
eq(#messages,before,'late save cannot notify or reopen for an unloaded view')
run(commands.dailyquest)
-- Error paths release the operation lock and allow retry.
for _,mode in ipairs({'throw','nil','not_ready'}) do
    responseMode=mode;run(commands.dailyquest);eq(notices[#notices].type,'error')
end
responseMode='ok';run(commands.dailyquest);eq(guiMessage().visible,true)
-- A dialog for an unloaded character cannot save or reopen its board.
for _,kind in ipairs({'reroll'}) do
    dialogDelayed=true;before=#requests
    local dialog=coroutine.create(function() callbacks.questAction({action=kind,id='progress'},function() end) end)
    local success,value=coroutine.resume(dialog);assert(success,value);eq(value,'dialog')
    handlers['QBCore:Client:OnPlayerUnload']()
    dialogDelayed=false;success,value=coroutine.resume(dialog);assert(success,value)
    eq(#requests,before,'stale dialog does not mutate server state')
    eq(guiMessage().visible,false)
    run(commands.dailyquest)
end
eq(alertClosed,1)
-- Close while a server reply is pending: no reopening or lock corruption.
clock=clock+2000;delayed=true
local old=coroutine.create(function() callbacks.questAction({action='refresh'},function() end) end)
local ok,result=coroutine.resume(old);assert(ok,result);eq(result,'await')
before=#requests;action('claim',{id='ready'});eq(#requests,before,'suppress duplicate actions')
action('preferences',{preferences={crime=true,employment=false}})
eq(#requests,before,'busy preference save never submits')
eq(messages[#messages].action,'suimag-dailyquest:preferencesResult');eq(messages[#messages].ok,false,'busy save must release browser saving state')
action('close');eq(focused,false);eq(guiMessage().visible,false)
-- Start a new open while the old reply is still in flight.
clock=clock+2000
local newer=coroutine.create(commands.dailyquest)
ok,result=coroutine.resume(newer);assert(ok,result);eq(result,'await')
ok,result=coroutine.resume(old);assert(ok,result)
eq(guiMessage().visible,false,'stale refresh cannot reopen closed GUI')
before=#requests;run(commands.dailyquest);eq(#requests,before,'old reply cannot release the new operation lock')
delayed=false;ok,result=coroutine.resume(newer);assert(ok,result)
eq(guiMessage().visible,true)
action('close')
before=focusCalls
callbacks.questReady({},function() end)
eq(guiMessage().visible,false,'late readiness must not reopen a closed board')
handlers['QBCore:Client:OnPlayerUnload']()
eq(focusCalls,before,'do not release another resource focus when already closed')
-- Timer ticks are local; only crossing the deadline requests a fresh board.
view.serverNow=2000;view.dailyResetAt=2010
run(commands.dailyquest)
local function tick() local success,value=coroutine.resume(threads[1]);assert(success,value);return value end
tick();before=#requests
for _=1,8 do tick() end
eq(#requests,before,'timer does not poll the server every second')
clock=clock+11000;view.dailyResetAt=88400;tick()
eq(#requests,before+1,'refresh at the deadline')
eq(guiMessage().visible,true,'automatic refresh keeps the board open')
-- An in-flight automatic refresh is invalidated by character unload.
view.dailyResetAt=view.serverNow;run(commands.dailyquest)
delayed=true;clock=clock+6000
repeat result=tick() until result=='await'
handlers['QBCore:Client:OnPlayerUnload']();delayed=false;tick()
eq(guiMessage().visible,false);eq(focused,false)
run(commands.dailyquest);handlers.onResourceStop('other-resource');eq(focused,true)
handlers.onResourceStop('suimag-dailyquest');eq(focused,false)
run(exposed.OpenQuests)
run(threads[#threads])
eq(guiMessage().visible,true,'public OpenQuests export')
-- Debug actions require the server capability and use dedicated callbacks.
view.canDebug=true;run(commands.dailyquest)
action('debugView',{visible=true})
eq(requests[#requests].name,'suimag-dailyquest:debug');eq(requests[#requests].args[1],'list')
action('debug',{operation='reset',id='daily_bus'})
eq(requests[#requests].args[1],'reset');eq(requests[#requests].args[2],'daily_bus')
action('debugView',{visible=false})
before=#requests;action('debug',{operation='reset'});eq(#requests,before,'debug actions require the debug view')
view.canDebug=false;run(commands.dailyquest)
before=#requests;action('debugView',{visible=true});eq(#requests,before,'non-admin cannot request debug data from NUI')
io.write(('client: %d assertions passed\n'):format(count))
