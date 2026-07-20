// ============================================================
// create-checkout-session
// ------------------------------------------------------------
// ログイン済みユーザーが呼ぶ。body で pack_id を受け取り、
// coin_packs(サーバー権威)から価格・付与数を確定して Stripe Checkout
// セッションを作成し、決済ページの URL を返す。
//
// 重要: 金額・コイン数はクライアントを一切信用せず、必ず DB から引く。
// 付与そのものは stripe-webhook 側でのみ行う(このFunctionはコインを増やさない)。
// ============================================================
import Stripe from 'https://esm.sh/stripe@14.25.0?target=deno&no-check'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4'
import { corsHeaders } from '../_shared/cors.ts'

const stripe = new Stripe(Deno.env.get('STRIPE_SECRET_KEY') ?? '', {
  apiVersion: '2024-06-20',
  httpClient: Stripe.createFetchHttpClient(),
})

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
const APP_URL = Deno.env.get('APP_URL') ?? ''

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }
  try {
    // 1) 呼び出しユーザーを JWT から特定する
    const authHeader = req.headers.get('Authorization') ?? ''
    const jwt = authHeader.replace('Bearer ', '')
    if (!jwt) {
      return json({ error: 'unauthorized' }, 401)
    }
    const admin = createClient(SUPABASE_URL, SERVICE_ROLE)
    const { data: userData, error: userErr } = await admin.auth.getUser(jwt)
    if (userErr || !userData.user) {
      return json({ error: 'unauthorized' }, 401)
    }
    const user = userData.user

    // 2) pack_id からサーバー権威の価格・付与数を取得
    const { packId } = await req.json().catch(() => ({ packId: null }))
    if (!packId) return json({ error: 'pack_id required' }, 400)

    const { data: pack, error: packErr } = await admin
      .from('coin_packs')
      .select('id, coins, bonus_coins, price_yen, active')
      .eq('id', packId)
      .single()
    if (packErr || !pack || !pack.active) {
      return json({ error: 'pack not found' }, 404)
    }
    const totalCoins = pack.coins + pack.bonus_coins

    // 3) Stripe Checkout セッションを作成
    const session = await stripe.checkout.sessions.create({
      mode: 'payment',
      // JPY はゼロ小数通貨。unit_amount は「円」そのまま。
      line_items: [
        {
          quantity: 1,
          price_data: {
            currency: 'jpy',
            unit_amount: pack.price_yen,
            product_data: {
              name: `ピタフレ コイン ${totalCoins}枚`,
              description:
                pack.bonus_coins > 0
                  ? `${pack.coins} + ボーナス${pack.bonus_coins}コイン`
                  : `${pack.coins}コイン`,
            },
          },
        },
      ],
      // 付与に必要な情報は metadata に載せ、webhook で使う
      metadata: {
        user_id: user.id,
        pack_id: pack.id,
        coins: String(totalCoins),
        price_yen: String(pack.price_yen),
      },
      success_url: `${APP_URL}/?checkout=success`,
      cancel_url: `${APP_URL}/?checkout=cancel`,
    })

    return json({ url: session.url }, 200)
  } catch (e) {
    console.error('[create-checkout-session]', e)
    return json({ error: 'internal_error' }, 500)
  }
})

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}
