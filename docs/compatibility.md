# 互換性と移行

## 対象

Qbox + ox_inventory を使用するFiveMサーバー向けです。ESXやqb-inventoryには対応していません。
次の版のソース/APIを参照して実装しています。実ゲームでの受入確認は別途必要です。

| リソース | 参照版 | 使用する機能 |
| --- | --- | --- |
| qbx_core | 1.23.0 | GetPlayer、AddMoney、サーバー内のPlayerLoaded / OnPlayerUnload |
| ox_inventory | 2.45.0 | usedItem、Items、CanCarryItem、AddItem |
| ox_lib | 3.32.3 | サーバーcallback、context menu、notify |
| oxmysql | 2.12.3 | query / single / update / transaction のawait |

Qboxの直接exportを使用し、qb-core互換ブリッジには依存しません。
UIは既存ox_libを使用するため、電話リソース・追加NUIビルドへの依存もありません。

## 連携上の前提

- プレイヤーの識別はcitizenidとサーバー内セッションで行います。
  FiveM exportは値をシリアライズするため、返されたPlayerテーブルの同一性には依存しません。
- `QBCore:Server:PlayerLoaded` はサーバー側のキャラクター生成通知です。
  クライアントが送れる `QBCore:Server:OnPlayerLoaded` と区別し、Qboxからの通知だけを受け付けます。
- ログアウト通知からプレイヤー削除までの間も、旧キャラクターの進捗・受取を拒否します。
- 飲食はox_inventoryのローカル使用完了イベントを受けます。使用前のフックでは加算しません。
- 外部ジョブはサーバー側で完了を確定してから、独自の永続的な完了IDを添えて `RecordActivity` を呼びます。
  旧バトルパスの活動通知には成功前の通知もあるため、自動で流用しません。

## 旧バトルパスとの切替

`Config.ConflictingResources` の初期値は `noob_battlepass`、`sky_battlepass`、`skybp_events` です。
いずれかが起動中・起動準備中なら、当リソースの進行と受取を休止します。
既存リソースは自動停止しません。停止後は本リソースの再起動なしで操作を再開できます。

旧バトルパスと、その連携用リソースを併せて停止してください。
カテゴリの `ensure [standalone]` 等から再起動されないように起動設定も整理します。
既存のすべてのクエストを移植するものではなく、日次20件・週次20件と追加用APIを提供します。

サーバー固有の資材一覧・実配置・認証情報はこの公開リポジトリに含めません。
すべての購入リソースや独自改造との無競合を保証するものではないため、導入後は [受入確認](operations.md) を行ってください。
## 40件カタログの追加要件

OneSyncのサーバーネイティブで5秒ごとに位置・運転席・車種を観測します。
既存資材で確認した13活動の通知を使うため、標準配布版に同じ通知があるとは限りません。
[連携仕様](integrations.md) と [全40件一覧](catalog.md) を参照してください。
完了前の狩猟アイテム通知、クライアント申告のATM・救急・配車イベントは使用していません。
