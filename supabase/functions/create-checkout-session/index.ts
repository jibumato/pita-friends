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

/**
 * 3Dセキュアの要求方法。'any'(既定・発行会社が対応していれば必ず認証)
 * または 'automatic'(Stripeの判断に任せる)。
 * 詳細は下の payment_method_options のコメントを参照。
 */
const THREE_D_SECURE =
  (Deno.env.get('STRIPE_3DS') ?? 'any') === 'automatic' ? 'automatic' : 'any'

const stripe = new Stripe(Deno.env.get('STRIPE_SECRET_KEY') ?? '', {
  apiVersion: '2024-06-20',
  httpClient: Stripe.createFetchHttpClient(),
})

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
// 末尾スラッシュを剥がす。"https://例.com/" のまま success_url を組むと
// "https://例.com//?checkout=success" と // になるうえ、CORS(_shared/cors.ts)の
// 許可オリジンもブラウザの Origin と一致しなくなる。設定ミスに強くする。
const APP_URL = (Deno.env.get('APP_URL') ?? '').replace(/\/+$/, '')

// 決済手段。カンマ区切りで指定する(例: "card,paypay")。
// 未設定なら Stripe のダッシュボード設定に任せる。
// PayPay はカードより手数料が低いため、有効化できたぶんだけ利益率が上がる。
// ただしStripe側で有効化していない手段を指定するとセッション作成が失敗するので、
// コードに直書きせず環境変数で切り替える。
const PAYMENT_METHODS = (Deno.env.get('STRIPE_PAYMENT_METHODS') ?? '')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean)

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
      .select('id, coins, price_yen, active')
      .eq('id', packId)
      .single()
    if (packErr || !pack || !pack.active) {
      return json({ error: 'pack not found' }, 404)
    }

    // あんしんサポート料。料率はDB(platform_pricing)が権威で、クライアントは関与しない。
    const { data: feeYen, error: feeErr } = await admin.rpc('safety_fee_for', {
      p_price_yen: pack.price_yen,
    })
    if (feeErr) {
      console.error('[create-checkout-session] safety_fee_for', feeErr.message)
      return json({ error: 'internal_error' }, 500)
    }
    const safetyFee = Number(feeYen ?? 0)

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
              // 0083で購入ボーナスを廃止したので、付与数＝購入数
              name: `ピタフレ コイン ${pack.coins}枚`,
              description: `${pack.coins}コイン`,
            },
          },
        },
        // あんしんサポート料は別明細にする。合算すると利用者から内訳が見えず、
        // 特商法の「商品代金以外の必要料金」の表示としても弱くなるため。
        ...(safetyFee > 0
          ? [
              {
                quantity: 1,
                price_data: {
                  currency: 'jpy',
                  unit_amount: safetyFee,
                  product_data: {
                    name: 'あんしんサポート料',
                    description:
                      '本人確認・承認制・通報ブロック・トラブル時の対応にかかる費用です',
                  },
                },
              },
            ]
          : []),
      ],
      // 決済手段。既定はカードのみで、PayPay等は環境変数で足す。
      // (Stripe側で有効化していない手段を指定するとセッション作成が失敗するため、
      //  コードではなく設定で切り替えられるようにしておく)
      ...(PAYMENT_METHODS.length > 0 ? { payment_method_types: PAYMENT_METHODS } : {}),
      // ------------------------------------------------------------
      // EMV 3-Dセキュア(3DS2)を要求する。
      // ------------------------------------------------------------
      // 税理士の第4回回答:
      //   「チャージバックの期間が、設計とまったく噛み合っていません。
      //     **国際ブランドの申立期限は取引日から120日程度**です。対する現在の
      //     防御は7日保留＋週次振込で、**期間が一桁違います。** 規約でピタメイトに
      //     返還義務を課すことは可能ですが、**善意の受領者から既払金を回収するのは
      //     実務上ほぼ不可能で、規約は防御になりません。**
      //     設計で防ぐべきで、**最も効果が大きいのは EMV 3-Dセキュア(3DS2)の適用**
      //     です。認証済み取引では不正利用によるチャージバックの責任がカード発行
      //     会社に移転します(ライアビリティシフト)。」
      //
      // 'any' は、発行会社が対応していれば必ず認証を挟む(= 転嫁を最大化する)。
      // 'automatic' は Stripe の判断に任せるため、認証されない取引が残る。
      // **既定を 'any' にしている**のは、本サービスが
      //   ①換金を伴い ②申立てまでに数か月あり ③回収手段が実質的に無い
      // という、取りこぼしが致命傷になる構造だからである。
      //
      // ⚠️ 認証を挟むぶん、購入の途中離脱は増える。数字を見て緩める場合は
      //    環境変数で 'automatic' にできるようにしてあるが、**戻すときは
      //    上の3条件が変わったかを確認すること。**
      payment_method_options: {
        card: { request_three_d_secure: THREE_D_SECURE },
      },
      // 付与に必要な情報は metadata に載せ、webhook で使う
      metadata: {
        user_id: user.id,
        pack_id: pack.id,
        coins: String(pack.coins),
        price_yen: String(pack.price_yen),
        safety_fee_yen: String(safetyFee),
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
