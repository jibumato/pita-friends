/**
 * アカウントデータの取得・更新。
 * バックエンド未設定時は呼び出さないこと(呼び出し側で isBackendConfigured
 * を確認する、または requireSupabase() が例外を投げる)。
 */
import { requireSupabase, isBackendConfigured } from './supabase'
import type { ContactScope, Gender, CoinPack } from '../flow'
import type {
  ReportCategory,
  BoardMood,
  BoardVc,
  BoardAudience,
  NotificationType,
  AccountRequestType,
  PayoutStatus,
  BankAccountType,
  PresenceStatus,
} from './database.types'

export type AccountBundle = {
  profile: { nickname: string; gender: Gender }
  /** 本人のアイコン画像URL(未設定は null)。 */
  avatarUrl: string | null
  /** 本人が選んでいる状態(今すぐ遊べる/オンライン/取り込み中)。 */
  presenceStatus: PresenceStatus
  safetyPrefs: {
    contact_scope: ContactScope
    approval_required: boolean
    show_online: boolean
    discoverable: boolean
    block_low_trust: boolean
  }
  hostSettings: {
    is_host: boolean
    hourly_rate: number
    games: string[]
    bio: string
    trial_discount_percent: number
    regulars_first_hours: number
  }
  wallet: { balance: number }
  trustStats: {
    manner_score: number
    /** レビュー件数。3件未満はスコアを出さない(docs/trust-safety-spec.md §1.2)。 */
    review_count: number
    dotakyan_count: number
    confirmed_count: number
    is_verified: boolean
  }
}

/** サインイン/起動時のセッション復元後に、本人のアカウントデータをまとめて取得する。 */
export async function fetchAccountBundle(userId: string): Promise<AccountBundle | null> {
  const sb = requireSupabase()
  const [profileRes, safetyRes, hostRes, walletRes, trustRes] = await Promise.all([
    sb.from('profiles').select('nickname, gender, avatar_path, presence_status').eq('id', userId).single(),
    sb
      .from('safety_prefs')
      .select('contact_scope, approval_required, show_online, discoverable, block_low_trust')
      .eq('user_id', userId)
      .single(),
    sb.from('host_settings').select('is_host, hourly_rate, games, bio, trial_discount_percent, regulars_first_hours').eq('user_id', userId).single(),
    sb.from('coin_wallets').select('balance, bonus_balance').eq('user_id', userId).single(),
    sb
      .from('profile_trust_stats')
      .select('manner_score, review_count, dotakyan_count, confirmed_count, is_verified')
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
    profile: { nickname: profileRes.data.nickname, gender: profileRes.data.gender },
    avatarUrl: profileRes.data.avatar_path ? avatarImageUrl(profileRes.data.avatar_path) : null,
    presenceStatus: profileRes.data.presence_status ?? 'online',
    safetyPrefs: safetyRes.data,
    hostSettings: hostRes.data,
    // 予約に使えるのは有償＋ボーナスの合計(消費は有償が先。0016)
    wallet: { balance: walletRes.data.balance + walletRes.data.bonus_balance },
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
  patch: Partial<{ is_host: boolean; hourly_rate: number; games: string[]; bio: string; trial_discount_percent: number }>,
): Promise<void> {
  const { error } = await requireSupabase().from('host_settings').update(patch).eq('user_id', userId)
  if (error) throw error
}

/**
 * そのピタメイトで自分に適用される初回お試し割引の割引率(%)を取得する。
 * 対象外(すでにそのピタメイトと遊んだことがある)・未設定なら0。
 * 表示専用で、実際の請求額は create_booking がサーバ側で決める。
 */
export async function fetchMyTrialDiscount(hostId: string): Promise<number> {
  const { data, error } = await requireSupabase().rpc('my_trial_discount', { p_host_id: hostId })
  if (error) throw error
  return Number(data ?? 0)
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
  /** レビュー件数。3件未満はスコアを出さない(docs/trust-safety-spec.md §1.2)。 */
  reviewCount: number
  isVerified: boolean
  /** ボイスプロフィールの公開URL(未登録は null)。カードから直接再生できる。 */
  voiceUrl: string | null
  voiceSeconds: number | null
  /** アイコン画像の公開URL(未設定は null=頭文字＋カラー)。 */
  avatarUrl: string | null
  /** 最終在席時刻(ISO)。オンライン状態を非公開にしている人は null。 */
  lastSeenAt: string | null
  /** 本人が選んだ状態(ready/online/busy)。 */
  presenceStatus: PresenceStatus
  /** ひとこと(0056)。14日を過ぎたものはサーバ側で null になる。 */
  statusText: string | null
  statusUpdatedAt: string | null
  /** 2回以上遊んだ人の数(0058)。0のときは表示しない。 */
  repeatGuests: number
}

/**
 * 「さがす」画面向けのピタメイト一覧。埋め込みリレーション(select内のネスト構文)は
 * 手書きDatabase型にRelationshipsメタデータが無く型解決できないため、
 * host_settings / profiles / profile_trust_stats を個別に取得しJS側で結合する。
 */
/**
 * 未ログインの訪問者に見せる「掲載中のピタメイト」。
 *
 * ログイン後の `fetchDiscoverableHosts` と違い、テーブルを直接読まずに
 * `public_host_cards()`(0052)を呼ぶ。RLSを緩めずに済ませるため。
 *
 * **オンライン状態とボイスは返らない。** 未ログインの相手に「いま誰が居るか」を
 * 教える必要が無く、付きまといの材料になるため意図的に外している(0052の注記)。
 */
export async function fetchPublicHostCards(limit = 24): Promise<DiscoverableHost[]> {
  const { data, error } = await requireSupabase().rpc('public_host_cards', { p_limit: limit })
  if (error) throw error
  return (data ?? []).map((r) => ({
    userId: r.host_id,
    nickname: r.nickname,
    avatarInitial: r.avatar_initial,
    avatarColor: r.avatar_color,
    hourlyRate: r.hourly_rate,
    games: r.games ?? [],
    bio: r.bio ?? '',
    mannerScore: Number(r.manner_score),
    reviewCount: r.review_count,
    isVerified: r.is_verified,
    voiceUrl: null,
    voiceSeconds: null,
    avatarUrl: r.avatar_path ? avatarImageUrl(r.avatar_path) : null,
    lastSeenAt: null,
    presenceStatus: 'online' as PresenceStatus,
    statusText: r.status_text,
    statusUpdatedAt: r.status_updated_at,
    repeatGuests: r.repeat_guests ?? 0,
  }))
}

export async function fetchDiscoverableHosts(excludeUserId: string | null): Promise<DiscoverableHost[]> {
  const sb = requireSupabase()
  const { data: hosts, error: hostsError } = await sb
    .from('host_settings')
    .select('user_id, hourly_rate, games, bio, status_text, status_updated_at')
    .eq('is_host', true)
  if (hostsError) throw hostsError
  if (!hosts) return []

  const userIds = hosts.map((h) => h.user_id).filter((id) => id !== excludeUserId)
  if (userIds.length === 0) return []

  const [{ data: profiles, error: profilesError }, { data: stats, error: statsError }] = await Promise.all([
    sb.from('profiles').select('id, nickname, avatar_initial, avatar_color, voice_path, voice_seconds, avatar_path, last_seen_at, presence_status').in('id', userIds),
    sb.from('profile_trust_stats').select('user_id, manner_score, review_count, is_verified').in('user_id', userIds),
  ])
  if (profilesError) throw profilesError
  if (statsError) throw statsError

  const profileMap = new Map((profiles ?? []).map((p) => [p.id, p]))
  const statsMap = new Map((stats ?? []).map((s) => [s.user_id, s]))

  // リピートの実績(0058/0060)はまとめて1往復で取る。取れなくても一覧は出す
  // (「また呼ばれている」は選ぶ助けであって、無いと困る情報ではない)。
  const repeatMap = new Map<string, { count: number; score: number }>()
  const { data: repeats } = await sb.rpc('host_repeat_stats', { p_host_ids: userIds })
  for (const r of repeats ?? []) {
    repeatMap.set(r.host_id, { count: r.repeat_guests, score: Number(r.repeat_score) })
  }

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
        reviewCount: stat?.review_count ?? 0,
        isVerified: stat?.is_verified ?? false,
        voiceUrl: profile.voice_path ? voiceGreetingUrl(profile.voice_path) : null,
        voiceSeconds: profile.voice_seconds ?? null,
        avatarUrl: profile.avatar_path ? avatarImageUrl(profile.avatar_path) : null,
        lastSeenAt: profile.last_seen_at ?? null,
        presenceStatus: profile.presence_status ?? 'online',
        // 古いひとことは出さない。判定はサーバの fresh_host_status と同じ14日
        ...freshStatus(h.status_text, h.status_updated_at),
        repeatGuests: repeatMap.get(h.user_id)?.count ?? 0,
      }
    })
    // 「また呼ばれているか」順。未ログインの掲載カード(public_host_cards)と
    // **同じ式・同じ並び**にすること。違うと、登録した瞬間に一覧が入れ替わって
    // 「さっき見た人がいない」になる。
    // repeat_score が取れなかったときは既定値(0.25)として扱い、順位を壊さない。
    .sort((a, b) => {
      const sa = repeatMap.get(a.userId)?.score ?? 0.25
      const sb2 = repeatMap.get(b.userId)?.score ?? 0.25
      if (sa !== sb2) return sb2 - sa
      if (a.mannerScore !== b.mannerScore) return b.mannerScore - a.mannerScore
      if (a.reviewCount !== b.reviewCount) return b.reviewCount - a.reviewCount
      return a.userId.localeCompare(b.userId)
    })
}

/**
 * ひとことを出してよいかの判定(0056)。
 * **`fresh_host_status()` の14日と必ず揃えること。** ここだけ直すと、
 * 未ログインのカードには出ないのにログイン後は出る、という食い違いになる。
 */
const STATUS_FRESH_DAYS = 14
function freshStatus(
  text: string | null,
  at: string | null,
): { statusText: string | null; statusUpdatedAt: string | null } {
  if (!text || !at) return { statusText: null, statusUpdatedAt: null }
  const age = Date.now() - new Date(at).getTime()
  if (age > STATUS_FRESH_DAYS * 86_400_000) return { statusText: null, statusUpdatedAt: null }
  return { statusText: text, statusUpdatedAt: at }
}

/* ============================================================
 * 決済(Stripe)。コインの付与はサーバー(webhook)でのみ行うため、
 * ここでできるのは「パック一覧の取得」と「Checkoutセッションの発行要求」まで。
 * ============================================================ */

/** 販売中のコインパックをサーバー(coin_packs)から取得する。 */
export async function fetchCoinPacks(): Promise<CoinPack[]> {
  const { data, error } = await requireSupabase()
    .from('coin_packs')
    .select('id, coins, bonus_coins, price_yen')
    .eq('active', true)
    .order('sort', { ascending: true })
  if (error) throw error
  return (data ?? []).map((p) => ({
    id: p.id,
    coins: p.coins,
    bonusCoins: p.bonus_coins,
    priceYen: p.price_yen,
  }))
}

/**
 * Edge Function の失敗から、人が読める理由を組み立てる。
 *
 * **supabase-js は本文を読まずに `Edge Function returned a non-2xx status code`
 * とだけ投げる。** どの Function がどう失敗しても文言が同じなので、
 * 画面のスクリーンショットからは何も分からない。エラーは `context` に
 * Response を持っているので、そこから本文と状態コードを取り出す。
 *
 * 末尾に `[500 internal_error]` の形で機械的な手掛かりも足す。
 * **問い合わせのスクリーンショット1枚で切り分けられるようにするため。**
 */
async function functionErrorMessage(error: unknown, fallback: string): Promise<string> {
  const ctx = (error as { context?: unknown } | null)?.context
  if (!(ctx instanceof Response)) {
    return error instanceof Error ? error.message : fallback
  }
  let code: string | null = null
  let body: Record<string, unknown> = {}
  try {
    body = (await ctx.clone().json()) as Record<string, unknown>
    if (typeof body.error === 'string') code = body.error
  } catch {
    /* 本文がJSONでないこともある。状態コードだけで返す */
  }
  const known: Record<string, string> = {
    unauthorized: 'ログインの有効期限が切れています。ログインし直してください',
    'pack not found': 'このコインパックは現在購入できません',
    'pack_id required': '購入するパックが選ばれていません',
    internal_error: '決済ページを準備できませんでした。時間をおいて試してください',
  }
  // 購入上限(規約 第8条の6第5項1号)。**金額を必ず出す。**
  // 「買えません」だけだと、いくらなら買えるのかが分からない
  if (code === 'PURCHASE_LIMIT_PER' || code === 'PURCHASE_LIMIT_PERIOD') {
    const b = body as { limit_yen?: number; remaining_yen?: number; period_days?: number }
    const yen = (v?: number) => (typeof v === 'number' ? `${v.toLocaleString()}円` : '—')
    return code === 'PURCHASE_LIMIT_PER'
      ? `安全のため、ご登録から間もないあいだは1回あたり${yen(b.limit_yen)}までの購入に制限しています（本人確認を済ませると解除されます）`
      : `安全のため、直近${b.period_days ?? 30}日間の購入は${yen(b.limit_yen)}までに制限しています。あと${yen(b.remaining_yen)}まで購入できます`
  }
  const head = (code && known[code]) || fallback
  return `${head} [${ctx.status}${code ? ` ${code}` : ''}]`
}

/**
 * Stripe Checkout セッションを発行し、決済ページのURLを返す。
 * 呼び出し側はこのURLへ遷移する。付与は決済完了後にwebhookが行う。
 */
export async function createCheckoutSession(packId: string): Promise<string> {
  const { data, error } = await requireSupabase().functions.invoke<{ url?: string; error?: string }>(
    'create-checkout-session',
    // 0106: 購入時点の環境を残すため端末IDも渡す。IPはEdge Function側が
    // X-Forwarded-For から読む(クライアント申告のIPは信用しない)
    { body: { packId, deviceId: getDeviceId() } },
  )
  if (error) throw new Error(await functionErrorMessage(error, '決済ページの準備に失敗しました'))
  if (!data?.url) throw new Error(data?.error || '決済ページの準備に失敗しました')
  return data.url
}

/* ============================================================
 * マッチング(誘う → 承認 → 約束)。schema: 0004_matching。
 * ・誘いの送信可否(contact_scope)は invites の RLS で強制される。
 * ・承認/辞退は approve_invite / decline_invite RPC 経由。
 * ============================================================ */

/** 誘いを送る。相手の安心設定(contact_scope)を満たさない場合はRLSで弾かれる。 */
export async function createInvite(
  toUserId: string,
  game: string,
  whenText: string,
  message: string,
): Promise<void> {
  const sb = requireSupabase()
  const { data: auth } = await sb.auth.getUser()
  const fromUser = auth.user?.id
  if (!fromUser) throw new Error('ログインが必要です')
  const { error } = await sb.from('invites').insert({
    from_user: fromUser,
    to_user: toUserId,
    game,
    when_text: whenText,
    message,
  })
  if (error) {
    // RLS(contact_scope)違反は 403。ユーザー向けに言い換える。
    if (error.code === '42501' || /row-level security/i.test(error.message)) {
      throw new Error('相手の安心設定により、いまは誘いを送れません（本人確認や同性のみ等の条件）。')
    }
    throwMapped(error)
  }
}

export type IncomingInvite = {
  id: string
  fromUserId: string
  name: string
  initial: string
  color: string
  verified: boolean
  manner: string
  dotakyan: string
  plays: number
  game: string
  when: string
  message: string
}

/** 自分宛の承認待ちの誘いを、送信者の信頼情報つきで取得する。 */
export async function fetchIncomingInvites(): Promise<IncomingInvite[]> {
  const sb = requireSupabase()
  const { data: auth } = await sb.auth.getUser()
  const me = auth.user?.id
  if (!me) throw new Error('ログインが必要です')

  const { data: invites, error } = await sb
    .from('invites')
    .select('id, from_user, game, when_text, message, created_at')
    .eq('to_user', me)
    .eq('status', 'pending')
    .order('created_at', { ascending: false })
  if (error) throw error
  if (!invites || invites.length === 0) return []

  const fromIds = invites.map((i) => i.from_user)
  const [{ data: profiles }, { data: stats }] = await Promise.all([
    sb.from('profiles').select('id, nickname, avatar_initial, avatar_color').in('id', fromIds),
    sb
      .from('profile_trust_stats')
      .select('user_id, manner_score, dotakyan_count, confirmed_count, is_verified')
      .in('user_id', fromIds),
  ])
  const pMap = new Map((profiles ?? []).map((p) => [p.id, p]))
  const sMap = new Map((stats ?? []).map((s) => [s.user_id, s]))

  return invites.map((i) => {
    const p = pMap.get(i.from_user)
    const s = sMap.get(i.from_user)
    const confirmed = s?.confirmed_count ?? 0
    const dotakyan = s?.dotakyan_count ?? 0
    const denom = confirmed + dotakyan
    return {
      id: i.id,
      fromUserId: i.from_user,
      name: p?.nickname || '(名前未設定)',
      initial: p?.avatar_initial || p?.nickname?.charAt(0) || '?',
      color: p?.avatar_color || '#B3E5F2',
      verified: s?.is_verified ?? false,
      manner: `★${(s?.manner_score ?? 4.5).toFixed(1)}`,
      dotakyan: `${denom > 0 ? Math.round((dotakyan / denom) * 100) : 0}%`,
      plays: confirmed,
      game: i.game,
      when: i.when_text,
      message: i.message,
    }
  })
}

/** 誘いを承認する(約束が成立する)。成立した約束(promise)のIDを返す(トークルームを開くのに使う)。 */
export async function approveInvite(inviteId: string): Promise<string> {
  const { data, error } = await requireSupabase().rpc('approve_invite', { p_invite_id: inviteId })
  if (error) throw error
  return data as string
}

/** 誘いを辞退する。 */
export async function declineInvite(inviteId: string): Promise<void> {
  const { error } = await requireSupabase().rpc('decline_invite', { p_invite_id: inviteId })
  if (error) throw error
}

/* ============================================================
 * チャット(トーク)。promise(約束)の当事者間だけがやり取りできる。
 * schema: 0010_messaging。
 * ============================================================ */

export type ChatThread = {
  promiseId: string
  partnerId: string
  partnerName: string
  partnerInitial: string
  partnerColor: string
  partnerVerified: boolean
  lastMessage: string | null
  lastMessageAt: string | null
  unreadCount: number
  /** 相手のオンライン表示用(非公開なら null)。 */
  partnerLastSeenAt: string | null
  partnerPresenceStatus: PresenceStatus
}

/** 自分が参加している約束(promise)を、トークルーム一覧として取得する。 */
export async function fetchChatThreads(): Promise<ChatThread[]> {
  const sb = requireSupabase()
  const { data: auth } = await sb.auth.getUser()
  const me = auth.user?.id
  if (!me) throw new Error('ログインが必要です')

  const { data: promises, error } = await sb
    .from('promises')
    .select('id, user_a, user_b, created_at')
    .or(`user_a.eq.${me},user_b.eq.${me}`)
    .order('created_at', { ascending: false })
  if (error) throw error
  if (!promises || promises.length === 0) return []

  const partnerIds = promises.map((p) => (p.user_a === me ? p.user_b : p.user_a))
  const promiseIds = promises.map((p) => p.id)

  const [{ data: profiles }, { data: stats }, { data: lastMsgs }, { data: reads }] = await Promise.all([
    sb.from('profiles').select('id, nickname, avatar_initial, avatar_color, last_seen_at, presence_status').in('id', partnerIds),
    sb.from('profile_trust_stats').select('user_id, is_verified').in('user_id', partnerIds),
    sb
      .from('messages')
      .select('promise_id, body, created_at, sender_id')
      .in('promise_id', promiseIds)
      .order('created_at', { ascending: false }),
    sb.from('message_reads').select('promise_id, last_read_at').eq('user_id', me).in('promise_id', promiseIds),
  ])
  const pMap = new Map((profiles ?? []).map((p) => [p.id, p]))
  const sMap = new Map((stats ?? []).map((s) => [s.user_id, s]))
  const readMap = new Map((reads ?? []).map((r) => [r.promise_id, r.last_read_at]))

  // 各promiseの最新メッセージ(降順で取得済みなので最初の1件)
  const lastByPromise = new Map<string, { body: string; created_at: string }>()
  for (const m of lastMsgs ?? []) {
    if (!lastByPromise.has(m.promise_id)) lastByPromise.set(m.promise_id, m)
  }
  // 未読数(自分が送っていない、last_read_at以降のメッセージ数)をカウント
  const unreadByPromise = new Map<string, number>()
  for (const m of lastMsgs ?? []) {
    if (m.sender_id === me) continue
    const lastRead = readMap.get(m.promise_id)
    if (!lastRead || new Date(m.created_at) > new Date(lastRead)) {
      unreadByPromise.set(m.promise_id, (unreadByPromise.get(m.promise_id) ?? 0) + 1)
    }
  }

  return promises.map((p) => {
    const partnerId = p.user_a === me ? p.user_b : p.user_a
    const partner = pMap.get(partnerId)
    const last = lastByPromise.get(p.id)
    return {
      promiseId: p.id,
      partnerId,
      partnerName: partner?.nickname || '(名前未設定)',
      partnerInitial: partner?.avatar_initial || partner?.nickname?.charAt(0) || '?',
      partnerColor: partner?.avatar_color || '#B3E5F2',
      partnerVerified: sMap.get(partnerId)?.is_verified ?? false,
      lastMessage: last?.body ?? null,
      lastMessageAt: last?.created_at ?? p.created_at,
      unreadCount: unreadByPromise.get(p.id) ?? 0,
      partnerLastSeenAt: partner?.last_seen_at ?? null,
      partnerPresenceStatus: partner?.presence_status ?? 'online',
    }
  })
}

/** 全トークの未読メッセージ合計(下部タブのバッジ表示用)。 */
export async function fetchUnreadTalkCount(): Promise<number> {
  const threads = await fetchChatThreads()
  return threads.reduce((sum, t) => sum + t.unreadCount, 0)
}

export type ThreadPartner = {
  userId: string
  name: string
  initial: string
  color: string
  verified: boolean
}

/** トークルーム(約束)の相手の情報を取得する(ヘッダー表示用)。 */
export async function fetchThreadPartner(promiseId: string): Promise<ThreadPartner | null> {
  const sb = requireSupabase()
  const { data: auth } = await sb.auth.getUser()
  const me = auth.user?.id
  if (!me) throw new Error('ログインが必要です')

  const { data: promise, error } = await sb
    .from('promises')
    .select('user_a, user_b')
    .eq('id', promiseId)
    .single()
  if (error) throw error
  if (!promise) return null
  const partnerId = promise.user_a === me ? promise.user_b : promise.user_a

  const [{ data: profile }, { data: stats }] = await Promise.all([
    sb.from('profiles').select('nickname, avatar_initial, avatar_color').eq('id', partnerId).maybeSingle(),
    sb.from('profile_trust_stats').select('is_verified').eq('user_id', partnerId).maybeSingle(),
  ])
  return {
    userId: partnerId,
    name: profile?.nickname || '(名前未設定)',
    initial: profile?.avatar_initial || profile?.nickname?.charAt(0) || '?',
    color: profile?.avatar_color || '#B3E5F2',
    verified: stats?.is_verified ?? false,
  }
}

export type ChatMessage = {
  id: string
  promiseId: string
  senderId: string
  body: string
  createdAt: string
}

/** 指定promiseのメッセージを古い順に取得する。 */
export async function fetchMessages(promiseId: string): Promise<ChatMessage[]> {
  const { data, error } = await requireSupabase()
    .from('messages')
    .select('id, promise_id, sender_id, body, created_at')
    .eq('promise_id', promiseId)
    .order('created_at', { ascending: true })
  if (error) throw error
  return (data ?? []).map((m) => ({
    id: m.id,
    promiseId: m.promise_id,
    senderId: m.sender_id,
    body: m.body,
    createdAt: m.created_at,
  }))
}

/** メッセージを送信する。 */
export async function sendMessage(promiseId: string, body: string): Promise<void> {
  const sb = requireSupabase()
  const { data: auth } = await sb.auth.getUser()
  const me = auth.user?.id
  if (!me) throw new Error('ログインが必要です')
  const { error } = await sb.from('messages').insert({ promise_id: promiseId, sender_id: me, body })
  if (error) throwMapped(error)
}

/** ピタメイトランキングの期間。 */
export type RankingPeriod = 'daily' | 'weekly' | 'monthly'

export type RankingEntry = {
  rank: number
  hostId: string
  nickname: string
  avatarInitial: string
  avatarColor: string
  avatarUrl: string | null
  completedCount: number
  mannerScore: number
  score: number
  isVerified: boolean
}

/**
 * ピタメイトランキングを取得する。スコアは「完了予約数×品質×信頼性」で、
 * 金額(投げ銭・稼ぎ)は一切含まない(スキル・活動ベース)。
 */
export async function fetchHostRanking(period: RankingPeriod, limit = 30): Promise<RankingEntry[]> {
  const { data, error } = await requireSupabase().rpc('host_ranking', { p_period: period, p_limit: limit })
  if (error) throw error
  return (data ?? []).map((r) => ({
    rank: Number(r.rank),
    hostId: r.host_id,
    nickname: r.nickname,
    avatarInitial: r.avatar_initial,
    avatarColor: r.avatar_color,
    avatarUrl: r.avatar_path ? avatarImageUrl(r.avatar_path) : null,
    completedCount: Number(r.completed_count),
    mannerScore: Number(r.manner_score),
    score: Number(r.score),
    isVerified: r.is_verified,
  }))
}

/** お気に入りに登録しているピタメイト。 */
export type FavoriteHost = {
  userId: string
  nickname: string
  avatarInitial: string
  avatarColor: string
  avatarUrl: string | null
  hourlyRate: number
  games: string[]
  mannerScore: number
  reviewCount: number
  isVerified: boolean
  /** いま予約を受け付けているか。false は「募集を休んでいる」。 */
  isActive: boolean
  favoritedAt: string
  /** ひとこと(0056)。14日を過ぎたものはサーバ側で null になる。 */
  statusText: string | null
  statusUpdatedAt: string | null
}

/**
 * お気に入り登録の追加・解除(0053)。
 * **誰をお気に入りにしているかは本人以外に見えない。** 相手には人数だけが伝わる。
 */
export async function setFavorite(hostId: string, on: boolean): Promise<void> {
  const { error } = await requireSupabase().rpc('set_favorite', { p_host_id: hostId, p_on: on })
  if (error) throw error
}

/** 自分がお気に入りにしているピタメイトの一覧。掲載を休んでいる相手も isActive=false で残る。 */
export async function fetchMyFavorites(): Promise<FavoriteHost[]> {
  const { data, error } = await requireSupabase().rpc('my_favorites')
  if (error) throw error
  return (data ?? []).map((r) => ({
    userId: r.host_id,
    nickname: r.nickname,
    avatarInitial: r.avatar_initial,
    avatarColor: r.avatar_color,
    avatarUrl: r.avatar_path ? avatarImageUrl(r.avatar_path) : null,
    hourlyRate: r.hourly_rate,
    games: r.games ?? [],
    mannerScore: Number(r.manner_score),
    reviewCount: r.review_count,
    isVerified: r.is_verified,
    isActive: r.is_active,
    favoritedAt: r.favorited_at,
    statusText: r.status_text,
    statusUpdatedAt: r.status_updated_at,
  }))
}

/** 自分をお気に入りにしている人数。誰かは分からない。 */
export async function fetchMyFavoriteCount(): Promise<number> {
  const { data, error } = await requireSupabase().rpc('my_favorite_count')
  if (error) throw error
  return data ?? 0
}

/**
 * 自分の「ひとこと」を読む(0056)。
 * 起動時の一括取得(fetchAccountBundle)には載せていない。あれは localStorage に
 * 持ち回るので、時刻つきで古くなる値を混ぜると、消したはずのひとことが
 * 手元だけ残り続ける。
 */
export async function fetchMyHostStatus(): Promise<{ text: string; updatedAt: string | null }> {
  const sb = requireSupabase()
  const { data: auth } = await sb.auth.getUser()
  const uid = auth.user?.id
  if (!uid) return { text: '', updatedAt: null }
  const { data, error } = await sb
    .from('host_settings')
    .select('status_text, status_updated_at')
    .eq('user_id', uid)
    .maybeSingle()
  if (error) throw error
  return { text: data?.status_text ?? '', updatedAt: data?.status_updated_at ?? null }
}

/**
 * 自分の「ひとこと」を書き換える(0056)。空文字を渡すと消える。
 * 返るのは更新時刻(消したときは null)。
 */
export async function setHostStatus(text: string): Promise<string | null> {
  const { data, error } = await requireSupabase().rpc('set_host_status', { p_text: text })
  if (error) throw error
  return data ?? null
}

/** 「この相手とは早く確定してよい」の設定(0062)。 */
export type FastRelease = {
  /** 設定している時間数。null は既定(72時間)のまま。 */
  hours: number | null
  /** 設定できる状態か(3回以上遊んだ相手かどうか)。 */
  eligible: boolean
}

export async function fetchFastRelease(hostId: string): Promise<FastRelease> {
  const { data, error } = await requireSupabase().rpc('my_fast_release', { p_host_id: hostId })
  if (error) throw error
  const q = (data ?? {}) as { hours?: number | null; eligible?: boolean }
  return { hours: q.hours ?? null, eligible: Boolean(q.eligible) }
}

/**
 * 自動確定を早める設定(0062)。null を渡すと既定(72時間)に戻る。
 * **ゲスト本人しか変えられない。** 72時間はゲストが申し出を出すための窓でもあり、
 * 運営やピタメイトの側から短くしてよいものではない。
 */
export async function setFastRelease(hostId: string, hours: number | null): Promise<void> {
  const { error } = await requireSupabase().rpc('set_fast_release', {
    p_host_id: hostId,
    p_hours: hours,
  })
  if (error) throw error
}

/** 自分とこの相手が一緒に遊んだ実績(0055)。 */
export type PlayHistoryWith = {
  count: number
  lastPlayedAt: Date | null
  /** 前回の長さ(分)と開始時刻(0059)。「前回と同じで予約」に使う。 */
  lastDurationMinutes: number | null
  lastScheduledAt: Date | null
}

/**
 * 「あなたとは3回目」を出すための回数。
 * 自分が当事者の予約しか数えないので、他人同士の関係は分からない。
 */
export async function fetchPlayHistoryWith(otherUserId: string): Promise<PlayHistoryWith> {
  const { data, error } = await requireSupabase().rpc('my_play_history_with', {
    p_other: otherUserId,
  })
  if (error) throw error
  const q = (data ?? {}) as {
    count?: number
    last_played_at?: string | null
    last_duration_minutes?: number | null
    last_scheduled_at?: string | null
  }
  return {
    count: Number(q.count ?? 0),
    lastPlayedAt: q.last_played_at ? new Date(q.last_played_at) : null,
    lastDurationMinutes: q.last_duration_minutes ?? null,
    lastScheduledAt: q.last_scheduled_at ? new Date(q.last_scheduled_at) : null,
  }
}

/** ギフト(ありがとうチップ)で選べる金額(コイン=円)。上限は1回50,000。 */
export const GIFT_AMOUNTS = [100, 500, 1000, 5000, 10000, 50000] as const

const GIFT_ERROR_MESSAGES: Record<string, string> = {
  INSUFFICIENT_COINS: '購入コインの残高が足りません。ギフトは購入コインからのみ行えます',
  INVALID_AMOUNT: 'ギフトの金額が正しくありません(1回50,000コインまで)',
  BLOCKED: 'この相手を指定したギフトは行えません',
  THREAD_NOT_FOUND: 'トークが見つかりませんでした',
  FORBIDDEN: 'このトークではギフトを行えません',
  SAME_DEVICE_FORBIDDEN: '同じ端末で使われたアカウント間ではギフトを行えません',
  NO_COMPLETED_PLAY: 'ギフトは、一緒に遊んだ(予約が完了した)ピタメイトを指定してのみ行えます',
  MUTUAL_GIFT_FORBIDDEN: 'この相手からギフトを受けているため、こちらからは行えません(相互送金の防止)',
  RECENT_PURCHASE_COOLDOWN: 'コイン購入から24時間はギフトを行えません',
  // 0097(規約 第7条の2第6項)。役務との牽連性と、送金網化の防止
  GIFT_WINDOW_CLOSED: 'プレイの完了から30日を過ぎたため、このお相手へのギフトは行えません',
  RECEIVER_MONTHLY_LIMIT: 'このピタメイトが直近30日に受けたギフトが上限に達しています',
  PAIR_MONTHLY_LIMIT: '同じお相手へのギフトが直近30日の上限に達しています',
  DAILY_LIMIT: '1日の送信上限(50,000コイン)を超えます',
  MONTHLY_LIMIT: '30日間の送信上限(200,000コイン)を超えます',
  NOT_AUTHENTICATED: 'ログインが必要です',
}

/**
 * この端末の安定ID(localStorageに永続化)。ギフトの自己取引検知に用いる。
 * ブラウザのストレージをクリアすると変わりうるが、通常の自己取引導線は捕捉できる。
 */
export function getDeviceId(): string {
  const KEY = 'pita_device_id'
  try {
    let id = localStorage.getItem(KEY)
    if (!id) {
      id =
        typeof crypto !== 'undefined' && 'randomUUID' in crypto
          ? crypto.randomUUID()
          : 'd_' + Math.random().toString(36).slice(2) + Date.now().toString(36)
      localStorage.setItem(KEY, id)
    }
    return id
  } catch {
    // localStorageが使えない環境ではセッション限りのIDにフォールバック
    return 'd_' + Math.random().toString(36).slice(2) + Date.now().toString(36)
  }
}

/** ログイン中ユーザーの端末IDを記録する(アプリ起動時に一度呼ぶ)。失敗は無視。 */
export async function recordDevice(): Promise<void> {
  try {
    await requireSupabase().rpc('record_device', { p_device_id: getDeviceId() })
  } catch {
    /* 監視用の記録なので、失敗してもユーザー操作は妨げない */
  }
}

/**
 * ログイン中ユーザーのIPを記録する(アプリ起動時に一度呼ぶ)。
 * ブラウザは自分の正しい公開IPを取得できないため、Edge Function(record-ip)が
 * サーバ側でX-Forwarded-Forを読んで記録する。失敗は無視(監視用のため)。
 */
export async function recordIp(): Promise<void> {
  try {
    await requireSupabase().functions.invoke('record-ip', {
      // 0106: アプリ起動の記録に端末IDを添える
      body: { deviceId: getDeviceId() },
    })
  } catch {
    /* Edge Function未デプロイ・ネットワーク不通でもユーザー操作は妨げない */
  }
}

/**
 * トークの相手にコインを贈る(ありがとうチップ)。原資は自分の購入コイン(balance)のみ。
 * 一緒に遊んだ(予約完了した)相手にのみ贈れ、相手は換金可能な報酬コインとして受け取る
 * (受領から7日間は換金保留)。端末IDを同送し、同一端末の自己取引を検知・遮断する。
 */
export async function sendGift(promiseId: string, coins: number, message?: string): Promise<void> {
  const { error } = await requireSupabase().rpc('send_gift', {
    p_promise_id: promiseId,
    p_coins: coins,
    p_message: message?.trim() ? message.trim() : null,
    p_device_id: getDeviceId(),
  })
  if (error) {
    const known = Object.keys(GIFT_ERROR_MESSAGES).find((k) => error.message.includes(k))
    throw new Error(known ? GIFT_ERROR_MESSAGES[known] : 'ギフトに失敗しました')
  }
}

/** 自分の購入コイン残高(換金不可・予約/ギフトに使える有償分)を取得する。 */
export async function fetchPaidBalance(): Promise<number> {
  const sb = requireSupabase()
  const { data: auth } = await sb.auth.getUser()
  const me = auth.user?.id
  if (!me) throw new Error('ログインが必要です')
  const { data, error } = await sb.from('coin_wallets').select('balance').eq('user_id', me).single()
  if (error) throw error
  return data.balance
}

/** このpromiseを既読にする(自分の既読位置を今に更新)。 */
export async function markThreadRead(promiseId: string): Promise<void> {
  const sb = requireSupabase()
  const { data: auth } = await sb.auth.getUser()
  const me = auth.user?.id
  if (!me) return
  const { error } = await sb
    .from('message_reads')
    .upsert({ promise_id: promiseId, user_id: me, last_read_at: new Date().toISOString() }, { onConflict: 'promise_id,user_id' })
  if (error) throw error
}

/** 指定promiseの新着メッセージをリアルタイム購読する。戻り値の関数で解除する。 */
export function subscribeToMessages(promiseId: string, onInsert: (m: ChatMessage) => void): () => void {
  const sb = requireSupabase()
  const channel = sb
    .channel(`messages:${promiseId}`)
    .on(
      'postgres_changes',
      { event: 'INSERT', schema: 'public', table: 'messages', filter: `promise_id=eq.${promiseId}` },
      (payload) => {
        const m = payload.new as { id: string; promise_id: string; sender_id: string; body: string; created_at: string }
        onInsert({ id: m.id, promiseId: m.promise_id, senderId: m.sender_id, body: m.body, createdAt: m.created_at })
      },
    )
    .subscribe()
  return () => {
    sb.removeChannel(channel)
  }
}

/* ============================================================
 * 募集板。schema: 0011_board。
 * ============================================================ */

export type BoardPostItem = {
  id: string
  game: string
  mood: BoardMood
  whenText: string
  vc: BoardVc
  capacity: number
  joinedCount: number
  audience: BoardAudience
  verifiedOnly: boolean
  note: string
  creatorId: string
  creatorName: string
  creatorInitial: string
  creatorColor: string
  creatorManner: number
  hasJoined: boolean
  isMine: boolean
}

/** 募集中(status='open')の投稿を新しい順に取得する。 */
export async function fetchBoardPosts(): Promise<BoardPostItem[]> {
  const sb = requireSupabase()
  const { data: auth } = await sb.auth.getUser()
  const me = auth.user?.id
  if (!me) throw new Error('ログインが必要です')

  const { data: posts, error } = await sb
    .from('board_posts')
    .select('id, creator_id, game, mood, when_text, capacity, vc, audience, verified_only, note, created_at')
    .eq('status', 'open')
    .order('created_at', { ascending: false })
  if (error) throw error
  if (!posts || posts.length === 0) return []

  const postIds = posts.map((p) => p.id)
  const creatorIds = posts.map((p) => p.creator_id)
  const [{ data: profiles }, { data: stats }, { data: participants }] = await Promise.all([
    sb.from('profiles').select('id, nickname, avatar_initial, avatar_color').in('id', creatorIds),
    sb.from('profile_trust_stats').select('user_id, manner_score').in('user_id', creatorIds),
    sb.from('board_participants').select('post_id, user_id').in('post_id', postIds),
  ])
  const pMap = new Map((profiles ?? []).map((p) => [p.id, p]))
  const sMap = new Map((stats ?? []).map((s) => [s.user_id, s]))
  const countByPost = new Map<string, number>()
  const joinedByMe = new Set<string>()
  for (const pp of participants ?? []) {
    countByPost.set(pp.post_id, (countByPost.get(pp.post_id) ?? 0) + 1)
    if (pp.user_id === me) joinedByMe.add(pp.post_id)
  }

  return posts.map((p) => {
    const creator = pMap.get(p.creator_id)
    return {
      id: p.id,
      game: p.game,
      mood: p.mood,
      whenText: p.when_text,
      vc: p.vc,
      capacity: p.capacity,
      joinedCount: countByPost.get(p.id) ?? 0,
      audience: p.audience,
      verifiedOnly: p.verified_only,
      note: p.note,
      creatorId: p.creator_id,
      creatorName: creator?.nickname || '(名前未設定)',
      creatorInitial: creator?.avatar_initial || creator?.nickname?.charAt(0) || '?',
      creatorColor: creator?.avatar_color || '#B3E5F2',
      creatorManner: sMap.get(p.creator_id)?.manner_score ?? 4.5,
      hasJoined: joinedByMe.has(p.id),
      isMine: p.creator_id === me,
    }
  })
}

/** 募集を作成する。 */
export async function createBoardPost(input: {
  game: string
  mood: BoardMood
  whenText: string
  capacity: number
  vc: BoardVc
  audience: BoardAudience
  verifiedOnly: boolean
  note: string
}): Promise<void> {
  const sb = requireSupabase()
  const { data: auth } = await sb.auth.getUser()
  const me = auth.user?.id
  if (!me) throw new Error('ログインが必要です')
  const { error } = await sb.from('board_posts').insert({
    creator_id: me,
    game: input.game,
    mood: input.mood,
    when_text: input.whenText,
    capacity: input.capacity,
    vc: input.vc,
    audience: input.audience,
    verified_only: input.verifiedOnly,
    note: input.note,
  })
  if (error) throwMapped(error)
}

/** 募集に参加する。定員・本人確認要件等はDB側(join_board_post RPC)でアトミックに検証される。 */
/**
 * 自分の募集を取り消す(論理削除)。参加者にはサーバ側で通知が飛ぶ。
 * 物理削除はしない(参加履歴・通報の追跡を残すため)。
 */
export async function cancelBoardPost(postId: string, reason?: string): Promise<void> {
  const { error } = await requireSupabase().rpc('cancel_board_post', {
    p_post_id: postId,
    p_reason: reason ?? null,
  })
  if (!error) return
  if (/ONLY_CREATOR_CAN_CANCEL/.test(error.message)) {
    throw new Error('自分が作成した募集のみ取り消せます')
  }
  if (/POST_NOT_FOUND/.test(error.message)) {
    throw new Error('募集が見つかりませんでした')
  }
  throw error
}

export async function joinBoardPost(postId: string): Promise<void> {
  const { error } = await requireSupabase().rpc('join_board_post', { p_post_id: postId })
  if (!error) return
  const msg = error.message
  if (msg.includes('VERIFICATION_REQUIRED')) throw new Error('本人確認済みの方のみ参加できます')
  if (msg.includes('AUDIENCE_RESTRICTED')) throw new Error('参加条件（同性のみ）を満たしていません')
  if (msg.includes('POST_FULL')) throw new Error('定員に達しました')
  if (msg.includes('ALREADY_JOINED')) throw new Error('すでに参加しています')
  if (msg.includes('BLOCKED')) throw new Error('参加できません')
  if (msg.includes('CANNOT_JOIN_OWN_POST')) throw new Error('自分の募集には参加できません')
  if (msg.includes('POST_NOT_OPEN')) throw new Error('この募集は締め切られました')
  throwMapped(error)
}

/* ============================================================
 * 通知。schema: 0012_notifications(DBトリガーで自動生成される)。
 * ============================================================ */

export type AppNotification = {
  id: string
  type: NotificationType
  title: string
  body: string
  relatedId: string | null
  read: boolean
  createdAt: string
}

/** 自分宛の通知を新しい順に取得する(直近50件)。 */
export async function fetchNotifications(): Promise<AppNotification[]> {
  const { data, error } = await requireSupabase()
    .from('notifications')
    .select('id, type, title, body, related_id, read, created_at')
    .order('created_at', { ascending: false })
    .limit(50)
  if (error) throw error
  return (data ?? []).map((n) => ({
    id: n.id,
    type: n.type,
    title: n.title,
    body: n.body,
    relatedId: n.related_id,
    read: n.read,
    createdAt: n.created_at,
  }))
}

/** 指定した通知1件を既読にする(通知一覧でタップして開いたとき用)。 */
export async function markNotificationRead(notificationId: string): Promise<void> {
  const { error } = await requireSupabase().from('notifications').update({ read: true }).eq('id', notificationId)
  if (error) throw error
}

/** 未読の通知をすべて既読にする。 */
export async function markAllNotificationsRead(): Promise<void> {
  const sb = requireSupabase()
  const { data: auth } = await sb.auth.getUser()
  const me = auth.user?.id
  if (!me) return
  const { error } = await sb.from('notifications').update({ read: true }).eq('user_id', me).eq('read', false)
  if (error) throw error
}

/** 未読通知の件数(ホームのベルのバッジ表示用)。 */
export async function fetchUnreadNotificationCount(): Promise<number> {
  const sb = requireSupabase()
  const { data: auth } = await sb.auth.getUser()
  const me = auth.user?.id
  if (!me) return 0
  const { count, error } = await sb
    .from('notifications')
    .select('id', { count: 'exact', head: true })
    .eq('user_id', me)
    .eq('read', false)
  if (error) throw error
  return count ?? 0
}

/** 承認された誘い(invite)から成立した約束(promise)のIDを引く(通知タップでトークを開くのに使う)。 */
export async function resolvePromiseIdForInvite(inviteId: string): Promise<string | null> {
  const { data, error } = await requireSupabase()
    .from('promises')
    .select('id')
    .eq('invite_id', inviteId)
    .maybeSingle()
  if (error) throw error
  return data?.id ?? null
}

/** 自分宛の承認待ち件数(誘い＋予約リクエスト。ホーム/マイページのバッジ用)。 */
export async function fetchPendingInviteCount(): Promise<number> {
  const sb = requireSupabase()
  const { data: auth } = await sb.auth.getUser()
  const me = auth.user?.id
  if (!me) return 0
  const [invites, bookings] = await Promise.all([
    sb.from('invites').select('id', { count: 'exact', head: true }).eq('to_user', me).eq('status', 'pending'),
    sb.from('bookings').select('id', { count: 'exact', head: true }).eq('host_id', me).eq('status', 'requested'),
  ])
  if (invites.error) throw invites.error
  if (bookings.error) throw bookings.error
  return (invites.count ?? 0) + (bookings.count ?? 0)
}

/** これまでに約束(promise)が成立した相手の人数(マイページの「フレンド」表示用)。 */
export async function fetchFriendCount(): Promise<number> {
  const sb = requireSupabase()
  const { data: auth } = await sb.auth.getUser()
  const me = auth.user?.id
  if (!me) return 0
  const { data, error } = await sb.from('promises').select('user_a, user_b').or(`user_a.eq.${me},user_b.eq.${me}`)
  if (error) throw error
  const partners = new Set((data ?? []).map((p) => (p.user_a === me ? p.user_b : p.user_a)))
  return partners.size
}

/* ============================================================
 * 通知設定・アカウント請求。schema: 0012_notifications。
 * ============================================================ */

export type NotificationPrefs = {
  notifyInvites: boolean
  notifyOnlineFriends: boolean
  notifyRecommendations: boolean
}

type PrefsRow = {
  notify_invites?: boolean
  notify_online_friends?: boolean
  notify_recommendations?: boolean
}

function toPrefs(row: unknown): NotificationPrefs {
  const r = (row ?? {}) as PrefsRow
  return {
    notifyInvites: r.notify_invites ?? true,
    notifyOnlineFriends: r.notify_online_friends ?? true,
    notifyRecommendations: r.notify_recommendations ?? false,
  }
}

/**
 * 通知の受け取り設定を取得する。
 *
 * **表を直接読まない。** notification_prefs の行は 0012 のトリガでしか
 * 作られないので、0012より前に登録したユーザーには行が無く、
 * .single() が失敗して設定画面が丸ごと死ぬ。0084 の関数は
 * 「無ければ作ってから返す」ので、行の有無を画面が気にしなくてよい。
 */
export async function fetchNotificationPrefs(): Promise<NotificationPrefs> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('get_notification_prefs')
  if (error) throw error
  return toPrefs(data)
}

/**
 * 通知の受け取り設定を更新する。
 *
 * 触ったトグルだけを送る(未指定は変更しない)。3つまとめて送ると、
 * 別の端末で先に変えた設定を上書きしてしまう。
 * 戻り値は**保存後の値**なので、画面はこれで状態を作り直す。
 */
export async function updateNotificationPrefs(
  patch: Partial<NotificationPrefs>,
): Promise<NotificationPrefs> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('set_notification_prefs', {
    p_invites: patch.notifyInvites ?? null,
    p_online_friends: patch.notifyOnlineFriends ?? null,
    p_recommendations: patch.notifyRecommendations ?? null,
  })
  if (error) throw error
  return toPrefs(data)
}

/* ============================================================
 * 退会(規約 第6条の2)。schema: 0086_account_withdrawal。
 * ============================================================ */

export type WithdrawalPreview = {
  /** 退会済みならその日時。null は在籍中。 */
  withdrawnAt: string | null
  /** 履行もキャンセルも済んでいない予約の件数(あると退会できない) */
  blockingBookings: number
  canWithdraw: boolean
  /** 退会で消滅するコイン。**画面に出すことを規約第6条の2第3項で約束している** */
  expiringPaid: number
  expiringBonus: number
  /** 退会後も換金できる報酬コインと、その期限 */
  earnedBalance: number
  payoutDays: number
  payoutDeadline: string
  verified: boolean
  hasBankAccount: boolean
}

function toWithdrawalPreview(row: unknown): WithdrawalPreview {
  const r = (row ?? {}) as Record<string, unknown>
  const n = (v: unknown) => (typeof v === 'number' ? v : Number(v ?? 0))
  return {
    withdrawnAt: (r.withdrawn_at as string | null) ?? null,
    blockingBookings: n(r.blocking_bookings),
    canWithdraw: Boolean(r.can_withdraw),
    expiringPaid: n(r.expiring_paid),
    expiringBonus: n(r.expiring_bonus),
    earnedBalance: n(r.earned_balance),
    payoutDays: n(r.payout_days),
    payoutDeadline: String(r.payout_deadline ?? ''),
    verified: Boolean(r.verified),
    hasBankAccount: Boolean(r.has_bank_account),
  }
}

/** 退会の画面に出す材料。消えるコインの数と、換金できる期限。 */
export async function fetchWithdrawalPreview(): Promise<WithdrawalPreview> {
  const { data, error } = await requireSupabase().rpc('withdrawal_preview')
  if (error) throw error
  return toWithdrawalPreview(data)
}

/**
 * 退会する。有償・無償コインは消滅し、報酬コインは90日だけ残る。
 * **取り消せない。** 呼ぶ前に必ず確認を取ること。
 */
export async function withdrawAccount(reason: string | null): Promise<WithdrawalPreview> {
  const { data, error } = await requireSupabase().rpc('withdraw_account', {
    p_reason: reason,
  })
  if (error) throw error
  // 実行後の戻り値は退会の結果。画面はこれを見て完了を出す
  return toWithdrawalPreview(data)
}

/** アカウント削除・データダウンロードの請求を記録する(運営が手動で対応)。 */
export async function submitAccountRequest(type: AccountRequestType): Promise<void> {
  const sb = requireSupabase()
  const { data: auth } = await sb.auth.getUser()
  const me = auth.user?.id
  if (!me) throw new Error('ログインが必要です')
  const { error } = await sb.from('account_requests').insert({ user_id: me, type })
  if (error) throw error
}

/* ============================================================
 * エスクロー予約決済・自社銀行振込によるピタメイトへの報酬支払い。
 * schema: 0013_escrow_payouts + 0014_bank_payouts。
 * ・購入コイン(balance)と報酬コイン(earned_balance)は別会計。
 *   換金できるのはearned_balanceのみ(不正対策・詳細はマイグレーション参照)。
 * ・ピタメイトは口座を登録して換金申請 → 運営が総合振込で支払う。
 * ============================================================ */

export type BookingInfo = {
  id: string
  guestId: string
  hostId: string
  coins: number
  /**
   * 割引前の定価(0038)。延長は通常価格なので(0039)、延長費用の見積りは
   * 実支払額(coins)ではなくこちらを基準にすること。
   * coins で割ると、初回割引の効いた安い単価で見積もってしまう。
   */
  listCoins: number
  /** 延長を含む現在の合計プレイ時間(分)。延長費用の見積り表示に使う。 */
  durationMinutes: number
  /** 最初に予約した分に適用された初回お試し割引の割引率(%)。 */
  discountPercent: number
  status: string
  scheduledAt: string
}

/** 指定promise(約束)に紐づく予約情報を取得する(booking由来のpromiseでなければnull)。 */
export async function fetchBookingForPromise(promiseId: string): Promise<BookingInfo | null> {
  const sb = requireSupabase()
  const { data: promise, error } = await sb
    .from('promises')
    .select('booking_id')
    .eq('id', promiseId)
    .single()
  if (error) throw error
  if (!promise.booking_id) return null

  const { data: booking, error: bErr } = await sb
    .from('bookings')
    .select('id, guest_id, host_id, coins, list_coins, discount_percent, duration_minutes, status, scheduled_at')
    .eq('id', promise.booking_id)
    .single()
  if (bErr) throw bErr
  return {
    id: booking.id,
    guestId: booking.guest_id,
    hostId: booking.host_id,
    coins: booking.coins,
    // 0038より前に作られた予約は list_coins が無いので、実支払額で代用する
    listCoins: booking.list_coins ?? booking.coins,
    discountPercent: booking.discount_percent ?? 0,
    durationMinutes: booking.duration_minutes,
    status: booking.status,
    scheduledAt: booking.scheduled_at,
  }
}

/**
 * プレイ時間を延長する(ゲスト本人・進行中のみ)。
 * 追加で消費したコイン数を返す。金額はサーバ側が時給レートから決める。
 */
export async function extendBooking(bookingId: string, additionalMinutes: 30 | 60): Promise<number> {
  const { data, error } = await requireSupabase().rpc('extend_booking', {
    p_booking_id: bookingId,
    p_additional_minutes: additionalMinutes,
  })
  if (!error) return (data as number) ?? 0
  const msg = error.message
  if (/INSUFFICIENT_COINS/.test(msg)) throw new Error('コインが足りません')
  if (/BOOKING_NOT_EXTENDABLE/.test(msg)) throw new Error('進行中の予約のみ延長できます')
  if (/ONLY_GUEST_CAN_EXTEND/.test(msg)) throw new Error('予約したご本人のみ延長できます')
  throw error
}

/** 「プレイ完了」を確定する(ゲスト本人のみ)。ピタメイトの報酬コインに反映される。 */
export async function completeBooking(bookingId: string): Promise<void> {
  const { error } = await requireSupabase().rpc('complete_booking', { p_booking_id: bookingId })
  if (error) throw error
}

/**
 * 予約をキャンセルする(当事者のみ)。返還ルールはDB側(規約第9条):
 * ピタメイト都合=全額返還 / ゲスト都合1時間前まで=全額返還 / 直前=返還なし。
 */
export async function cancelBooking(bookingId: string, reason?: string): Promise<void> {
  const { error } = await requireSupabase().rpc('cancel_booking', {
    p_booking_id: bookingId,
    ...(reason ? { p_reason: reason } : {}),
  })
  if (error) {
    if (error.message.includes('BOOKING_NOT_CANCELLABLE')) {
      throw new Error('この予約はキャンセルできない状態です(すでに完了/キャンセル済み)')
    }
    throw new Error('キャンセルに失敗しました')
  }
}

/** 相手への評価(星+タグ)を送る。promiseごとに1回のみ。 */
export async function submitReview(
  promiseId: string,
  revieweeId: string,
  stars: number,
  tags: string[],
): Promise<void> {
  const sb = requireSupabase()
  const { data: auth } = await sb.auth.getUser()
  const me = auth.user?.id
  if (!me) throw new Error('ログインが必要です')
  const { error } = await sb.from('reviews').insert({
    promise_id: promiseId,
    reviewer_id: me,
    reviewee_id: revieweeId,
    stars: Math.min(5, Math.max(1, Math.round(stars))) as 1 | 2 | 3 | 4 | 5,
    tags,
  })
  if (error) {
    if (error.code === '23505') throw new Error('この約束はすでに評価済みです')
    throw new Error('評価の送信に失敗しました')
  }
}

/** このpromiseに対して自分がすでに評価済みかを返す。 */
export async function hasReviewedPromise(promiseId: string): Promise<boolean> {
  const sb = requireSupabase()
  const { data: auth } = await sb.auth.getUser()
  const me = auth.user?.id
  if (!me) throw new Error('ログインが必要です')
  const { data, error } = await sb
    .from('reviews')
    .select('id')
    .eq('promise_id', promiseId)
    .eq('reviewer_id', me)
    .maybeSingle()
  if (error) throw error
  return !!data
}

export type EarningsSummary = {
  /** 換金可能な報酬コイン残高。 */
  earnedBalance: number
  /** まだ「プレイ完了」されていない、確定済み予約に含まれるコイン(エスクロー中)。 */
  escrowedCoins: number
}

/** ピタメイトとしての収益サマリー(換金可能分・エスクロー中分)を取得する。 */
export async function fetchEarnings(): Promise<EarningsSummary> {
  const sb = requireSupabase()
  const { data: auth } = await sb.auth.getUser()
  const me = auth.user?.id
  if (!me) throw new Error('ログインが必要です')

  const [{ data: wallet, error: wErr }, { data: pending, error: pErr }] = await Promise.all([
    sb.from('coin_wallets').select('earned_balance').eq('user_id', me).single(),
    sb.from('bookings').select('coins').eq('host_id', me).eq('status', 'confirmed'),
  ])
  if (wErr) throw wErr
  if (pErr) throw pErr
  return {
    earnedBalance: wallet.earned_balance,
    escrowedCoins: (pending ?? []).reduce((sum, b) => sum + b.coins, 0),
  }
}

/** 換金の運用パラメータ。DB側(request_bank_payout)の定数と一致させること。 */
export const PAYOUT_FEE_COINS = 300
/** 最低換金額。0063で1,000→5,000に変更(サーバの request_bank_payout と揃えること)。 */
export const PAYOUT_MIN_COINS = 5000

export type BankAccount = {
  bankName: string
  bankCode: string
  branchName: string
  branchCode: string
  accountType: BankAccountType
  accountNumber: string
  accountHolderKana: string
}

/** 登録済みの振込先口座を取得する(未登録ならnull)。 */
export async function fetchBankAccount(): Promise<BankAccount | null> {
  const sb = requireSupabase()
  const { data: auth } = await sb.auth.getUser()
  const me = auth.user?.id
  if (!me) throw new Error('ログインが必要です')
  const { data, error } = await sb
    .from('host_bank_accounts')
    .select('bank_name, bank_code, branch_name, branch_code, account_type, account_number, account_holder_kana')
    .eq('user_id', me)
    .maybeSingle()
  if (error) throw error
  if (!data) return null
  return {
    bankName: data.bank_name,
    bankCode: data.bank_code,
    branchName: data.branch_name,
    branchCode: data.branch_code,
    accountType: data.account_type,
    accountNumber: data.account_number,
    accountHolderKana: data.account_holder_kana,
  }
}

/** ひらがな→カタカナ・小文字英字→大文字・全角英数→半角などの名義の正規化。 */
export function normalizeKanaName(input: string): string {
  return input
    .replace(/[ぁ-ん]/g, (ch) => String.fromCharCode(ch.charCodeAt(0) + 0x60))
    .replace(/[ａ-ｚＡ-Ｚ０-９]/g, (ch) => String.fromCharCode(ch.charCodeAt(0) - 0xfee0))
    .toUpperCase()
    .trim()
}

/** 振込先口座を登録/更新する。 */
export async function saveBankAccount(account: BankAccount): Promise<void> {
  const sb = requireSupabase()
  const { data: auth } = await sb.auth.getUser()
  const me = auth.user?.id
  if (!me) throw new Error('ログインが必要です')
  const { error } = await sb.from('host_bank_accounts').upsert({
    user_id: me,
    bank_name: account.bankName.trim(),
    bank_code: account.bankCode,
    branch_name: account.branchName.trim(),
    branch_code: account.branchCode,
    account_type: account.accountType,
    account_number: account.accountNumber,
    account_holder_kana: normalizeKanaName(account.accountHolderKana),
  })
  if (error) throw error
}

const PAYOUT_ERROR_MESSAGES: Record<string, string> = {
  MIN_PAYOUT_COINS: `換金は${PAYOUT_MIN_COINS.toLocaleString()}コインから申請できます`,
  NOT_VERIFIED: '換金には本人確認の完了が必要です',
  BANK_ACCOUNT_NOT_REGISTERED: '先にピタメイト設定から振込先口座を登録してください',
  INSUFFICIENT_EARNED_BALANCE: '換金可能な残高が足りません',
  GIFT_ON_HOLD: 'ギフトで付与された報酬コインは7日間は換金できません。保留が明けるまでお待ちください',
  // 0100(規約 第6条の2第4項・第6条の3第2項)。分割できると手数料を何度も取られる
  FINAL_PAYOUT_MUST_BE_WHOLE:
    '退会・利用停止の後は、いま換金できる全額を1回でお申し込みください（分けると換金事務手数料が毎回かかります）',
  BELOW_PAYOUT_FEE: '換金事務手数料（300コイン）を超える額でお申し込みください',
  // 0077。**理由を詳しく書かない。**チャージバックの存否は決済当事者と当社の間の
  // 情報で、報酬を受け取る側に相手方の決済事情を伝えるべきではない。
  // 「いつ明けるか」も申立ての決着次第なので約束できない。
  DISPUTE_ON_HOLD:
    'お支払いの確認中の予約が含まれているため、その分は一時的に換金をお預かりしています。確認が済み次第、換金できるようになります',
}

/** 換金できる額と保留の内訳(0077)。 */
export type PayoutHold = {
  earnedBalance: number
  /** 直近7日にギフトで付与された分(0069) */
  giftHold: number
  /** 係争中のチャージバックに紐づく予約の報酬(0077) */
  disputeHold: number
  /** いま申請できる額 */
  available: number
}

export async function fetchPayoutHold(): Promise<PayoutHold | null> {
  const { data, error } = await requireSupabase().rpc('my_payout_hold', {})
  if (error) throw error
  if (!data) return null
  const r = data as Record<string, unknown>
  return {
    earnedBalance: Number(r.earnedBalance ?? 0),
    giftHold: Number(r.giftHold ?? 0),
    disputeHold: Number(r.disputeHold ?? 0),
    available: Number(r.available ?? 0),
  }
}

/** 報酬コインの換金(銀行振込)を申請する。振込は運営がまとめて行う。 */
export async function requestPayout(coins: number): Promise<void> {
  const { error } = await requireSupabase().rpc('request_bank_payout', { p_coins: coins })
  if (error) {
    const known = Object.keys(PAYOUT_ERROR_MESSAGES).find((k) => error.message.includes(k))
    throw new Error(known ? PAYOUT_ERROR_MESSAGES[known] : '換金の申請に失敗しました')
  }
}

export type PayoutRecord = {
  id: string
  coins: number
  amountYen: number
  feeYen: number
  status: PayoutStatus
  createdAt: string
}

/** 換金履歴を新しい順に取得する。 */
export async function fetchPayoutHistory(): Promise<PayoutRecord[]> {
  const { data, error } = await requireSupabase()
    .from('payouts')
    .select('id, coins, amount_yen, fee_yen, status, created_at')
    .order('created_at', { ascending: false })
    .limit(30)
  if (error) throw error
  return (data ?? []).map((p) => ({
    id: p.id,
    coins: p.coins,
    amountYen: p.amount_yen,
    feeYen: p.fee_yen,
    status: p.status,
    createdAt: p.created_at,
  }))
}

export type PublicProfile = {
  userId: string
  nickname: string
  avatarInitial: string
  avatarColor: string
  isVerified: boolean
  mannerScore: number
  /** レビュー件数。3件未満はスコアを出さない(docs/trust-safety-spec.md §1.2)。 */
  reviewCount: number
  dotakyanRate: number
  confirmedCount: number
  isHost: boolean
  hourlyRate: number
  games: string[]
  bio: string
  voiceUrl: string | null
  voiceSeconds: number | null
  avatarUrl: string | null
  lastSeenAt: string | null
  presenceStatus: PresenceStatus
  latestReview: { stars: number; tags: string[]; reviewerName: string } | null
  /** ひとこと(0056)。14日を過ぎたものは null。 */
  statusText: string | null
  statusUpdatedAt: string | null
  /** 2回以上遊んだ人の数(0058)。 */
  repeatGuests: number
}

/** 他ユーザーの公開プロフィールを取得する(さがす/ホーム等から個別に表示)。 */
export async function fetchPublicProfile(userId: string): Promise<PublicProfile | null> {
  const sb = requireSupabase()
  const [profileRes, trustRes, hostRes, reviewRes, repeatRes] = await Promise.all([
    sb.from('profiles').select('nickname, avatar_initial, avatar_color, voice_path, voice_seconds, avatar_path, last_seen_at, presence_status').eq('id', userId).single(),
    sb
      .from('profile_trust_stats')
      .select('manner_score, review_count, dotakyan_count, confirmed_count, is_verified')
      .eq('user_id', userId)
      .single(),
    sb.from('host_settings').select('is_host, hourly_rate, games, bio, trial_discount_percent, status_text, status_updated_at').eq('user_id', userId).single(),
    sb
      .from('reviews')
      .select('stars, tags, reviewer_id')
      .eq('reviewee_id', userId)
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle(),
    sb.rpc('host_repeat_guests', { p_host_id: userId }),
  ])
  if (profileRes.error) throw profileRes.error
  if (!profileRes.data) return null
  const trust = trustRes.data
  const host = hostRes.data
  const confirmed = trust?.confirmed_count ?? 0
  const dotakyan = trust?.dotakyan_count ?? 0
  const denom = confirmed + dotakyan

  let latestReview: PublicProfile['latestReview'] = null
  if (reviewRes.data) {
    let reviewerName = 'フレンド'
    const { data: reviewer } = await sb
      .from('profiles')
      .select('nickname')
      .eq('id', reviewRes.data.reviewer_id)
      .maybeSingle()
    if (reviewer?.nickname) reviewerName = reviewer.nickname
    latestReview = { stars: reviewRes.data.stars, tags: reviewRes.data.tags, reviewerName }
  }

  return {
    userId,
    nickname: profileRes.data.nickname || '(名前未設定)',
    avatarInitial: profileRes.data.avatar_initial || profileRes.data.nickname?.charAt(0) || '?',
    avatarColor: profileRes.data.avatar_color || '#B3E5F2',
    isVerified: trust?.is_verified ?? false,
    mannerScore: trust?.manner_score ?? 4.5,
    reviewCount: trust?.review_count ?? 0,
    dotakyanRate: denom > 0 ? Math.round((dotakyan / denom) * 100) : 0,
    confirmedCount: confirmed,
    isHost: host?.is_host ?? false,
    hourlyRate: host?.hourly_rate ?? 0,
    games: host?.games ?? [],
    bio: host?.bio ?? '',
    avatarUrl: profileRes.data.avatar_path ? avatarImageUrl(profileRes.data.avatar_path) : null,
    voiceUrl: profileRes.data.voice_path ? voiceGreetingUrl(profileRes.data.voice_path) : null,
    voiceSeconds: profileRes.data.voice_seconds ?? null,
    lastSeenAt: profileRes.data.last_seen_at ?? null,
    presenceStatus: profileRes.data.presence_status ?? 'online',
    ...freshStatus(host?.status_text ?? null, host?.status_updated_at ?? null),
    repeatGuests: repeatRes.data ?? 0,
    latestReview,
  }
}

const VOICE_BUCKET = 'voice-greetings'

/** 音声挨拶パスから公開URLを作る。 */
export function voiceGreetingUrl(path: string): string {
  return requireSupabase().storage.from(VOICE_BUCKET).getPublicUrl(path).data.publicUrl
}

export type OwnVoice = { url: string; seconds: number } | null

/** 自分の音声挨拶を取得する(マイページの管理用)。 */
export async function fetchOwnVoiceGreeting(): Promise<OwnVoice> {
  const sb = requireSupabase()
  const { data: auth } = await sb.auth.getUser()
  const me = auth.user?.id
  if (!me) return null
  const { data, error } = await sb.from('profiles').select('voice_path, voice_seconds').eq('id', me).single()
  if (error || !data?.voice_path) return null
  return { url: voiceGreetingUrl(data.voice_path), seconds: data.voice_seconds ?? 0 }
}

/**
 * 録音した音声挨拶をアップロードして公開する(B方式=即公開)。戻り値は公開URL。
 *
 * 保存は Edge Function(voice-upload)経由で行う。アイコン画像と同じく、
 * ブラウザから storage.upload() を直接呼ぶと RLS で拒否されるため。
 * 保存先パスはサーバ側で {uid}/greeting.webm を組み立てるので、
 * 他人のフォルダには書き込めない。
 */
export async function uploadVoiceGreeting(blob: Blob, seconds: number): Promise<string> {
  const sb = requireSupabase()
  const form = new FormData()
  form.append('file', new File([blob], 'greeting.webm', { type: blob.type || 'audio/webm' }))
  form.append('seconds', String(Math.max(1, Math.min(15, Math.round(seconds)))))
  const { data, error } = await sb.functions.invoke<{ ok: boolean; url: string }>(
    'voice-upload',
    { body: form },
  )
  if (error) throw error
  if (!data?.url) throw new Error('アップロードに失敗しました')
  return data.url
}

/** 自分の音声挨拶を削除する。 */
export async function deleteVoiceGreeting(): Promise<void> {
  const { error } = await requireSupabase().functions.invoke('voice-delete')
  if (error) throw error
}

/** 管理者が音声挨拶を削除する(通報対応)。 */
export async function adminClearVoiceGreeting(userId: string): Promise<void> {
  const { error } = await requireSupabase().rpc('admin_clear_voice_greeting', { p_user_id: userId })
  if (error) throw error
}

/* ============================================================
 * プロフィールのアイコン画像(アバター)。schema: 0025_avatar_image。
 * avatar_path が null なら頭文字＋カラーの既定アバターで表示する。
 * ============================================================ */

const AVATAR_BUCKET = 'avatars'

/** アイコン画像パスから公開URLを作る。 */
export function avatarImageUrl(path: string): string {
  return requireSupabase().storage.from(AVATAR_BUCKET).getPublicUrl(path).data.publicUrl
}

/**
 * 選んだ画像をアップロードして自分のアイコンに設定する(B方式=即公開)。
 * 戻り値は公開URL(キャッシュ回避のため更新時刻付き)。
 *
 * 保存は Edge Function(avatar-upload)経由で行う。ブラウザから
 * storage.upload() を直接呼ぶと、ポリシー・バケット設定・JWTが全て
 * 正しいにもかかわらず avatars バケットの RLS で必ず拒否されたため。
 * 保存先パスはサーバ側で {uid}/avatar.webp を組み立てるので、
 * 他人のフォルダには書き込めない。
 */
export async function uploadAvatar(blob: Blob): Promise<string> {
  const sb = requireSupabase()
  const form = new FormData()
  form.append('file', new File([blob], 'avatar.webp', { type: blob.type || 'image/webp' }))
  const { data, error } = await sb.functions.invoke<{ ok: boolean; url: string }>(
    'avatar-upload',
    { body: form },
  )
  if (error) throw error
  if (!data?.url) throw new Error('アップロードに失敗しました')
  return data.url
}

/** 自分のアイコン画像を削除して既定アバターに戻す。 */
export async function deleteAvatar(): Promise<void> {
  const { error } = await requireSupabase().functions.invoke('avatar-delete')
  if (error) throw error
}

/** 管理者がアイコン画像を削除する(通報対応)。 */
export async function adminClearAvatar(userId: string): Promise<void> {
  const { error } = await requireSupabase().rpc('admin_clear_avatar', { p_user_id: userId })
  if (error) throw error
}

/* ============================================================
 * オンラインステータス。schema: 0026_presence_status。
 * Realtime Presence(いま開いている人)を補い、last_seen_at で
 * 「5分前」「1時間前」といった直近の在席も出せるようにする。
 * オンライン状態を非公開にしている人は last_seen_at が null のまま。
 * ============================================================ */

/** 自分の在席を記録する。非公開設定ならサーバー側で無視される。 */
export async function touchPresence(): Promise<void> {
  const { error } = await requireSupabase().rpc('touch_presence')
  if (error) throw error
}

/**
 * 「みまもり」一次検知のヒットを記録する(docs/trust-safety-spec.md §4.2)。
 * 送信はブロックしないため、記録の失敗もユーザー操作を止めない。
 * 本文は送らず、一致した断片のみを渡す。
 */
export async function recordContentFlag(
  category: 'contact' | 'money' | 'dating',
  surface: 'message' | 'board' | 'profile',
  matched: string,
  proceeded: boolean,
): Promise<void> {
  if (!isBackendConfigured) return
  const { error } = await requireSupabase().rpc('record_content_flag', {
    p_category: category,
    p_surface: surface,
    p_matched: matched,
    p_proceeded: proceeded,
  })
  if (error) console.warn('[pita-friends] みまもり記録に失敗:', error.message)
}

/**
 * みまもりへの同意を記録する(同意日時と同意した文言のバージョン)。
 *
 * 記録に失敗しても登録の導線は止めない。同意そのものは画面のチェックで
 * 取得できており、ここで例外を投げると本人確認へ進めなくなるため。
 * (マイグレーション0031が未適用の環境でも登録が通るようにする意図もある)
 */
export async function recordMonitoringConsent(version: string): Promise<void> {
  if (!isBackendConfigured) return
  const { error } = await requireSupabase().rpc('record_monitoring_consent', {
    p_version: version,
  })
  if (error) console.warn('[pita-friends] みまもり同意の記録に失敗:', error.message)
}

/** みまもりへの同意を撤回する。 */
export async function revokeMonitoringConsent(): Promise<void> {
  const { error } = await requireSupabase().rpc('revoke_monitoring_consent', {})
  if (error) throw error
}

/** みまもり同意の現状(設定画面の表示用)。0074 の my_monitoring_consent。 */
export type MonitoringConsentState = {
  /** 有効な同意があるか。false のときメッセージ等が止まっている */
  active: boolean
  /** 記録が1件も無い(0031より前の登録・記録の失敗)。撤回とは区別する */
  unrecorded: boolean
  version: string | null
  agreedAt: Date | null
  revokedAt: Date | null
}

export async function fetchMonitoringConsent(): Promise<MonitoringConsentState | null> {
  const { data, error } = await requireSupabase().rpc('my_monitoring_consent', {})
  if (error) throw error
  if (!data) return null
  const r = data as {
    active?: boolean
    unrecorded?: boolean
    version?: string | null
    agreedAt?: string | null
    revokedAt?: string | null
  }
  return {
    active: r.active !== false,
    unrecorded: r.unrecorded === true,
    version: r.version ?? null,
    agreedAt: r.agreedAt ? new Date(r.agreedAt) : null,
    revokedAt: r.revokedAt ? new Date(r.revokedAt) : null,
  }
}

/**
 * みまもり同意の撤回でDB側が止めた操作を、利用者向けの文言に言い換える。
 * 該当しなければ null を返す。
 *
 * 撤回の帰結は規約 第4条6項(弁護士回答 Q16 の文言)。相手側の撤回でも止まるのは
 * 「メッセージは双方の通信」だから(Q19) だが、**誰が撤回したかは相手に明かさない**
 * — 撤回は同意の状態であって、他人に開示すべき情報ではない。
 */
export function monitoringConsentBlockMessage(message: string): string | null {
  if (/COINS_FROZEN_DISPUTE/.test(message)) {
    // **凍結の理由や回避方法は書かない。** 書くと、申立てを取り下げれば
    // 使えると分かってしまう。問い合わせ窓口に誘導するにとどめる。
    return 'お支払いの確認中のため、コインのご利用を一時的にお預かりしています。お手数ですが、お問い合わせ窓口までご連絡ください。'
  }
  if (/PARTNER_MONITORING_CONSENT_REVOKED/.test(message)) {
    return 'お相手が「みまもり」への同意を撤回しているため、やりとりの機能をご利用いただけません。'
  }
  if (/MONITORING_CONSENT_REVOKED/.test(message)) {
    return '「みまもり」への同意を撤回されているため、メッセージなどのやりとりの機能は停止しています。設定＞みまもりへの同意から再度同意すると、ご利用いただけます。'
  }
  return null
}

/** DBのエラーを、みまもり撤回なら言い換えてから投げ直す。 */
function throwMapped(error: { message: string }): never {
  const m = monitoringConsentBlockMessage(error.message)
  throw m ? new Error(m) : error
}

/** 自分の状態(今すぐ遊べる/オンライン/取り込み中)を設定する。 */
export async function setPresenceStatus(status: PresenceStatus): Promise<void> {
  const { error } = await requireSupabase().rpc('set_presence_status', { p_status: status })
  if (error) throw error
}

/**
 * ピタメイト予約をリクエストし、コインをアトミックに確保する(create_booking RPC)。
 * この時点では予約は「承諾待ち(requested)」で、約束(トーク)はまだ成立しない。
 * ピタメイトが承諾して初めてトークが開く。戻り値は booking_id。
 */
/**
 * 同じ時刻を毎週くり返して2〜4回まとめて予約する(0061)。
 *
 * 新しいお金の仕組みではなく、create_booking を回数分呼ぶだけ。料金・割引・
 * キャンセル規定は1件ずつ従来どおり効く。**どこかで失敗すれば1件も作られない**
 * ので、途中まで作られて頼んでいない組み合わせに払う、ということが起きない。
 */
export async function createBookingSeriesRemote(
  hostId: string,
  durationMinutes: number,
  policyVersion: string,
  firstStart: Date,
  count: number,
): Promise<string[]> {
  const { data, error } = await requireSupabase().rpc('create_booking_series', {
    p_host_id: hostId,
    p_duration_minutes: durationMinutes,
    p_policy_version: policyVersion,
    p_first_start: firstStart.toISOString(),
    p_count: count,
  })
  if (error) throwMapped(error)
  return data ?? []
}

export async function createBookingRemote(
  hostId: string,
  /** 30分刻み(30〜240)。上限はサーバの platform_pricing.max_duration_minutes。 */
  durationMinutes: number,
  policyVersion: string,
  /** 希望開始時刻。null なら「今すぐ」(承諾時点が開始時刻)。 */
  scheduledAt: Date | null = null,
): Promise<string> {
  const { data, error } = await requireSupabase().rpc('create_booking', {
    p_host_id: hostId,
    p_duration_minutes: durationMinutes,
    p_policy_version: policyVersion,
    p_scheduled_at: scheduledAt ? scheduledAt.toISOString() : null,
  })
  if (error) throwMapped(error)
  return data as string
}

/**
 * 空き状況の1マス(1時間)。0051。
 * regulars は「常連への先行予約の期間中」(0057)。
 * **ScheduleGrid の SlotState と同じ並びに保つこと。**
 */
export type ScheduleSlot = {
  slotAt: Date
  state: 'past' | 'closed' | 'booked' | 'regulars' | 'open'
}

/**
 * ピタメイトの空き状況を1時間ごとに取得する(誰でも見られる)。
 * 予約の中身(相手が誰か等)は返ってこない。
 */
export async function fetchHostSchedule(hostUserId: string, days = 7): Promise<ScheduleSlot[]> {
  const { data, error } = await requireSupabase().rpc('host_schedule', {
    p_host_id: hostUserId,
    p_days: days,
  })
  if (error) throw error
  return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
    slotAt: new Date(String(r.slot_at)),
    state: (r.state as ScheduleSlot['state']) ?? 'closed',
  }))
}

/** 募集枠(曜日0=日〜6=土 × 時0〜23)。日本時間で解釈される。 */
export type AvailabilitySlot = { weekday: number; hour: number }

export async function fetchMyAvailability(): Promise<AvailabilitySlot[]> {
  const sb = requireSupabase()
  const { data: auth } = await sb.auth.getUser()
  const uid = auth.user?.id
  if (!uid) return []
  const { data, error } = await sb
    .from('host_availability')
    .select('weekday, hour')
    .eq('user_id', uid)
  if (error) throw error
  return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
    weekday: Number(r.weekday),
    hour: Number(r.hour),
  }))
}

/** 自分の募集枠をまとめて置き換える。 */
export async function saveMyAvailability(slots: AvailabilitySlot[]): Promise<number> {
  const { data, error } = await requireSupabase().rpc('set_host_availability', {
    p_slots: slots,
  })
  if (error) throw error
  return Number(data ?? 0)
}

/** プレイ開始の申告(チェックイン)の状況。無断欠席の自動処理(0050)で使う。 */
export type CheckinState = {
  /** 開始時刻を過ぎているか */
  started: boolean
  iAmGuest: boolean
  myCheckedIn: boolean
  partnerCheckedIn: boolean
  /** 相手の不参加でコインの確定が止まっている状態か */
  heldForNoShow: boolean
  graceMinutes: number
}

export async function fetchCheckinState(bookingId: string): Promise<CheckinState> {
  const { data, error } = await requireSupabase().rpc('my_booking_checkin_state', {
    p_booking_id: bookingId,
  })
  if (error) throw error
  const q = (data ?? {}) as Record<string, unknown>
  return {
    started: Boolean(q.started),
    iAmGuest: Boolean(q.i_am_guest),
    myCheckedIn: Boolean(q.my_checked_in),
    partnerCheckedIn: Boolean(q.partner_checked_in),
    heldForNoShow: Boolean(q.held_for_no_show),
    graceMinutes: Number(q.grace_minutes ?? 15),
  }
}

/**
 * 「はじめました」。押しても何も確定しない(お金は動かない)。
 * ゲストが押したうえで相手が現れなければ、開始+猶予でサーバが自動的に
 * コインの確定を止める。ピタメイトが押せば止まっていたものが自動で解ける。
 */
export async function checkInBooking(bookingId: string): Promise<void> {
  const { error } = await requireSupabase().rpc('check_in_booking', {
    p_booking_id: bookingId,
  })
  if (error) throw error
}

/** 予約で埋まっている時間帯。予約画面で選べない時刻を灰色にするために使う。 */
export type BusySlot = { startsAt: Date; endsAt: Date; who: 'host' | 'me' }

/**
 * そのピタメイトと自分の、埋まっている時間帯を取得する(0049)。
 * どちらも新しい予約を弾く要因なので、まとめて扱う。
 * 相手が誰か・何コインかは返ってこない。
 */
export async function fetchBusySlots(hostUserId: string, days = 14): Promise<BusySlot[]> {
  const { data, error } = await requireSupabase().rpc('booking_busy_slots', {
    p_host_id: hostUserId,
    p_days: days,
  })
  if (error) throw error
  return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
    startsAt: new Date(String(r.starts_at)),
    endsAt: new Date(String(r.ends_at)),
    who: r.who === 'me' ? 'me' : 'host',
  }))
}

/** いまキャンセルしたときの見積り。金額はサーバで確定させる。 */
export type RefundQuote = {
  /** 予約に消費されているコイン(延長分を含む) */
  coins: number
  /** 実際に戻るコイン */
  refundCoins: number
  /** ピタメイトの報酬として確定するコイン */
  forfeitCoins: number
  /** 段階制の返還率(%)。表示の補足用 */
  basePercent: number
  /** 没収の上限(0048)が効いて、率から期待されるより多く戻る状態か */
  capped: boolean
  /**
   * 両方がチェックイン済み = **実際に遊んだあと**か(0102)。
   * このときキャンセルは完了と同じ扱いになり、ドタキャン記録がつかない。
   * **画面で作り直さないこと**(判定はサーバの1か所にある)。
   */
  played: boolean
  /**
   * 戻るはずだが**当初の期限を過ぎていて戻らない**枚数(0109)。
   *
   * 規約 第9条5の2: 返還されるコインの期限は**当初の取得日**を基準に計算する。
   * したがって期限を過ぎていれば返還されずに消える。**押す前に知らせる**。
   */
  lapsedCoins: number
  /** 戻るが、期限が `soonDays` 日以内に来る枚数 */
  soonCoins: number
  /** 戻る分のうち最も早い期限(ISO)。無ければ null */
  soonestExpiresAt: string | null
  /** 「期限が近い」の目安の日数(失効の事前通知と同じ値) */
  soonDays: number
  /**
   * 消えた分のうち**金銭で返す**枚数(1コイン=1円)。
   * 第9条5の3 は**ゲスト無帰責の場合のみ**なので、
   * ゲストが自分でキャンセルするときは0になる。
   */
  cashRefundCoins: number
}

/**
 * いまキャンセルしたら実際に何コイン戻るかを取得する。
 *
 * 0048 で没収額に上限(平均的な損害の頭打ち)を入れたため、
 * 「率 × コイン数」では実額が出せなくなった。**画面で掛け算をしないこと**。
 * 判定も計算もサーバ(booking_refund_coins)の1か所に集約してある。
 */
export async function fetchMyRefundQuote(bookingId: string): Promise<RefundQuote> {
  const { data, error } = await requireSupabase().rpc('my_booking_refund_quote', {
    p_booking_id: bookingId,
  })
  if (error) throw error
  const q = (data ?? {}) as Record<string, unknown>
  return {
    coins: Number(q.coins ?? 0),
    refundCoins: Number(q.refund_coins ?? 0),
    forfeitCoins: Number(q.forfeit_coins ?? 0),
    basePercent: Number(q.base_percent ?? 0),
    capped: Boolean(q.capped),
    played: Boolean(q.played),
    lapsedCoins: Number(q.lapsed_coins ?? 0),
    soonCoins: Number(q.soon_coins ?? 0),
    soonestExpiresAt: (q.soonest_expires_at as string | null) ?? null,
    soonDays: Number(q.soon_days ?? 14),
    cashRefundCoins: Number(q.cash_refund_coins ?? 0),
  }
}

/** 保有コイン(有償+ボーナス)のうち最も近い有効期限を返す(なければnull)。 */
export async function fetchSoonestCoinExpiry(): Promise<string | null> {
  const sb = requireSupabase()
  const { data: auth } = await sb.auth.getUser()
  const me = auth.user?.id
  if (!me) return null
  const { data, error } = await sb
    .from('coin_lots')
    .select('expires_at')
    .eq('user_id', me)
    .gt('remaining', 0)
    .order('expires_at', { ascending: true })
    .limit(1)
    .maybeSingle()
  if (error) throw error
  return data?.expires_at ?? null
}

export type IncomingBookingRequest = {
  bookingId: string
  guestId: string
  name: string
  initial: string
  color: string
  verified: boolean
  manner: string
  dotakyan: string
  plays: number
  coins: number
  durationMinutes: number
}

/** 自分(ピタメイト)宛の承諾待ち予約リクエストを、申込者の信頼情報つきで取得する。 */
export async function fetchIncomingBookingRequests(): Promise<IncomingBookingRequest[]> {
  const sb = requireSupabase()
  const { data: auth } = await sb.auth.getUser()
  const me = auth.user?.id
  if (!me) throw new Error('ログインが必要です')

  const { data: bookings, error } = await sb
    .from('bookings')
    .select('id, guest_id, coins, duration_minutes, created_at')
    .eq('host_id', me)
    .eq('status', 'requested')
    .order('created_at', { ascending: false })
  if (error) throw error
  if (!bookings || bookings.length === 0) return []

  const guestIds = bookings.map((b) => b.guest_id)
  const [{ data: profiles }, { data: stats }] = await Promise.all([
    sb.from('profiles').select('id, nickname, avatar_initial, avatar_color').in('id', guestIds),
    sb
      .from('profile_trust_stats')
      .select('user_id, manner_score, dotakyan_count, confirmed_count, is_verified')
      .in('user_id', guestIds),
  ])
  const pMap = new Map((profiles ?? []).map((p) => [p.id, p]))
  const sMap = new Map((stats ?? []).map((s) => [s.user_id, s]))

  return bookings.map((b) => {
    const p = pMap.get(b.guest_id)
    const s = sMap.get(b.guest_id)
    const confirmed = s?.confirmed_count ?? 0
    const dotakyan = s?.dotakyan_count ?? 0
    const denom = confirmed + dotakyan
    return {
      bookingId: b.id,
      guestId: b.guest_id,
      name: p?.nickname || '(名前未設定)',
      initial: p?.avatar_initial || p?.nickname?.charAt(0) || '?',
      color: p?.avatar_color || '#B3E5F2',
      verified: s?.is_verified ?? false,
      manner: `★${(s?.manner_score ?? 4.5).toFixed(1)}`,
      dotakyan: `${denom > 0 ? Math.round((dotakyan / denom) * 100) : 0}%`,
      plays: confirmed,
      coins: b.coins,
      durationMinutes: b.duration_minutes,
    }
  })
}

/** 予約リクエストを承諾する(約束=トークが成立)。promise_idを返す。 */
export async function approveBooking(bookingId: string): Promise<string> {
  const { data, error } = await requireSupabase().rpc('approve_booking', { p_booking_id: bookingId })
  if (error) throw error
  return data as string
}

/** 予約リクエストを辞退する(コインは申込者へ全額返却)。 */
export async function declineBooking(bookingId: string): Promise<void> {
  const { error } = await requireSupabase().rpc('decline_booking', { p_booking_id: bookingId })
  if (error) throw error
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
/**
 * 居住地の自己申告(規約 第3条3項・突合表G4)。
 *
 * 弁護士の整理では**自己申告で足り、実質的な審査は求められない**。
 * ただし E-4(みまもり同意)と同じ失敗を繰り返さないよう、
 * **申告を求めた事実と回答を記録する**。画面のチェックだけでは、
 * 「利用条件として提示した」ことの証跡が残らない。
 *
 * ⚠️ 国籍は尋ねない。条文どおり居住地だけを扱う。
 */
export const RESIDENCY_VERSION = 'v1'

export async function declareResidency(declaredJapan: boolean): Promise<void> {
  const { error } = await requireSupabase().rpc('declare_residency', {
    p_declared_japan: declaredJapan,
    p_version: RESIDENCY_VERSION,
  })
  if (error) throw error
}

export type ResidencyDeclaration = {
  declaredJapan: boolean | null
  version: string | null
  declaredAt: string | null
}

export async function fetchMyResidencyDeclaration(): Promise<ResidencyDeclaration> {
  const { data, error } = await requireSupabase().rpc('my_residency_declaration')
  if (error) throw error
  const d = (data ?? {}) as Partial<ResidencyDeclaration>
  return {
    declaredJapan: d.declaredJapan ?? null,
    version: d.version ?? null,
    declaredAt: d.declaredAt ?? null,
  }
}

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
  if (!error) return
  // 0081 のトリガ。画面側でチェックを必須にしているので通常は出ないが、
  // 未申告と「いいえ」で文言を変える(前者は操作の案内、後者は利用条件の説明)
  if (/RESIDENCY_NOT_DECLARED/.test(error.message)) {
    throw new Error('お住まいの確認にチェックを入れてください')
  }
  if (/RESIDENCY_OUTSIDE_JAPAN/.test(error.message)) {
    throw new Error('ピタフレは日本国内にお住まいの方に限りご利用いただけます')
  }
  throw error
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

// ============================================================
// ピタメイト向けダッシュボード
// ============================================================

/** ダッシュボードの集計結果(host_dashboard RPCの返り値)。 */
export type HostDashboard = {
  monthStart: string
  ticketCoins: number
  giftCoins: number
  grossCoins: number
  feeCoins: number
  netCoins: number
  effectiveRate: number
  tier: {
    currentRate: number
    nextBound: number | null
    nextRate: number | null
    remainingCoins: number | null
  }
  daily: { day: number; coins: number }[]
  repeat: {
    repeatCoins: number
    totalCoins: number
    repeatRate: number
    repeaterGuests: number
    newGuests: number
  }
  response: {
    requests: number
    approved: number
    approvalRate: number
    medianReplySeconds: number | null
  }
  heatmap: { dow: number; hour: number; count: number }[]
}

/** ピタメイト向けダッシュボードの集計を取得する。 */
export async function fetchHostDashboard(): Promise<HostDashboard> {
  const { data, error } = await requireSupabase().rpc('host_dashboard', {})
  if (error) throw error
  const d = (data ?? {}) as Record<string, any>
  return {
    monthStart: d.month_start ?? '',
    ticketCoins: d.ticket_coins ?? 0,
    giftCoins: d.gift_coins ?? 0,
    grossCoins: d.gross_coins ?? 0,
    feeCoins: d.fee_coins ?? 0,
    netCoins: d.net_coins ?? 0,
    effectiveRate: Number(d.effective_rate ?? 0),
    tier: {
      currentRate: Number(d.tier?.current_rate ?? 0),
      nextBound: d.tier?.next_bound ?? null,
      nextRate: d.tier?.next_rate == null ? null : Number(d.tier.next_rate),
      remainingCoins: d.tier?.remaining_coins ?? null,
    },
    daily: Array.isArray(d.daily) ? d.daily.map((x: any) => ({ day: x.day, coins: x.coins })) : [],
    repeat: {
      repeatCoins: d.repeat?.repeat_coins ?? 0,
      totalCoins: d.repeat?.total_coins ?? 0,
      repeatRate: Number(d.repeat?.repeat_rate ?? 0),
      repeaterGuests: d.repeat?.repeater_guests ?? 0,
      newGuests: d.repeat?.new_guests ?? 0,
    },
    response: {
      requests: d.response?.requests ?? 0,
      approved: d.response?.approved ?? 0,
      approvalRate: Number(d.response?.approval_rate ?? 0),
      medianReplySeconds:
        d.response?.median_reply_seconds == null ? null : Number(d.response.median_reply_seconds),
    },
    heatmap: Array.isArray(d.heatmap)
      ? d.heatmap.map((x: any) => ({ dow: x.dow, hour: x.hour, count: x.count }))
      : [],
  }
}

// ============================================================
// 運営コンソール(0066)
// ------------------------------------------------------------
// **すべて管理者判定つきのRPC経由。** RLSは利用者本人に絞られているので、
// 運営でも通報や換金申請を直接 select できない。判定はDB側に置いてあり、
// 画面を隠すだけの制御にはしていない(隠しても叩けたら意味がない)。
// ============================================================

/** ダッシュボードの件数。キーは日本語のままDBから来る(画面にそのまま並べる)。 */
export type AdminSummary = Record<string, number | null>

export async function fetchAdminSummary(): Promise<AdminSummary> {
  const { data, error } = await requireSupabase().rpc('admin_console_summary')
  if (error) throw error
  return (data ?? {}) as AdminSummary
}

export type AdminReport = {
  id: string
  reporterName: string
  reportedId: string
  reportedName: string
  category: string
  severity: string
  messageSnapshot: unknown
  status: string
  resolution: string | null
  createdAt: string
  reportedManner: number | null
  reportedReportCount: number
}

export async function fetchAdminReports(status = 'open'): Promise<AdminReport[]> {
  const { data, error } = await requireSupabase().rpc('admin_reports', {
    p_status: status,
    p_limit: 100,
  })
  if (error) throw error
  return (data ?? []).map((r) => ({
    id: r.id,
    reporterName: r.reporter_name,
    reportedId: r.reported_id,
    reportedName: r.reported_name,
    category: r.category,
    severity: r.severity,
    messageSnapshot: r.message_snapshot,
    status: r.status,
    resolution: r.resolution,
    createdAt: r.created_at,
    reportedManner: r.reported_manner,
    reportedReportCount: r.reported_report_count,
  }))
}

/** 通報の処分。理由は必須(理由の無い処分を記録に残さないため)。 */
export async function resolveReportAsAdmin(
  reportId: string,
  resolution: string,
  status: 'resolved' | 'dismissed',
  penaltyPoints: number | null,
): Promise<void> {
  const { error } = await requireSupabase().rpc('admin_resolve_report', {
    p_report_id: reportId,
    p_resolution: resolution,
    p_status: status,
    p_penalty_points: penaltyPoints,
  })
  if (error) throw error
}

/* ------------------------------------------------------------
 * 募集投稿のモデレーション(0112・突合表G21)
 *
 * それまで運営に消す手段が無かった。`cancelBoardPost` は投稿者専用で、
 * 通報は**人**に対するものなので投稿を指せない。
 * ------------------------------------------------------------ */

export type AdminBoardPost = {
  id: string
  creatorId: string
  creatorNickname: string | null
  game: string
  mood: string
  whenText: string
  capacity: number
  vc: string
  audience: string
  verifiedOnly: boolean
  note: string | null
  status: string
  participants: number
  createdAt: string
  cancelledAt: string | null
  cancelReason: string | null
}

/** `status` に 'all' を渡すと取り下げ済みも含む。 */
export async function fetchAdminBoardPosts(status = 'open'): Promise<AdminBoardPost[]> {
  const { data, error } = await requireSupabase().rpc('admin_board_posts', {
    p_status: status,
    p_limit: 100,
  })
  if (error) throw error
  return (data ?? []).map((r) => ({
    id: r.id,
    creatorId: r.creator_id,
    creatorNickname: r.creator_nickname,
    game: r.game,
    mood: r.mood,
    whenText: r.when_text,
    capacity: r.capacity,
    vc: r.vc,
    audience: r.audience,
    verifiedOnly: r.verified_only,
    note: r.note,
    status: r.status,
    participants: r.participants,
    createdAt: r.created_at,
    cancelledAt: r.cancelled_at,
    cancelReason: r.cancel_reason,
  }))
}

/** 運営が募集を取り下げる。**理由は必須**(サーバ側でも REASON_REQUIRED で弾く)。 */
export async function removeBoardPostAsAdmin(postId: string, reason: string): Promise<void> {
  const { error } = await requireSupabase().rpc('admin_remove_board_post', {
    p_post_id: postId,
    p_reason: reason,
  })
  if (error) throw error
}

export type AdminHeldBooking = {
  id: string
  guestName: string
  hostName: string
  coins: number
  paidCoins: number
  durationMinutes: number
  scheduledAt: string
  heldAt: string
  heldDays: number
  holdReason: string | null
  reportCount: number
}

export async function fetchAdminHeldBookings(): Promise<AdminHeldBooking[]> {
  const { data, error } = await requireSupabase().rpc('admin_held_bookings', { p_limit: 100 })
  if (error) throw error
  return (data ?? []).map((b) => ({
    id: b.id,
    guestName: b.guest_name,
    hostName: b.host_name,
    coins: b.coins,
    paidCoins: b.paid_coins,
    durationMinutes: b.duration_minutes,
    scheduledAt: b.scheduled_at,
    heldAt: b.held_at,
    heldDays: b.held_days,
    holdReason: b.hold_reason,
    reportCount: b.report_count,
  }))
}

/** 申し出を退けて確定する(ピタメイトに全額)。 */
export async function releaseHoldComplete(bookingId: string, note: string): Promise<void> {
  const { error } = await requireSupabase().rpc('admin_release_hold_complete', {
    p_booking_id: bookingId,
    p_note: note,
  })
  if (error) throw error
}

/** 申し出を認めて指定の割合を返還する。0%なら全額返還。 */
export async function releaseHoldRefund(
  bookingId: string,
  percent: number,
  note: string,
): Promise<void> {
  const { error } = await requireSupabase().rpc('admin_release_hold_refund', {
    p_booking_id: bookingId,
    p_refund_percent: percent,
    p_note: note,
  })
  if (error) throw error
}

export type AdminPayout = {
  id: string
  nickname: string
  coins: number
  amountYen: number
  feeYen: number
  createdAt: string
  bankName: string
  bankCode: string
  branchName: string
  branchCode: string
  accountType: string
  accountNumber: string
  accountHolderKana: string
  isVerified: boolean
  /** このピタメイトと決済カードを共有している**他の**アカウントの数(0080・E-9) */
  sharedCardCount: number
  /** 受け取ったギフトのうち、IPまたはカードの共有で印が付いた件数 */
  flaggedGiftCount: number
  /**
   * カードのフィンガープリントで判定できない購入(PayPay等)の件数(0096)。
   * **`sharedCardCount` が 0 でも安心材料にならない**ことを示すために使う。
   * 「調べた結果シロ」と「調べようがなかった」は別の事実。
   */
  nonCardPurchaseCount: number
}

/**
 * 未処理の換金申請。**口座情報を含む。**
 * この呼び出しは admin_actions に記録される(誰がいつ口座を見たか)。
 */
export async function fetchAdminPendingPayouts(): Promise<AdminPayout[]> {
  const { data, error } = await requireSupabase().rpc('admin_pending_payouts', { p_limit: 500 })
  if (error) throw error
  return (data ?? []).map((p) => ({
    id: p.id,
    nickname: p.nickname,
    coins: p.coins,
    amountYen: p.amount_yen,
    feeYen: p.fee_yen,
    createdAt: p.created_at,
    bankName: p.bank_name,
    bankCode: p.bank_code,
    branchName: p.branch_name,
    branchCode: p.branch_code,
    accountType: p.account_type,
    accountNumber: p.account_number,
    accountHolderKana: p.account_holder_kana,
    isVerified: p.is_verified,
    sharedCardCount: Number(p.shared_card_count ?? 0),
    flaggedGiftCount: Number(p.flagged_gift_count ?? 0),
    nonCardPurchaseCount: Number(p.non_card_purchase_count ?? 0),
  }))
}

/**
 * 換金申請の受付が終了した後も残っている報酬コイン(0107)。
 *
 * **残高は消していない。** 退会から90日でセルフサービスの窓口は閉じるが、
 * 報酬コインは既に稼得した金銭債権なので消滅させない
 * (2026-08-05の弁護士回答 論点A-1・規約 第6条の2第4項)。
 * 個別の申出を受けたら、この一覧から起票する。
 */
export async function fetchClosedWindowBalances(): Promise<ClosedWindowBalance[]> {
  const { data, error } = await requireSupabase().rpc('admin_closed_window_balances', {
    p_limit: 200,
  })
  if (error) throw error
  return (data ?? []).map((r) => ({
    userId: r.user_id,
    nickname: r.nickname ?? '(名前なし)',
    payoutDeadline: r.payout_deadline,
    windowClosedAt: r.window_closed_at,
    earnedBalance: Number(r.earned_balance ?? 0),
    hasBankAccount: !!r.has_bank_account,
    isVerified: !!r.is_verified,
  }))
}

export type ClosedWindowBalance = {
  userId: string
  nickname: string
  payoutDeadline: string | null
  windowClosedAt: string | null
  earnedBalance: number
  hasBankAccount: boolean
  isVerified: boolean
}

/**
 * 受付終了後の個別の申出として、換金を起票する(0107)。
 * **換金可能な全額**を1回で出す。ギフト・係争の保留はそのまま効く。
 */
export async function payoutOnRequest(userId: string, reason: string): Promise<string> {
  const { data, error } = await requireSupabase().rpc('admin_payout_on_request', {
    p_user_id: userId,
    p_reason: reason,
  })
  if (error) throw error
  return data as string
}

/** ⚠️ 実際に振り込んだ後にだけ押す。取り消す手立ては無い。 */
export async function markPayoutPaid(payoutId: string, note: string): Promise<void> {
  const { error } = await requireSupabase().rpc('admin_mark_payout_paid', {
    p_payout_id: payoutId,
    p_note: note,
  })
  if (error) throw error
}

/** 振込できなかった。申請コインは手数料も含め全額戻る(0014)。 */
export async function markPayoutFailed(payoutId: string, reason: string): Promise<void> {
  const { error } = await requireSupabase().rpc('admin_mark_payout_failed', {
    p_payout_id: payoutId,
    p_reason: reason,
  })
  if (error) throw error
}

export type AdminAccountRequest = {
  id: string
  userId: string
  nickname: string
  type: 'data_export' | 'account_deletion'
  status: string
  createdAt: string
  waitingDays: number
}

export async function fetchAdminAccountRequests(): Promise<AdminAccountRequest[]> {
  const { data, error } = await requireSupabase().rpc('admin_account_requests', { p_limit: 100 })
  if (error) throw error
  return (data ?? []).map((a) => ({
    id: a.id,
    userId: a.user_id,
    nickname: a.nickname,
    type: a.type as 'data_export' | 'account_deletion',
    status: a.status,
    createdAt: a.created_at,
    waitingDays: a.waiting_days,
  }))
}

export async function setAccountRequestStatus(
  requestId: string,
  status: 'processing' | 'completed',
): Promise<void> {
  const { error } = await requireSupabase().rpc('admin_set_account_request_status', {
    p_request_id: requestId,
    p_status: status,
  })
  if (error) throw error
}

/**
 * 決済の異議申立て(チャージバック)。0075。
 * **resolved_at が null の行がある利用者は、コインの消費が止まっている。**
 */
export type AdminDispute = {
  id: string
  userId: string | null
  nickname: string | null
  stripeDisputeId: string
  amountYen: number | null
  reason: string | null
  status: 'open' | 'won' | 'lost' | 'closed'
  createdAt: string
  coinBalance: number
  earnedBalance: number
}

export async function fetchAdminDisputes(): Promise<AdminDispute[]> {
  const { data, error } = await requireSupabase().rpc('admin_open_disputes', {})
  if (error) throw error
  return ((data ?? []) as Record<string, unknown>[]).map((d) => ({
    id: String(d.id),
    userId: (d.user_id as string) ?? null,
    nickname: (d.nickname as string) ?? null,
    stripeDisputeId: String(d.stripe_dispute_id),
    amountYen: (d.amount_yen as number) ?? null,
    reason: (d.reason as string) ?? null,
    status: d.status as AdminDispute['status'],
    createdAt: String(d.created_at),
    coinBalance: Number(d.coin_balance ?? 0),
    earnedBalance: Number(d.earned_balance ?? 0),
  }))
}

/** 凍結を解除する。理由は必須(後から説明を求められる操作なので)。 */
export async function resolveDispute(id: string, note: string): Promise<void> {
  const { error } = await requireSupabase().rpc('admin_resolve_dispute', {
    p_id: id,
    p_note: note,
  })
  if (!error) return
  if (/NOTE_REQUIRED/.test(error.message)) throw new Error('解除の理由を入力してください')
  if (/DISPUTE_NOT_FOUND/.test(error.message)) throw new Error('すでに解除されています')
  throw error
}

export type AdminHealth = {
  integrity: {
    check_name: string
    severity: string
    affected_count: number
    total_gap: number | null
    ran_at: string
    detail: unknown
  }[]
  ledgerExport: { ran_at: string; ok: boolean; row_count: number; error: string | null } | null
  push: {
    pending: number
    givenUp: number
    devices: number
    disabled: number
    lastError: string | null
  }
}

export async function fetchAdminHealth(): Promise<AdminHealth> {
  const { data, error } = await requireSupabase().rpc('admin_health')
  if (error) throw error
  const d = (data ?? {}) as Partial<AdminHealth>
  return {
    integrity: d.integrity ?? [],
    ledgerExport: d.ledgerExport ?? null,
    push: d.push ?? { pending: 0, givenUp: 0, devices: 0, disabled: 0, lastError: null },
  }
}

export type AdminAction = {
  id: string
  actorName: string
  kind: string
  targetId: string | null
  note: string | null
  at: string
}

export async function fetchAdminActions(): Promise<AdminAction[]> {
  const { data, error } = await requireSupabase().rpc('admin_recent_actions', { p_limit: 100 })
  if (error) throw error
  return (data ?? []).map((a) => ({
    id: a.id,
    actorName: a.actor_name,
    kind: a.kind,
    targetId: a.target_id,
    note: a.note,
    at: a.at,
  }))
}

// ------------------------------------------------------------
// 会計(0070/0076/0078/0079)
//
// 月次の締めをこの画面だけで終わらせるための読み取り。
// **SQL Editor を毎月開くのは続かない**ので、残高・損益・仕訳を
// 同じ画面から取れるようにしてある。すべて読み取り専用。
// ------------------------------------------------------------

/** accounting_balances() の1行。列名が日本語なのは、そのまま帳簿に写せるようにするため。 */
export type AccountingBalanceRow = {
  区分: string
  勘定科目: string
  金額円: number
  備考: string
}

export async function fetchAccountingBalances(): Promise<AccountingBalanceRow[]> {
  const { data, error } = await requireSupabase().rpc('accounting_balances', {})
  if (error) throw error
  return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
    区分: String(r['区分'] ?? ''),
    勘定科目: String(r['勘定科目'] ?? ''),
    金額円: Number(r['金額円'] ?? 0),
    備考: String(r['備考'] ?? ''),
  }))
}

export type AccountingRevenueRow = {
  区分: string
  科目: string
  金額円: number
  消費税: string
}

export async function fetchAccountingRevenue(
  from: string,
  to: string,
): Promise<AccountingRevenueRow[]> {
  const { data, error } = await requireSupabase().rpc('accounting_revenue', {
    p_from: from,
    p_to: to,
  })
  if (error) throw error
  return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
    区分: String(r['区分'] ?? ''),
    科目: String(r['科目'] ?? ''),
    金額円: Number(r['金額円'] ?? 0),
    消費税: String(r['消費税'] ?? ''),
  }))
}

/** accounting_journal() の1行。1行=借方1・貸方1・金額1(単純仕訳)。 */
export type AccountingJournalRow = {
  日付: string
  区分: string
  借方科目: string
  借方補助: string
  貸方科目: string
  貸方補助: string
  金額円: number
  税区分: string
  摘要: string
  伝票id: string
}

export async function fetchAccountingJournal(
  from: string,
  to: string,
): Promise<AccountingJournalRow[]> {
  const { data, error } = await requireSupabase().rpc('accounting_journal', {
    p_from: from,
    p_to: to,
  })
  if (error) throw error
  return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
    日付: String(r['日付'] ?? ''),
    区分: String(r['区分'] ?? ''),
    借方科目: String(r['借方科目'] ?? ''),
    借方補助: String(r['借方補助'] ?? ''),
    貸方科目: String(r['貸方科目'] ?? ''),
    貸方補助: String(r['貸方補助'] ?? ''),
    金額円: Number(r['金額円'] ?? 0),
    税区分: String(r['税区分'] ?? ''),
    摘要: String(r['摘要'] ?? ''),
    伝票id: String(r['伝票id'] ?? ''),
  }))
}

export type AccountingJournalCheckRow = {
  項目: string
  仕訳から円: number
  元帳から円: number
  差額円: number
  判定: string
}

/**
 * 仕訳の自己検証。**開業日から当日まで**の全期間で呼ぶこと
 * (累計で元帳の残高と比べるため、月だけを渡すと必ず食い違う)。
 */
export async function fetchAccountingJournalCheck(
  from: string,
  to: string,
): Promise<AccountingJournalCheckRow[]> {
  const { data, error } = await requireSupabase().rpc('accounting_journal_check', {
    p_from: from,
    p_to: to,
  })
  if (error) throw error
  return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
    項目: String(r['項目'] ?? ''),
    仕訳から円: Number(r['仕訳から円'] ?? 0),
    元帳から円: Number(r['元帳から円'] ?? 0),
    差額円: Number(r['差額円'] ?? 0),
    判定: String(r['判定'] ?? ''),
  }))
}

/**
 * ピタメイト1人あたりの年間支払額。
 *
 * 源泉徴収は不要と整理しているが(`docs/legal/tax-inquiry-withholding.md`)、
 * **年間いくら誰に払ったかは、いつ聞かれても即答できる状態にしておく**。
 * 聞かれてから集計するのでは遅い。
 */
export type AccountingHostPaymentRow = {
  userId: string
  nickname: string
  件数: number
  支払額円: number
  手数料円: number
  最終支払日: string | null
}

export async function fetchAccountingHostPayments(
  year: number,
): Promise<AccountingHostPaymentRow[]> {
  const { data, error } = await requireSupabase().rpc('accounting_host_payments', { p_year: year })
  if (error) throw error
  return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
    userId: String(r.user_id ?? ''),
    nickname: String(r.nickname ?? ''),
    件数: Number(r['件数'] ?? 0),
    支払額円: Number(r['支払額円'] ?? 0),
    手数料円: Number(r['手数料円'] ?? 0),
    最終支払日: (r['最終支払日'] as string) ?? null,
  }))
}

// ------------------------------------------------------------
// 手数料の率(表示用)
// ------------------------------------------------------------

/**
 * プラットフォーム利用料の率。
 *
 * **規約 第8条の2第3項で「具体的な率は本サービス上に表示します」と約束している。**
 * 条文を外出しした以上、画面に出さないと守れない約束になる
 * (docs/legal/terms-implementation-matrix.md G2)。
 */
export type FeeRates = {
  /** 予約の段階制。upperBound が null の段は「それ以上」 */
  bookingTiers: { upperBound: number | null; percent: number }[]
  /** 同一ゲストからの2回目以降の引き下げ(pt) */
  repeatDiscountPoints: number
  /** 引き下げ後の下限(%) */
  floorPercent: number
  /** ありがとうギフトの一律の率(%) */
  giftPercent: number
}

export async function fetchFeeRates(): Promise<FeeRates | null> {
  const { data, error } = await requireSupabase().rpc('fee_rates')
  if (error) throw error
  const r = (data ?? null) as Partial<FeeRates> | null
  if (!r || !Array.isArray(r.bookingTiers)) return null
  return {
    bookingTiers: r.bookingTiers,
    repeatDiscountPoints: typeof r.repeatDiscountPoints === 'number' ? r.repeatDiscountPoints : 0,
    floorPercent: typeof r.floorPercent === 'number' ? r.floorPercent : 0,
    giftPercent: typeof r.giftPercent === 'number' ? r.giftPercent : 0,
  }
}

/* ============================================================
 * 運営: 金銭返金(0085)と、チャージバック清算の相殺(0088)。
 *
 * **どちらも SQL Editor を開かずに完結できること。**
 * 台帳を動かす操作が画面から見えないと、運用が属人化する。
 * ============================================================ */

export type AdminCashRefund = {
  id: string
  userId: string
  nickname: string | null
  bookingId: string | null
  coins: number
  amountYen: number
  cause: string
  createdAt: string
}

/** 規約第9条5の3。未払いの金銭返金の一覧。 */
export async function fetchAdminCashRefunds(): Promise<AdminCashRefund[]> {
  const { data, error } = await requireSupabase().rpc('admin_pending_cash_refunds', {})
  if (error) throw error
  return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
    id: String(r.id),
    userId: String(r.user_id),
    nickname: (r.nickname as string) ?? null,
    bookingId: (r.booking_id as string) ?? null,
    coins: Number(r.coins ?? 0),
    amountYen: Number(r.amount_yen ?? 0),
    cause: String(r.cause ?? ''),
    createdAt: String(r.created_at),
  }))
}

/** 支払済み/却下にする。却下は理由が必須(DB側でも拒否される)。 */
export async function resolveCashRefund(
  id: string,
  status: 'paid' | 'rejected',
  note: string,
): Promise<void> {
  const { error } = await requireSupabase().rpc('admin_resolve_cash_refund', {
    p_id: id,
    p_status: status,
    p_note: note || null,
  })
  if (error) throw error
}

export type AdminOffsetablePurchase = {
  purchaseId: string
  userId: string
  nickname: string | null
  priceYen: number
  disputedAt: string
  candidateCount: number
  candidateCoins: number
  notifiedCount: number
}

/** 相殺を起こせる購入(異議が成立したもの)。 */
export async function fetchAdminOffsetablePurchases(): Promise<AdminOffsetablePurchase[]> {
  const { data, error } = await requireSupabase().rpc('admin_offsetable_purchases', {})
  if (error) throw error
  return ((data ?? []) as Record<string, unknown>[]).map((p) => ({
    purchaseId: String(p.purchase_id),
    userId: String(p.user_id),
    nickname: (p.nickname as string) ?? null,
    priceYen: Number(p.price_yen ?? 0),
    disputedAt: String(p.disputed_at),
    candidateCount: Number(p.candidate_count ?? 0),
    candidateCoins: Number(p.candidate_coins ?? 0),
    notifiedCount: Number(p.notified_count ?? 0),
  }))
}

/** 控除を予告する(まだ1コインも引かない)。戻り値は予告した件数。 */
export async function notifyChargebackOffset(purchaseId: string): Promise<number> {
  const { data, error } = await requireSupabase().rpc('chargeback_offset_notify', {
    p_purchase_id: purchaseId,
  })
  if (error) throw error
  return Number(data ?? 0)
}

export type AdminChargebackOffset = {
  id: string
  hostId: string
  nickname: string | null
  bookingId: string | null
  giftId: string | null
  coins: number
  status: 'notified' | 'executed'
  notifiedAt: string
  objectionDeadline: string
  objectedAt: string | null
  objectionNote: string | null
  executedCoins: number | null
  unpaidEarned: number
}

export async function fetchAdminChargebackOffsets(): Promise<AdminChargebackOffset[]> {
  const { data, error } = await requireSupabase().rpc('admin_chargeback_offsets', {})
  if (error) throw error
  return ((data ?? []) as Record<string, unknown>[]).map((o) => ({
    id: String(o.id),
    hostId: String(o.host_id),
    nickname: (o.nickname as string) ?? null,
    bookingId: (o.booking_id as string) ?? null,
    giftId: (o.gift_id as string) ?? null,
    coins: Number(o.coins ?? 0),
    status: o.status as AdminChargebackOffset['status'],
    notifiedAt: String(o.notified_at),
    objectionDeadline: String(o.objection_deadline),
    objectedAt: (o.objected_at as string) ?? null,
    objectionNote: (o.objection_note as string) ?? null,
    executedCoins: (o.executed_coins as number) ?? null,
    unpaidEarned: Number(o.unpaid_earned ?? 0),
  }))
}

/** 控除を実行する。戻り値は実際に引けた枚数(未払が足りなければ少なくなる)。 */
export async function executeChargebackOffset(id: string, note: string): Promise<number> {
  const { data, error } = await requireSupabase().rpc('chargeback_offset_execute', {
    p_id: id,
    p_note: note || null,
  })
  if (error) throw error
  return Number(data ?? 0)
}

/** 控除を取りやめる。理由は必須。 */
export async function cancelChargebackOffset(id: string, note: string): Promise<void> {
  const { error } = await requireSupabase().rpc('chargeback_offset_cancel', {
    p_id: id,
    p_note: note,
  })
  if (error) throw error
}

/* ============================================================
 * コインの有効期限(規約 第7条5の3)。schema: 0089。
 * ============================================================ */

export type CoinExpiry = {
  expiresAt: string
  kind: 'paid' | 'bonus'
  coins: number
  daysLeft: number
}

/** 自分のコインを有効期限ごとに。**合計だけでは使い切る判断ができない。** */
export async function fetchMyCoinExpiry(): Promise<CoinExpiry[]> {
  const { data, error } = await requireSupabase().rpc('my_coin_expiry', {})
  if (error) throw error
  return ((data ?? []) as unknown as Record<string, unknown>[]).map((r) => ({
    expiresAt: String(r.expires_at),
    kind: r.kind as CoinExpiry['kind'],
    coins: Number(r.coins ?? 0),
    daysLeft: Number(r.days_left ?? 0),
  }))
}

/* ============================================================
 * 運営: 購入の取消し(規約 第7条の3第5項)。schema: 0090。
 * ============================================================ */

export type AdminPurchase = {
  purchaseId: string
  userId: string
  nickname: string | null
  coins: number
  priceYen: number
  safetyFeeYen: number
  createdAt: string
  voidedAt: string | null
  hasDispute: boolean
  unusedCoins: number
}

export async function fetchAdminRecentPurchases(limit = 30): Promise<AdminPurchase[]> {
  const { data, error } = await requireSupabase().rpc('admin_recent_purchases', {
    p_limit: limit,
  })
  if (error) throw error
  return ((data ?? []) as Record<string, unknown>[]).map((p) => ({
    purchaseId: String(p.purchase_id),
    userId: String(p.user_id),
    nickname: (p.nickname as string) ?? null,
    coins: Number(p.coins ?? 0),
    priceYen: Number(p.price_yen ?? 0),
    safetyFeeYen: Number(p.safety_fee_yen ?? 0),
    createdAt: String(p.created_at),
    voidedAt: (p.voided_at as string) ?? null,
    hasDispute: Boolean(p.has_dispute),
    unusedCoins: Number(p.unused_coins ?? 0),
  }))
}

/**
 * 購入を取り消す。未使用コインが消え、**コイン代金とあんしんサポート料**が
 * 金銭返金の債務になる(規約 第7条の3第5項・税理士Q14(c))。
 * チャージバックがある購入は二重返金になるので拒否される。
 */
export async function voidPurchase(
  purchaseId: string,
  reason: string,
): Promise<{ voidedCoins: number; refundYen: number; feeYen: number }> {
  const { data, error } = await requireSupabase().rpc('admin_void_purchase', {
    p_purchase_id: purchaseId,
    p_reason: reason,
  })
  if (error) throw error
  const r = (data ?? {}) as Record<string, unknown>
  return {
    voidedCoins: Number(r.voided_coins ?? 0),
    refundYen: Number(r.refund_yen ?? 0),
    feeYen: Number(r.fee_yen ?? 0),
  }
}

/* ============================================================
 * 運営: 料率の変更(規約 第8条の2第4項・5項)。schema: 0091。
 * ============================================================ */

export type FeeTier = { upperBound: number | null; percent: number }

export type AdminFeeSchedule = {
  effectiveFrom: string
  isCurrent: boolean
  isFuture: boolean
  reason: string | null
  announcedAt: string | null
  notifiedHosts: number | null
  bookingTiers: FeeTier[]
  giftPercent: number | null
}

export async function fetchAdminFeeSchedules(): Promise<AdminFeeSchedule[]> {
  const { data, error } = await requireSupabase().rpc('admin_fee_schedules', {})
  if (error) throw error
  return ((data ?? []) as Record<string, unknown>[]).map((s) => ({
    effectiveFrom: String(s.effective_from),
    isCurrent: Boolean(s.is_current),
    isFuture: Boolean(s.is_future),
    reason: (s.reason as string) ?? null,
    announcedAt: (s.announced_at as string) ?? null,
    notifiedHosts: (s.notified_hosts as number) ?? null,
    bookingTiers: (s.booking_tiers as FeeTier[]) ?? [],
    giftPercent: (s.gift_percent as number) ?? null,
  }))
}

/**
 * 料率の変更を予約する(規約 第8条の2第4項)。
 * **30日以上先の日付でしか登録できず**、登録と同時にピタメイト全員へ
 * 個別通知が飛ぶ。変更前に成立した予約には旧料率が適用される(5項)。
 */
export async function scheduleFeeChange(
  effectiveFrom: string,
  reason: string,
  bookingTiers: FeeTier[],
  giftPercent: number,
): Promise<{ effectiveFrom: string; tiers: number; notifiedHosts: number }> {
  const { data, error } = await requireSupabase().rpc('admin_schedule_fee_change', {
    p_effective_from: effectiveFrom,
    p_reason: reason,
    p_booking_tiers: bookingTiers,
    p_gift_percent: giftPercent,
  })
  if (error) throw error
  const r = (data ?? {}) as Record<string, unknown>
  return {
    effectiveFrom: String(r.effective_from ?? effectiveFrom),
    tiers: Number(r.tiers ?? 0),
    notifiedHosts: Number(r.notified_hosts ?? 0),
  }
}

/* ============================================================
 * 運営: 制限値(規約 第7条の2・第8条の6第5項)。schema: 0101。
 *
 * 条文は幅でしか書いていない(「一定期間」「最長30日」)ので、
 * **数値は運営がここから動かせる。** 天井はサーバの CHECK 制約が持ち、
 * `caps` として返ってくる。画面側に天井を書き写さないこと
 * (制約を直したときに画面だけ古い数字を出し続ける)。
 * ============================================================ */

export type PlatformLimits = {
  newUser: {
    days: number
    purchaseMaxYen: number
    periodPurchaseMaxYen: number
    payoutHoldDays: number
  }
  gift: {
    maxPerTx: number
    maxPerDay: number
    maxPerMonth: number
    maxRecvMonth: number
    maxPairMonth: number
    windowDays: number
  }
  caps: Record<string, number>
  updatedAt: string | null
}

/** 制限値のキー。`admin_update_platform_limits` が受け付けるものと同じ。 */
export type PlatformLimitKey =
  | 'newUserDays'
  | 'newUserPurchaseMaxYen'
  | 'newUserPeriodPurchaseMaxYen'
  | 'newUserPayoutHoldDays'
  | 'giftMaxPerTx'
  | 'giftMaxPerDay'
  | 'giftMaxPerMonth'
  | 'giftMaxRecvMonth'
  | 'giftMaxPairMonth'
  | 'giftWindowDays'

export async function fetchPlatformLimits(): Promise<PlatformLimits> {
  const { data, error } = await requireSupabase().rpc('admin_platform_limits', {})
  if (error) throw error
  const r = (data ?? {}) as Record<string, Record<string, number>>
  const n = (o: Record<string, number> | undefined, k: string) => Number(o?.[k] ?? 0)
  return {
    newUser: {
      days: n(r.newUser, 'days'),
      purchaseMaxYen: n(r.newUser, 'purchaseMaxYen'),
      periodPurchaseMaxYen: n(r.newUser, 'periodPurchaseMaxYen'),
      payoutHoldDays: n(r.newUser, 'payoutHoldDays'),
    },
    gift: {
      maxPerTx: n(r.gift, 'maxPerTx'),
      maxPerDay: n(r.gift, 'maxPerDay'),
      maxPerMonth: n(r.gift, 'maxPerMonth'),
      maxRecvMonth: n(r.gift, 'maxRecvMonth'),
      maxPairMonth: n(r.gift, 'maxPairMonth'),
      windowDays: n(r.gift, 'windowDays'),
    },
    caps: (r.caps ?? {}) as Record<string, number>,
    updatedAt: (r.updatedAt as unknown as string) ?? null,
  }
}

/**
 * 制限値を変える。**変えるキーだけ**を渡す(部分更新)。
 * 理由は必須で、前後の値とともに運営の操作記録に残る。
 */
export async function updatePlatformLimits(
  reason: string,
  values: Partial<Record<PlatformLimitKey, number>>,
): Promise<{ changed: string }> {
  const { data, error } = await requireSupabase().rpc('admin_update_platform_limits', {
    p_reason: reason,
    p_values: values,
  })
  if (error) throw error
  const r = (data ?? {}) as Record<string, unknown>
  return { changed: String(r.changed ?? '') }
}

/* ============================================================
 * 運営: 経営指標(0105)。
 *
 * 事業計画書(docs/business-plan-2026-08.md)は
 *   ・実効利用料率 18%
 *   ・GMVに対する貢献利益率 19.4%
 * を前提に置いている。**構造の欠陥を探すためではなく、この前提が
 * 実績とずれたことに早く気づくため**の数字。
 * ============================================================ */

export type BusinessKpis = {
  fees: {
    grossCoins: number
    feeCoins: number
    /** 予約とギフトを合算した実効率(%)。取引が無ければ null */
    blendedPercent: number | null
    bookingGrossCoins: number
    /** 予約だけの実効率(%)。**計画の18%と比べるのはこちら** */
    bookingPercent: number | null
    giftGrossCoins: number
    /** ギフトだけの実効率(%)。一律35%なので、混ざると合算が上がる */
    giftPercent: number | null
    /**
     * ギフト流通総額 ÷ 予約対価総額(%)。**法務の指標**（0110）。
     *
     * ギフトを「為替取引に当たらない」と整理する根拠のひとつは、
     * **ギフトが主たる収益源ではなく、役務に付随する任意の追加対価**である
     * ことにある。条文で宣言するだけでは足りず、実績で示せなければ
     * 財務局への照会でも紛争でも通らない（2026-08-05の弁護士回答 論点B(b)2）。
     *
     * **上がり続けているのに放置しないこと。**
     */
    giftToBookingPercent: number | null
  }
  concentration: {
    activeHosts: number
    top5Coins: number
    /** 上位5人が予約GMVに占める割合(%) */
    top5Percent: number | null
    /** 最大の1人が占める割合(%)。**この人が抜けたら売上の何割が消えるか** */
    top1Percent: number | null
  }
  chargebacks: {
    count: number
    amountYen: number
    openCount: number
    lostCount: number
    purchaseYen: number
    /** 購入額に対する申立て額の割合(%)。**分母はGMVではなく購入額** */
    ratePercent: number | null
  }
  safetyFeeYen: number
}

export async function fetchBusinessKpis(from: string, to: string): Promise<BusinessKpis> {
  const { data, error } = await requireSupabase().rpc('admin_business_kpis', {
    p_from: from,
    p_to: to,
  })
  if (error) throw error
  const r = (data ?? {}) as Record<string, Record<string, unknown>>
  const n = (o: Record<string, unknown> | undefined, k: string) => Number(o?.[k] ?? 0)
  // **null を 0 に潰さない。**「率が0%」と「まだ何も起きていない」は別のこと
  const p = (o: Record<string, unknown> | undefined, k: string) =>
    o?.[k] == null ? null : Number(o[k])
  return {
    fees: {
      grossCoins: n(r.fees, 'grossCoins'),
      feeCoins: n(r.fees, 'feeCoins'),
      blendedPercent: p(r.fees, 'blendedPercent'),
      bookingGrossCoins: n(r.fees, 'bookingGrossCoins'),
      bookingPercent: p(r.fees, 'bookingPercent'),
      giftGrossCoins: n(r.fees, 'giftGrossCoins'),
      giftPercent: p(r.fees, 'giftPercent'),
      giftToBookingPercent: p(r.fees, 'giftToBookingPercent'),
    },
    concentration: {
      activeHosts: n(r.concentration, 'activeHosts'),
      top5Coins: n(r.concentration, 'top5Coins'),
      top5Percent: p(r.concentration, 'top5Percent'),
      top1Percent: p(r.concentration, 'top1Percent'),
    },
    chargebacks: {
      count: n(r.chargebacks, 'count'),
      amountYen: n(r.chargebacks, 'amountYen'),
      openCount: n(r.chargebacks, 'openCount'),
      lostCount: n(r.chargebacks, 'lostCount'),
      purchaseYen: n(r.chargebacks, 'purchaseYen'),
      ratePercent: p(r.chargebacks, 'ratePercent'),
    },
    safetyFeeYen: Number((r as Record<string, unknown>).safetyFeeYen ?? 0),
  }
}

export type PaymentMethodMixRow = {
  method: string
  purchases: number
  amountYen: number
  sharePercent: number | null
}

/** 決済手段の内訳。PayPayの比率が上がるほど貢献利益率が改善する。 */
export async function fetchPaymentMethodMix(
  from: string,
  to: string,
): Promise<PaymentMethodMixRow[]> {
  const { data, error } = await requireSupabase().rpc('admin_payment_method_mix', {
    p_from: from,
    p_to: to,
  })
  if (error) throw error
  return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
    method: String(r.method),
    purchases: Number(r.purchases ?? 0),
    amountYen: Number(r.amount_yen ?? 0),
    sharePercent: r.share_percent == null ? null : Number(r.share_percent),
  }))
}

/* ============================================================
 * 証跡(0106)。異議申立てで争うための記録。
 * ============================================================ */

/**
 * ポリシーへの同意を、**表示していた文面ごと**記録する。
 *
 * 版番号だけでは「その版が何と書いてあったか」を後から示せない。
 * 弁護士（2026-07-30 Q14）の条件①「同意の痕跡（ログ）を残す」に対応する。
 *
 * **失敗しても呼び出し側の処理を止めないこと。** 記録は付随作業で、
 * ここで例外にすると予約そのものができなくなる。
 */
export async function recordPolicyConsent(
  kind: 'cancellation' | 'purchase' | 'terms',
  shownText: string,
  relatedId?: string | null,
): Promise<void> {
  try {
    await requireSupabase().rpc('record_policy_consent', {
      p_kind: kind,
      p_shown_text: shownText,
      p_related_id: relatedId ?? null,
      p_device_id: getDeviceId(),
    })
  } catch (e) {
    console.error('[recordPolicyConsent]', e)
  }
}

/** 異議申立てから証跡一式を取り出す（運営）。 */
export async function fetchDisputeEvidence(disputeId: string): Promise<unknown> {
  const { data, error } = await requireSupabase().rpc('admin_dispute_evidence', {
    p_dispute_id: disputeId,
  })
  if (error) throw error
  return data
}
