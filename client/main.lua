local prefix = 'suimag-dailyquest:'
local busy, generation, lastList = false, 0, nil
local open
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
    local ok, result = pcall(lib.callback.await, prefix .. action, false, ...)
    if epoch ~= generation then return { ok = false, error = 'cancelled' } end
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
    local root = prefix .. 'root'
    if not data.needsSetup and type(data.dailyResetAt)=='number' and type(data.serverNow)=='number' then
        countdown={seconds=math.max(0,data.dailyResetAt-data.serverNow),at=GetGameTimer(),label=data.dailyReset}
    else countdown=nil end
    overlayStamp=nil
    if data.needsSetup then
        lib.registerContext({id=root,title='クエストを始める',options={{
            title='初回の抽選設定',icon='sliders',
            description='犯罪・職業条件の除外を選んでから、日次3件・週次2件を抽選します。',
            onSelect=function() configure(data) end,
        }}})
        lib.showContext(root)
        return
    end
    local contexts = {}
    local rootOptions = {}
    for _, kind in ipairs({ 'daily', 'weekly' }) do
        local title = kind == 'daily' and 'デイリー' or 'ウィークリー'
        local reset = kind == 'daily' and data.dailyReset or data.weeklyReset
        local options = {
            { title = '次回更新: ' .. reset, description = kind=='daily'
                and '達成済みの未受取報酬は更新時に自動受取。オフライン中は次回ログイン時に受け取ります。'
                or 'ウィークリー報酬は期限内に受け取ってください。', icon = 'clock', readOnly = true },
        }
        options[#options+1]={title='リロール残り '..data.rerolls[kind]..'回',
            description='未達成のクエストを選択して1件交換できます。',icon='shuffle',readOnly=true}
        local completed, total, claimable = 0, 0, 0
        for _, quest in ipairs(data.quests) do
            if quest.period == kind then
                total = total + 1
                local done = quest.value >= quest.target
                local canClaim = done and quest.status == 'active'
                if done then completed = completed + 1 end
                if canClaim then claimable = claimable + 1 end
                local state = quest.available == false and not done and '連携元が未起動' or quest.status == 'claimed' and '受取済み'
                    or quest.status == 'pending' and '確認待ち' or canClaim and '報酬を受け取る' or '進行中'
                local factor = 10 ^ (quest.precision or 0)
                local current = math.floor(quest.value / quest.scale * factor) / factor
                local target = quest.target / quest.scale
                options[#options + 1] = {
                    title = quest.title .. ' · ' .. state,
                    description = quest.description .. ('\n%g / %g %s  •  %s'):format(current, target, quest.unit, quest.reward),
                    icon = quest.status == 'claimed' and 'circle-check'
                        or quest.status == 'pending' and 'hourglass-half' or canClaim and 'gift' or 'bullseye',
                    progress = math.min(100, quest.value / quest.target * 100),
                    colorScheme = canClaim and 'teal' or 'blue',
                    metadata={
                        {label='属性',value=quest.tags and quest.tags.crime and '犯罪' or quest.tags and quest.tags.employment and '職業・所属必須' or '一般'},
                        {label='交換',value=quest.canReroll and '選択してリロール' or '交換不可'},
                    },
                    readOnly = not canClaim and not quest.canReroll,
                    onSelect = canClaim and function() receive(quest) end
                        or quest.canReroll and function() reroll(quest) end or nil,
                }
            end
        end
        if kind=='daily' and data.dailyBonus then
            local bonus=data.dailyBonus
            local state=bonus.status=='claimed' and '受取済み' or bonus.status=='pending' and '確認待ち'
                or bonus.canClaim and '受け取る' or '未達成'
            options[#options+1]={
                title='デイリー全クリア報酬 · '..state,
                description=('%d / %d件クリア  •  追加 %s'):format(bonus.completed,bonus.total,bonus.reward),
                icon=bonus.status=='claimed' and 'circle-check' or bonus.status=='pending' and 'hourglass-half' or 'award',
                progress=math.min(100,bonus.completed/bonus.total*100),colorScheme='teal',
                readOnly=not bonus.canClaim,
                onSelect=bonus.canClaim and function() receiveBonus(bonus) end or nil,
            }
        end
        if total == 0 then options[#options + 1] = { title = 'クエストはありません', readOnly = true } end
        options[#options + 1] = { title = '進捗を更新', icon = 'rotate', onSelect = function() open(kind) end }
        contexts[#contexts + 1] = { id = prefix .. kind, title = title, menu = root, options = options }
        rootOptions[#rootOptions + 1] = {
            title = title,
            description = ('達成 %d / %d  •  受取可能 %d\n次回更新: %s'):format(completed, total, claimable, reset),
            menu = prefix .. kind, icon = kind == 'daily' and 'sun' or 'calendar-week',
        }
    end
    if data.drawError then
        rootOptions[#rootOptions+1]={title='抽選できる候補が不足しています',icon='circle-info',readOnly=true,
            description='除外設定や連携元の状態を確認してください。既存のクエストは変更していません。'}
    end
    rootOptions[#rootOptions+1]={title='抽選する属性を設定',icon='sliders',
        description='変更は次回更新・リロールから適用します。',onSelect=function() configure(data) end}
    rootOptions[#rootOptions + 1] = { title = '進捗を更新', icon = 'rotate', onSelect = function() open() end }
    contexts[#contexts + 1] = { id = root, title = 'デイリー / ウィークリークエスト', options = rootOptions }
    lib.registerContext(contexts)
    lib.showContext(selected and prefix .. selected or root)
end

open = function(selected)
    if busy then return end
    local operation = {}
    busy = operation
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
    generation = generation + 1
    local operation=busy
    busy=false
    countdown,overlayStamp=nil,nil
    if overlayVisible then SendNUIMessage({action=prefix..'countdown',visible=false}) end
    overlayVisible=false
    if type(operation)=='table' and operation.kind=='preferences' then lib.closeInputDialog() end
    if type(operation)=='table' and operation.kind=='reroll' then lib.closeAlertDialog() end
    local context = lib.getOpenContextMenu()
    if context and context:sub(1, #prefix) == prefix then lib.hideContext() end
end

RegisterNetEvent('QBCore:Client:OnPlayerUnload', close)
AddEventHandler('onResourceStop', function(name)
    if name == GetCurrentResourceName() then close() end
end)

-- A passive NUI badge counts locally, avoiding an ox_lib menu reopen every second.
RegisterNUICallback('countdownReady',function(_,cb)
    overlayStamp=nil
    cb({})
end)

CreateThread(function()
    while true do
        Wait(250)
        local context=lib.getOpenContextMenu()
        local own=context==prefix..'root' or context==prefix..'daily' or context==prefix..'weekly'
        local visible=own and not busy and countdown~=nil
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
                if epoch==generation and lib.getOpenContextMenu()==context and result.ok then
                    render(result,context==prefix..'root' and nil or context:sub(#prefix+1))
                end
            end
        elseif overlayVisible then
            SendNUIMessage({action=prefix..'countdown',visible=false})
            overlayVisible=false
        end
    end
end)
