/**
 * 取引データを Supabase の外(Cloudflare R2)へ定期的に写し取る Worker。
 *
 * ねらい:
 *   Supabase の PITR は月$100+かかるうえ、Supabase 内部の機能なので
 *   「Supabase ごと失う」事故には効かない。ここでは別事業者に写しを置く。
 *
 * なぜ差分が簡単に取れるのか:
 *   0044 で coin_transactions / coin_purchases は追記専用になっている。
 *   行は増えるだけで書き換わらないので、「created_at が前回以降の行」を
 *   取るだけで完全な写しになる。変更検知(CDC)の仕組みが要らない。
 *
 *   一方 bookings / payouts / coin_lots は状態が変わるので、差分では
 *   追えない。件数が少ないうちは日次で丸ごと取るほうが確実で安い。
 *
 * 出力:
 *   ledger/incremental/YYYY/MM/DD/HH-<table>.ndjson   … 1時間ごと
 *   ledger/snapshot/YYYY-MM-DD/<table>.ndjson         … 1日1回
 *   ledger/manifest/<run_at>.json                     … 件数の記録
 *
 * 実行結果は Supabase の ledger_exports に書き戻す。止まったことに
 * 気づけないバックアップは無いのと同じなので、0047 の整合性チェックが
 * ここを見て「エクスポートが止まっている」を検知する。
 */

/** @cloudflare/workers-types に依存しないための最小定義。 */
type R2Bucket = {
  put(key: string, value: string, options?: unknown): Promise<unknown>
}

export interface Env {
  /** 例: https://xxxx.supabase.co */
  SUPABASE_URL: string
  /** service_role キー。Worker のシークレットに入れる(フロントには絶対に置かない) */
  SUPABASE_SERVICE_ROLE_KEY: string
  /** 手動実行用の合言葉。未設定なら手動実行は無効 */
  TRIGGER_SECRET?: string
  LEDGER: R2Bucket
}

/**
 * 追記専用のテーブル。created_at で差分が取れる。
 * 0044 のトリガーで UPDATE/DELETE が禁止されているので、
 * 「一度書き出した行が後から変わる」ことがない。
 */
const APPEND_ONLY = ['coin_transactions', 'coin_purchases'] as const

/**
 * 状態が変わるテーブル。丸ごと取る。
 * どれも金額に関わるものだけに絞ってあるので、件数は当面小さい。
 *
 * order はページ送りを安定させるための並び順。テーブルごとに時刻列の
 * 名前が違い(coin_wallets には時刻列自体が無い)ので個別に指定する。
 */
const SNAPSHOT: { table: string; order: string }[] = [
  { table: 'bookings', order: 'created_at' },
  { table: 'payouts', order: 'created_at' },
  { table: 'coin_lots', order: 'created_at' },
  { table: 'coin_wallets', order: 'user_id' },
  { table: 'coin_lot_consumptions', order: 'created_at' },
  { table: 'ledger_audit', order: 'at' },
  { table: 'account_anonymizations', order: 'anonymized_at' },
]

/** PostgREST の1回あたりの取得件数。 */
const PAGE = 1000

/**
 * 差分の取得窓。1時間ごとに実行して2時間分を取る。
 * わざと重ねている。実行が1回飛んでも穴が空かないほうが、
 * 同じ行が2回出ることより望ましい(NDJSONなので重複は後で潰せる)。
 */
const WINDOW_HOURS = 2

async function fetchRows(
  env: Env,
  table: string,
  query: string,
): Promise<Record<string, unknown>[]> {
  const rows: Record<string, unknown>[] = []
  for (let offset = 0; ; offset += PAGE) {
    const url = `${env.SUPABASE_URL}/rest/v1/${table}?${query}&limit=${PAGE}&offset=${offset}`
    const res = await fetch(url, {
      headers: {
        apikey: env.SUPABASE_SERVICE_ROLE_KEY,
        Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
        Accept: 'application/json',
      },
    })
    if (!res.ok) {
      throw new Error(`${table}: ${res.status} ${await res.text()}`)
    }
    const page = (await res.json()) as Record<string, unknown>[]
    rows.push(...page)
    if (page.length < PAGE) return rows
  }
}

function toNdjson(rows: Record<string, unknown>[]): string {
  return rows.map((r) => JSON.stringify(r)).join('\n') + (rows.length ? '\n' : '')
}

/** 実行結果を Supabase に書き戻す(止まったことを検知できるように)。 */
async function recordRun(
  env: Env,
  kind: 'incremental' | 'snapshot',
  ok: boolean,
  rowCount: number,
  detail: unknown,
  error?: string,
): Promise<void> {
  const res = await fetch(`${env.SUPABASE_URL}/rest/v1/ledger_exports`, {
    method: 'POST',
    headers: {
      apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
      'Content-Type': 'application/json',
      Prefer: 'return=minimal',
    },
    body: JSON.stringify({
      kind,
      ok,
      row_count: rowCount,
      detail,
      error: error ?? null,
    }),
  })
  // 書き戻しに失敗しても本体は成功しているので、ログだけ残して握る。
  if (!res.ok) {
    console.error(`ledger_exports への記録に失敗: ${res.status} ${await res.text()}`)
  }
}

function pad(n: number): string {
  return String(n).padStart(2, '0')
}

async function runIncremental(env: Env, now: Date): Promise<void> {
  const since = new Date(now.getTime() - WINDOW_HOURS * 3600_000).toISOString()
  const prefix =
    `ledger/incremental/${now.getUTCFullYear()}/${pad(now.getUTCMonth() + 1)}/` +
    `${pad(now.getUTCDate())}/${pad(now.getUTCHours())}`

  const counts: Record<string, number> = {}
  let total = 0
  try {
    for (const table of APPEND_ONLY) {
      const rows = await fetchRows(
        env,
        table,
        `select=*&created_at=gte.${encodeURIComponent(since)}&order=created_at.asc`,
      )
      counts[table] = rows.length
      total += rows.length
      // 0件でも空ファイルを置く。「取りに行った証拠」を残すため。
      await env.LEDGER.put(`${prefix}-${table}.ndjson`, toNdjson(rows))
    }
    await env.LEDGER.put(
      `ledger/manifest/${now.toISOString()}-incremental.json`,
      JSON.stringify({ kind: 'incremental', since, ran_at: now.toISOString(), counts }, null, 2),
    )
    await recordRun(env, 'incremental', true, total, { since, counts })
  } catch (e) {
    await recordRun(env, 'incremental', false, total, { since, counts }, String(e))
    throw e
  }
}

async function runSnapshot(env: Env, now: Date): Promise<void> {
  const day = `${now.getUTCFullYear()}-${pad(now.getUTCMonth() + 1)}-${pad(now.getUTCDate())}`
  const counts: Record<string, number> = {}
  let total = 0
  try {
    for (const { table, order } of SNAPSHOT) {
      const rows = await fetchRows(env, table, `select=*&order=${order}.asc`)
      counts[table] = rows.length
      total += rows.length
      await env.LEDGER.put(`ledger/snapshot/${day}/${table}.ndjson`, toNdjson(rows))
    }
    await env.LEDGER.put(
      `ledger/manifest/${now.toISOString()}-snapshot.json`,
      JSON.stringify({ kind: 'snapshot', ran_at: now.toISOString(), counts }, null, 2),
    )
    await recordRun(env, 'snapshot', true, total, { counts })
  } catch (e) {
    await recordRun(env, 'snapshot', false, total, { counts }, String(e))
    throw e
  }
}

export default {
  /** Cron Trigger から呼ばれる。 */
  async scheduled(event: { cron: string }, env: Env): Promise<void> {
    const now = new Date()
    // wrangler.jsonc の crons の並びと対応させている。
    if (event.cron.startsWith('23 19')) {
      await runSnapshot(env, now)
    } else {
      await runIncremental(env, now)
    }
  },

  /**
   * 手動実行(初回の動作確認用)。
   *   curl -H "Authorization: Bearer $TRIGGER_SECRET" \
   *        "https://pita-ledger-export.<account>.workers.dev/?kind=snapshot"
   */
  async fetch(request: Request, env: Env): Promise<Response> {
    if (!env.TRIGGER_SECRET) {
      return new Response('manual trigger disabled', { status: 404 })
    }
    if (request.headers.get('Authorization') !== `Bearer ${env.TRIGGER_SECRET}`) {
      return new Response('unauthorized', { status: 401 })
    }
    const kind = new URL(request.url).searchParams.get('kind') ?? 'incremental'
    const now = new Date()
    try {
      if (kind === 'snapshot') {
        await runSnapshot(env, now)
      } else {
        await runIncremental(env, now)
      }
      return new Response(`${kind} ok\n`)
    } catch (e) {
      return new Response(`${kind} failed: ${String(e)}\n`, { status: 500 })
    }
  },
}
