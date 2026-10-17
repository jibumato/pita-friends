// identity-images-purge の動作確認。Supabase(認証・テーブル・ストレージ)を
// fetch の差し替えで模して、本体の Deno.serve に渡された関数を直接呼ぶ。
//
//   deno test --allow-env --allow-net --allow-read \
//     --import-map supabase/functions/identity-images-purge/test-import-map.json \
//     supabase/functions/identity-images-purge/purge.test.ts
//
// (esm.sh に届かない環境でも動くよう、import map で同じ版の npm を使う)

const URL_ = 'http://supabase.test'
Deno.env.set('SUPABASE_URL', URL_)
Deno.env.set('SUPABASE_ANON_KEY', 'anon')
Deno.env.set('SUPABASE_SERVICE_ROLE_KEY', 'service')
Deno.env.set('IDENTITY_PURGE_SECRET', 'cron-secret')

const ADMIN = 'aaaaaaaa-0000-0000-0000-000000000001'
const USER = 'bbbbbbbb-0000-0000-0000-000000000002'
const GONE = 'cccccccc-0000-0000-0000-000000000003'
const OLD = new Date(Date.now() - 3 * 86400_000).toISOString()
const NEW = new Date().toISOString()

type Obj = { bucket: string; name: string; created_at: string }
let db: Record<string, Record<string, unknown>[]>
let storage: Obj[]
let failRemove = false

function reset() {
  failRemove = false
  db = {
    admins: [{ user_id: ADMIN }],
    identity_verifications: [
      { id: 'v-pending', user_id: USER, status: 'pending', document_path: `${USER}/document-3.jpg`, selfie_path: `${USER}/selfie-3.jpg`, images_deleted_at: null, created_at: NEW },
      { id: 'v-verified', user_id: USER, status: 'verified', document_path: `${USER}/document-1.jpg`, selfie_path: `${USER}/selfie-1.jpg`, images_deleted_at: null, created_at: OLD },
      { id: 'v-anon', user_id: GONE, status: 'verified', document_path: null, selfie_path: null, images_deleted_at: null, created_at: OLD },
    ],
    account_anonymizations: [{ user_id: GONE, storage_purged_at: null }],
    integrity_checks: [],
  }
  storage = [
    { bucket: 'identity-documents', name: `${USER}/document-3.jpg`, created_at: NEW }, // 審査待ち: 残す
    { bucket: 'identity-documents', name: `${USER}/selfie-3.jpg`, created_at: NEW },
    { bucket: 'identity-documents', name: `${USER}/document-1.jpg`, created_at: OLD }, // 承認済み: 消す
    { bucket: 'identity-documents', name: `${USER}/selfie-1.jpg`, created_at: OLD },
    { bucket: 'identity-documents', name: `${USER}/document-2.jpg`, created_at: OLD }, // 申請行の無い古い画像: 消す
    { bucket: 'identity-documents', name: `${USER}/selfie-9.jpg`, created_at: NEW }, // 申請行の無い新しい画像(アップロード中): 残す
    { bucket: 'identity-documents', name: `${GONE}/document-1.jpg`, created_at: OLD }, // 退会者: 消す
    { bucket: 'avatars', name: `${GONE}/avatar.webp`, created_at: OLD },
    { bucket: 'voice-greetings', name: `${GONE}/greeting.webm`, created_at: OLD },
    { bucket: 'avatars', name: `${USER}/avatar.webp`, created_at: OLD }, // 退会していない人のアバター: 残す
  ]
}

function filterRows(rows: Record<string, unknown>[], params: URLSearchParams) {
  return rows.filter((r) => {
    for (const [k, v] of params) {
      if (['select', 'limit', 'offset', 'order', 'columns'].includes(k)) continue
      const [op, ...rest] = v.split('.')
      const val = rest.join('.')
      if (op === 'eq' && String(r[k]) !== val) return false
      if (op === 'is' && val === 'null' && r[k] !== null) return false
      if (op === 'in') {
        const list = val.replace(/^\(|\)$/g, '').split(',').map((s) => s.replace(/^"|"$/g, ''))
        if (!list.includes(String(r[k]))) return false
      }
    }
    return true
  })
}

const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { 'Content-Type': 'application/json' } })

globalThis.fetch = async (input: Request | URL | string, init?: RequestInit) => {
  const req = new Request(input, init)
  const u = new URL(req.url)
  const body = req.method === 'GET' || req.method === 'HEAD' ? null : await req.text()
  if (u.pathname === '/auth/v1/user') {
    const tok = req.headers.get('Authorization')?.slice(7)
    if (tok === 'admin-token') return json({ id: ADMIN, aud: 'authenticated' })
    if (tok === 'user-token') return json({ id: USER, aud: 'authenticated' })
    return json({ msg: 'invalid' }, 401)
  }
  if (u.pathname.startsWith('/rest/v1/')) {
    const table = u.pathname.slice('/rest/v1/'.length)
    const rows = db[table]
    if (req.method === 'GET') {
      const hit = filterRows(rows, u.searchParams)
      if (req.headers.get('Accept')?.includes('vnd.pgrst.object')) {
        return hit.length === 1 ? json(hit[0]) : json({ code: 'PGRST116', message: 'no rows' }, 406)
      }
      return json(hit)
    }
    if (req.method === 'PATCH') {
      const patch = JSON.parse(body!)
      for (const r of filterRows(rows, u.searchParams)) Object.assign(r, patch)
      return new Response(null, { status: 204 })
    }
    if (req.method === 'POST') {
      rows.push(JSON.parse(body!))
      return new Response(null, { status: 201 })
    }
  }
  if (u.pathname.startsWith('/storage/v1/object/list/')) {
    const bucket = u.pathname.split('/').pop()!
    const { prefix = '', limit = 100, offset = 0 } = JSON.parse(body!)
    const inBucket = storage.filter((o) => o.bucket === bucket)
    let entries: { name: string; id: string | null; created_at?: string }[]
    if (prefix === '') {
      entries = [...new Set(inBucket.map((o) => o.name.split('/')[0]))].map((name) => ({ name, id: null }))
    } else {
      entries = inBucket
        .filter((o) => o.name.startsWith(prefix + '/'))
        .map((o) => ({ name: o.name.slice(prefix.length + 1), id: crypto.randomUUID(), created_at: o.created_at }))
    }
    return json(entries.slice(offset, offset + limit))
  }
  if (u.pathname.startsWith('/storage/v1/object/') && req.method === 'DELETE') {
    if (failRemove) return json({ statusCode: '500', error: 'boom', message: 'storage down' }, 500)
    const bucket = u.pathname.split('/').pop()!
    const { prefixes } = JSON.parse(body!) as { prefixes: string[] }
    const removed = storage.filter((o) => o.bucket === bucket && prefixes.includes(o.name))
    storage = storage.filter((o) => !removed.includes(o))
    return json(removed.map((o) => ({ name: o.name, bucket_id: bucket })))
  }
  return json({ error: `unmocked ${req.method} ${u.pathname}` }, 599)
}

let handler: (req: Request) => Promise<Response>
// deno-lint-ignore no-explicit-any
;(Deno as any).serve = (h: typeof handler) => { handler = h }
await import('./index.ts')

const call = (headers: Record<string, string>, body: unknown = {}) =>
  handler(new Request('http://fn.test', { method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body: JSON.stringify(body) }))
const has = (bucket: string, name: string) => storage.some((o) => o.bucket === bucket && o.name === name)
const row = (id: string) => db.identity_verifications.find((r) => r.id === id)!

function assert(cond: unknown, msg: string) { if (!cond) throw new Error(msg) }

Deno.test('運営が判定した直後: その申請の画像だけを消して記録する', async () => {
  reset()
  const res = await call({ Authorization: 'Bearer admin-token' }, { verificationId: 'v-verified' })
  const out = await res.json()
  assert(res.status === 200 && out.removed === 2, `status ${res.status} ${JSON.stringify(out)}`)
  assert(!has('identity-documents', `${USER}/document-1.jpg`), '承認済みの画像が残っている')
  assert(row('v-verified').images_deleted_at, '消した日時が記録されていない')
  assert(has('identity-documents', `${USER}/document-3.jpg`), '審査待ちの画像まで消えた')
})

Deno.test('審査待ちの申請は消さない', async () => {
  reset()
  const res = await call({ Authorization: 'Bearer admin-token' }, { verificationId: 'v-pending' })
  assert(res.status === 409, `status ${res.status}`)
  assert(has('identity-documents', `${USER}/document-3.jpg`), '審査待ちの画像が消えた')
})

Deno.test('運営以外・ログインなしは弾く', async () => {
  reset()
  assert((await call({ Authorization: 'Bearer user-token' }, { verificationId: 'v-verified' })).status === 403, '一般利用者が通った')
  assert((await call({}, { verificationId: 'v-verified' })).status === 401, 'ログインなしで通った')
  assert((await call({ 'x-purge-secret': 'wrong' })).status === 401, '違う合言葉で掃除が動いた')
  assert(has('identity-documents', `${USER}/document-1.jpg`), '弾いたのに消えている')
})

Deno.test('ストレージの削除に失敗したら、成功扱いにも記録にもしない', async () => {
  reset()
  failRemove = true
  const res = await call({ Authorization: 'Bearer admin-token' }, { verificationId: 'v-verified' })
  assert(res.status === 500, `status ${res.status}`)
  assert(row('v-verified').images_deleted_at === null, '失敗したのに消した日時が入った')
})

Deno.test('毎日の掃除: 判定済み・紐づかない古い画像・退会者のファイルを消し、健全性に書く', async () => {
  reset()
  const res = await call({ 'x-purge-secret': 'cron-secret' })
  const out = await res.json()
  assert(res.status === 200 && out.ok, JSON.stringify(out))
  assert(!has('identity-documents', `${USER}/document-1.jpg`), '判定済みの画像が残っている')
  assert(!has('identity-documents', `${USER}/document-2.jpg`), '申請行の無い古い画像が残っている')
  assert(has('identity-documents', `${USER}/selfie-9.jpg`), 'アップロード直後の画像まで消えた')
  assert(has('identity-documents', `${USER}/document-3.jpg`), '審査待ちの画像が消えた')
  for (const [b, n] of [['identity-documents', `${GONE}/document-1.jpg`], ['avatars', `${GONE}/avatar.webp`], ['voice-greetings', `${GONE}/greeting.webm`]]) {
    assert(!has(b, n), `退会者のファイルが残っている: ${b}/${n}`)
  }
  assert(has('avatars', `${USER}/avatar.webp`), '退会していない人のアバターが消えた')
  assert(db.account_anonymizations[0].storage_purged_at, '退会者の削除が記録されていない')
  const rec = db.integrity_checks.at(-1) as { check_name: string; severity: string; total_gap: number }
  assert(rec?.check_name === 'identity_images_purge' && rec.severity === 'ok', JSON.stringify(rec))
  assert(rec.total_gap === 6, `消した枚数 ${rec.total_gap}`)
})

Deno.test('毎日の掃除: 消せなければ error として健全性に出す', async () => {
  reset()
  failRemove = true
  await call({ 'x-purge-secret': 'cron-secret' })
  const rec = db.integrity_checks.at(-1) as { severity: string; affected_count: number }
  assert(rec.severity === 'error' && rec.affected_count > 0, JSON.stringify(rec))
  assert(row('v-verified').images_deleted_at === null, '失敗したのに記録された')
})

Deno.test('毎日の掃除: 審査待ちが7日を超えたら、その件数つきで warn にする', async () => {
  reset()
  row('v-pending').created_at = new Date(Date.now() - 8 * 86400_000).toISOString()
  await call({ 'x-purge-secret': 'cron-secret' })
  const rec = db.integrity_checks.at(-1) as { severity: string; affected_count: number }
  assert(rec.severity === 'warn' && rec.affected_count === 1, JSON.stringify(rec))
  assert(has('identity-documents', `${USER}/document-3.jpg`), '審査待ちの画像が消えた')
})
