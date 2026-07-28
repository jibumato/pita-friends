# ホスト報酬の振込 運用手順書(自社銀行振込)

換金方式は **自社の総合振込(GameRoom型)** です(2026-07-21決定)。
Stripeはコイン購入(Checkout)のみに使い、ホストへの振込には関与しません。

- 手数料: 申請1件につき **300コイン(=¥300)** をコイン側で控除(振込額 = 申請コイン − 300)
- 最低申請額: **5,000コイン**(0063で1,000から変更。競合と同条件に揃えた)
- 締め: **毎週日曜締め・翌週金曜払い**(当該日が銀行休業日なら翌営業日)
- 変更したい場合: `supabase/migrations/0063_align_payout_terms.sql` の `c_fee` / `c_min_coins` と、
  `src/lib/queries.ts` の `PAYOUT_FEE_COINS` / `PAYOUT_MIN_COINS` を揃えて変更

> **なぜ週次か。** 競合(GameRoom)は毎週月曜に振り込んでいます。月末締め翌月払いだと
> 最悪60日待たせることになり、手数料率を数pt下げるより体感の差が大きい。
> 0062で自動確定を24時間に縮められるようにしましたが、その後の振込が月次のままでは
> 意味が薄いので、セットで週次にしています。

## ⚠️ 法務上の注意(必読)

自社振込は **資金移動の実行主体が当社になる** ため、資金移動業/収納代行の
法的整理が必要です。**本番で換金機能を有効にする前に必ず弁護士レビューを
受けてください**(`docs/legal/coin-economy-legal-review.md` §7.2)。

## 全体の流れ

```
ホスト: 口座登録(ホスト設定) → 換金申請(ウォレット)
                                     │ payouts(status=pending) が溜まる
運営(週次): ① 締め: 振込リストをSQLで出力
            ② ネットバンキングの総合振込にCSVアップロード → 実行
            ③ 消し込み: mark_payout_paid / 失敗分は mark_payout_failed
```

口座情報は申請時点のスナップショットが `payouts` に保存されるため、
申請後にホストが口座を変更しても、その回の振込リストは変わりません。

## ⓪ 前提: プレイ完了の自動確定(0015)

ゲストが「プレイ完了」を押さない予約は、予約時刻から**72時間で自動確定**されて
ホストの報酬になります(`auto_complete_bookings()`)。0015のマイグレーションが
pg_cron に毎時実行を登録します。Supabaseで pg_cron が無効だった場合は、
ダッシュボード → Database → Extensions で `pg_cron` を有効化してから
0015 の末尾の `do $do$ ...` ブロックを再実行するか、締めの前に手動で
`select public.auto_complete_bookings();` を実行してください。

## ① 締め: 振込リストの出力

Supabase ダッシュボード → SQL Editor で実行し、結果をCSVダウンロードします。

```sql
-- 振込待ち(pending)の一覧。銀行のCSVフォーマットに合わせて列順は調整してください。
select
  p.id                  as payout_id,     -- 消し込みで使うID(振込データには含めない)
  p.bank_code           as 銀行コード,
  p.branch_code         as 支店コード,
  case p.account_type when '普通' then '1' when '当座' then '2' end as 預金種目,
  p.account_number      as 口座番号,
  p.account_holder_kana as 受取人名,
  p.amount_yen          as 振込金額
from public.payouts p
where p.status = 'pending'
order by p.created_at;
```

> 多くのネット銀行(住信SBIネット銀行・GMOあおぞら等)の総合振込は
> 「銀行コード,支店コード,預金種目(1=普通/2=当座),口座番号,受取人名(半角カナ),金額」
> のCSVを受け付けます。**受取人名を半角カナに変換する必要がある銀行**の場合は、
> 銀行側のアップロード画面の変換機能か、Excelで変換してください。

合計金額の確認(振込資金の準備用):

```sql
select count(*) as 件数, sum(amount_yen) as 振込合計
from public.payouts where status = 'pending';
```

## ①-2 締め時の不正チェック(弁護士指摘Q3②: 自己予約・共謀予約の検知)

ボーナスコイン等を「身内の予約→完了確定→換金」で現金化する動線は、
マネロン・不正の温床になりやすい典型ルートです。**振込前に毎回**次のSQLで確認してください。

```sql
-- 換金申請中のホストについて、報酬の「ゲスト集中度」を見る。
-- 特定の1〜2人のゲストからの報酬が大半を占めるホストは個別確認する。
select
  p.user_id                                   as host_id,
  pr.nickname                                 as host_name,
  b.guest_id,
  gp.nickname                                 as guest_name,
  count(*)                                    as 完了予約数,
  sum(b.coins)                                as 報酬コイン合計
from public.payouts p
join public.bookings b on b.host_id = p.user_id and b.status = 'completed'
join public.profiles pr on pr.id = p.user_id
join public.profiles gp on gp.id = b.guest_id
where p.status = 'pending'
group by p.user_id, pr.nickname, b.guest_id, gp.nickname
order by p.user_id, sum(b.coins) desc;
```

疑わしい場合(同一ゲストへの依存が極端・短時間の連続予約・購入直後の即完了など)は、
該当ホストの`mark_payout_failed`で差し戻して事情を確認してから振り込むこと。

## ①-2b ギフト(投げ銭)の不正チェック(弁護士指摘Q11(c))

ギフトは `send_gift` 側で相互送金禁止・チャージ後24時間禁止・上限・**同一端末の自己取引
遮断**・7日換金保留を自動適用しているが、端末IDはクリアされうるため、**振込前に**次の
SQLでもパターンを確認する。

```sql
-- (1) 同一端末を共有しているアカウントの組(自己取引の疑い)。
-- send_gift はこの組の送金を遮断するが、記録済みの関係は必ず目視する。
select d1.device_id,
       d1.user_id as user_a, pa.nickname as name_a,
       d2.user_id as user_b, pb.nickname as name_b
from public.user_devices d1
join public.user_devices d2 on d1.device_id = d2.device_id and d1.user_id < d2.user_id
join public.profiles pa on pa.id = d1.user_id
join public.profiles pb on pb.id = d2.user_id
order by d1.device_id;

-- (2) 受け取りギフトの「送り主集中度」。特定の1〜2人からの受領が大半を占める
-- 換金申請中ホストは個別確認する(共謀の疑い)。
select p.user_id as host_id, pr.nickname as host_name,
       g.sender_id, sp.nickname as sender_name,
       count(*) as ギフト件数, sum(g.coins) as 受領コイン合計
from public.payouts p
join public.gifts g on g.receiver_id = p.user_id
join public.profiles pr on pr.id = p.user_id
join public.profiles sp on sp.id = g.sender_id
where p.status = 'pending'
group by p.user_id, pr.nickname, g.sender_id, sp.nickname
order by p.user_id, sum(g.coins) desc;

-- (3) 直近7日の受領ギフト(=まだ換金保留中)の額。換金可能額の内訳確認用。
select receiver_id, sum(coins) as 保留中ギフト
from public.gifts
where created_at > now() - interval '7 days'
group by receiver_id
order by sum(coins) desc;

-- (4) IP要確認フラグの立ったギフト(送り主と受け手が同一IPを共有した履歴あり)。
-- 遮断はしていないので、換金前に個別確認する。
select g.id, g.created_at, g.coins,
       g.sender_id, sp.nickname as sender_name,
       g.receiver_id, rp.nickname as receiver_name
from public.gifts g
join public.profiles sp on sp.id = g.sender_id
join public.profiles rp on rp.id = g.receiver_id
where g.ip_flagged
order by g.created_at desc;

-- (5) 同一IPを共有しているアカウントの組(調査の入口)。
select a.ip,
       a.user_id as user_a, pa.nickname as name_a,
       b.user_id as user_b, pb.nickname as name_b
from public.user_ips a
join public.user_ips b on a.ip = b.ip and a.user_id < b.user_id
join public.profiles pa on pa.id = a.user_id
join public.profiles pb on pb.id = b.user_id
order by a.ip;
```

疑わしい場合は該当ホストの`mark_payout_failed`で差し戻し、事情確認してから振り込むこと。
IP一致は同一Wi-Fi・キャリアNATでも起きるため、それ単体では不正と断定しないこと。

> **稼働中の監視**: 端末ID(0021・同一端末は送信遮断) / IP共有(0022・調査フラグ)。
> **継続課題(未実装)**: カード(決済手段)フィンガープリントの監視は、購入フロー
> (Stripe webhook)で payment_method のフィンガープリントを保存する改修が必要。

## ①-3 資金の分別管理(弁護士指摘Q2(c))

ユーザーのコイン購入代金(Stripeからの入金)と報酬振込の原資は、**事業資金と
別の専用口座**で管理してください(収納代行の預り金性格の裏付け+倒産時の
ユーザー保護の説明材料。弁護士の強い推奨事項)。

## ② 総合振込の実行

1. ネットバンキングにログイン → 総合振込(一括振込)メニュー
2. ①のCSVをアップロード → 内容を確認 → 承認・実行
3. 振込日はアプリ内の表示(`Wallet.tsx` の「毎週日曜締め・翌週金曜払い」)と
   一致させること。**ずれると規約(第7条6項)・特商法表記とも食い違う**ので、
   運用を変えるときは3か所を同時に直す

> 💡 振込手数料の実費は銀行によって大差があります(ネット銀行: 他行宛¥145〜160/件、
> メガバンク: ¥250〜660/件)。件数が増えてきたら法人口座をネット銀行に。

## ③ 消し込み

**全件成功した場合**(SQL Editorで):

```sql
-- pending全件を振込済みにする(②を実行した直後にだけ使うこと)
select public.mark_payout_paid(id) from public.payouts where status = 'pending';
```

**一部失敗した場合**(口座相違などでエラーになった行):

```sql
-- 失敗した1件を差し戻す(コインは手数料も含め全額払い戻される)
select public.mark_payout_failed('<payout_id>', '口座番号相違のため振込不能');
-- 残りの成功分を振込済みにする
select public.mark_payout_paid(id) from public.payouts where status = 'pending';
```

失敗分はホストのウォレットに「失敗」と表示され、コインが戻ります。
ホストに口座情報の修正を依頼し、修正後に再申請してもらってください。

## エラー(振込不能)を減らすコツ

- アプリ側で口座番号7桁・支店コード3桁・カナ名義を入力時に検証済み
- それでも起きる主因は「名義相違」(旧姓のまま・スペース有無)と「口座解約済み」
- 発生率の目安は1〜3%。1件の対応(連絡→修正→再申請→次回振込)に10〜20分かかるため、
  振込前に銀行の「事前チェック」機能があれば使うこと
- **振込後に返る(組戻し)と手数料¥660〜880が当社負担**になるので、事前チェック推奨

## 週次の所要時間の目安

| 作業 | 時間 |
|---|---|
| 締め・リスト出力(①) | 10分 |
| アップロード・承認・資金確認(②) | 15分 |
| 消し込み(③) | 10分 |
| エラー対応 | 件数の1〜3% × 15分 |

1回あたり35分＋エラー対応で、**月4回なら2.5〜4時間程度**が目安です。
月次(1回)より1〜1.5時間ほど増えますが、件数が同じなら1回あたりの件数は
4分の1になるので、エラー対応の総量は変わりません。増えるのは締めと
アップロードの手間だけです。

> 💡 **振込手数料の実費は件数に比例するので、週次にしても総額は変わりません**
> (同じホストが月4回申請すれば増えますが、最低5,000コインの制約があるので
> 少額を小刻みに申請されることは起きにくい)。

### 週次の運用日
- **日曜 23:59 締め**(それまでに `pending` になった申請が対象)
- **翌週金曜に振込実行**
- 金曜が銀行休業日なら翌営業日

**なぜ日曜締め・金曜払いか。**(金曜締め・水曜払いから変更)

締めから支払いまでの日数はどちらも5日で、申請は週内にほぼ均等に発生するため、
**締め曜日を変えても平均の待ち時間は変わりません**。それでも日曜締めを選ぶ理由:

1. **①-2の不正チェックに使える営業日が2日→4日になる。** 自己予約・共謀予約の
   検知はこの手順が実質唯一の防波堤で、怪しい行を見つけてから本人に確認して
   判断する余地が要る。金曜締め・水曜払いだと月火の2日しかなく、
   月曜に別件が入っただけで詰む。
2. **週末の稼ぎが同じサイクルに入る。** プレイは金土日に集中する。0062で常連との
   予約は24時間確定にできるので、金曜のプレイは土曜に確定する。日曜締めなら
   その週に入るが、金曜23:59締めだと丸1週間待たせることになる。
3. **金曜着金はホストにとって都合がよい**(週末に使える)。

> ⚠️ **金曜払いの弱点。** 振込エラー(名義相違・口座解約)が金曜に判明すると、
> 対応が週明けになります。組戻しが発生すると手数料¥660〜880が当社負担です。
> 失敗分は `mark_payout_failed` でコインが全額(手数料込み)ホストのウォレットに
> 戻るので宙ぶらりんにはなりませんが、**銀行の事前チェック機能があれば必ず使って
> ください**。木曜払いにすれば金曜に手当てできますが、金曜着金の価値を優先しています。

> 💡 **滞留(キャッシュフロー)を延ばしたいなら、締め曜日ではなく
> 「締め〜支払いの日数」か「最低換金額」を動かすこと。** 締め曜日は効きません。
