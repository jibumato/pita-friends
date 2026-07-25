// ============================================================
// avatar-delete
// ------------------------------------------------------------
// アイコン画像を削除して既定アバター(頭文字＋カラー)に戻す。
// avatar-upload と同じ理由で、Storage の削除も service role で行う。
// 削除対象は必ずサーバ側で {uid}/avatar.webp を組み立てるため、
// 他人の画像は消せない。
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

const BUCKET = 'avatars'

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }
  try {
    const authHeader = req.headers.get('Authorization') ?? ''
    if (!authHeader.startsWith('Bearer ')) {
      console.error('[avatar-delete] auth', 'missing bearer')
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
      // 401の原因を後から追えるように残す(ログが無いと調査できないため)
      console.error('[avatar-delete] auth', userErr?.message ?? 'no user')
      return json({ error: 'unauthorized' }, 401)
    }

    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    })

    // 先に参照を外す(ファイル削除が失敗しても既定アバターに戻るようにする)
    const { error: updErr } = await admin
      .from('profiles')
      .update({ avatar_path: null })
      .eq('id', uid)
    if (updErr) {
      console.error('[avatar-delete] profiles', updErr.message)
      return json({ error: 'update_failed' }, 500)
    }

    const { error: rmErr } = await admin.storage.from(BUCKET).remove([`${uid}/avatar.webp`])
    if (rmErr) {
      // 実体が消せなくても公開参照は外れているため、成功として返す
      console.warn('[avatar-delete] storage', rmErr.message)
    }

    return json({ ok: true }, 200)
  } catch (e) {
    console.error('[avatar-delete]', e)
    return json({ error: 'internal_error' }, 500)
  }
})

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}
