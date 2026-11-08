local root = assert(arg[1], 'Usage: lua tests/integration_resources_spec.lua /path/to/local-resource-copy')
local checks, failures = 0, 0
local function eq(a,b,label)
    checks=checks+1; assert(a==b,label..': '..tostring(a)..' ~= '..tostring(b))
end
local function read(path)
    local f=assert(io.open(path,'rb')); local s=f:read('*a'); f:close(); return s:gsub('\r\n','\n')
end
local function section(s,a,b)
    local start=assert(s:find(a,1,true),a); local stop=assert(s:find(b,start,true),b)
    return s:sub(start,stop-1)
end
local function execute(code,env,label)
    setmetatable(env,{__index=_G}); assert(load(code,label,'t',env))()
end
local function test(name,fn)
    local ok,err=pcall(fn); if not ok then failures=failures+1 end
    print((ok and 'PASS ' or 'FAIL ')..name..(ok and '' or ': '..tostring(err)))
end

test('fishing reasons and the real dailyquest adapter',function()
    local handlers,caller,calls={},nil,{}
    local env={
        AddEventHandler=function(name,fn) handlers[name]=fn end,
        GetInvokingResource=function()return caller end,
        GetResourceState=function()return 'started' end,
        GetGameTimer=function()return 1000 end,
        DQRuntime={identity=function()return 'TEST' end,
            signal=function(_,_,activity) calls[#calls+1]=activity end},
    }
    for _,path in ipairs({'config.lua','server/domain.lua','server/adapters.lua'}) do
        execute(read(path),env,path)
    end
    local function event(name,resource,...)
        caller=resource;handlers[name](...)
    end
    env.self={}
    env.player={Functions={AddMoney=function(account,amount,reason)
        event('QBCore:Server:OnMoneyChange','qbx_core',1,account,amount,'add',reason or 'unknown')
    end}}
    local source=read(root..'/[whitejob]/pug-fishing/config/config-framework.lua')
    execute(section(source,'self.AddMoney = function','self.RemoveMoney = function'),env,'fishing wrapper')
    for i,reason in ipairs({'sell-fish','sell-crabs','sell-gems'}) do
        env.self.AddMoney('cash',100+i,reason)
        event('pv_poe:job:complete','pug-fishing',1,'pug-fishing',100+i)
        eq(#calls,math.min(i,2),reason)
    end
    env.self.AddMoney('cash',200)
    event('pv_poe:job:complete','pug-fishing',1,'pug-fishing',200)
    eq(#calls,2,'unspecified reason')
end)

test('taxi rejects stale routes without scheduling or paying',function()
    local callback,scheduled,paid,progressed=nil,0,0,0
    local row={ride_id={class='standard'}}
    local env={
        functions={
            RemoveTaxiCall=function()local result=row;row=nil;return result end,
            RewardPlayer=function()paid=paid+1 end,
            UpdateChallengeProgress=function()progressed=progressed+1 end,
        },
        gg={framework={GetIdentifier=function()return 'TEST' end}},
        cfg={challenges={standard=true}},
        lib={callback={register=function(_,fn)callback=fn end}},
        CreateThread=function()scheduled=scheduled+1 end,
    }
    local source=read(root..'/[whitejob]/gg_taxijob/base/core/open_code/server.lua')
    execute(section(source,'functions = functions or {}','-- Used on Route Completion'),env,'taxi callback')
    eq(callback(1,'rides',1),true,'valid route')
    eq(callback(1,'rides',1),false,'duplicate route')
    eq(callback(1,'rides',999),false,'unknown route')
    eq(paid,1,'one payment');eq(progressed,1,'one challenge increment')
    eq(scheduled,1,'only valid completion schedules a replacement')
end)

local function houseCase(steps,expected,requiresLoot,actor)
    local handlers,ended,current,granted={},nil,nil,0
    local position=setmetatable({},{__sub=function()
        return setmetatable({},{__len=function()return 0 end})
    end})
    local robbery={host=1,interiorKey='test',looted={}}
    local containers={}
    for i,step in ipairs(steps) do
        containers[i]={coords=position,items={{name='testloot',count=1,chance=step.empty and 0 or 100}}}
    end
    local env={
        source=actor or 1,
        InsideOf={[1]=1,[2]=1},Robberies={[1]=robbery},
        Config={CompleteRequiresLoot=requiresLoot~=false,Loot={distance=1.5},
            Interiors={test={takeLoot=containers}}},
        Shared={Info=function()end,Error=function()end,Success=function()end},
        exports={ox_inventory={
            CanCarryItem=function()return current.carry end,
            AddItem=function()if current.add then granted=granted+1 end;return current.add end,
        }},
        itemLabel=function(name)return name end,playerCoords=function()return position end,
        now=function()return 1000 end,syncInside=function()end,leavePlayer=function()end,
        endRobbery=function(_,reason)ended=reason end,
        RegisterNetEvent=function(name,fn)handlers[name]=fn end,
    }
    local source=read(root..'/[robbery]/satou_houserobbery/server/main.lua')
    execute(section(source,"RegisterNetEvent('satou_houserobbery:exit'","RegisterNetEvent('satou_houserobbery:requestSync'"),env,'house loot and exit')
    for i,step in ipairs(steps) do current=step;handlers['satou_houserobbery:loot'](i) end
    env.source=1;handlers['satou_houserobbery:exit']()
    eq(ended,expected,'house completion')
    if expected=='abandoned' then eq(granted,0,'no actual loot') end
end

test('house requires a successful item grant',function()
    houseCase({{carry=false,add=true}},'abandoned')
    houseCase({{carry=true,add=false}},'abandoned')
    houseCase({{carry=true,add=true,empty=true}},'abandoned')
    houseCase({{carry=true,add=true}},'completed')
    houseCase({{carry=true,add=true},{carry=false,add=false}},'completed')
    houseCase({{carry=true,add=true}},'completed',true,2)
    houseCase({},'completed',false)
    houseCase({},'abandoned')
end)
print(('%d assertions, %d failing groups'):format(checks,failures))
if failures>0 then os.exit(1) end
