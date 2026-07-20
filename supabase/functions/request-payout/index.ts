// ============================================================
// request-payout
// ------------------------------------------------------------
// ログイン済みのホストが「換金する」を押したときに呼ぶ。
// 呼び出しユーザー自身の earned_balance(報酬コイン、購入コインとは
// 別会計)からのみ換金できる。実際の資金移動はStripe Connectの
// Transferで行い、Stripeが実際の銀行口座への着金(送金業務)を担う
// (当社が資金移動業の登録なしにこれを行える設計上の前提)。
//
// 換金レートは 1コイン = 1円(ウォレット画面の表示と一致)。
// ⚠️ コインパックにはボーナスコイン(無償分)が含まれるため、
// ボーナスで得たコインが予約経由でホストの報酬になり、そのまま
// 1:1で換金されると、購入時に対応する実収益のない支払いが発生しうる。
// 本番投入前に、手数料(プラットフォームフィー)でこの差分を吸収する
// 設計にするか、ボーナス設計自体を見直すか、事業側で確定させること。
// 現状 PLATFORM_FEE_BPS は 0(手数料なし)のプレースホルダー。
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

// プラットフォーム手数料(ベーシスポイント、100 = 1%)。事業側で確定するまでの仮値。
const PLATFORM_FEE_BPS = 0

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }
  try {
    const authHeader = req.headers.get('Authorization') ?? ''
    const jwt = authHeader.replace('Bearer ', '')
    if (!jwt) return json({ error: 'unauthorized' }, 401)

    const admin = createClient(SUPABASE_URL, SERVICE_ROLE)
    const { data: userData, error: userErr } = await admin.auth.getUser(jwt)
    if (userErr || !userData.user) return json({ error: 'unauthorized' }, 401)
    const user = userData.user

    const { coins } = await req.json().catch(() => ({ coins: null }))
    if (!coins || !Number.isInteger(coins) || coins <= 0) {
      return json({ error: '換金するコイン数を指定してください' }, 400)
    }

    const { data: account } = await admin
      .from('host_payout_accounts')
      .select('stripe_account_id, payouts_enabled')
      .eq('user_id', user.id)
      .maybeSingle()
    if (!account?.payouts_enabled) {
      return json({ error: '振込先の設定が完了していません' }, 400)
    }

    // 残高チェック+確保をアトミックに行う(実際の送金前にコインを減らす)
    const { data: payoutId, error: reserveErr } = await admin.rpc('reserve_payout', {
      p_user_id: user.id,
      p_coins: coins,
    })
    if (reserveErr) {
      const msg = reserveErr.message ?? ''
      if (msg.includes('INSUFFICIENT_EARNED_BALANCE')) return json({ error: '換金可能な残高が不足しています' }, 400)
      if (msg.includes('PAYOUTS_NOT_ENABLED')) return json({ error: '振込先の設定が完了していません' }, 400)
      console.error('[request-payout] reserve_payout失敗', reserveErr)
      return json({ error: 'internal_error' }, 500)
    }

    const amountYen = Math.floor((coins * (10000 - PLATFORM_FEE_BPS)) / 10000)

    try {
      const transfer = await stripe.transfers.create({
        amount: amountYen,
        currency: 'jpy',
        destination: account.stripe_account_id,
        transfer_group: String(payoutId),
      })
      await admin.rpc('finalize_payout', { p_payout_id: payoutId, p_stripe_transfer_id: transfer.id })
      return json({ ok: true, amountYen }, 200)
    } catch (stripeErr) {
      console.error('[request-payout] Stripe Transfer失敗', stripeErr)
      await admin.rpc('fail_payout', {
        p_payout_id: payoutId,
        p_reason: stripeErr instanceof Error ? stripeErr.message : 'stripe_transfer_failed',
      })
      return json({ error: '送金に失敗しました。時間をおいて再度お試しください' }, 502)
    }
  } catch (e) {
    console.error('[request-payout]', e)
    return json({ error: 'internal_error' }, 500)
  }
})

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}
