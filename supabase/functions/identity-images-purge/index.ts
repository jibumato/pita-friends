// ============================================================
// identity-images-purge
// ------------------------------------------------------------
// 本人確認の提出画像を、サーバー側(service role の Storage API)で消して記録する。
// 規約 第3条5項「照合の完了後すみやかに削除」を守るための仕組み(0129)。
//
// 呼び方は2つ。
//
//   1. 運営が承認・却下した直後(運営の画面から、ログイン中のトークンで)
//        POST { verificationId }
//      → その申請の画像を消し、identity_verifications.images_deleted_at を入れる。
//        審査待ち(pending)の申請は消さない。
//
//   2. 毎日の掃除(pg_cron から。x-purge-secret ヘッダで認証)
//        POST {}
//      → ①判定済みなのに消えていない申請 ②どの審査待ちの申請にも紐づかない
//        画像(申請の作成に失敗して残ったもの等。アップロード途中を消さないよう
//        24時間たったものだけ) ③匿名化した利用者のファイル(本人確認・アバター・声)
//        を消し、結果を integrity_checks('identity_images_purge')に書く。
//        運営コンソールの「健全性」に出る。
//
// 必要な環境変数: SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY
//                 IDENTITY_PURGE_SECRET(毎日の掃除用。未設定なら掃除は動かない)
// デプロイ: supabase functions deploy identity-images-purge --no-verify-jwt
//   (cron からはログイントークン無しで呼ぶため。運営の呼び出しは中で検証する)
// ============================================================
import { createClient, type SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4'

// CORSヘッダーはこのファイル内に持つ(_shared からの import にすると
// ダッシュボードの「Via Editor」で単体デプロイできなくなるため)。
const corsHeaders = {
  'Access-Control-Allow-Origin': (Deno.env.get('APP_URL') ?? '*').replace(/\/+$/, ''),
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? ''
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
const PURGE_SECRET = Deno.env.get('IDENTITY_PURGE_SECRET') ?? ''

const BUCKET = 'identity-documents'
/** 匿名化した利用者について、フォルダごと消すバケット。 */
const USER_BUCKETS = ['identity-documents', 'avatars', 'voice-greetings']
/** アップロードしてから申請行ができるまでの間に消さないための猶予。 */
const ORPHAN_GRACE_MS = 24 * 3600 * 1000
/** これより長く審査待ちのままなら warn にする(画像を預かり続けている)。 */
const PENDING_WARN_MS = 7 * 24 * 3600 * 1000
const PAGE = 100

type Admin = SupabaseClient
type Row = { id: string; document_path: string | null; selfie_path: string | null }

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405)

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  })

  try {
    const secret = req.headers.get('x-purge-secret')
    if (secret !== null) {
      if (!PURGE_SECRET) {
        console.error('[identity-images-purge] IDENTITY_PURGE_SECRET が未設定')
        return json({ error: 'not_configured' }, 500)
      }
      if (secret !== PURGE_SECRET) return json({ error: 'unauthorized' }, 401)
      return json(await sweep(admin), 200)
    }

    // ---- 運営が判定した直後の1件 ----
    const authHeader = req.headers.get('Authorization') ?? ''
    if (!authHeader.startsWith('Bearer ')) return json({ error: 'unauthorized' }, 401)
    const token = authHeader.slice('Bearer '.length)
    const { data: userData, error: userErr } = await createClient(SUPABASE_URL, ANON_KEY).auth.getUser(token)
    const uid = userData?.user?.id
    if (userErr || !uid) {
      console.error('[identity-images-purge] auth', userErr?.message ?? 'no user')
      return json({ error: 'unauthorized' }, 401)
    }
    const { data: isAdmin, error: adminErr } = await admin
      .from('admins').select('user_id').eq('user_id', uid).maybeSingle()
    if (adminErr) throw adminErr
    if (!isAdmin) return json({ error: 'not_admin' }, 403)

    const { verificationId } = (await req.json().catch(() => ({}))) as { verificationId?: string }
    if (!verificationId) return json({ error: 'verification_id_required' }, 400)

    const { data: row, error: rowErr } = await admin
      .from('identity_verifications')
      .select('id, status, document_path, selfie_path')
      .eq('id', verificationId)
      .maybeSingle()
    if (rowErr) throw rowErr
    if (!row) return json({ error: 'not_found' }, 404)
    // 審査中の画像は運営が見るために要る。判定前には消さない
    if (row.status === 'pending') return json({ error: 'not_decided' }, 409)

    const removed = await purgeRow(admin, row as Row)
    return json({ ok: true, removed }, 200)
  } catch (e) {
    console.error('[identity-images-purge]', e)
    return json({ error: 'internal_error', message: String((e as Error)?.message ?? e) }, 500)
  }
})

/** 1件の申請の画像を消し、消したことを記録する。戻り値は実際に消えたファイル数。 */
async function purgeRow(admin: Admin, row: Row): Promise<number> {
  const paths = [row.document_path, row.selfie_path].filter((p): p is string => !!p)
  let removed = 0
  if (paths.length > 0) {
    // 既に無いファイルはエラーにならず data に含まれないだけなので、
    // 「消えている」状態になったと扱ってよい
    const { data, error } = await admin.storage.from(BUCKET).remove(paths)
    if (error) throw new Error(`storage: ${error.message}`)
    removed = data?.length ?? 0
  }
  const { error: updErr } = await admin
    .from('identity_verifications')
    .update({ images_deleted_at: new Date().toISOString() })
    .eq('id', row.id)
  if (updErr) throw new Error(`record: ${updErr.message}`)
  return removed
}

type Listed = { name: string; id: string | null; created_at?: string | null }

/** バケットの1階層分を全部取る(ページ送りつき)。 */
async function listAll(admin: Admin, bucket: string, prefix: string): Promise<Listed[]> {
  const out: Listed[] = []
  for (let offset = 0; ; offset += PAGE) {
    const { data, error } = await admin.storage.from(bucket).list(prefix, { limit: PAGE, offset })
    if (error) throw new Error(`list ${bucket}/${prefix}: ${error.message}`)
    out.push(...((data ?? []) as Listed[]))
    if (!data || data.length < PAGE) return out
  }
}

async function removeMany(admin: Admin, bucket: string, paths: string[]): Promise<number> {
  let n = 0
  for (let i = 0; i < paths.length; i += PAGE) {
    const { data, error } = await admin.storage.from(bucket).remove(paths.slice(i, i + PAGE))
    if (error) throw new Error(`remove ${bucket}: ${error.message}`)
    n += data?.length ?? 0
  }
  return n
}

async function sweep(admin: Admin) {
  const problems: Record<string, unknown>[] = []
  let removedFiles = 0

  // ① 判定済みなのに消えていない申請
  const { data: decided, error: decErr } = await admin
    .from('identity_verifications')
    .select('id, document_path, selfie_path')
    .in('status', ['verified', 'rejected'])
    .is('images_deleted_at', null)
  if (decErr) throw decErr
  let decidedPurged = 0
  for (const row of (decided ?? []) as Row[]) {
    try {
      removedFiles += await purgeRow(admin, row)
      decidedPurged++
    } catch (e) {
      problems.push({ kind: '判定済みの画像を消せない', verification_id: row.id, error: String(e) })
    }
  }

  // ② どの審査待ちの申請にも紐づかない画像
  const { data: pending, error: penErr } = await admin
    .from('identity_verifications')
    .select('document_path, selfie_path, created_at')
    .eq('status', 'pending')
  if (penErr) throw penErr
  const keep = new Set<string>()
  let oldestPending: string | null = null
  let pendingTooLong = 0
  for (const p of (pending ?? []) as { document_path: string | null; selfie_path: string | null; created_at: string }[]) {
    if (p.document_path) keep.add(p.document_path)
    if (p.selfie_path) keep.add(p.selfie_path)
    if (!oldestPending || p.created_at < oldestPending) oldestPending = p.created_at
    if (Date.now() - new Date(p.created_at).getTime() > PENDING_WARN_MS) pendingTooLong++
  }
  let orphansRemoved = 0
  try {
    const now = Date.now()
    const orphans: string[] = []
    for (const top of await listAll(admin, BUCKET, '')) {
      // id が null のものはフォルダ(= 利用者ごとのフォルダ)
      const entries = top.id === null
        ? (await listAll(admin, BUCKET, top.name)).map((f) => ({ ...f, path: `${top.name}/${f.name}` }))
        : [{ ...top, path: top.name }]
      for (const f of entries) {
        if (f.id === null || keep.has(f.path)) continue
        const age = f.created_at ? now - new Date(f.created_at).getTime() : Infinity
        if (age > ORPHAN_GRACE_MS) orphans.push(f.path)
      }
    }
    orphansRemoved = await removeMany(admin, BUCKET, orphans)
    removedFiles += orphansRemoved
  } catch (e) {
    problems.push({ kind: '紐づかない画像を消せない', error: String(e) })
  }

  // ③ 匿名化した利用者のファイル
  const { data: anon, error: anonErr } = await admin
    .from('account_anonymizations')
    .select('user_id')
    .is('storage_purged_at', null)
  if (anonErr) throw anonErr
  let anonymizedPurged = 0
  for (const { user_id } of (anon ?? []) as { user_id: string }[]) {
    try {
      for (const bucket of USER_BUCKETS) {
        const files = (await listAll(admin, bucket, user_id)).filter((f) => f.id !== null)
        removedFiles += await removeMany(admin, bucket, files.map((f) => `${user_id}/${f.name}`))
      }
      const { error } = await admin
        .from('account_anonymizations')
        .update({ storage_purged_at: new Date().toISOString() })
        .eq('user_id', user_id)
      if (error) throw new Error(`record: ${error.message}`)
      anonymizedPurged++
    } catch (e) {
      problems.push({ kind: '退会者のファイルを消せない', user_id, error: String(e) })
    }
  }

  const severity = problems.length > 0 ? 'error' : pendingTooLong > 0 ? 'warn' : 'ok'
  const detail = {
    rows: problems.slice(0, 20),
    decided_purged: decidedPurged,
    orphans_removed: orphansRemoved,
    anonymized_purged: anonymizedPurged,
    pending_count: pending?.length ?? 0,
    pending_over_7_days: pendingTooLong,
    oldest_pending_at: oldestPending,
    note: '本人確認の画像の削除(規約第3条5項・0129)。審査待ちの画像だけが残っているのが正しい状態',
  }
  const { error: recErr } = await admin.from('integrity_checks').insert({
    check_name: 'identity_images_purge',
    severity,
    // warn(審査待ちが長い)のときは、その件数を出す。0 件の warn にしない
    affected_count: problems.length > 0 ? problems.length : pendingTooLong,
    total_gap: removedFiles,
    detail,
  })
  if (recErr) console.error('[identity-images-purge] integrity_checks', recErr.message)

  return { ok: problems.length === 0, severity, removed_files: removedFiles, ...detail }
}

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}
