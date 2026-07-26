# 取引データを失わないための備え

お金を扱う以上、いちばん避けたいのは「取引記録が壊れる」ことです。
ただし本当に怖いのは壊れること自体ではなく、**壊れたことに気づかないまま
時間が経つ**ことです。バックアップを持っていても、破損に3か月気づかなければ
どの時点まで巻き戻すのが正しいのか判断できず、復元しても意味がありません。

そのため対策を3層に分け、**検知を最優先**で入れています。

| 層 | やること | 状態 |
|---|---|---|
| ① 予防 | 台帳を追記専用にし、誤操作で壊れないようにする | ✅ `0044` |
| ② 検知 | 毎日、残高と履歴を突き合わせ、ズレたら通知する | ✅ `0043` |
| ③ 復旧 | 任意の時点に巻き戻せるようにする | ⬜ **Supabase Pro + PITR の有効化が必要** |

③ だけは管理画面での契約・設定なので、こちらで実装できません。
**コインを1円でも売る前に済ませてください**(手順は末尾)。

---

## なぜ検知が成り立つのか

この設計にはもともと冗長性があります。同じ事実を別の形で3通り持っています。

- `coin_wallets.balance` / `bonus_balance` … `coin_lots`(取得ロット)の集計キャッシュ
- `coin_transactions` … 全ての残高変動の履歴(0003〜0046 の67か所から記録)
- `coin_purchases` … Stripe 側にも同じ記録が残る

いちばん効く不変条件はこれです。

```
Σ coin_transactions.amount == balance + bonus_balance + earned_balance
```

残高の変動は必ず1行の履歴を伴うので、**どのバケット(有償/ボーナス/報酬)に
入ったかを分類しなくても、合計だけで全てのズレを捕まえられます**。
この式が実装に対して本当に成り立つことは、実際のRPCだけで一通りの取引を
回してから照合する `supabase/tests/98_integrity_checks.sql` で確認しています。

特に危ないのは `greatest(0, balance - X)` 形式の更新です
(`0018` の `expire_coins`、`0030`/`0040` の失効差し引き、`0033` の手数料控除)。
既にズレていると更新側だけが 0 で止まり、履歴には満額が残るため、
ズレが静かに拡大します。上の式はこれを一発で捕まえます。

---

## ① 予防 — 台帳の追記専用化(`0044`)

実務でDBが壊れる原因は、ハードウェア故障よりも**運用中の人為ミス**が
圧倒的に多いです。管理画面から行を選んで消す、`where` を付け忘れた
`UPDATE` を流す、といったものです。

RLS は効きません。管理画面も Edge Function も `service_role` で動くため
RLS を迂回できるからです。テーブル側のトリガーで拒否しています。

| テーブル | 制限 |
|---|---|
| `coin_transactions` | 変更も削除も禁止 |
| `coin_purchases` | 変更も削除も禁止 |
| `payouts` | 削除禁止。金額・宛先の変更も禁止(status の更新は通常運用なので可) |
| `coin_lots` | 削除禁止(`remaining` の更新は消費・失効で必要なので可) |
| `coin_lot_consumptions` | 削除禁止。`restored_at` 以外の変更も禁止 |
| `bookings` | 削除禁止(預かり中のコインが宙に浮く) |

### やむを得ず直接操作するとき

「絶対に変更できない」のは運用として無理があります。いつか正当な訂正が
必要になり、そのときトリガーごと外されて二度と戻らない、というのが
最悪の結末です。そこで**明示的に宣言すれば通るが、宣言は必ず記録される**
形にしています。

```sql
begin;
set local app.ledger_override = 'on';
update public.coin_transactions set note = '...' where id = '...';
commit;
```

旧値・新値・実行者が `ledger_audit` に残るので、誤った訂正はここから
復元できます。防げるのは「うっかり」ですが、狙いはそこで十分です。

### 副作用: ユーザーの物理削除が止まる

マネーテーブルは全て `auth.users` に `on delete cascade` でぶら下がって
いるため、ユーザーを物理削除しようとすると台帳の削除が走り、
`LEDGER_IMMUTABLE` で止まります。**黙って消えることはもうありません。**
退会そのものは後述の匿名化で行います。

---

## ② 検知 — 日次の整合性チェック(`0043`)

毎日 04:07(JST基準の設定はUTCで登録)に `run_integrity_checks()` が走り、
結果を `integrity_checks` に記録します。`error` が1件でもあれば
**管理者全員に通知**が飛びます。

| チェック | 見ているもの | 重さ |
|---|---|---|
| `wallet_vs_lots_paid` / `_bonus` | 残高キャッシュ vs ロットの残 | error |
| `wallet_vs_ledger` | 3つの残高の合計 vs 履歴の累計(**最重要**) | error |
| `purchase_vs_ledger` | 入金記録 vs 履歴(Webhookの二重処理・付与漏れ) | error |
| `payout_vs_ledger` | 換金申請 vs 履歴 | error |
| `escrow_split` | 預かり中の予約の `coins = paid + bonus` | error |
| `stale_expired_lots` | 失効処理(`expire_coins`)が止まっていないか | warn |
| `escrow_outstanding` | 預かり中コインの総額(指標) | ok |
| `unused_coin_balance` | 未使用の前払いコイン総額(指標) | ok |

最後の2つはズレではなく、毎日記録して時系列で見るための数字です。
前払式支払手段の残高監視(基準日 3/31・9/30)の材料にもなります。

### アラートが来たら

```sql
-- 1. 何が鳴っているか
select * from public.integrity_latest;

-- 2. 誰がズレているか(detail に先頭20件が入っている)
select check_name, affected_count, total_gap, detail
from public.integrity_latest where severity = 'error';

-- 3. その人の履歴を時系列で見る
select created_at, type, amount, note, related_booking_id
from public.coin_transactions
where user_id = '<user_id>' order by created_at;

-- 4. いつからズレたか(過去の記録と比べる)
select ran_at, affected_count, total_gap
from public.integrity_checks
where check_name = 'wallet_vs_ledger' order by ran_at desc limit 30;
```

**直す前に原因を特定してください。** 残高を合わせるだけでは同じズレが
翌日また再発します。原因が分かったら、履歴を書き換えるのではなく
**打ち消しの行を追加**して残高を合わせるのが原則です。

手で実行したいときは、管理者としてログインした状態で
`select public.run_integrity_checks();` を呼べます。

---

## 退会は「削除」ではなく「匿名化」(`0046`)

削除請求に応じる義務があるのは**個人情報**であって、取引金額の記録では
ありません。金額の記録には保存義務があります(所得税法上7年、
資金決済法上の記録保持)。プライバシーポリシー草案も
「法令上の保存義務がある場合を除き削除」と書いています。

```sql
-- 未対応の退会請求と、実行できない理由
select * from public.pending_account_deletions;

-- 実行(管理者としてログインした状態で)
select public.anonymize_user('<user_id>');
```

消えるもの: 表示名・自己紹介・アバター・音声・メールアドレス・
振込先口座・本人確認画像・端末ID・IP・通知設定・安心設定

残るもの: `coin_purchases` / `coin_transactions` / `payouts` / `bookings`
(誰のものかは `user_id` でのみ辿れる状態になります)

未処理の取引が残っているうちは実行できません。

| エラー | 意味 | 先にやること |
|---|---|---|
| `OPEN_BOOKINGS_REMAIN` | 進行中の予約がある | 完了かキャンセルまで進める |
| `PENDING_PAYOUT_REMAINS` | 処理待ちの換金がある | 振込を実行するか失敗にする |
| `EARNED_BALANCE_REMAINS` | 未払いの報酬が残っている | 換金してもらう(勝手に消さない) |

残っている前払いコインは失効します(規約:退会時の払戻しなし)。
このとき残高だけ 0 にすると履歴と食い違って②の照合が鳴るため、
ロット・残高・履歴の3点セットで落としています。

> **判断が要る点(未確定)**: メッセージ本文は**消していません**。
> 二者間の会話であり、通報・トラブル対応の証跡としてプライバシーポリシーで
> 保持目的を開示しているためです。本人の書いた内容も個人情報と整理するなら
> 消す設計に変える余地があります。弁護士確認の対象にしてください。

---

## ③ 復旧 — こちらで実装できない部分

### 必須: Supabase Pro + PITR

1. Supabase ダッシュボード → Settings → Billing で **Pro プラン**にする
   - 無料プランには保証されたバックアップがありません
   - Pro は日次バックアップ(7日保持)が付きます
2. Settings → Add-ons → **Point-in-Time Recovery** を有効化
   - 任意の時点に巻き戻せます。「誤操作の直前」に戻せるのはこれだけです
3. Database → Backups で、実際にバックアップが取れていることを目視確認

**コインを1円でも売る前に**済ませてください。売った後に失うと、
利用者への説明も返金対応も原資の把握もできなくなります。

### 推奨: 別事業者への論理バックアップ

Supabase 自体が飛んだ場合・アカウントが凍結された場合の備えです。
日次で `pg_dump` を取り、Cloudflare R2 等に置きます。

```bash
# 接続文字列は Supabase の Settings → Database から取得
pg_dump "$SUPABASE_DB_URL" \
  --no-owner --no-acl \
  -t 'public.coin_*' -t 'public.payouts' -t 'public.bookings' \
  -t 'public.ledger_audit' -t 'public.integrity_checks' \
  | gzip > "pita-ledger-$(date +%F).sql.gz"
```

金額に関わるテーブルだけに絞れば軽く済みます。
実行には Supabase の DB 接続情報と R2 の認証情報が必要なので、
そちらで用意してください。

### 推奨: Stripe との突合(月次)

Stripe には決済の記録が独立して残っています。これが実質「4つ目の写し」で、
自社DBが壊れても入金額だけは再構成できます。

```sql
-- 自社側の月次入金
select date_trunc('month', created_at) as month,
       count(*), sum(price_yen) as yen, sum(coins_credited) as coins
from public.coin_purchases group by 1 order by 1;
```

これを Stripe ダッシュボードの月次売上と突き合わせます
(`launch-checklist.md` の運用ルーティンにも記載)。

---

## テスト

| ファイル | 確認すること |
|---|---|
| `98_integrity_checks.sql` | 実RPCで一通り取引を回して全チェックがokになること。壊し方ごとにどのチェックが鳴るか |
| `99_ledger_immutable.sql` | 台帳の変更・削除が止まること。宣言すれば通り旧値が残ること。物理削除が止まること |
| `91_account_anonymize.sql` | 未処理の取引があるうちは退会させないこと。**退会後も取引記録が残ること** |
