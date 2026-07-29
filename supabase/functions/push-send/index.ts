// ============================================================
// push-send
// ------------------------------------------------------------
// push_outbox に積まれたぶんを配信元(FCM/Apple/Mozilla)へ送る。
// pg_cron + pg_net から1分おきに叩く想定(手順: docs/web-push-setup.md)。
//
// なぜ Edge Function か: Postgres からは外部へHTTPを投げられない。
// そしてトリガーの中から投げると、配信元が落ちているときに
// notifications の insert ごと失敗する(予約や通報の通知が消える)。
//
// **認証について**
//   このプロジェクトは JWT 署名鍵のローテーション以降、プラットフォーム側の
//   Verify JWT が使えず OFF にしている(docs/deploy-avatar-functions.md)。
//   つまりこの関数は誰でも叩ける状態に置かれる。だから自前で
//   x-push-secret を検証する。**PUSH_CRON_SECRET を必ず設定すること。**
//   未設定なら起動しない(黙って無認証で動くほうが危ない)。
//
// 必要な環境変数(Supabase の Secrets):
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY  … 既定で入っている
//   VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY / VAPID_SUBJECT
//   PUSH_CRON_SECRET
// ============================================================
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4'
import { buildPushRequest, type VapidKeys } from './webpush.ts'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
const CRON_SECRET = Deno.env.get('PUSH_CRON_SECRET') ?? ''
const VAPID: VapidKeys = {
  publicKey: Deno.env.get('VAPID_PUBLIC_KEY') ?? '',
  privateKey: Deno.env.get('VAPID_PRIVATE_KEY') ?? '',
  subject: Deno.env.get('VAPID_SUBJECT') ?? '',
}

/** 一度に扱う件数。Edge Function の実行時間に収まる範囲で。 */
const BATCH = 100
/** 同時に投げる本数。配信元に一気に投げすぎない。 */
const CONCURRENCY = 10

type ClaimRow = {
  outbox_id: string
  endpoint: string
  p256dh: string
  auth: string
  payload: unknown
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

/** 配列を n 本ずつに切る。 */
function chunk<T>(items: T[], n: number): T[][] {
  const out: T[][] = []
  for (let i = 0; i < items.length; i += n) out.push(items.slice(i, i + n))
  return out
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return json({ error: 'method_not_allowed' }, 405)
  }
  // 秘密が設定されていないなら動かさない。無認証で動くより落ちるほうがよい
  if (!CRON_SECRET) {
    console.error('[push-send] PUSH_CRON_SECRET が未設定')
    return json({ error: 'not_configured' }, 500)
  }
  if (req.headers.get('x-push-secret') !== CRON_SECRET) {
    return json({ error: 'forbidden' }, 403)
  }
  if (!VAPID.publicKey || !VAPID.privateKey || !VAPID.subject) {
    console.error('[push-send] VAPID鍵が未設定')
    return json({ error: 'vapid_not_configured' }, 500)
  }

  const db = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } })

  const { data, error } = await db.rpc('claim_push_batch', { p_limit: BATCH })
  if (error) {
    console.error('[push-send] claim', error.message)
    return json({ error: 'claim_failed' }, 500)
  }
  const rows = (data ?? []) as ClaimRow[]
  if (rows.length === 0) {
    return json({ claimed: 0, sent: 0, gone: 0 })
  }

  const nowSeconds = Math.floor(Date.now() / 1000)
  // outbox 1件が端末ぶんに展開されている。届いた本数を数えて、
  // 1本でも通れば完了にする(端末を複数持っている人の1台が死んでいても再送しない)
  const delivered = new Map<string, number>()
  const errors = new Map<string, string>()
  const gone: string[] = []

  for (const group of chunk(rows, CONCURRENCY)) {
    await Promise.all(
      group.map(async (row) => {
        try {
          const built = await buildPushRequest(
            { endpoint: row.endpoint, p256dh: row.p256dh, auth: row.auth },
            row.payload,
            VAPID,
            nowSeconds,
          )
          const res = await fetch(built.url, {
            method: 'POST',
            headers: built.headers,
            body: built.body,
          })
          if (res.ok) {
            delivered.set(row.outbox_id, (delivered.get(row.outbox_id) ?? 0) + 1)
            return
          }
          // 404/410 は「購読が消えた」。二度と送らない
          if (res.status === 404 || res.status === 410) {
            gone.push(row.endpoint)
            errors.set(row.outbox_id, `gone:${res.status}`)
            return
          }
          const text = await res.text().catch(() => '')
          errors.set(row.outbox_id, `${res.status}:${text.slice(0, 120)}`)
          console.error('[push-send] send', res.status, text.slice(0, 200))
        } catch (e) {
          errors.set(row.outbox_id, `throw:${e instanceof Error ? e.message : String(e)}`)
          console.error('[push-send] throw', e)
        }
      }),
    )
  }

  // 消えた購読を止める。重複は落としてから
  await Promise.all(
    [...new Set(gone)].map((endpoint) =>
      db.rpc('disable_push_subscription', { p_endpoint: endpoint, p_reason: 'gone' }),
    ),
  )

  const outboxIds = [...new Set(rows.map((r) => r.outbox_id))]
  await Promise.all(
    outboxIds.map((id) =>
      db.rpc('mark_push_result', {
        p_outbox_id: id,
        p_delivered: delivered.get(id) ?? 0,
        p_error: errors.get(id) ?? null,
      }),
    ),
  )

  const sent = [...delivered.values()].reduce((a, b) => a + b, 0)
  return json({ claimed: outboxIds.length, targets: rows.length, sent, gone: gone.length })
})
