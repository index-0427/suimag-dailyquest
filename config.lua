Config = {}

Config.Command = 'dailyquest'
-- キー割り当ては初期状態で無効。必要なら 'F7' 等を指定。
Config.Key = nil
Config.Reset = { offsetMinutes = 540, hour = 5, weekDay = 1 } -- JST / 月曜=1、日曜=7
Config.TickSeconds = 15
Config.AutoCreateTables = true
Config.RequestCooldownMs = 1000
Config.ConsumeCooldownSeconds = 3
Config.Consumables = { water = true, burger = true }
Config.ConflictingResources = { 'noob_battlepass', 'sky_battlepass', 'skybp_events' }

-- 一つのクエストにつき報酬は一種類。金額はテスト導入用の初期値。
-- 公開済みの id / period / metric を変えず、新しい条件は新しいidで追加する。
-- target / reward は期間内の初回作成時にDBへ固定され、変更は次の期間から適用。
Config.Quests = {
    {
        id = 'daily_visit', period = 'daily', metric = 'attendance', target = 1,
        title = '今日の街歩き', description = 'キャラクターで街に参加する。', unit = '日',
        reward = { type = 'bank', amount = 1000 },
    },
    {
        id = 'daily_time', period = 'daily', metric = 'playtime', target = 30 * 60,
        title = '街で過ごす30分', description = '今日、合計30分間接続する（離席時間を含む）。',
        reward = { type = 'bank', amount = 3000 },
    },
    {
        id = 'daily_meals', period = 'daily', metric = 'consume', target = 3,
        title = '食事を忘れずに', description = '水またはバーガーを合計3回使用する。', unit = '回',
        reward = { type = 'bank', amount = 2000 },
    },
    {
        id = 'weekly_visits', period = 'weekly', metric = 'attendance', target = 3,
        title = '今週の常連', description = '今週、異なる3日間に街に参加する。日付は午前5時に切り替わる。', unit = '日',
        reward = { type = 'bank', amount = 5000 },
    },
    {
        id = 'weekly_time', period = 'weekly', metric = 'playtime', target = 3 * 60 * 60,
        title = '街と過ごす一週間', description = '今週、合計3時間接続する（離席時間を含む）。',
        reward = { type = 'bank', amount = 10000 },
    },
    {
        id = 'weekly_meals', period = 'weekly', metric = 'consume', target = 15,
        title = '一週間の食卓', description = '今週、水またはバーガーを合計15回使用する。', unit = '回',
        reward = { type = 'bank', amount = 5000 },
    },
}

-- サーバーexport RecordActivity を呼べるリソースと一回の上限。
-- 連携元に成功確認と一意の完了IDが必要。初期状態では外部連携なし。
Config.Activities = {
    -- delivery = { resources = { ['my-delivery'] = true }, maxAmount = 1 },
}
-- 外部連携クエストの例（Config.Questsに追加）:
-- { id='daily_delivery', period='daily', metric='activity', activity='delivery', target=3,
--   title='配達のお仕事', description='配達を3回完了する。', unit='回',
--   reward={ type='item', name='water', amount=2 } },
