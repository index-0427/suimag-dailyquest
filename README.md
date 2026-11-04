# suimag-dailyquest

FiveM / Qbox 用のデイリー・ウィークリークエスト。Luaのみ、ビルド不要です。
`/dailyquest` で ox_lib のメニューを開き、進捗を確認して達成報酬を受け取ります。

- 日次20候補から3件・週次20候補から2件をキャラクター別に抽選。日次は短時間枠を最低1件
- 日次は毎日 **JST 05:00**、週次は **月曜 JST 05:00** に更新。サーバーOSのタイムゾーンに依存しない
- 初回の属性設定、犯罪／職業・所属必須の除外、未達成1件を日次・週次各1回リロール
- 金銭（銀行／現金）または ox_inventory のアイテム報酬
- 進捗と受取状態を専用SQLテーブルに保存。再接続・リソース再起動後も継続
- 同時受取をSQLの条件付き更新で排他。結果不明の配布は保留し、自動で再配布しない
- 既存ジョブの自動連携、永続クールダウン、新規連携向けexportと完了IDによる重複排除
- 既存の `noob_battlepass` / `sky_battlepass` / `skybp_events` が起動中なら進行・受取を休止
- 初期状態ではキー割当なし。LB Phone・既存ジョブ・既存DBテーブルへの変更不要

## クエスト

**日次20候補から3件・週次20候補から2件**を固定抽選します。[全40件の目標・報酬・判定元](docs/catalog.md)を用意しています。
来訪・滞在・飲食に加え、徒歩、自転車、自動車、勤務、バス、ごみ回収、電気工事、郵便、タクシー、現金輸送、
釣り、狩猟、建築、高圧洗浄、リサイクル、家強盗、ブースティングを収録しています。

報酬は提示されたクエストを達成した場合に受け取れます。抽選結果は再接続・再起動でも保持します。
既存6件のID・条件・報酬は維持しています。詳しいルールは [抽選とリロール](docs/selection.md) を参照してください。
職業への所属や仕事・犯罪の参加条件が必要なクエストもあり、全件達成は必須ではありません。
金額はテスト導入用の初期値です。経済への影響を確認して config.lua で調整してください。
接続時間には離席を含み、キャラクター選択画面・オフライン時間は含みません。導入前の実績は遡及しません。
接続したまま午前5時をまたいだ場合も新しい日の参加として数えます。
期限までに手動で受け取らなかった報酬は失効します。

## 導入

OneSync有効環境で使用します。必要なリソース: `oxmysql` / `ox_lib` / `qbx_core` / `ox_inventory`。
対応バージョンと連携方針は [互換性と移行](docs/compatibility.md) を参照してください。

1. リポジトリを **suimag-dailyquest** というフォルダ名で配置します。単一インスタンスのみ対応します。
2. 旧バトルパスとその連携リソースの起動指定を整理します。`ensure [standalone]` などのカテゴリ起動にも注意してください。
3. 依存リソース・カテゴリ起動の後に下記を設定します。同じ依存の ensure を追加する必要はありません。
4. 起動時に `sql/schema.sql` の専用7テーブルを自動作成します。自動作成しない運用では管理者が先にSQLを実行し、`Config.AutoCreateTables = false` にします。
5. コンソールで `dailyquest_status`、ゲーム内で `/dailyquest` を確認します。

```cfg
# 既存の依存リソースとカテゴリの ensure より後に配置
# 旧リソースの自動起動指定からも外してください。
stop skybp_events
stop sky_battlepass
# noob_battlepass を導入している環境のみ停止
# stop noob_battlepass

ensure suimag-dailyquest
```

このリポジトリの実装・ローカル検証では **接続先への配置、DB操作、stop/ensure/restartは実行していません**。
実機導入手順と確認項目は [運用・受入確認](docs/operations.md) にあります。

1.1.0以前から更新する場合は preferences / boards / assignments テーブルも必要です。自動作成が無効なら sql/schema.sql を再適用してください。

## 設定

`config.lua` の `Config.Quests` が表示順です。

- `id`: 保存キー。公開後は変更しない。条件を別物にする場合は新しいIDを追加
- `period`: `daily` / `weekly`
- `metric`: `attendance`（参加日数）/ `playtime`（秒）/ `consume`（使用回数）/ `distance`（移動距離m）/ `duty`（勤務秒）/ `activity`（外部連携）
- `target`: 正の整数。参加日数は日次1、週次最大7
- `reward`: `{ type = 'bank', amount = 1000 }`、`{ type = 'cash', amount = 1000 }`、
  または `{ type = 'item', name = 'water', amount = 2 }`
- 飲食対象は `Config.Consumables` の実在するアイテム名を指定。現在は対応環境で確認した `water` / `burger` のみ
- `Config.Key` を設定すると FiveM のキー設定に登録。既存操作との重複を確認してから指定

**目標値・報酬は各キャラクターのその期間の初回記録時に固定**されます。途中で設定を変更しても作成済みレコードには反映しません。
期間途中の変更では、まだ記録のないキャラクターに新設定が適用されます。全員を揃える変更は更新時刻に行ってください。
`id / period / metric / activity / tags / requirements / quick / Reset` を運用中に書き換えると期間の解釈が変わるため、停止して移行方針を決めてください。
タイトル・説明・飲食対象の変更は即時反映されるため、進行中の条件と食い違わないようにします。
削除したクエストは表示・受取対象から外れますが、保存記録は残ります。

## ジョブ連携

任意のサーバーリソースの成功処理から呼びます。初期設定では13の連携元を許可しています。自動連携の契約は [連携仕様](docs/integrations.md) を参照してください。新しい連携元は明示的に追加します。

```lua
-- config.lua
Config.Activities.delivery = {
    resources = { ['my-delivery'] = true },
    maxAmount = 1,
}
Config.Quests[#Config.Quests + 1] = {
    id = 'daily_delivery', period = 'daily',
    metric = 'activity', activity = 'delivery', target = 3,
    title = '配達のお仕事', description = '配達を3回完了する。', unit = '回',
    reward = { type = 'item', name = 'water', amount = 2 },
}
```

```lua
-- my-delivery のサーバー側。完了を検証・確定した処理の中で実行。
-- completionId はジョブ側で保存する一意ID。再試行時にも同じIDを使う。
local ok, reason = exports['suimag-dailyquest']:RecordActivity(
    source, 'delivery', 1, 'delivery-' .. completionId
)
```

引数は対象プレイヤーID、活動名、加算数、一意の完了IDです。
完了IDは英数字・`_`・`-` の1〜96文字。同じ citizenid / 活動名 / 完了ID は、週が変わっても一度しか加算しません。
複数の連携元が同じ活動を使う場合は完了IDにリソース名などを含めてください。
重複送信や、その活動のクエストが提示されていない場合も、受付成功として `true` を返します。進捗は提示中の該当クエストにだけ加算します。失敗は `false, reason` です。
`busy` / `storage_error` / `not_ready` は同じ完了IDで再試行できます。`forbidden` / `invalid_activity` は設定・引数を修正します。
オフラインプレイヤーは対象外です。成功通知前に切断した仕事を後日自動精算する機能はありません。

**クライアントから任意の進捗・加算数・報酬額を送るイベントはありません。**
外部連携側でも、クライアントの完了申告をそのままexportに流さず、所持品・位置・ジョブ状態・完了IDなどをサーバーで検証してください。
旧 `skybp:*` のうち、成功前の狩猟通知は使用しません。リサイクル・ブースティングは確認済みの完了通知を発火元チェック付きで購読します。

ほかのクライアントUIからメニューを開く場合:

```lua
exports['suimag-dailyquest']:OpenQuests()
```

## 保存と障害時の扱い

専用テーブルは `suimag_dailyquest_progress`、`suimag_dailyquest_visits`、`suimag_dailyquest_events`、`suimag_dailyquest_signal_gates`、`suimag_dailyquest_preferences`、`suimag_dailyquest_boards`、`suimag_dailyquest_assignments` です。
既存のQbox・バトルパスのテーブルは変更しません。自動削除はなく、移転時はこの7テーブルもバックアップしてください。

接続時間は約15秒ごとに保存します。切断・正常停止・強制終了で最後の未保存区間を失う場合があります。
DB障害で結果不明の時間加算は再送しません。長いサーバーストールや時計の大幅な変化中の時間も加算しません。
飲食の保存に失敗した操作は自動再送せず、ログを記録します。

報酬受取は `active → pending → claimed`。明確な付与失敗のみ `active` に戻します。
例外・プロセス停止などで成否不明なら `pending` を保持し、自動再配布しません。
満杯のインベントリは受取権を消費しません。期限内に空きを作れば再試行できます。

Qboxの所持金保存・ox_inventoryの保存と当リソースのSQLは**同一トランザクションではありません**。
報酬プロバイダーの成功後も、サーバー全体の強制終了ではプロバイダー側の保存が間に合わない場合があります。
厳密なexactly-once配布は保証しません。確認番号 `dailyquest:<claimId>` と付与ログで管理者が照合します。
保留を一括解除したり自動再試行したりせず、[運用手順](docs/operations.md) に従ってください。

## 開発・検証

Lua 5.4、Python 3、MariaDBのサーバー／クライアントが必要です。追加言語パッケージ不要。

```bash
find . -name '*.lua' -not -path './.git/*' -print0 | xargs -0 -n1 luac -p
TZ=UTC lua tests/domain_spec.lua
TZ=America/New_York lua tests/domain_spec.lua
lua tests/server_spec.lua
lua tests/client_spec.lua
lua tests/catalog_spec.lua
lua tests/selection_spec.lua
lua tests/boards_spec.lua
lua tests/tracking_spec.lua
lua tests/adapters_spec.lua
python3 tests/sql_spec.py
```

SQL検証は `/tmp/suimag-dq-db-*` に使い捨てDBを起動し、ネットワークを無効にして専用Unixソケットだけを使います。
既存のDB・設定ファイル・外部サーバーには接続しません。終了時は検証用プロセスを停止し、一時データを削除します。
GitHub Actionsでも同じ検証を実行します。
FiveMの実描画・ゲーム接続・各報酬プロバイダーの動作は実機確認が必要です。

## API参照

- [Qbox Server Exports](https://docs.qbox.re/resources/qbx_core/exports/server)
- [FiveM Secure Your Events](https://docs.fivem.net/docs/developers/server-security/)
- [Ox Lib Context Menu](https://overextended.dev/docs/ox_lib/Interface/Client/context)
- [Oxmysql Transaction](https://overextended.dev/docs/oxmysql/Functions/transaction)
