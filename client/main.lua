local prefix = 'suimag-dailyquest:'
local busy, generation, lastList = false, 0, nil
local open
local guiData, guiVisible, guiReady
local function guiHide()
    local wasVisible=guiVisible
    guiVisible=false
    SendNUIMessage({action=prefix..'gui',visible=false})
    if wasVisible then SetNuiFocus(false,false) end
end
local countdown,overlayStamp
local overlayVisible,nextRefresh=false,0

local errors = {
    setup_required = '最初に抽選設定を保存してください。',
    no_candidates = '条件に合う交換候補がありません。リロール回数は消費していません。',
    reroll_used = 'この期間のリロールは使用済みです。',
    reroll_completed = '達成済み・受取済みのクエストは交換できません。',
    not_assigned = '提示されていないクエストです。一覧を更新してください。',
    not_ready = 'クエストの準備中です。しばらくしてからお試しください。',
    player_unavailable = 'キャラクターの読み込み後に開いてください。',
    storage_error = '保存処理に失敗しました。時間をおいてお試しください。',
    busy = '処理中です。しばらくしてからお試しください。',
    rate_limited = '操作が速すぎます。少し待ってからお試しください。',
    invalid_request = '無効なクエストです。一覧を更新してください。',
    expired = '更新時刻を過ぎました。新しいクエストを確認してください。',
    pending = '報酬は確認待ちです。二重配布防止のため再受取を停止しています。管理者へご連絡ください。',
    claimed = 'この報酬は受取済みです。',
    incomplete = 'まだ目標に達していません。',
    invalid_item = '報酬コインが未登録です。管理者へご連絡ください。',
    inventory_full = 'コインを受け取る空きがありません。持ち物を整理してから受け取ってください。',
    reward_failed = '報酬を付与できませんでした。時間をおいて再度お試しください。',
    claim_unavailable = '受取状態が変わりました。一覧を更新してください。',
    unavailable = 'サーバーに接続できませんでした。しばらくしてからお試しください。',
}

local function notify(result)
    local description = errors[result.error] or errors.unavailable
    if result.claimId then description = description .. ' 確認番号: ' .. result.claimId end
    lib.notify({ title = 'デイリー / ウィークリー', type = 'error', description = description })
end

local function request(action, ...)
    local epoch = generation
    if action == 'list' and lastList then
        local elapsed = GetGameTimer() - lastList
        if elapsed >= 0 and elapsed < Config.RequestCooldownMs + 100 then Wait(Config.RequestCooldownMs + 100 - elapsed) end
    end
    if epoch ~= generation then return { ok = false, error = 'cancelled' } end
    if action == 'list' then lastList = GetGameTimer() end
    if guiVisible then SendNUIMessage({action=prefix..'busy',busy=true,operation=action}) end
    local ok, result = pcall(lib.callback.await, prefix .. action, false, ...)
    if epoch ~= generation then return { ok = false, error = 'cancelled' } end
    if guiVisible then SendNUIMessage({action=prefix..'busy',busy=false}) end
    if not ok or type(result) ~= 'table' then return { ok = false, error = 'unavailable' } end
    return result
end

local function receive(quest)
    if busy then return end
    local operation = {}
    busy = operation
    local result = request('claim', quest.id, quest.periodStart)
    if busy == operation then busy = false end
    if result.error == 'cancelled' then return end
    if result.ok then
        lib.notify({ title = 'クエスト報酬', description = quest.reward .. ' を受け取りました。', type = 'success' })
    else
        notify(result)
    end
    open(quest.period)
end

local function receiveBonus(bonus)
    if busy then return end
    local operation={}
    busy=operation
    local result=request('claimBonus',bonus.periodStart)
    if busy==operation then busy=false end
    if result.error=='cancelled' then return end
    if result.ok then
        lib.notify({title='デイリー全クリア報酬',description=bonus.reward..' を受け取りました。',type='success'})
    else notify(result) end
    open('daily')
end
local function configure(data)
    if busy then return end
    local operation,epoch={kind='preferences'},generation
    busy=operation
    local prefs=data.preferences or {crime=true,employment=false}
    guiHide()
    local input=lib.inputDialog(data.needsSetup and '初回の抽選設定' or '抽選するクエストの属性',{
        {type='checkbox',label='犯罪を除外する',checked=prefs.crime},
        {type='checkbox',label='職業・所属必須を除外する',checked=prefs.employment},
    })
    if epoch~=generation then return end
    if not input then
        if busy==operation then busy=false end
        open()
        return
    end
    local result=request('preferences',{crime=input[1]==true,employment=input[2]==true})
    if busy==operation then busy=false end
    if result.error=='cancelled' then return end
    if result.ok then
        lib.notify({title='抽選設定',type='success',description=data.needsSetup
            and '設定を保存しました。日次3件・週次2件を抽選します。'
            or '設定を保存しました。次回更新・リロールから適用します。提示済みの内容は変わりません。'})
    else notify(result) end
    open()
end

local function reroll(quest)
    if busy then return end
    local operation,epoch={kind='reroll'},generation
    busy=operation
    guiHide()
    local choice=lib.alertDialog({
        header='このクエストを交換しますか？',
        content=quest.title..' の進捗は失われます。交換後は0から開始し、この期間のリロール1回分を使います。',
        cancel=true,labels={confirm='交換する',cancel='戻る'},
    })
    if epoch~=generation then return end
    if choice~='confirm' then
        if busy==operation then busy=false end
        open(quest.period)
        return
    end
    local result=request('reroll',quest.id,quest.periodStart)
    if busy==operation then busy=false end
    if result.error=='cancelled' then return end
    if result.ok then lib.notify({title='リロール',type='success',description='クエストを1件交換しました。'})
    else notify(result) end
    open(quest.period)
end
local function render(data, selected)
    if not data.needsSetup and type(data.dailyResetAt)=='number' and type(data.serverNow)=='number' then
        countdown={seconds=math.max(0,data.dailyResetAt-data.serverNow),at=GetGameTimer(),label=data.dailyReset}
    else countdown=nil end
    overlayStamp=nil
    local wasVisible=guiVisible
    guiData,guiVisible=data,true
    SendNUIMessage({action=prefix..'gui',visible=true,data=data,selected=selected})
    if guiReady and not wasVisible then SetNuiFocus(true,true) end
end

open = function(selected)
    if busy then return end
    local operation = {}
    busy = operation
    if not guiVisible then selected=selected or 'daily' end
    local result = request('list')
    if busy == operation then busy = false end
    if result.error == 'cancelled' then return end
    if not result.ok then notify(result); return end
    render(result, selected)
end

RegisterCommand(Config.Command, function() open() end, false)
if Config.Key then RegisterKeyMapping(Config.Command, 'デイリー / ウィークリークエスト', 'keyboard', Config.Key) end
exports('OpenQuests', function() CreateThread(function() open() end) end)

local function close()
    guiHide()
    guiData=nil
    generation = generation + 1
    local operation=busy
    busy=false
    countdown,overlayStamp=nil,nil
    if overlayVisible then SendNUIMessage({action=prefix..'countdown',visible=false}) end
    overlayVisible=false
    if type(operation)=='table' and operation.kind=='preferences' then lib.closeInputDialog() end
    if type(operation)=='table' and operation.kind=='reroll' then lib.closeAlertDialog() end
end

RegisterNUICallback('questAction',function(data,cb)
    cb({ok=true})
    if type(data)~='table' or not guiVisible then return end
    if data.action=='close' then close(); return end
    if busy or not guiData then return end
    if data.action=='refresh' then open(data.period=='weekly' and 'weekly' or 'daily')
    elseif data.action=='preferences' then configure(guiData)
    elseif data.action=='bonus' then
        if guiData.dailyBonus and guiData.dailyBonus.canClaim then receiveBonus(guiData.dailyBonus) end
    elseif data.action=='claim' or data.action=='reroll' then
        for _,quest in ipairs(guiData.quests or {}) do
            if quest.id==data.id then
                if data.action=='claim' and quest.status=='active' and quest.value>=quest.target then receive(quest)
                elseif data.action=='reroll' and quest.canReroll then reroll(quest) end
                break
            end
        end
    end
end)

RegisterNetEvent('QBCore:Client:OnPlayerUnload', close)
AddEventHandler('onResourceStop', function(name)
    if name == GetCurrentResourceName() then close() end
end)

-- Both page scripts are loaded before this handshake; never focus an unloaded UI.
RegisterNUICallback('questReady',function(_,cb)
    guiReady=true
    overlayStamp=nil
    if guiVisible and guiData then
        SendNUIMessage({action=prefix..'gui',visible=true,data=guiData})
        SetNuiFocus(true,true)
    end
    cb({})
end)

CreateThread(function()
    while true do
        Wait(250)
        local visible=guiVisible and not busy and countdown~=nil
        if visible then
            local now=GetGameTimer()
            local delta=now-countdown.at
            local remaining=math.max(0,countdown.seconds-math.max(0,delta)/1000)
            if delta<0 then
                countdown.seconds,countdown.at=0,now
                remaining,nextRefresh=0,now
                overlayStamp=nil
            end
            if not overlayVisible or overlayStamp~=countdown then
                SendNUIMessage({action=prefix..'countdown',visible=true,remaining=remaining,resetLabel=countdown.label})
                overlayVisible,overlayStamp=true,countdown
            end
            if (remaining<=0 or delta<0) and now>=nextRefresh then
                nextRefresh=now+5000
                local operation,epoch={},generation
                busy=operation
                local result=request('list')
                if busy==operation then busy=false end
                -- Never steal focus from a closed menu, a dialog or another resource.
                if epoch==generation and guiVisible and result.ok then
                    render(result)
                end
            end
        elseif overlayVisible then
            SendNUIMessage({action=prefix..'countdown',visible=false})
            overlayVisible=false
        end
    end
end)
