// ============================================================
// stripe-webhook
// ------------------------------------------------------------
// Stripe から呼ばれる(ユーザーのブラウザからではない)。
// 署名を検証し、checkout.session.completed を処理して
// credit_coins_for_purchase(冪等)でコインを付与する(コイン購入)。
// ※ホストへの報酬振込は自社銀行振込(0014)のため、Stripeは関与しない。
//
// このFunctionは JWT 検証を無効にしてデプロイすること:
//   supabase functions deploy stripe-webhook --no-verify-jwt
// (Stripe は Supabase の JWT を持たないため)
//
// Stripeダッシュボードで購読するイベント:
//   ・checkout.session.completed  … コインの付与
//   ・charge.dispute.created      … **異議申立て。残高を凍結する**
//   ・charge.dispute.closed       … 決着。won なら自動で解除、lost は運営が対応
//
// ⚠️ **dispute の2つを購読し忘れると凍結が働きません。**
//    税理士の第2回回答Q14:「これがないと『チャージバックを申し立てながら、
//    その間にコインを使い切る』という極めて単純な不正が通ります。」
//    購読設定はダッシュボード側の設定なので、コードだけでは担保できません。
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
    // 0083で購入ボーナスを廃止した。**廃止をまたいだ決済**(メタデータに
    // 古い bonus_coins が残っているもの)が届く可能性があるので読み取りは
    // 残すが、付与には使わない。DB側(credit_coins_for_purchase)でも無視する。
    const staleBonus = parseInt(m.bonus_coins ?? '0', 10)
    if (staleBonus > 0) {
      console.warn('[stripe-webhook] 廃止済みの購入ボーナスを無視しました', {
        session: session.id,
        bonus: staleBonus,
      })
    }
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
      p_bonus_coins: 0,
      p_price_yen: priceYen,
      p_session_id: session.id,
      p_payment_intent: (session.payment_intent as string) ?? null,
    })
    if (error) {
      // 5xx を返すと Stripe が自動リトライする(冪等なので二重付与は起きない)
      console.error('[stripe-webhook] credit failed', error)
      return new Response('credit failed', { status: 500 })
    }

    // 預かったあんしんサポート料を購入履歴に残す。
    // credit_coins_for_purchase の引数は増やしていない。引数を変えると、
    // マイグレーションの適用とこの関数のデプロイの順序が前後したときに
    // 付与そのものが落ちるため(コインが増えない事故になる)。
    // 保証料の記録が1件欠けるより、付与が止まるほうが重大。
    const safetyFeeYen = parseInt(m.safety_fee_yen ?? '0', 10)
    if (safetyFeeYen > 0) {
      const { error: feeErr } = await admin
        .from('coin_purchases')
        .update({ safety_fee_yen: safetyFeeYen })
        .eq('stripe_session_id', session.id)
      // 失敗しても 200 を返す。ここで 5xx にすると Stripe がリトライし、
      // 付与済みなのに再送され続けることになる。
      if (feeErr) console.error('[stripe-webhook] safety fee record failed', feeErr)
    }

    // ----------------------------------------------------------
    // 決済カードのフィンガープリントを記録する(0080・E-9)
    //
    // 端末IDは消せる、IPは変わる。**カードは同じ実カードである限り
    // 変わらない**ので、自作自演(自分のカードで買ったコインを別アカウントの
    // 自分にギフトして換金する)の検知としては最も強い。
    //
    // カード番号そのものは受け取らない。Stripe が返す不可逆な
    // フィンガープリントと、ブランド・下4桁だけを保存する。
    //
    // **失敗しても 200 を返す。** ここで 5xx にすると、付与は済んでいるのに
    // Stripe が再送し続ける。記録が1件欠けるより、そちらのほうが重い。
    // PayPay 等カード以外の決済では fingerprint が無いので何もしない。
    // ----------------------------------------------------------
    try {
      const piId = session.payment_intent as string | null
      if (piId) {
        const pi = await stripe.paymentIntents.retrieve(piId, {
          expand: ['latest_charge'],
        })
        const charge = pi.latest_charge as Stripe.Charge | null
        const card = charge?.payment_method_details?.card
        if (card?.fingerprint) {
          const { error: cardErr } = await admin.rpc('record_payment_card', {
            p_user_id: userId,
            p_fingerprint: card.fingerprint,
            p_brand: card.brand ?? null,
            p_last4: card.last4 ?? null,
          })
          if (cardErr) console.error('[stripe-webhook] card record failed', cardErr)
        }
      }
    } catch (e) {
      console.error('[stripe-webhook] card fingerprint lookup failed', e)
    }
  }

  // ------------------------------------------------------------
  // 異議申立て(チャージバック)。残高の凍結・解除。
  // created と closed で同じ関数を呼び、status だけを変える。
  // record_payment_dispute は dispute id で冪等なので、再送されても安全。
  // ------------------------------------------------------------
  if (event.type === 'charge.dispute.created' || event.type === 'charge.dispute.closed') {
    const d = event.data.object as Stripe.Dispute
    // Stripe の dispute.status は複数の値をとる。当社が区別したいのは
    // 「当社の主張が通った(won)」「返金が確定した(lost)」の2つだけで、
    // 審査中の細かい状態は open として扱う(= 凍結を続ける)。
    const status =
      d.status === 'won'
        ? 'won'
        : d.status === 'lost'
          ? 'lost'
          : event.type === 'charge.dispute.closed'
            ? 'closed'
            : 'open'

    const admin = createClient(SUPABASE_URL, SERVICE_ROLE)
    const { error } = await admin.rpc('record_payment_dispute', {
      p_stripe_dispute_id: d.id,
      p_stripe_charge_id: (d.charge as string) ?? null,
      p_stripe_payment_intent: (d.payment_intent as string) ?? null,
      // Stripe の amount は最小通貨単位。日本円は最小単位が「円」なのでそのまま
      p_amount_yen: typeof d.amount === 'number' ? d.amount : null,
      p_reason: d.reason ?? null,
      p_status: status,
    })
    if (error) {
      // ここは 5xx を返して Stripe にリトライさせる。
      // **記録できないまま 200 を返すと、凍結されないまま申立てが進む。**
      console.error('[stripe-webhook] dispute record failed', error)
      return new Response('dispute record failed', { status: 500 })
    }
  }

  return new Response('ok', { status: 200 })
})
