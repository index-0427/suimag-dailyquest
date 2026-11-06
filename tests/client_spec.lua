dofile('config.lua')
local commands, exposed, handlers, contexts, notices = {}, {}, {}, {}, {}
local threads,nuiCallbacks,nuiMessages={},{},{}
local clock, menu, registeredKey, requests, mode, count = 10000, nil, nil, {}, 'ok', 0
local function eq(a,b,label)
    count=count+1;assert(a==b,(label or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b))
end
local view={
    ok=true,preferences={crime=true,employment=false},rerolls={daily=1,weekly=1},dailyReset='11/05 05:00 (UTC+09:00)',weeklyReset='11/09 05:00 (UTC+09:00)',
    quests={
        {id='visit',period='daily',periodStart=123,title='Visit',description='Description',value=1,target=1,status='active',unit='日',scale=1,reward='銀行 $1000'},
        {id='time',period='daily',periodStart=123,title='Time',description='Description',value=30,target=60,status='active',unit='分',scale=60,reward='銀行 $1000'},
        {id='pending',period='weekly',periodStart=123,title='Pending',description='Description',value=1,target=1,status='pending',unit='日',scale=1,reward='銀行 $1000'},
        {id='paid',period='weekly',periodStart=123,title='Paid',description='Description',value=1,target=1,status='claimed',unit='日',scale=1,reward='銀行 $1000'},
    },
}
GetGameTimer=function() return clock end
GetCurrentResourceName=function() return 'suimag-dailyquest' end
Wait=function(ms) clock=clock+ms;coroutine.yield(ms) end
CreateThread=function(fn) threads[#threads+1]=coroutine.create(fn) end
RegisterNUICallback=function(name,fn) nuiCallbacks[name]=fn end
SendNUIMessage=function(data) nuiMessages[#nuiMessages+1]=data end
RegisterCommand=function(name,fn) commands[name]=fn end
RegisterKeyMapping=function(_,_,_,key) registeredKey=key end
RegisterNetEvent=function(name,fn) handlers[name]=fn end
AddEventHandler=function(name,fn) handlers[name]=fn end
exports=setmetatable({},{__call=function(_,name,fn) exposed[name]=fn end})
lib={
    callback={await=function(name,_,...)
        requests[#requests+1]={name=name,args={...}}
        if mode=='delayed' then coroutine.yield('await') end
        if mode=='throw' then error('timeout') end
        if mode=='nil' then return nil end
        if mode=='not_ready' then return {ok=false,error='not_ready'} end
        if name=='suimag-dailyquest:preferences' or name=='suimag-dailyquest:reroll' or name=='suimag-dailyquest:claimBonus' then return {ok=true} end
        if name=='suimag-dailyquest:claim' then
            if mode=='pending' then return {ok=false,error='pending',claimId=42} end
            return {ok=true}
        end
        return view
    end},
    notify=function(data) notices[#notices+1]=data end,
    registerContext=function(items) if items.id then contexts[items.id]=items else for _,item in ipairs(items) do contexts[item.id]=item end end end,
    showContext=function(id) menu=id end,
    getOpenContextMenu=function() return menu end,
    hideContext=function() menu=nil end,
}
dofile('client/main.lua')
local function drain(co)
    while coroutine.status(co)~='dead' do local ok,err=coroutine.resume(co);assert(ok,err) end
end
local function call(fn)
    drain(coroutine.create(fn))
    for i=2,#threads do drain(threads[i]) end
end
local prefix='suimag-dailyquest:'
eq(registeredKey,'F10','default quest key binding')
call(commands.dailyquest)
eq(menu,prefix..'root')
eq(#contexts[prefix..'root'].options,4)
local daily=contexts[prefix..'daily'].options
eq(daily[3].readOnly,false)
eq(daily[3].progress,100)
eq(daily[4].readOnly,true)
eq(daily[4].progress,50)
eq(daily[4].onSelect,nil)
local weekly=contexts[prefix..'weekly'].options
eq(weekly[3].readOnly,true);eq(weekly[4].readOnly,true)
call(daily[3].onSelect)
eq(notices[#notices].type,'success')
eq(menu,prefix..'daily')
local claimRequest=requests[#requests-1]
eq(claimRequest.name,prefix..'claim')
eq(claimRequest.args[1],'visit');eq(claimRequest.args[2],123)
mode='pending';call(contexts[prefix..'daily'].options[3].onSelect)
eq(notices[#notices].description:find('42',1,true)~=nil,true)
mode='throw';call(commands.dailyquest);eq(notices[#notices].type,'error')
mode='nil';call(commands.dailyquest);eq(notices[#notices].type,'error')
mode='not_ready';call(commands.dailyquest);eq(notices[#notices].description,'クエストの準備中です。しばらくしてからお試しください。')
mode='ok'
-- Switching characters closes only this menu and rejects stale replies.
clock=clock+2000;mode='delayed'
local old=coroutine.create(commands.dailyquest)
local ok,result=coroutine.resume(old);assert(ok,result);eq(result,'await')
local before=#requests
call(commands.dailyquest);eq(#requests,before,'busy suppresses duplicate callback')
handlers['QBCore:Client:OnPlayerUnload']()
eq(menu,nil)
-- A new character can open while the old callback is still awaiting its result.
clock=clock+2000
local newer=coroutine.create(commands.dailyquest)
ok,result=coroutine.resume(newer);assert(ok,result);eq(result,'await')
mode='ok'
ok,result=coroutine.resume(old);assert(ok,result)
eq(menu,nil,'old callback cannot reopen UI')
before=#requests;call(commands.dailyquest);eq(#requests,before,'old reply cannot clear new operation lock')
ok,result=coroutine.resume(newer);assert(ok,result)
eq(menu,prefix..'root')
menu='other-resource:menu'
handlers['QBCore:Client:OnPlayerUnload']()
eq(menu,'other-resource:menu','do not close another resource menu')
call(exposed.OpenQuests)
eq(menu,prefix..'root')
handlers.onResourceStop('other-resource');eq(menu,prefix..'root')
handlers.onResourceStop('suimag-dailyquest');eq(menu,nil)

view.quests[#view.quests+1]={id='walk',period='daily',periodStart=123,title='Walk',description='Walk',
    value=567,target=1000,status='active',unit='km',scale=1000,precision=1,reward='銀行 $1500'}
local unavailable={id='bus',period='daily',periodStart=123,title='Bus',description='Work',
    value=0,target=1,status='active',unit='回',scale=1,reward='銀行 $2500',available=false}
view.quests[#view.quests+1]=unavailable
mode='ok';call(commands.dailyquest)
daily=contexts[prefix..'daily'].options
eq(daily[5].description:find('0.5 / 1 km',1,true)~=nil,true,'fractional kilometre display')
eq(daily[6].title:find('連携元が未起動',1,true)~=nil,true)
eq(daily[6].readOnly,true)
unavailable.value=1;call(commands.dailyquest)
eq(contexts[prefix..'daily'].options[6].readOnly,false,'earned reward stays claimable when provider stops')

-- Initial setup, preference editing and a single-quest reroll all require deliberate UI actions.
local dialogValue={true,true}
local dialogMode='normal'
local inputClosed,alertClosed=0,0
lib.inputDialog=function()
    if dialogMode=='delay' then coroutine.yield('dialog') end
    return dialogValue
end
lib.alertDialog=function() return dialogValue end
lib.closeInputDialog=function() inputClosed=inputClosed+1 end
lib.closeAlertDialog=function() alertClosed=alertClosed+1 end
view.needsSetup=true
call(commands.dailyquest)
eq(#contexts[prefix..'root'].options,1,'no quests before first setup')
before=#requests
call(contexts[prefix..'root'].options[1].onSelect)
local prefRequest=requests[before+1]
eq(prefRequest.name,prefix..'preferences')
eq(prefRequest.args[1].crime,true);eq(prefRequest.args[1].employment,true)
view.needsSetup=false
call(commands.dailyquest)
dialogValue={false,true}
call(contexts[prefix..'root'].options[3].onSelect)
eq(requests[#requests-1].name,prefix..'preferences')
eq(requests[#requests-1].args[1].crime,false)
-- Canceling first setup must not save preferences or draw.
view.needsSetup=true;dialogValue=nil;call(commands.dailyquest);before=#requests
call(contexts[prefix..'root'].options[1].onSelect)
eq(#requests,before+1,'only a list refresh after cancel')
view.needsSetup=false;view.quests[2].canReroll=true
call(commands.dailyquest)
dialogValue='confirm';before=#requests
call(contexts[prefix..'daily'].options[4].onSelect)
eq(requests[before+1].name,prefix..'reroll')
eq(requests[before+1].args[1],'time')
eq(requests[before+1].args[2],123)
dialogValue='cancel';before=#requests
call(contexts[prefix..'daily'].options[4].onSelect)
eq(#requests,before+1,'canceling exchange sends no reroll request')
-- A dialog opened for the old character cannot save into the new one.
dialogMode='delay';dialogValue={true,true};before=#requests
local dialog=coroutine.create(contexts[prefix..'root'].options[3].onSelect)
ok,result=coroutine.resume(dialog);assert(ok,result);eq(result,'dialog')
handlers['QBCore:Client:OnPlayerUnload']()
eq(inputClosed,1)
ok,result=coroutine.resume(dialog);assert(ok,result)
eq(#requests,before,'stale dialog cannot mutate preferences')


-- Daily completion bonus is a separate action, not a sixth quest or a weekly bonus.
view.needsSetup=false;mode='ok';dialogMode='normal'
view.dailyBonus={periodStart=123,completed=2,total=3,status='active',reward='銀行 $200000',canClaim=false}
call(commands.dailyquest)
local function bonusOption()
    for _,option in ipairs(contexts[prefix..'daily'].options) do
        if option.title:find('デイリー全クリア報酬',1,true) then return option end
    end
end
eq(bonusOption().readOnly,true);eq(bonusOption().onSelect,nil)
view.dailyBonus.completed=3;view.dailyBonus.canClaim=true
call(commands.dailyquest)
eq(bonusOption().readOnly,false)
before=#requests
call(bonusOption().onSelect)
eq(requests[before+1].name,prefix..'claimBonus');eq(requests[before+1].args[1],123)
eq(notices[#notices].title,'デイリー全クリア報酬')
view.dailyBonus.status='claimed';view.dailyBonus.canClaim=false
call(commands.dailyquest);eq(bonusOption().readOnly,true)
view.dailyBonus.status='pending';call(commands.dailyquest)
eq(bonusOption().title:find('確認待ち',1,true)~=nil,true)
local weeklyBonus=false
for _,option in ipairs(contexts[prefix..'weekly'].options) do
    if option.title:find('全クリア',1,true) then weeklyBonus=true end
end
eq(weeklyBonus,false)

-- Countdown visibility and boundary refresh use a local timer, not one server call per second.
view.serverNow=1000;view.dailyResetAt=1010;mode='ok'
call(commands.dailyquest)
local timerThread=threads[1]
local function tick()
    local success,value=coroutine.resume(timerThread);assert(success,value);return value
end
eq(tick(),250)
tick()
eq(nuiMessages[#nuiMessages].visible,true)
eq(nuiMessages[#nuiMessages].action,prefix..'countdown')
before=#requests
for _=1,8 do tick() end
eq(#requests,before,'countdown ticks require no server polling')
menu='other-resource:menu';tick()
eq(nuiMessages[#nuiMessages].visible,false)
eq(menu,'other-resource:menu','countdown does not take focus')
call(commands.dailyquest)
view.serverNow=1010;view.dailyResetAt=87410
clock=clock+11000
before=#requests;tick()
eq(requests[before+1].name,prefix..'list','refresh once when the daily deadline passes')
eq(menu,prefix..'root')
tick();eq(nuiMessages[#nuiMessages].visible,true)
eq(nuiMessages[#nuiMessages].remaining>86000,true,'new day countdown')
-- A delayed automatic refresh must not reopen a menu closed while the callback was waiting.
view.serverNow=2000;view.dailyResetAt=2000
call(commands.dailyquest);mode='delayed';clock=clock+6000
local value=tick()
while value~='await' do value=tick() end
menu='other-resource:menu';mode='ok';tick()
eq(menu,'other-resource:menu','late auto-refresh cannot steal focus')
handlers['QBCore:Client:OnPlayerUnload']()
eq(nuiMessages[#nuiMessages].visible,false,'overlay clears on logout')
io.write(('client: %d assertions passed\n'):format(count))
