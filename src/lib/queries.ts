/**
 * アカウントデータの取得・更新。
 * バックエンド未設定時は呼び出さないこと(呼び出し側で isBackendConfigured
 * を確認する、または requireSupabase() が例外を投げる)。
 */
import { requireSupabase } from './supabase'
import type { ContactScope, Gender } from '../flow'

export type AccountBundle = {
  profile: { nickname: string; gender: Gender }
  safetyPrefs: {
    contact_scope: ContactScope
    approval_required: boolean
    show_online: boolean
    discoverable: boolean
    block_low_trust: boolean
  }
  hostSettings: { is_host: boolean; hourly_rate: number; games: string[]; bio: string }
  wallet: { balance: number }
  trustStats: {
    manner_score: number
    dotakyan_count: number
    confirmed_count: number
    is_verified: boolean
  }
}

/** サインイン/起動時のセッション復元後に、本人のアカウントデータをまとめて取得する。 */
export async function fetchAccountBundle(userId: string): Promise<AccountBundle | null> {
  const sb = requireSupabase()
  const [profileRes, safetyRes, hostRes, walletRes, trustRes] = await Promise.all([
    sb.from('profiles').select('nickname, gender').eq('id', userId).single(),
    sb
      .from('safety_prefs')
      .select('contact_scope, approval_required, show_online, discoverable, block_low_trust')
      .eq('user_id', userId)
      .single(),
    sb.from('host_settings').select('is_host, hourly_rate, games, bio').eq('user_id', userId).single(),
    sb.from('coin_wallets').select('balance').eq('user_id', userId).single(),
    sb
      .from('profile_trust_stats')
      .select('manner_score, dotakyan_count, confirmed_count, is_verified')
      .eq('user_id', userId)
      .single(),
  ])

  const firstError =
    profileRes.error || safetyRes.error || hostRes.error || walletRes.error || trustRes.error
  if (firstError) throw firstError
  if (!profileRes.data || !safetyRes.data || !hostRes.data || !walletRes.data || !trustRes.data) {
    return null
  }

  return {
    profile: profileRes.data,
    safetyPrefs: safetyRes.data,
    hostSettings: hostRes.data,
    wallet: walletRes.data,
    trustStats: trustRes.data,
  }
}

export async function updateProfileRemote(
  userId: string,
  patch: Partial<{ nickname: string; gender: Gender }>,
): Promise<void> {
  const { error } = await requireSupabase().from('profiles').update(patch).eq('id', userId)
  if (error) throw error
}

export async function updateSafetyPrefsRemote(
  userId: string,
  patch: Partial<{
    contact_scope: ContactScope
    approval_required: boolean
    show_online: boolean
    discoverable: boolean
    block_low_trust: boolean
  }>,
): Promise<void> {
  const { error } = await requireSupabase().from('safety_prefs').update(patch).eq('user_id', userId)
  if (error) throw error
}

export async function updateHostSettingsRemote(
  userId: string,
  patch: Partial<{ is_host: boolean; hourly_rate: number; games: string[]; bio: string }>,
): Promise<void> {
  const { error } = await requireSupabase().from('host_settings').update(patch).eq('user_id', userId)
  if (error) throw error
}
