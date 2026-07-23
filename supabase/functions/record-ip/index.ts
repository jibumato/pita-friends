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
// ============================================================
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4'
import { corsHeaders } from '../_shared/cors.ts'

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
      return json({ error: 'unauthorized' }, 401)
    }

    const ip = clientIp(req)
    if (!ip || ip.length < 3 || ip.length > 64) {
      // IPが取れない環境でも失敗にはしない(監視用の記録に過ぎない)
      return json({ ok: true, recorded: false }, 200)
    }

    // 呼び出しユーザーのJWTでRPCを実行(auth.uid()が本人になる)
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
