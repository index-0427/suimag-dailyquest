# suimag-dailyquest

FiveM / Qbox 用のデイリー・ウィークリークエスト。Lua + HTML/CSS/JavaScript、ビルド不要です。
F10 または `/dailyquest` で専用GUIを開き、進捗を確認して達成報酬を受け取ります。
ネイビーを基調としたカード型UIで期間を切り替え、Escで閉じます。[GUIの検証手順](docs/gui.md)も用意しています。

- 日次20候補から3件・週次20候補から2件をキャラクター別に抽選。日次は短時間枠を最低1件
- 日次は毎日 **JST 05:00**、週次は **月曜 JST 05:00** に更新。画面を開いている間は日次更新までのカウントダウンを表示
- 初回の属性設定、犯罪／職業・所属必須の除外、未達成1件を日次・週次各1回リロール
- 共通の銀行報酬：デイリー1件15万、全クリア追加20万＋FLEトークン1枚、ウィークリー1件50万
- 犯罪タグは黒コイン、職業・所属必須タグは白コインを追加。デイリー1枚・ウィークリー3枚
- 日次更新時に達成済み・未受取の通常報酬と全クリア報酬を自動受取。オフライン中は次回ログイン時に受取
- 進捗と受取状態を専用SQLテーブルに保存。再接続・リソース再起動後も継続
- 同時受取をSQLの条件付き更新で排他。結果不明の配布は保留し、自動で再配布しない
- 既存ジョブのサーバー内通知との自動連携と、永続クールダウンによる重複抑止
- 初期キー割当はF10。LB Phone・既存ジョブ・既存DBテーブルへの変更不要

## クエスト

**日次20候補から3件・週次20候補から2件**を固定抽選します。[全40件の目標・報酬・判定元](docs/catalog.md)を用意しています。
来訪・滞在・飲食に加え、徒歩、自転車、自動車、勤務、バス、ごみ回収、電気工事、郵便、タクシー、現金輸送、
釣り、狩猟、建築、高圧洗浄、リサイクル、家強盗、ブースティングを収録しています。

報酬は提示されたクエストを達成した場合に受け取れます。抽選結果は再接続・再起動でも保持します。
クエストのID・条件を維持し、報酬は期間ごとの共通設定に統一しています。詳しいルールは [抽選とリロール](docs/selection.md) を参照してください。
職業への所属や仕事・犯罪の参加条件が必要なクエストもあり、全件達成は必須ではありません。
初期設定では、日次全クリアで合計65万、週次2件で合計100万です。全クリア報酬はデイリー画面の専用項目から1日1回受け取れます。
接続時間には離席を含み、キャラクター選択画面・オフライン時間は含みません。導入前の実績は遡及しません。
接続したまま午前5時をまたいだ場合も新しい日の参加として数えます。
日次の達成済み未受取報酬は更新後に自動受取します。週次は従来どおり期限内に手動で受け取ってください。
自動受取はこの機能の初回起動後に迎える日次更新から有効で、導入前に失効した過去の報酬は遡及しません。
詳しくは [更新表示と自動受取](docs/daily-reset.md) を参照してください。

## 導入

OneSync有効環境で使用します。必要なリソース: `oxmysql` / `ox_lib` / `qbx_core` / `ox_inventory`。
対応バージョンと連携方針は [互換性と移行](docs/compatibility.md) を参照してください。

1. リポジトリをリソースディレクトリに配置します。フォルダ名は任意です。以下は `suimag-dailyquest` を例にしています。単一インスタンスで利用します。
2. 依存リソース・カテゴリ起動の後に下記を設定します。同じ依存の ensure を追加する必要はありません。
3. 起動時に `sql/schema.sql` の専用10テーブルを自動作成します。自動作成しない運用では管理者が先にSQLを実行し、`Config.AutoCreateTables = false` にします。
4. コンソールの `Ready. Command: /dailyquest` と、ゲーム内で `/dailyquest` を確認します。

```cfg
# 既存の依存リソースとカテゴリの ensure より後に配置
ensure suimag-dailyquest
```

このリポジトリの実装・ローカル検証では **接続先への配置、DB操作、stop/ensure/restartは実行していません**。
実機導入手順と確認項目は [運用・受入確認](docs/operations.md) にあります。

1.4.0では自動受取の開始時刻を保存する automation テーブルを追加します。1.3.0からは全クリア報酬用の bonuses も必要です。自動作成が無効なら sql/schema.sql を再適用してください。1.1.0以前からは preferences / boards / assignments も必要です。

コイン報酬追加版では、progressテーブルに `reward_coin` と `reward_coin_amount` を追加します。
自動作成が有効なら起動時に追加します（ALTER権限が必要）。無効なら更新前に `sql/schema.sql` を再適用してください。
ox_inventoryに `black_coin`、`white_coin`、`fle_token` が登録されている必要があります。`fle_token` の表示名はアイテム定義の `label` を参照するため、`label = 'FLEトークン'` にしてください。

## 設定

`config.lua` の `Config.Quests` が表示順です。

- `id`: 保存キー。公開後は変更しない。条件を別物にする場合は新しいIDを追加
- `period`: `daily` / `weekly`
- `metric`: `attendance`（参加日数）/ `playtime`（秒）/ `consume`（使用回数）/ `distance`（移動距離m）/ `duty`（勤務秒）/ `activity`（外部連携）
- `target`: 正の整数。参加日数は日次1、週次最大7
- 飲食対象は `Config.Consumables` の実在するアイテム名を指定。現在は対応環境で確認した `water` / `burger` のみ
- `Config.Key` の初期値は `F10`。別のキーに変更でき、`nil` にするとキー登録を無効化

全クリア報酬にFLEトークン（`fle_token`）1枚を追加します。枚数・アイテムIDは `Config.CoinRewards.dailyComplete` / `dailyCompleteItem` で変更できます。既存環境では `sql/schema.sql` の再適用が必要です（自動作成が有効なら起動時に適用）。受取済み・保留中の報酬には遡及付与しません。

金銭報酬は Config.Rewards、タグ別の追加コインは Config.CoinRewards で設定します。個別クエストに reward を書くと設定エラーになります。

```lua
Config.Rewards = {
    account = 'bank',
    daily = 150000,
    dailyComplete = 200000,
    weekly = 500000,
}
```

目標値は各キャラクターの期間初回記録時に固定します。
報酬設定の変更はリソース再起動後、キャラクターの読込時に未受取（active）の当期レコードへ適用します。
受取済み（claimed）と成否確認待ち（pending）は元の金額を維持し、差額の自動補填はしません。
全クリア報酬も同じ扱いです。詳しくは [共通報酬](docs/rewards.md) を参照してください。
`id / period / metric / activity / tags / requirements / quick / Reset` を運用中に書き換えると期間の解釈が変わるため、停止して移行方針を決めてください。
タイトル・説明・飲食対象の変更は即時反映されるため、進行中の条件と食い違わないようにします。
削除したクエストは表示・受取対象から外れますが、保存記録は残ります。

現在のジョブが `admin`、または `Config.DebugAce`（初期値 `admin`）のACEが許可されていると、左側のデバッグから全クエストの進捗検証・リセットと、
サーバー共通の抽選ON/OFFを操作できます。[使い方](docs/gui.md#管理者向けデバッグ)を参照してください。
この追加では検証用進捗と抽選設定の2テーブルが必要です。自動作成が無効なら `sql/schema.sql` を再適用してください。

## ジョブ連携

13の連携元が発火するサーバー内の完了通知を `server/adapters.lua` で受信します。
発火元を確認し、設定に応じてQboxの入金と照合したうえで、永続クールダウン付きで進捗を加算します。
通知の契約と連携元は [連携仕様](docs/integrations.md) を参照してください。
進捗の対象は、接続中のキャラクターに提示されているクエストです。

**クライアントから任意の進捗・加算数・報酬額を送るイベントはありません。**
旧 `skybp:*` のうち、成功前の狩猟通知は使用しません。リサイクル・ブースティングは確認済みの完了通知を発火元チェック付きで購読します。

ほかのクライアントUIからメニューを開く場合:

```lua
exports['suimag-dailyquest']:OpenQuests()
```

フォルダ名を変更した場合は、exportsの参照先もその名前に合わせます。

## 保存と障害時の扱い

専用テーブルは `suimag_dailyquest_progress`、`suimag_dailyquest_visits`、`suimag_dailyquest_signal_gates`、`suimag_dailyquest_preferences`、`suimag_dailyquest_boards`、`suimag_dailyquest_assignments`、`suimag_dailyquest_bonuses`、`suimag_dailyquest_automation`、`suimag_dailyquest_debug_progress`、`suimag_dailyquest_pool` です。
既存のQbox・バトルパスのテーブルは変更しません。自動削除はなく、移転時はこの10テーブルもバックアップしてください。

接続時間は約15秒ごとに保存します。切断・正常停止・強制終了で最後の未保存区間を失う場合があります。
DB障害で結果不明の時間加算は再送しません。長いサーバーストールや時計の大幅な変化中の時間も加算しません。
飲食の保存に失敗した操作は自動再送せず、ログを記録します。

報酬受取は `active → pending → claimed`。金銭未付与が確実な失敗は `active` に戻します。
金銭付与後にコイン付与が失敗・不明になった場合は `pending` を保持し、報酬全体を再配布しません。
例外・プロセス停止などで成否不明なら `pending` を保持し、自動再配布しません。
報酬は共通の金銭報酬（bank / cash）とタグ別の追加コインです。旧版のアイテム単体報酬は付与対象外です。

Qboxの所持金保存・ox_inventoryの保存と当リソースのSQLは**同一トランザクションではありません**。
報酬プロバイダーの成功後も、サーバー全体の強制終了ではプロバイダー側の保存が間に合わない場合があります。
厳密なexactly-once配布は保証しません。確認番号 `dailyquest:<claimId>` と付与ログで管理者が照合します。
保留を一括解除したり自動再試行したりせず、[運用手順](docs/operations.md) に従ってください。

## 開発・検証

Lua 5.4、Node.js、Python 3、MariaDBのサーバー／クライアントが必要です。追加言語パッケージ不要。

```bash
find . -name '*.lua' -not -path './.git/*' -print0 | xargs -0 -n1 luac -p
TZ=UTC lua tests/domain_spec.lua
TZ=America/New_York lua tests/domain_spec.lua
lua tests/server_spec.lua
lua tests/client_spec.lua
lua tests/catalog_spec.lua
lua tests/selection_spec.lua
lua tests/boards_spec.lua
lua tests/settlement_spec.lua
lua tests/tracking_spec.lua
lua tests/adapters_spec.lua
node --check ui/countdown.js
node --check ui/quests.js
node tests/countdown_spec.js
python3 tests/sql_spec.py
```

SQL検証は `/tmp/suimag-dq-db-*` に使い捨てDBを起動し、ネットワークを無効にして専用Unixソケットだけを使います。
既存のDB・設定ファイル・外部サーバーには接続しません。終了時は検証用プロセスを停止し、一時データを削除します。
GitHub Actionsでも同じ検証を実行します。
FiveMの実描画・ゲーム接続・各報酬プロバイダーの動作は実機確認が必要です。

## API参照

- [Qbox Server Exports](https://docs.qbox.re/resources/qbx_core/exports/server)
- [FiveM Secure Your Events](https://docs.fivem.net/docs/developers/server-security/)
- [FiveM NUI Callbacks](https://docs.fivem.net/docs/scripting-manual/nui-development/nui-callbacks/)
- [Oxmysql Transaction](https://overextended.dev/docs/oxmysql/Functions/transaction)
