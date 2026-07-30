// ============================================================
// avatar-upload
// ------------------------------------------------------------
// プロフィールのアイコン画像を保存する。
//
// なぜ Edge Function か:
// ブラウザから直接 Storage に保存する実装(storage.upload)が、
// avatars バケットの RLS で必ず拒否される事象に遭遇したため。
//   ・ポリシー(bucket_id と auth.uid() の比較)は正しい
//   ・バケット設定(public/サイズ/MIME)も正しい
//   ・Authorization ヘッダも本人のJWTが乗っている
//   ・アップロード先パスの uid と JWT の sub も完全一致
//   ・profiles など他テーブルへの書き込み(同じ auth.uid() 依存)は成功する
//   ・「誰でも insert 可」の一時ポリシーを入れても拒否される
// ここまで揃って拒否されるため、クライアントからの直接アップロードは
// 諦め、サーバ側で service role を使って保存する方式に切り替えた。
//
// 安全性: service role は RLS を素通りするため、
//   ・Authorization の JWT を検証して本人を特定し
//   ・保存先パスは必ずサーバ側で {uid}/avatar.webp を組み立てる
// ことで、他人のフォルダに書き込めないようにしている(クライアントから
// パスを受け取らない)。加えて MIME とサイズもサーバ側で再検証する。
// ============================================================
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4'

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

const BUCKET = 'avatars'
const MAX_BYTES = 3 * 1024 * 1024
const ALLOWED = new Set(['image/jpeg', 'image/png', 'image/webp'])

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }
  try {
    const authHeader = req.headers.get('Authorization') ?? ''
    if (!authHeader.startsWith('Bearer ')) {
      console.error('[avatar-upload] auth', 'missing bearer')
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
      console.error('[avatar-upload] auth', userErr?.message ?? 'no user')
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
    const contentType = file.type || 'image/webp'
    if (!ALLOWED.has(contentType)) {
      return json({ error: 'unsupported_type' }, 415)
    }

    // パスはサーバ側で組み立てる(クライアントの指定は受け付けない)
    const path = `${uid}/avatar.webp`

    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    })
    const { error: upErr } = await admin.storage
      .from(BUCKET)
      .upload(path, file, { upsert: true, contentType })
    if (upErr) {
      console.error('[avatar-upload] storage', upErr.message)
      return json({ error: 'upload_failed' }, 500)
    }

    // profiles.avatar_path を更新(service role なので直接更新でよい)
    const { error: updErr } = await admin
      .from('profiles')
      .update({ avatar_path: path })
      .eq('id', uid)
    if (updErr) {
      console.error('[avatar-upload] profiles', updErr.message)
      return json({ error: 'update_failed' }, 500)
    }

    const { data: pub } = admin.storage.from(BUCKET).getPublicUrl(path)
    return json({ ok: true, url: `${pub.publicUrl}?v=${Date.now()}` }, 200)
  } catch (e) {
    console.error('[avatar-upload]', e)
    return json({ error: 'internal_error' }, 500)
  }
})

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}
