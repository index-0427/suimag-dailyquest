dofile('config.lua')
local commands, exposed, handlers, contexts, notices = {}, {}, {}, {}, {}
local clock, menu, registeredKey, requests, mode, count = 10000, nil, nil, {}, 'ok', 0
local function eq(a,b,label)
    count=count+1;assert(a==b,(label or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b))
end
local view={
    ok=true,dailyReset='11/05 05:00 (UTC+09:00)',weeklyReset='11/09 05:00 (UTC+09:00)',
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
CreateThread=function(fn) local co=coroutine.create(fn);while coroutine.status(co)~='dead' do local ok,err=coroutine.resume(co);assert(ok,err) end end
RegisterCommand=function(name,fn) commands[name]=fn end
RegisterKeyMapping=function() registeredKey=true end
RegisterNetEvent=function(name,fn) handlers[name]=fn end
AddEventHandler=function(name,fn) handlers[name]=fn end
exports=setmetatable({},{__call=function(_,name,fn) exposed[name]=fn end})
lib={
    callback={await=function(name,_,...)
        requests[#requests+1]={name=name,args={...}}
        if mode=='delayed' then coroutine.yield('await') end
        if mode=='throw' then error('timeout') end
        if mode=='nil' then return nil end
        if mode=='conflict' then return {ok=false,error='conflict'} end
        if name=='suimag-dailyquest:claim' then
            if mode=='pending' then return {ok=false,error='pending',claimId=42} end
            return {ok=true}
        end
        return view
    end},
    notify=function(data) notices[#notices+1]=data end,
    registerContext=function(items) for _,item in ipairs(items) do contexts[item.id]=item end end,
    showContext=function(id) menu=id end,
    getOpenContextMenu=function() return menu end,
    hideContext=function() menu=nil end,
}
dofile('client/main.lua')
local function call(fn) CreateThread(fn) end
local prefix='suimag-dailyquest:'
eq(registeredKey,nil,'default does not claim a keyboard binding')
call(commands.dailyquest)
eq(menu,prefix..'root')
eq(#contexts[prefix..'root'].options,3)
local daily=contexts[prefix..'daily'].options
eq(daily[2].readOnly,false)
eq(daily[2].progress,100)
eq(daily[3].readOnly,true)
eq(daily[3].progress,50)
eq(daily[3].onSelect,nil)
local weekly=contexts[prefix..'weekly'].options
eq(weekly[2].readOnly,true);eq(weekly[3].readOnly,true)
call(daily[2].onSelect)
eq(notices[#notices].type,'success')
eq(menu,prefix..'daily')
local claimRequest=requests[#requests-1]
eq(claimRequest.name,prefix..'claim')
eq(claimRequest.args[1],'visit');eq(claimRequest.args[2],123)
mode='pending';call(contexts[prefix..'daily'].options[2].onSelect)
eq(notices[#notices].description:find('42',1,true)~=nil,true)
mode='throw';call(commands.dailyquest);eq(notices[#notices].type,'error')
mode='nil';call(commands.dailyquest);eq(notices[#notices].type,'error')
mode='conflict';call(commands.dailyquest);eq(notices[#notices].description:find('切替',1,true)~=nil,true)
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
io.write(('client: %d assertions passed\n'):format(count))
