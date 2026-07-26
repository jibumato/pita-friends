# ローカルPostgresでのマイグレーション検証

Supabase に触れずに、ローカルの PostgreSQL でマイグレーションを通しで適用し、
コインの返金まわりの挙動を確認するための一式です。

`0030_refund_lot_expiry.sql`(返金コインの有効期限)の検証に使いました。
本番DBには一切触れません。

## 使い方

```bash
# 1. ローカルPostgresを起動(初回のみ initdb)
export PGDATA=$HOME/pgdata
/usr/lib/postgresql/16/bin/initdb -D "$PGDATA" -U postgres --auth=trust
/usr/lib/postgresql/16/bin/pg_ctl -D "$PGDATA" -o '-p 55432 -k /tmp' -l /tmp/pg.log start

# 2. まっさらなDBを作り、Supabase相当のシムを入れる
psql -h /tmp -p 55432 -U postgres -c "drop database if exists pita"
psql -h /tmp -p 55432 -U postgres -c "create database pita"
psql -h /tmp -p 55432 -U postgres -d pita -c "create extension if not exists pgcrypto"
psql -h /tmp -p 55432 -U postgres -d pita -c "create publication supabase_realtime"
psql -h /tmp -p 55432 -U postgres -d pita -c "create role anon nologin; create role authenticated nologin; create role service_role nologin" 
psql -h /tmp -p 55432 -U postgres -d pita -f supabase/tests/00_supabase_shim.sql
psql -h /tmp -p 55432 -U postgres -d pita -f supabase/tests/01_storage_shim.sql

# 3. マイグレーションを番号順に全適用
for f in supabase/migrations/*.sql; do
  psql -h /tmp -p 55432 -U postgres -d pita -q -v ON_ERROR_STOP=1 -f "$f" || { echo "FAIL $f"; break; }
done

# 4. テストを流す
psql -h /tmp -p 55432 -U postgres -d pita -f supabase/tests/10_refund_expiry.sql
```

> ロールは DB をまたいで共有されるため、2回目以降 `create role` はエラーになります
> (無視して構いません)。

## シムについて

Supabase 固有のものだけを最小限に置き換えています。

| シム | 中身 |
|---|---|
| `auth.users` | id と email だけのテーブル |
| `auth.uid()` | `current_setting('test.uid')` を返す。テスト中に `set test.uid = '<uuid>'` で切り替える |
| `storage.buckets` / `objects` / `foldername()` | 本人確認画像・アバター用の最小定義 |
| `cron.schedule()` | 何もしないダミー(0018がジョブ登録を呼ぶため) |

`set local` ではなく **`set`** を使ってください。psql の各文が独立トランザクション
になるため、`set local` だと次の文に効きません。

## テストの内容

| ファイル | 確認すること |
|---|---|
| `10_refund_expiry.sql` | 5か月前に購入したコインで予約→辞退したとき、返金分が**当初の期限のまま**戻ること(0030の本体) |
| `11_refund_lapsed.sql` | 返金までに当初の期限が切れていた場合、戻さずキャッシュ残高から差し引き、`expire` の取引履歴が残ること。`restored_at` が入って二重返金されないこと |
| `12_refund_legacy_fallback.sql` | 0030より前に作られた消費記録の無い予約でも、予約作成時刻を基準に期限を引き直すこと |
| `20_monitoring_consent.sql` | みまもり同意の記録(0031)。同じ版で二重記録されないこと、文言改定で新しい行が積まれること、撤回で全行に `revoked_at` が入ること、撤回後に再同意できること、未ログインでは何も起きないこと |

### 0030 の効果を確認する

0030 を**除いて**適用すると `10_refund_expiry.sql` 相当のケースが落ちます
(返金分が「今から6か月後」の新しい期限になり、当初の発行日からの通算で
約11か月使えるコインが生まれる)。0030 を含めると当初の期限を引き継ぎます。

### `30_cancellation_evidence.sql` について

E-1(ポリシー版の記録)とE-2(立証材料ビュー)の確認に加えて、
**キャンセルポリシーの表示が実態と食い違っている問題**(open-issues.md の E-10)を
再現します。承諾直後にゲストがキャンセルしても全額没収されることを、
実際にコイン残高で確認できます。

### `40_host_fees.sql` について

ホスト手数料(0033)の検証です。累進の段(20/17/14/12%)、指名リピート割引
(−3pt・下限10%)、ギフトの一律30%、ティア境界をまたぐ予約の4ケースを、
手計算と突き合わせて確認します。

このテストで **トリガーの発火順序のバグを1件発見しました**。`complete_booking` は
「予約を completed にする」→「報酬を満額付与する」の順で書かれているため、
通常の `AFTER UPDATE` トリガーだと付与より前に手数料を引こうとして、残高が
無いところからの控除が丸ごと消えます(1件目の400コインが消えました)。
`deferrable initially deferred` の制約トリガーにして解決しています。

### `50_host_dashboard.sql` について

ホスト向けダッシュボードの集計(0034)。ゲスト2人(1人はリピート・1人は新規)と
辞退1件の状況を作り、手数料・実効料率・リピート率・成約率・時間帯が正しく
出るかを見ます。`_fixture_host.sql` が共通のデータ投入です。

ここでも1件バグを見つけました。リピーター数と新規数を単純に filter で数えると、
初回と2回目が同じ月にあるゲストが**両方に二重計上**されます(新規1人のはずが2人)。
差し引きで出すよう修正しています。

### `60_extension.sql` について

延長課金(0035)。進行中の予約に+30分して、時間・コイン・支払コインが増えること、
**延長分もロット記録に残ること**(残らないと0030の返金で期限を引き直されてしまう)、
完了時の手数料が延長後の総額にかかること、完了後は延長できないことを確認します。

### `70_cancel_board_post.sql` について

募集の取り消し(0036)。他人は取り消せないこと、作成者は理由つきで取り消せること、
**参加者全員に通知が届くこと**、連打しても通知が増えないこと、直接UPDATEの
ポリシーが外れていることを確認します。
