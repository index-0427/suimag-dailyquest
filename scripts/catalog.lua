dofile('config.lua')
dofile('server/domain.lua')
DQ.validate(Config)
local function target(q)
    if q.metric=='playtime' or q.metric=='duty' then return ('%g分'):format(q.target/60) end
    if q.metric=='distance' then return ('%gkm'):format(q.target/1000) end
    return q.target..(q.unit or '回')
end
local function collector(q)
    if q.metric=='activity' then
        local rule=Config.Activities[q.activity]
        return rule.resource .. (rule.payment and '：入金＋精算通知' or '：完了通知')
    end
    return ({attendance='Qboxのキャラクター参加',playtime='サーバー接続時間',
        consume='ox_inventoryの使用完了',distance='OneSyncのサーバー位置観測',duty='Qboxの出勤状態'})[q.metric]
end
io.write([[
# クエスト一覧

日次20候補から3件、週次20候補から2件をキャラクター別に固定抽選します。
日次は短時間枠を最低1件含め、犯罪・職業必須の除外設定、実際の所属、連携元の稼働状態を反映します。
[抽選・リロールのルール](selection.md) を参照してください。
クエストのID・条件を維持し、金銭報酬は全候補共通です。デイリー1件15万・ウィークリー1件50万。
犯罪タグには黒コイン、職業・所属必須タグには白コインを追加します。日次1枚・週次3枚です。
日次はJST毎日05:00、週次はJST月曜05:00に更新します。

デイリー全3件をクリアすると、追加20万＋Fleトークン1枚を1日1回受け取れます（日次合計65万）。週次2件は合計100万です。
下表は全候補の一覧です。実際に提示される3件・2件だけが進捗・報酬の対象です。
勤務クエストは職業への所属・出勤が必要です。ジョブ・犯罪は各リソースの参加条件に従います。
連携元が未起動の未達成クエストには「連携元が未起動」を表示し、達成済みの報酬は受け取れます。

]])
for _,period in ipairs({'daily','weekly'}) do
    io.write(period=='daily' and '## デイリー候補（20種類）\n\n' or '## ウィークリー候補（20種類）\n\n')
    io.write('| ID | クエスト | 目標 | 報酬 | 判定元 |\n| --- | --- | --- | ---: | --- |\n')
    for _,q in ipairs(Config.Quests) do
        if q.period==period then
            local reward=('$%d'):format(DQ.reward(q.period).amount)
            local coin,amount=DQ.coins(q)
            if amount>0 then reward=reward..(' + %s × %d'):format(coin,amount) end
            io.write(('| %s | %s | %s | %s | %s |\n'):format(q.id,q.title,target(q),reward,collector(q)))
        end
    end
    io.write('\n')
end
io.write([[
## 数え方

- バス・ごみ・電気・郵便・現金輸送は、既存リソースが出す**精算通知1回**を1回と数えます。
  1ルートが複数回精算される仕様なら、その精算ごとに数えます。ルート数やアイテム個数とは異なります。
- 上記の精算・タクシー・釣り・狩猟は、同じキャラクターに2秒以内に届いた同額のQbox入金通知と照合します。
  入金だけ、精算通知だけ、クエスト報酬の入金では進みません。照合に使った入金は使い回しません。
- タクシーはNPCルートの入金理由だけを受け付けます。釣りは魚・カニの売却で進み、宝石売却では進みません。
- 狩猟は売却・ミッションの精算を数えます。解体前の通知や獲得アイテム数では数えません。
- 建築は支払い対象の完了通知、清掃は契約完了通知で進みます。
- リサイクルは箱の納品完了です。素材の個数では数えません。
- 家強盗は戦利品取得後にホストが脱出し、完了時の参加者一覧にいるキャラクターが対象です。
  ブースティングは成功フックから通知された参加者が対象です。
- 既存通知に完了一意IDがないため、同じ活動は永続クールダウンで重複を抑えます。
  精算系30秒、建築・清掃・家強盗・ブースティング60秒、リサイクル5秒です。
  正規の作業でもこの間隔未満の2件目は加算しません。再起動・日付更新でクールダウンは解除されません。
  クールダウンを過ぎた古い通知の再送は、新しい完了と区別できません。
- 移動は5秒ごとのサーバー上の位置差（水平距離）を測るため、曲がり道などは実走行より少なく数えます。
  徒歩は非乗車区間、自転車は設定モデル、自動車はautomobileの運転席が対象です。
  同乗・バイク・航空機、車両／席／バケットの変更、死亡・長い欠測、速度上限を超える区間は除外します。
  非乗車の遊泳など、サーバーから歩行と区別できない移動は徒歩側に含まれ得ます。
  OneSync位置情報は不正クライアントを完全に検知する仕組みではありません。
- 勤務時間はQboxの同じ職業で出勤状態が続いた区間のみ。無職・退勤・死亡中は除外します。
  サンプリング間の短い切替までは分解できません。離席中の出勤は含みます。
- 移動・勤務は約15秒ごとに保存。切断等で最後の未保存区間を失う場合があります。
  更新時刻をまたぐ区間は旧期間・新期間に按分して保存します。

この一覧は `lua scripts/catalog.lua > docs/catalog.md` で再生成できます。
]])
