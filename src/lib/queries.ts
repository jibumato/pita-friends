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

export type DiscoverableHost = {
  userId: string
  nickname: string
  avatarInitial: string
  avatarColor: string
  hourlyRate: number
  games: string[]
  bio: string
  mannerScore: number
  isVerified: boolean
}

/**
 * 「さがす」画面向けのホスト一覧。埋め込みリレーション(select内のネスト構文)は
 * 手書きDatabase型にRelationshipsメタデータが無く型解決できないため、
 * host_settings / profiles / profile_trust_stats を個別に取得しJS側で結合する。
 */
export async function fetchDiscoverableHosts(excludeUserId: string | null): Promise<DiscoverableHost[]> {
  const sb = requireSupabase()
  const { data: hosts, error: hostsError } = await sb
    .from('host_settings')
    .select('user_id, hourly_rate, games, bio')
    .eq('is_host', true)
  if (hostsError) throw hostsError
  if (!hosts) return []

  const userIds = hosts.map((h) => h.user_id).filter((id) => id !== excludeUserId)
  if (userIds.length === 0) return []

  const [{ data: profiles, error: profilesError }, { data: stats, error: statsError }] = await Promise.all([
    sb.from('profiles').select('id, nickname, avatar_initial, avatar_color').in('id', userIds),
    sb.from('profile_trust_stats').select('user_id, manner_score, is_verified').in('user_id', userIds),
  ])
  if (profilesError) throw profilesError
  if (statsError) throw statsError

  const profileMap = new Map((profiles ?? []).map((p) => [p.id, p]))
  const statsMap = new Map((stats ?? []).map((s) => [s.user_id, s]))

  return hosts
    .filter((h) => profileMap.has(h.user_id))
    .map((h) => {
      const profile = profileMap.get(h.user_id)!
      const stat = statsMap.get(h.user_id)
      return {
        userId: h.user_id,
        nickname: profile.nickname || '(名前未設定)',
        avatarInitial: profile.avatar_initial || profile.nickname.charAt(0) || '?',
        avatarColor: profile.avatar_color || '#B3E5F2',
        hourlyRate: h.hourly_rate,
        games: h.games,
        bio: h.bio,
        mannerScore: stat?.manner_score ?? 4.5,
        isVerified: stat?.is_verified ?? false,
      }
    })
}

/** ホスト予約を確定し、コインをアトミックに消費する(create_booking RPC)。予約IDを返す。 */
export async function createBookingRemote(hostId: string, durationMinutes: 30 | 60 | 120): Promise<string> {
  const { data, error } = await requireSupabase().rpc('create_booking', {
    p_host_id: hostId,
    p_duration_minutes: durationMinutes,
  })
  if (error) throw error
  return data as string
}

function fileExtension(file: File): string {
  const fromName = file.name.split('.').pop()
  if (fromName && fromName.length <= 5) return fromName.toLowerCase()
  if (file.type === 'image/png') return 'png'
  if (file.type === 'image/webp') return 'webp'
  return 'jpg'
}

/**
 * 本人確認書類・顔写真をStorageにアップロードし、審査待ち行を作成する。
 * 「初期のみ運営が目視で審査する」運用のため、eKYCベンダーのような即時
 * 判定はできない。画像は審査完了まで一時的に保持され、審査後は運営が
 * 手動で削除する(docs/manual-verification-review.md参照)。
 */
export async function submitIdentityVerification(
  userId: string,
  documentFile: File,
  selfieFile: File,
): Promise<void> {
  const sb = requireSupabase()
  const ts = Date.now()
  const documentPath = `${userId}/document-${ts}.${fileExtension(documentFile)}`
  const selfiePath = `${userId}/selfie-${ts}.${fileExtension(selfieFile)}`

  const [docUpload, selfieUpload] = await Promise.all([
    sb.storage.from('identity-documents').upload(documentPath, documentFile, { upsert: true }),
    sb.storage.from('identity-documents').upload(selfiePath, selfieFile, { upsert: true }),
  ])
  if (docUpload.error) throw docUpload.error
  if (selfieUpload.error) throw selfieUpload.error

  const { error } = await sb.from('identity_verifications').insert({
    user_id: userId,
    status: 'pending',
    document_path: documentPath,
    selfie_path: selfiePath,
  })
  if (error) throw error
}

export type VerificationStatusInfo = { status: 'pending' | 'verified' | 'rejected'; rejectedReason: string | null } | null

/** 直近の本人確認申請のステータスを取得する(未申請ならnull)。 */
export async function fetchLatestVerificationStatus(userId: string): Promise<VerificationStatusInfo> {
  const { data, error } = await requireSupabase()
    .from('identity_verifications')
    .select('status, rejected_reason')
    .eq('user_id', userId)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle()
  if (error) throw error
  if (!data) return null
  return { status: data.status, rejectedReason: data.rejected_reason }
}
