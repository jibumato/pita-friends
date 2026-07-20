// ============================================================
// stripe-webhook
// ------------------------------------------------------------
// Stripe から呼ばれる(ユーザーのブラウザからではない)。
// 署名を検証し、次の2種類のイベントを処理する:
//   ・checkout.session.completed → credit_coins_for_purchase(冪等)で
//     コインを付与する(コイン購入)
//   ・account.updated → Stripe Connect(Express)アカウントの
//     オンボーディングが完了(payouts_enabled)したら
//     host_payout_accounts.payouts_enabled を true にする
//
// このFunctionは JWT 検証を無効にしてデプロイすること:
//   supabase functions deploy stripe-webhook --no-verify-jwt
// (Stripe は Supabase の JWT を持たないため)
//
// Stripeダッシュボードで購読するイベント: checkout.session.completed,
// account.updated (Connect の場合は「アカウント」タイプのWebhookとして
// 別途登録が必要な場合がある。docs/payments-stripe-setup.md 参照)
// ============================================================
import Stripe from 'https://esm.sh/stripe@14.25.0?target=deno&no-check'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4'

const stripe = new Stripe(Deno.env.get('STRIPE_SECRET_KEY') ?? '', {
  apiVersion: '2024-06-20',
  httpClient: Stripe.createFetchHttpClient(),
})
// 署名検証は非同期版 + SubtleCrypto を使う(Deno 環境)
const cryptoProvider = Stripe.createSubtleCryptoProvider()

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
const WEBHOOK_SECRET = Deno.env.get('STRIPE_WEBHOOK_SECRET') ?? ''

Deno.serve(async (req) => {
  const signature = req.headers.get('stripe-signature')
  if (!signature) return new Response('missing signature', { status: 400 })

  const body = await req.text()
  let event: Stripe.Event
  try {
    event = await stripe.webhooks.constructEventAsync(
      body,
      signature,
      WEBHOOK_SECRET,
      undefined,
      cryptoProvider,
    )
  } catch (e) {
    console.error('[stripe-webhook] signature verification failed', e)
    return new Response('invalid signature', { status: 400 })
  }

  if (event.type === 'checkout.session.completed') {
    const session = event.data.object as Stripe.Checkout.Session
    // 未払いのまま completed になるケースは弾く
    if (session.payment_status !== 'paid') {
      return new Response('ignored (not paid)', { status: 200 })
    }
    const m = session.metadata ?? {}
    const userId = m.user_id
    const packId = m.pack_id ?? null
    const coins = parseInt(m.coins ?? '0', 10)
    const priceYen = parseInt(m.price_yen ?? '0', 10)

    if (!userId || !coins) {
      console.error('[stripe-webhook] missing metadata', m)
      return new Response('bad metadata', { status: 400 })
    }

    const admin = createClient(SUPABASE_URL, SERVICE_ROLE)
    const { error } = await admin.rpc('credit_coins_for_purchase', {
      p_user_id: userId,
      p_pack_id: packId,
      p_coins: coins,
      p_price_yen: priceYen,
      p_session_id: session.id,
      p_payment_intent: (session.payment_intent as string) ?? null,
    })
    if (error) {
      // 5xx を返すと Stripe が自動リトライする(冪等なので二重付与は起きない)
      console.error('[stripe-webhook] credit failed', error)
      return new Response('credit failed', { status: 500 })
    }
  }

  if (event.type === 'account.updated') {
    const account = event.data.object as Stripe.Account
    const admin = createClient(SUPABASE_URL, SERVICE_ROLE)
    const { error } = await admin
      .from('host_payout_accounts')
      .update({ payouts_enabled: !!account.payouts_enabled })
      .eq('stripe_account_id', account.id)
    if (error) {
      console.error('[stripe-webhook] host_payout_accounts更新に失敗', error)
      return new Response('update failed', { status: 500 })
    }
  }

  return new Response('ok', { status: 200 })
})
