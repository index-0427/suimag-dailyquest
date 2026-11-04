local prefix = 'suimag-dailyquest:'
local busy, generation, lastList = false, 0, nil
local open

local errors = {
    not_ready = 'クエストの準備中です。しばらくしてからお試しください。',
    conflict = '既存のバトルパスと切替作業中のため、クエストを休止しています。',
    player_unavailable = 'キャラクターの読み込み後に開いてください。',
    storage_error = '保存処理に失敗しました。時間をおいてお試しください。',
    busy = '処理中です。しばらくしてからお試しください。',
    rate_limited = '操作が速すぎます。少し待ってからお試しください。',
    invalid_request = '無効なクエストです。一覧を更新してください。',
    expired = '更新時刻を過ぎました。新しいクエストを確認してください。',
    pending = '報酬は確認待ちです。二重配布防止のため再受取を停止しています。管理者へご連絡ください。',
    claimed = 'この報酬は受取済みです。',
    incomplete = 'まだ目標に達していません。',
    invalid_item = '報酬アイテムが未登録です。管理者へご連絡ください。',
    inventory_full = '持ち物に空きがありません。空けてから再度受け取ってください。',
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

local function render(data, selected)
    local root = prefix .. 'root'
    local contexts = {}
    local rootOptions = {}
    for _, kind in ipairs({ 'daily', 'weekly' }) do
        local title = kind == 'daily' and 'デイリー' or 'ウィークリー'
        local reset = kind == 'daily' and data.dailyReset or data.weeklyReset
        local options = {
            { title = '次回更新: ' .. reset, description = '期限を過ぎた報酬は受け取れません。', icon = 'clock', readOnly = true },
        }
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
                    readOnly = not canClaim,
                    onSelect = canClaim and function() receive(quest) end or nil,
                }
            end
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
    busy = false
    local context = lib.getOpenContextMenu()
    if context and context:sub(1, #prefix) == prefix then lib.hideContext() end
end

RegisterNetEvent('QBCore:Client:OnPlayerUnload', close)
AddEventHandler('onResourceStop', function(name)
    if name == GetCurrentResourceName() then close() end
end)
