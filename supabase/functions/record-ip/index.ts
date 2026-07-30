// ============================================================
// record-ip
// ------------------------------------------------------------
// ログイン済みユーザーがアプリ起動時に呼ぶ。リクエストヘッダの
// X-Forwarded-For から呼び出し元の実IPを読み、record_ip RPC で
// user_ips に記録する(ギフトのIP共有検知に使う)。
//
// なぜ Edge Function か: ブラウザからは自分の正しい公開IPを取得できず、
// クライアント申告のIPは信用できない。プラットフォームが付与する
// X-Forwarded-For をサーバ側で読む必要があるため。
//
// 認証について:
// このプロジェクトでは JWT 署名鍵のローテーション以降、Edge Function の
// プラットフォーム側 JWT 検証(Verify JWT)が機能せず 401 になるため、
// 設定で OFF にしている(docs/deploy-avatar-functions.md 参照)。
// そのぶん関数内で getUser(token) により本人を検証する。
// 記録先は record_ip 内の auth.uid() が決めるため、他人のIPは記録できない。
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

/** X-Forwarded-For 等から呼び出し元の実IP(先頭)を取り出す。 */
function clientIp(req: Request): string | null {
  const xff = req.headers.get('x-forwarded-for')
  if (xff) {
    const first = xff.split(',')[0]?.trim()
    if (first) return first
  }
  return req.headers.get('x-real-ip') ?? req.headers.get('cf-connecting-ip') ?? null
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }
  try {
    const authHeader = req.headers.get('Authorization') ?? ''
    if (!authHeader.startsWith('Bearer ')) {
      console.error('[record-ip] auth', 'missing bearer')
      return json({ error: 'unauthorized' }, 401)
    }

    // 呼び出し元の本人確認。
    // getUser() は引数なしだとクライアント自身のセッション(サーバでは常に空)を
    // 見てしまうため、必ずトークンを明示的に渡してAuth APIに検証させる。
    const token = authHeader.slice('Bearer '.length)
    const { data: userData, error: userErr } = await createClient(
      SUPABASE_URL,
      ANON_KEY,
    ).auth.getUser(token)
    if (userErr || !userData?.user?.id) {
      console.error('[record-ip] auth', userErr?.message ?? 'no user')
      return json({ error: 'unauthorized' }, 401)
    }

    const ip = clientIp(req)
    if (!ip || ip.length < 3 || ip.length > 64) {
      // IPが取れない環境でも失敗にはしない(監視用の記録に過ぎない)
      return json({ ok: true, recorded: false }, 200)
    }

    // 呼び出しユーザーのJWTでRPCを実行(record_ip 内の auth.uid() が本人になる)
    const userClient = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    })
    const { error } = await userClient.rpc('record_ip', { p_ip: ip })
    if (error) {
      console.error('[record-ip] rpc', error.message)
      return json({ ok: false }, 200)
    }
    return json({ ok: true, recorded: true }, 200)
  } catch (e) {
    console.error('[record-ip]', e)
    return json({ error: 'internal_error' }, 500)
  }
})

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}
