/**
 * アカウントデータの取得・更新。
 * バックエンド未設定時は呼び出さないこと(呼び出し側で isBackendConfigured
 * を確認する、または requireSupabase() が例外を投げる)。
 */
import { requireSupabase } from './supabase'
import type { ContactScope, Gender } from '../flow'
import type { ReportCategory } from './database.types'

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

/** 本人確認の審査(管理画面)向けAPI。admins テーブルに登録されたユーザーのみ実際に操作できる(RLS/RPC側で強制)。 */

export async function checkIsAdmin(userId: string): Promise<boolean> {
  const { data, error } = await requireSupabase()
    .from('admins')
    .select('user_id')
    .eq('user_id', userId)
    .maybeSingle()
  if (error) throw error
  return !!data
}

export type PendingVerification = {
  id: string
  userId: string
  nickname: string
  createdAt: string
  documentPath: string | null
  selfiePath: string | null
}

/** 審査待ち(status='pending')の本人確認申請を、申請の古い順に取得する。 */
export async function fetchPendingVerifications(): Promise<PendingVerification[]> {
  const sb = requireSupabase()
  const { data, error } = await sb
    .from('identity_verifications')
    .select('id, user_id, created_at, document_path, selfie_path')
    .eq('status', 'pending')
    .order('created_at', { ascending: true })
  if (error) throw error
  if (!data || data.length === 0) return []

  const userIds = data.map((d) => d.user_id)
  const { data: profiles, error: profilesError } = await sb.from('profiles').select('id, nickname').in('id', userIds)
  if (profilesError) throw profilesError
  const nameMap = new Map((profiles ?? []).map((p) => [p.id, p.nickname]))

  return data.map((d) => ({
    id: d.id,
    userId: d.user_id,
    nickname: nameMap.get(d.user_id) || '(名前未設定)',
    createdAt: d.created_at,
    documentPath: d.document_path,
    selfiePath: d.selfie_path,
  }))
}

/** 非公開バケット内の画像を、審査担当が一時的に閲覧するための署名付きURL(5分間有効)。 */
export async function getSignedVerificationImageUrl(path: string): Promise<string> {
  const { data, error } = await requireSupabase().storage.from('identity-documents').createSignedUrl(path, 300)
  if (error) throw error
  return data.signedUrl
}

/** 本人確認を承認する(DB更新のみ)。画像削除は deleteVerificationImages で別途行う。 */
export async function approveVerification(verificationId: string, isAdult: boolean): Promise<void> {
  const { error } = await requireSupabase().rpc('approve_identity_verification', {
    p_verification_id: verificationId,
    p_is_adult: isAdult,
  })
  if (error) throw error
}

/** 本人確認を却下する(DB更新のみ)。画像削除は deleteVerificationImages で別途行う。 */
export async function rejectVerification(verificationId: string, reason: string): Promise<void> {
  const { error } = await requireSupabase().rpc('reject_identity_verification', {
    p_verification_id: verificationId,
    p_reason: reason,
  })
  if (error) throw error
}

/**
 * 審査完了後、提出画像をStorageから削除する(管理者のみ、best-effort)。
 * 法務レビュー(operations-legal-qa.md Q6)の「審査後は速やかに削除」に対応。
 * 削除に失敗しても審査結果自体は確定済みなので、例外は投げず握りつぶす。
 */
export async function deleteVerificationImages(paths: (string | null)[]): Promise<void> {
  const targets = paths.filter((p): p is string => !!p)
  if (targets.length === 0) return
  try {
    await requireSupabase().storage.from('identity-documents').remove(targets)
  } catch (err) {
    console.warn('[pita-friends] 本人確認画像の削除に失敗(審査結果は確定済み):', err)
  }
}

/* ============================================================
 * 通報・ブロック(docs/trust-safety-spec.md §3)
 * ・reports は insert のみ(閲覧は自分の通報のみ、審査は運営)
 * ・blocks は片方向。RLSで blocker_id = auth.uid() を強制
 * ============================================================ */

/** 通報を作成する。severityはDBトリガーがカテゴリから自動付与する。 */
export async function submitReport(reportedId: string, category: ReportCategory): Promise<void> {
  const sb = requireSupabase()
  const { data: auth } = await sb.auth.getUser()
  const reporterId = auth.user?.id
  if (!reporterId) throw new Error('ログインが必要です')
  const { error } = await sb.from('reports').insert({
    reporter_id: reporterId,
    reported_id: reportedId,
    category,
  })
  if (error) throw error
}

/** 相手をブロックする。既にブロック済みでも成功扱い(冪等)。 */
export async function blockUser(blockedId: string, reason?: string): Promise<void> {
  const sb = requireSupabase()
  const { data: auth } = await sb.auth.getUser()
  const blockerId = auth.user?.id
  if (!blockerId) throw new Error('ログインが必要です')
  const { error } = await sb
    .from('blocks')
    .upsert({ blocker_id: blockerId, blocked_id: blockedId, reason: reason ?? null }, { onConflict: 'blocker_id,blocked_id' })
  if (error) throw error
}

export type BlockedUser = {
  userId: string
  nickname: string
  avatarInitial: string
  avatarColor: string
  createdAt: string
}

/** 自分がブロックしているユーザーの一覧(新しい順)。 */
export async function fetchBlockedUsers(): Promise<BlockedUser[]> {
  const sb = requireSupabase()
  const { data: blocks, error } = await sb
    .from('blocks')
    .select('blocked_id, created_at')
    .order('created_at', { ascending: false })
  if (error) throw error
  if (!blocks || blocks.length === 0) return []

  const ids = blocks.map((b) => b.blocked_id)
  const { data: profiles, error: pErr } = await sb
    .from('profiles')
    .select('id, nickname, avatar_initial, avatar_color')
    .in('id', ids)
  if (pErr) throw pErr
  const map = new Map((profiles ?? []).map((p) => [p.id, p]))

  return blocks.map((b) => {
    const p = map.get(b.blocked_id)
    return {
      userId: b.blocked_id,
      nickname: p?.nickname || '(不明なユーザー)',
      avatarInitial: p?.avatar_initial || p?.nickname?.charAt(0) || '?',
      avatarColor: p?.avatar_color || '#B3E5F2',
      createdAt: b.created_at,
    }
  })
}

/** ブロックを解除する。 */
export async function unblockUser(blockedId: string): Promise<void> {
  const sb = requireSupabase()
  const { data: auth } = await sb.auth.getUser()
  const blockerId = auth.user?.id
  if (!blockerId) throw new Error('ログインが必要です')
  const { error } = await sb
    .from('blocks')
    .delete()
    .eq('blocker_id', blockerId)
    .eq('blocked_id', blockedId)
  if (error) throw error
}
