# プッシュ通知(Web Push)の設定手順

0064 でプッシュの仕組みを入れました。**鍵を作って設定するまでは、アプリ側の
導線そのものが出ません**(`VITE_VAPID_PUBLIC_KEY` が空なら
`pushState()` が `unsupported` を返し、誘いも設定行も描かれない)。
つまり未設定のまま公開しても、壊れた通知ボタンが出ることはありません。

前提として **0064_web_push.sql を適用済み**であること。

---

## 全体の流れ

```
notifications に1行入る
  └─ トリガー _enqueue_push が push_outbox に積む(端末を登録している人だけ)
       └─ pg_cron が1分おきに Edge Function push-send を叩く
            └─ claim_push_batch で取り出す(push_enabled・静かにする時間はここで見る)
                 └─ RFC 8291 で暗号化して配信元(FCM/Apple/Mozilla)へPOST
                      └─ sw.js の push ハンドラが通知を出す
```

**なぜトリガーから直接HTTPを叩かないのか**: 配信元が落ちているときに
`notifications` の insert ごと失敗します。予約や通報の通知が「プッシュが
送れなかったから」消えるのは本末転倒なので、積むだけにしてあります。

---

## 1. VAPID 鍵を作る

配信元に「この送信は登録した運営からのものだ」と示すための鍵です。
`node` があればこれだけで作れます(外部パッケージは不要)。

```bash
node -e '
const b64u = (b) => Buffer.from(b).toString("base64url");
crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign","verify"])
  .then(async (kp) => {
    const jwk = await crypto.subtle.exportKey("jwk", kp.privateKey);
    const pub = Buffer.concat([
      Buffer.from([4]),
      Buffer.from(jwk.x, "base64url"),
      Buffer.from(jwk.y, "base64url"),
    ]);
    console.log("VAPID_PUBLIC_KEY =", b64u(pub));
    console.log("VAPID_PRIVATE_KEY =", jwk.d);
  });
'
```

> ⚠️ **秘密鍵(`VAPID_PRIVATE_KEY`)はリポジトリに絶対に入れないでください。**
> 漏れると第三者がピタフレを名乗って利用者にプッシュを送れます。
> 公開鍵のほうは公開前提の値で、クライアントのJSに埋め込まれます。
>
> ⚠️ **一度公開したら公開鍵を変えないでください。** 変えると、既に登録済みの
> 購読すべてが無効になり(配信元が鍵の不一致で拒否する)、利用者に
> 再登録してもらう手立てがありません。

## 2. Cloudflare(フロント)の環境変数

| 変数 | 値 |
|---|---|
| `VITE_VAPID_PUBLIC_KEY` | 手順1の `VAPID_PUBLIC_KEY` |

`VITE_SUPABASE_URL` / `VITE_SUPABASE_ANON_KEY` と同じ場所に足します。
この3つはいずれも公開されて問題ない値です(service_roleキーは**絶対に**入れない)。

## 3. Supabase の Secrets

`Project Settings → Edge Functions → Secrets`(または `supabase secrets set`)。

| 変数 | 値 |
|---|---|
| `VAPID_PUBLIC_KEY` | 手順1の公開鍵(手順2と同じ値) |
| `VAPID_PRIVATE_KEY` | 手順1の秘密鍵 |
| `VAPID_SUBJECT` | `mailto:` の運営連絡先。例 `mailto:support@pitafure.com` |
| `PUSH_CRON_SECRET` | 適当な長いランダム文字列(`openssl rand -hex 32`) |

`SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY` は既定で入っています。

> `PUSH_CRON_SECRET` は必須です。このプロジェクトは Verify JWT を OFF に
> しているため(`docs/deploy-avatar-functions.md`)、Edge Function は誰でも
> 叩ける状態に置かれます。push-send は**未設定なら 500 で動きません**
> — 黙って無認証で動くほうが危ないので、そう作ってあります。

## 4. Edge Function をデプロイする

`supabase/functions/push-send/` には2ファイルあります。

- `index.ts` … 取り出して送る本体
- `webpush.ts` … 暗号化とVAPID署名(Web Crypto だけで書いてある)

```bash
supabase functions deploy push-send --no-verify-jwt
```

ダッシュボードの「Via Editor」で貼る場合は、**2ファイルとも**作ってください
(`index.ts` が `./webpush.ts` を読みます)。

> `npm` の `web-push` は使っていません。あれは Node の crypto に依存していて
> Deno の互換層で動く保証がないためです。`webpush.ts` は Web Crypto だけなので
> Deno でも Node でも同じように動き、暗号化→復号の往復をローカルで
> 確かめてあります(RFC 8291 / 8188 / 8292 準拠)。

## 5. pg_cron から1分おきに叩く

SQL Editor で。`pg_net` が必要です(Supabase では `Database → Extensions` から有効化)。

```sql
create extension if not exists pg_net;
create extension if not exists pg_cron;

-- 送信(1分おき)
select cron.schedule(
  'push-send',
  '* * * * *',
  $$
  select net.http_post(
    url := 'https://<PROJECT-REF>.supabase.co/functions/v1/push-send',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-push-secret', '<PUSH_CRON_SECRET と同じ値>'
    ),
    body := '{}'::jsonb
  );
  $$
);

-- 片付け(1日1回、JST 4:00 = UTC 19:00)
select cron.schedule('prune-push', '0 19 * * *', $$select public.prune_push();$$);
```

`<PROJECT-REF>` と秘密は実際の値に置き換えてください。
**この cron 定義には秘密が入るので、実行後のSQLをどこかに貼り残さないこと。**

登録の確認と解除:

```sql
select jobid, jobname, schedule, active from cron.job order by jobid;
-- やり直すとき: select cron.unschedule('push-send');
```

---

## 動作確認

### 手で1回だけ送ってみる

```bash
curl -i -X POST 'https://<PROJECT-REF>.supabase.co/functions/v1/push-send' \
  -H 'x-push-secret: <PUSH_CRON_SECRET>' -H 'Content-Type: application/json' -d '{}'
```

`{"claimed":0,"sent":0,"gone":0}` が返れば配線は通っています(送るものが無い状態)。

### 実機での確認項目

1. **iPhone**: Safari で開く →(通知の設定行が「ホーム画面に追加すると使えます」に
   なっていること)→ ホーム画面に追加 → アイコンから起動 → 設定の行が
   トグルに変わる → 推しに⭐を付ける → 説明シートが出る → 「通知を受け取る」
2. `push_subscriptions` に行が入ること
3. 別の端末/アカウントから予約リクエストを送り、**アプリを閉じた状態で**届くこと
4. 通知をタップして、閉じている状態から起動 →「受け取った誘い」に着地すること
5. `message_received` の通知で、**ロック画面に本文が出ないこと**(名前だけ)
6. 設定 → 通知 → トグルを切る → 届かなくなること

### 溜まっているか見る

```sql
select
  count(*) filter (where sent_at is null) as 送信待ち,
  count(*) filter (where sent_at is not null) as 送信済み,
  count(*) filter (where attempts >= 3 and sent_at is null) as 諦めた,
  max(attempts) as 最大試行
from public.push_outbox;

-- 直近の失敗理由
select type, attempts, last_error, created_at
from public.push_outbox
where sent_at is null and last_error is not null
order by created_at desc limit 20;

-- 端末の状況
select count(*) filter (where disabled_at is null) as 有効,
       count(*) filter (where disabled_at is not null) as 停止,
       min(last_seen_at) as 最も古い起動
from public.push_subscriptions;
```

---

## 仕様として押さえておくこと

**ロック画面に本文を出さない種類がある。**
`message_received`(メッセージ本文の先頭60文字)と `gift_received`(金額と
添えた言葉)は、SQL側(`_push_lockscreen_body`)で本文を空にしています。
ロック画面は他人の目に入る場所なので、題名(=誰から)だけにしてあります。
**種類を増やすときは、その body に人に見られて困るものが入らないか確かめること。**

**許可ダイアログは一度しか出せない。**
断られたら二度と出せません。だからアプリ側は
`src/lib/push.ts` / `PushPrompt.tsx` で、必ず先に説明シートを出し、
「受け取る」を押した人にだけ本物のダイアログを見せます。
**起動時に許可を求めるコードを足さないでください。** この経路が永久に死にます。

**聞くきっかけは2つだけ。** 推しに⭐を付けた直後と、予約リクエストを出した直後。
どちらも「通知が欲しくなった瞬間」です。断られた/「あとで」の場合は
14日 → 60日 → 打ち切りで間隔を延ばします。

**iOSはホーム画面に追加しないと通知が使えない。**
Safari のタブで開いているあいだは `PushManager` 自体が存在しません。
なので追加の案内(`src/lib/install.ts`)と一本の導線になっています。

**静かにする時間は既定で入れていない。** ゲームは夜に遊ぶもので、深夜の誘いは
むしろ本題です。設定した人にだけ効き、しかも急がない種類
(枠が空いた・ギフト・募集・プレイ完了)だけを止めます。
予約・メッセージ・誘い・通報は深夜でも通します。

**静かな時間のあいだ試行回数を食いません。** 食うと朝になる前に「3回で諦め」に
達して永久に届かなくなります(`75_web_push.sql` の項目7でここを見ています)。
