Config = {}

Config.Command = 'dailyquest'
-- F11でクエスト画面を開く。キー割り当てを無効にする場合は nil。
Config.Key = 'F11'
Config.Reset = { offsetMinutes = 540, hour = 5, weekDay = 1 } -- JST / 月曜=1、日曜=7
Config.TickSeconds = 15
Config.AutoCreateTables = true
Config.RequestCooldownMs = 1000
Config.ConsumeCooldownSeconds = 3
Config.Consumables = { water = true, burger = true }
Config.ConflictingResources = { 'noob_battlepass', 'sky_battlepass', 'skybp_events' }

-- 報酬は全クエスト共通。デイリー3件で45万＋全クリア20万、ウィークリー2件で100万。
Config.Rewards = { account='bank', daily=150000, dailyComplete=200000, weekly=500000 }
-- 公開済みの id / period / metric を変えず、新しい条件は新しいidで追加する。
-- target は期間内の初回作成時に固定。共通報酬の変更は未受取(active)に適用し、保留・受取済みは維持。
Config.Quests = {
    {
        id = 'daily_visit', period = 'daily', metric = 'attendance', target = 1,
        title = '今日の街歩き', description = 'キャラクターで街に参加する。', unit = '日',
    },
    {
        id = 'daily_time', period = 'daily', metric = 'playtime', target = 30 * 60,
        title = '街で過ごす30分', description = '今日、合計30分間接続する（離席時間を含む）。',
    },
    {
        id = 'daily_meals', period = 'daily', metric = 'consume', target = 3,
        title = '食事を忘れずに', description = '水またはバーガーを合計3回使用する。', unit = '回',
    },
    {
        id = 'weekly_visits', period = 'weekly', metric = 'attendance', target = 3,
        title = '今週の常連', description = '今週、異なる3日間に街に参加する。日付は午前5時に切り替わる。', unit = '日',
    },
    {
        id = 'weekly_time', period = 'weekly', metric = 'playtime', target = 3 * 60 * 60,
        title = '街と過ごす一週間', description = '今週、合計3時間接続する（離席時間を含む）。',
    },
    {
        id = 'weekly_meals', period = 'weekly', metric = 'consume', target = 15,
        title = '一週間の食卓', description = '今週、水またはバーガーを合計15回使用する。', unit = '回',
    },
}


-- OneSync上の位置とQboxの勤務状態をサーバーで観測。
Config.Tracking = {
    sampleSeconds = 5,
    maxSpeed = { walk = 9, cycle = 25, drive = 120 }, -- m/s、超過区間は破棄
    bicycles = { 'bmx', 'cruiser', 'fixter', 'scorcher', 'tribike', 'tribike2', 'tribike3' },
    excludedJobs = { unemployed = true },
}

-- 既存リソースを変更せず、確認済みのサーバー内通知を受信する。
-- payment=true は直前のQbox入金と照合。給与・送金・クエスト報酬だけでは進まない。
-- 永続クールダウンは日付更新・リソース再起動でも維持される。
Config.Activities = {
    bus = { resource='gg_busjob', signal='job', payment=true, cooldown=30 },
    garbage = { resource='gg_garbagejob', signal='job', payment=true, cooldown=30 },
    electrician = { resource='gg_electricianjob', signal='job', payment=true, cooldown=30 },
    postal = { resource='gg_gopostal', signal='job', payment=true, cooldown=30 },
    taxi = { resource='gg_taxijob', signal='job', payment=true, reasons={ ['Finshed Taxi Route']=true }, cooldown=30 },
    gruppe = { resource='gg_gruppejob', signal='job', payment=true, cooldown=30 },
    fishing = { resource='pug-fishing', signal='job', payment=true, reasons={ ['sell-fish']=true, ['sell-crabs']=true }, cooldown=30 },
    hunting = { resource='wais-hunting', signal='job', payment=true, cooldown=30 },
    construction = { resource='tw-builderjob', signal='job', cooldown=60 },
    cleaning = { resource='kq_powerwashing', signal='job', cooldown=60 },
    recycle = { resource='jim-recycle', signal='recycle', cooldown=5 },
    house = { resource='satou_houserobbery', signal='house', cooldown=60 },
    boosting = { resource='gg_boosting', signal='boosting', cooldown=60 },
}
for _, rule in pairs(Config.Activities) do
    rule.resources = { [rule.resource] = true }
    rule.maxAmount = 1
end

-- 日次20種類・週次20種類。既存6件のIDと条件は維持。
local function pair(id, metric, daily, weekly, titles, description, extra)
    for i, period in ipairs({ 'daily', 'weekly' }) do
        local quest = {
            id=period .. '_' .. id, period=period, metric=metric,
            target=i == 1 and daily or weekly, title=titles[i],
            description=description,
        }
        for key, value in pairs(extra or {}) do quest[key] = value end
        Config.Quests[#Config.Quests + 1] = quest
    end
end

pair('walk', 'distance', 1000, 7000, { '街角ウォーキング', '一週間の街歩き' },
    '車に乗らず街を移動する。通常の歩行・走行をサーバーで計測する。', { mode='walk', unit='m' })
pair('cycle', 'distance', 3000, 20000, { 'ペダルをこいで', 'サイクリング週間' },
    '自転車を運転して移動する。同乗・車両の乗換区間は対象外。', { mode='cycle', unit='m' })
pair('drive', 'distance', 8000, 60000, { '今日のドライブ', '街をつなぐドライバー' },
    '自動車を運転して移動する。同乗・バイク・航空機は対象外。', { mode='drive', unit='m' })
pair('duty', 'duty', 30*60, 3*60*60, { '今日の勤務', '一週間のお仕事' },
    'Qboxの職業で出勤して過ごす。無職・退勤中・死亡中は対象外。')

pair('bus', 'activity', 1, 5, { '街の足を支える', 'バス運行の一週間' },
    'バス業務の精算通知と入金を確認する。精算1回で進捗+1。', { activity='bus', unit='回' })
pair('garbage', 'activity', 1, 5, { '街をきれいに', 'ごみ回収のエキスパート' },
    'ごみ回収業務の精算通知と入金を確認する。精算1回で進捗+1。', { activity='garbage', unit='回' })
pair('electrician', 'activity', 2, 10, { '街に明かりを', '電気設備を守る' },
    '電気工事業務の精算通知と入金を確認する。精算1回で進捗+1。', { activity='electrician', unit='回' })
pair('postal', 'activity', 2, 10, { '今日のお届けもの', '配達の頼れる人' },
    '郵便配達の精算通知と入金を確認する。精算1回で進捗+1。', { activity='postal', unit='回' })
pair('taxi', 'activity', 2, 12, { 'お客様を目的地へ', '今週のタクシードライバー' },
    'NPCタクシーのルートを終え、運賃の入金を受ける。', { activity='taxi', unit='回' })
pair('gruppe', 'activity', 1, 5, { '大切な荷物を守る', '現金輸送のプロ' },
    '現金輸送業務の精算通知と入金を確認する。精算1回で進捗+1。', { activity='gruppe', unit='回' })
pair('fishing', 'activity', 1, 5, { '今日の水揚げ', '一週間の漁獲便り' },
    '釣りで手に入れた魚またはカニを売却して入金を受ける。宝石売却は対象外。', { activity='fishing', unit='回' })
pair('hunting', 'activity', 1, 5, { '狩りの成果', 'ハンターの一週間' },
    '狩猟の売却・ミッションで精算通知と入金を受ける。獲得アイテム数では数えない。', { activity='hunting', unit='回' })
pair('construction', 'activity', 1, 4, { '街づくりに参加', '今週の建築クルー' },
    '建築の仕事を完了し、支払い対象のクルーとして完了通知を受ける。', { activity='construction', unit='回' })
pair('cleaning', 'activity', 1, 4, { '高圧洗浄の日', '街を磨く一週間' },
    '高圧洗浄の契約を完了し、サーバーの完了通知を受ける。', { activity='cleaning', unit='回' })
pair('recycle', 'activity', 5, 30, { '資源を次の誰かへ', '循環する街' },
    'リサイクルの箱を回収・納品する。素材の個数ではなく箱の納品回数で数える。', { activity='recycle', unit='箱' })
pair('house', 'activity', 1, 3, { 'ひと仕事して脱出', '家強盗の一週間' },
    '戦利品を得てホストが脱出する家強盗を完了する。完了時の参加者が対象。', { activity='house', unit='回' })
pair('boosting', 'activity', 1, 3, { 'ターゲット車両を届ける', '今週のブースティング' },
    'ブースティングを完了する。成功フックで通知されたグループ参加者が対象。', { activity='boosting', unit='回' })

-- カタログから各期間に提示する件数。設定保存前は抽選・進捗加算をしない。
Config.Draw = { daily=3, weekly=2 }
-- タグは複数付与可能。必要なら requirements.jobs={police=2} / types={leo=true} で所属・最低ランクを限定。
for _, quest in ipairs(Config.Quests) do
    quest.tags = {}
    if quest.activity == 'house' or quest.activity == 'boosting' then quest.tags.crime = true end
    if quest.metric == 'duty' then
        quest.tags.employment = true
        quest.requirements = { employed=true }
    end
    quest.quick = quest.period == 'daily' and
        (quest.metric == 'attendance' or quest.metric == 'consume'
            or (quest.metric == 'distance' and (quest.mode == 'walk' or quest.mode == 'cycle')))
end
