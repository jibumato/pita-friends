// ============================================================
// create-connect-account
// ------------------------------------------------------------
// ログイン済みユーザーが呼ぶ。本人確認済みのホストが「振込先を設定する」
// を押したときに、Stripe Connect(Express)アカウントを(未作成なら)作成し、
// オンボーディング用のURL(Account Link)を返す。
//
// 実際に振込ができる状態(payouts_enabled)になったかどうかは、
// Stripe側のオンボーディング完了後に届く account.updated Webhook
// (stripe-webhook Function)で判定・反映する。このFunction自体は
// アカウントの作成とリンク発行のみを行う。
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
    const authHeader = req.headers.get('Authorization') ?? ''
    const jwt = authHeader.replace('Bearer ', '')
    if (!jwt) return json({ error: 'unauthorized' }, 401)

    const admin = createClient(SUPABASE_URL, SERVICE_ROLE)
    const { data: userData, error: userErr } = await admin.auth.getUser(jwt)
    if (userErr || !userData.user) return json({ error: 'unauthorized' }, 401)
    const user = userData.user

    // 本人確認済みのユーザーのみ振込先を設定できる(ホスト掲載の要件と揃える)
    const { data: stats } = await admin
      .from('profile_trust_stats')
      .select('is_verified')
      .eq('user_id', user.id)
      .maybeSingle()
    if (!stats?.is_verified) {
      return json({ error: '本人確認が完了してから設定してください' }, 403)
    }

    // 既存のConnectアカウントがあれば使い回す(なければ新規作成)
    const { data: existing } = await admin
      .from('host_payout_accounts')
      .select('stripe_account_id')
      .eq('user_id', user.id)
      .maybeSingle()

    let accountId = existing?.stripe_account_id
    if (!accountId) {
      const account = await stripe.accounts.create({
        type: 'express',
        country: 'JP',
        email: user.email,
        capabilities: {
          transfers: { requested: true },
        },
        business_type: 'individual',
      })
      accountId = account.id
      const { error: insertErr } = await admin
        .from('host_payout_accounts')
        .insert({ user_id: user.id, stripe_account_id: accountId })
      if (insertErr) {
        console.error('[create-connect-account] host_payout_accounts作成に失敗', insertErr)
        return json({ error: 'internal_error' }, 500)
      }
    }

    const accountLink = await stripe.accountLinks.create({
      account: accountId,
      refresh_url: `${APP_URL}/?connect=refresh`,
      return_url: `${APP_URL}/?connect=return`,
      type: 'account_onboarding',
    })

    return json({ url: accountLink.url }, 200)
  } catch (e) {
    console.error('[create-connect-account]', e)
    return json({ error: 'internal_error' }, 500)
  }
})

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}
