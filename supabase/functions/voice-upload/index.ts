// ============================================================
// voice-upload
// ------------------------------------------------------------
// ボイスプロフィール(15秒までの音声挨拶)を保存する。
//
// なぜ Edge Function か: アイコン画像(avatar-upload)と同じ理由。
// ブラウザから直接 Storage に保存すると、ポリシー・バケット設定・JWTが
// すべて正しいにもかかわらず RLS で拒否されるため、サーバ側で
// service role を使って保存する。
//
// 安全性: service role は RLS を素通りするため、
//   ・Authorization の JWT を検証して本人を特定し
//   ・保存先パスは必ずサーバ側で {uid}/greeting.webm を組み立てる
// ことで、他人のフォルダに書き込めないようにしている。
// 長さ(1〜15秒)・MIME・サイズもサーバ側で再検証する。
//
// デプロイ後に Settings で「Verify JWT」を OFF にすること
// (詳細は docs/deploy-avatar-functions.md)。
// ============================================================
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4'

// CORSヘッダーはこのファイル内に持つ(_shared からの import にすると
// ダッシュボードの「Via Editor」で単体デプロイできなくなるため)。
const corsHeaders = {
  'Access-Control-Allow-Origin': Deno.env.get('APP_URL') ?? '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? ''
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''

const BUCKET = 'voice-greetings'
const MAX_BYTES = 2 * 1024 * 1024
const ALLOWED = new Set(['audio/webm', 'audio/mp4', 'audio/ogg', 'audio/mpeg', 'audio/aac'])
const MAX_SECONDS = 15

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }
  try {
    const authHeader = req.headers.get('Authorization') ?? ''
    if (!authHeader.startsWith('Bearer ')) {
      console.error('[voice-upload] auth', 'missing bearer')
      return json({ error: 'unauthorized' }, 401)
    }

    // 呼び出し元の本人確認。
    // getUser() は引数なしだとクライアント自身のセッション(サーバでは常に空)を
    // 見てしまうため、必ずトークンを明示的に渡してAuth APIに検証させる。
    const token = authHeader.slice('Bearer '.length)
    const userClient = createClient(SUPABASE_URL, ANON_KEY)
    const { data: userData, error: userErr } = await userClient.auth.getUser(token)
    const uid = userData?.user?.id
    if (userErr || !uid) {
      console.error('[voice-upload] auth', userErr?.message ?? 'no user')
      return json({ error: 'unauthorized' }, 401)
    }

    const form = await req.formData()
    const file = form.get('file')
    if (!(file instanceof File)) {
      return json({ error: 'file_required' }, 400)
    }
    if (file.size > MAX_BYTES) {
      return json({ error: 'too_large' }, 413)
    }
    // ブラウザによっては 'audio/webm;codecs=opus' のように付加情報が付く
    const contentType = (file.type || 'audio/webm').split(';')[0].trim()
    if (!ALLOWED.has(contentType)) {
      return json({ error: 'unsupported_type' }, 415)
    }

    const rawSeconds = Number(form.get('seconds') ?? 0)
    const seconds = Math.max(1, Math.min(MAX_SECONDS, Math.round(rawSeconds || 1)))

    // パスはサーバ側で組み立てる(クライアントの指定は受け付けない)
    const path = `${uid}/greeting.webm`

    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    })
    const { error: upErr } = await admin.storage
      .from(BUCKET)
      .upload(path, file, { upsert: true, contentType })
    if (upErr) {
      console.error('[voice-upload] storage', upErr.message)
      return json({ error: 'upload_failed' }, 500)
    }

    const { error: updErr } = await admin
      .from('profiles')
      .update({ voice_path: path, voice_seconds: seconds })
      .eq('id', uid)
    if (updErr) {
      console.error('[voice-upload] profiles', updErr.message)
      return json({ error: 'update_failed' }, 500)
    }

    const { data: pub } = admin.storage.from(BUCKET).getPublicUrl(path)
    return json({ ok: true, url: `${pub.publicUrl}?v=${Date.now()}`, seconds }, 200)
  } catch (e) {
    console.error('[voice-upload]', e)
    return json({ error: 'internal_error' }, 500)
  }
})

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}
