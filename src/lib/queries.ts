/**
 * アカウントデータの取得・更新。
 * バックエンド未設定時は呼び出さないこと(呼び出し側で isBackendConfigured
 * を確認する、または requireSupabase() が例外を投げる)。
 */
import { requireSupabase } from './supabase'
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
} from './database.types'

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
    sb.from('coin_wallets').select('balance, bonus_balance').eq('user_id', userId).single(),
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
 * Stripe Checkout セッションを発行し、決済ページのURLを返す。
 * 呼び出し側はこのURLへ遷移する。付与は決済完了後にwebhookが行う。
 */
export async function createCheckoutSession(packId: string): Promise<string> {
  const { data, error } = await requireSupabase().functions.invoke<{ url?: string; error?: string }>(
    'create-checkout-session',
    { body: { packId } },
  )
  if (error) throw error
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
    throw error
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
    sb.from('profiles').select('id, nickname, avatar_initial, avatar_color').in('id', partnerIds),
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
  if (error) throw error
}

/** ホストランキングの期間。 */
export type RankingPeriod = 'daily' | 'weekly' | 'monthly'

export type RankingEntry = {
  rank: number
  hostId: string
  nickname: string
  avatarInitial: string
  avatarColor: string
  completedCount: number
  mannerScore: number
  score: number
  isVerified: boolean
}

/**
 * ホストランキングを取得する。スコアは「完了予約数×品質×信頼性」で、
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
    completedCount: Number(r.completed_count),
    mannerScore: Number(r.manner_score),
    score: Number(r.score),
    isVerified: r.is_verified,
  }))
}

/** ギフト(ありがとうチップ)で選べる金額(コイン=円)。上限は1回50,000。 */
export const GIFT_AMOUNTS = [100, 500, 1000, 5000, 10000, 50000] as const

const GIFT_ERROR_MESSAGES: Record<string, string> = {
  INSUFFICIENT_COINS: '購入コインの残高が足りません。ギフトは購入コインからのみ贈れます',
  INVALID_AMOUNT: 'ギフトの金額が正しくありません(1回50,000コインまで)',
  BLOCKED: 'この相手にはギフトを贈れません',
  THREAD_NOT_FOUND: 'トークが見つかりませんでした',
  FORBIDDEN: 'このトークではギフトを贈れません',
  SAME_DEVICE_FORBIDDEN: '同じ端末で使われたアカウント間ではギフトを贈れません',
  NO_COMPLETED_PLAY: 'ギフトは、一緒に遊んだ(予約が完了した)相手にだけ贈れます',
  MUTUAL_GIFT_FORBIDDEN: '相手からギフトを受け取っているため、こちらからは贈れません(相互送金の防止)',
  RECENT_PURCHASE_COOLDOWN: 'コイン購入から24時間はギフトを贈れません',
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
    await requireSupabase().functions.invoke('record-ip', { body: {} })
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
    throw new Error(known ? GIFT_ERROR_MESSAGES[known] : 'ギフトの送信に失敗しました')
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
  if (error) throw error
}

/** 募集に参加する。定員・本人確認要件等はDB側(join_board_post RPC)でアトミックに検証される。 */
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
  throw error
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

/** 通知の受け取り設定を取得する。 */
export async function fetchNotificationPrefs(): Promise<NotificationPrefs> {
  const sb = requireSupabase()
  const { data: auth } = await sb.auth.getUser()
  const me = auth.user?.id
  if (!me) throw new Error('ログインが必要です')
  const { data, error } = await sb
    .from('notification_prefs')
    .select('notify_invites, notify_online_friends, notify_recommendations')
    .eq('user_id', me)
    .single()
  if (error) throw error
  return {
    notifyInvites: data.notify_invites,
    notifyOnlineFriends: data.notify_online_friends,
    notifyRecommendations: data.notify_recommendations,
  }
}

/** 通知の受け取り設定を更新する。 */
export async function updateNotificationPrefs(patch: Partial<NotificationPrefs>): Promise<void> {
  const sb = requireSupabase()
  const { data: auth } = await sb.auth.getUser()
  const me = auth.user?.id
  if (!me) throw new Error('ログインが必要です')
  const { error } = await sb
    .from('notification_prefs')
    .update({
      notify_invites: patch.notifyInvites,
      notify_online_friends: patch.notifyOnlineFriends,
      notify_recommendations: patch.notifyRecommendations,
    })
    .eq('user_id', me)
  if (error) throw error
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
 * エスクロー予約決済・自社銀行振込によるホストへの報酬支払い。
 * schema: 0013_escrow_payouts + 0014_bank_payouts。
 * ・購入コイン(balance)と報酬コイン(earned_balance)は別会計。
 *   換金できるのはearned_balanceのみ(不正対策・詳細はマイグレーション参照)。
 * ・ホストは口座を登録して換金申請 → 運営が総合振込で支払う。
 * ============================================================ */

export type BookingInfo = {
  id: string
  guestId: string
  hostId: string
  coins: number
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
    .select('id, guest_id, host_id, coins, status, scheduled_at')
    .eq('id', promise.booking_id)
    .single()
  if (bErr) throw bErr
  return {
    id: booking.id,
    guestId: booking.guest_id,
    hostId: booking.host_id,
    coins: booking.coins,
    status: booking.status,
    scheduledAt: booking.scheduled_at,
  }
}

/** 「プレイ完了」を確定する(ゲスト本人のみ)。ホストの報酬コインに反映される。 */
export async function completeBooking(bookingId: string): Promise<void> {
  const { error } = await requireSupabase().rpc('complete_booking', { p_booking_id: bookingId })
  if (error) throw error
}

/**
 * 予約をキャンセルする(当事者のみ)。返還ルールはDB側(規約第9条):
 * ホスト都合=全額返還 / ゲスト都合1時間前まで=全額返還 / 直前=返還なし。
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

/** ホストとしての収益サマリー(換金可能分・エスクロー中分)を取得する。 */
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
export const PAYOUT_MIN_COINS = 1000

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
  BANK_ACCOUNT_NOT_REGISTERED: '先にホスト設定から振込先口座を登録してください',
  INSUFFICIENT_EARNED_BALANCE: '換金可能な残高が足りません',
  GIFT_ON_HOLD: '受け取ったギフトは7日間は換金できません。保留が明けるまでお待ちください',
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
  dotakyanRate: number
  confirmedCount: number
  isHost: boolean
  hourlyRate: number
  games: string[]
  bio: string
  voiceUrl: string | null
  voiceSeconds: number | null
  latestReview: { stars: number; tags: string[]; reviewerName: string } | null
}

/** 他ユーザーの公開プロフィールを取得する(さがす/ホーム等から個別に表示)。 */
export async function fetchPublicProfile(userId: string): Promise<PublicProfile | null> {
  const sb = requireSupabase()
  const [profileRes, trustRes, hostRes, reviewRes] = await Promise.all([
    sb.from('profiles').select('nickname, avatar_initial, avatar_color, voice_path, voice_seconds').eq('id', userId).single(),
    sb
      .from('profile_trust_stats')
      .select('manner_score, dotakyan_count, confirmed_count, is_verified')
      .eq('user_id', userId)
      .single(),
    sb.from('host_settings').select('is_host, hourly_rate, games, bio').eq('user_id', userId).single(),
    sb
      .from('reviews')
      .select('stars, tags, reviewer_id')
      .eq('reviewee_id', userId)
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle(),
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
    dotakyanRate: denom > 0 ? Math.round((dotakyan / denom) * 100) : 0,
    confirmedCount: confirmed,
    isHost: host?.is_host ?? false,
    hourlyRate: host?.hourly_rate ?? 0,
    games: host?.games ?? [],
    bio: host?.bio ?? '',
    voiceUrl: profileRes.data.voice_path ? voiceGreetingUrl(profileRes.data.voice_path) : null,
    voiceSeconds: profileRes.data.voice_seconds ?? null,
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
 * 録音した音声挨拶をアップロードして公開する(B方式=即公開)。
 * 原資は本人フォルダ配下に固定パスで上書き保存。戻り値は公開URL。
 */
export async function uploadVoiceGreeting(blob: Blob, seconds: number): Promise<string> {
  const sb = requireSupabase()
  const { data: auth } = await sb.auth.getUser()
  const me = auth.user?.id
  if (!me) throw new Error('ログインが必要です')
  const path = `${me}/greeting.webm`
  const { error: upErr } = await sb.storage.from(VOICE_BUCKET).upload(path, blob, {
    upsert: true,
    contentType: blob.type || 'audio/webm',
  })
  if (upErr) throw upErr
  const { error } = await sb.rpc('set_voice_greeting', { p_path: path, p_seconds: Math.max(1, Math.min(15, Math.round(seconds))) })
  if (error) throw error
  return voiceGreetingUrl(path)
}

/** 自分の音声挨拶を削除する。 */
export async function deleteVoiceGreeting(): Promise<void> {
  const sb = requireSupabase()
  const { data: auth } = await sb.auth.getUser()
  const me = auth.user?.id
  if (!me) return
  await sb.rpc('clear_voice_greeting')
  await sb.storage.from(VOICE_BUCKET).remove([`${me}/greeting.webm`]).catch(() => undefined)
}

/** 管理者が音声挨拶を削除する(通報対応)。 */
export async function adminClearVoiceGreeting(userId: string): Promise<void> {
  const { error } = await requireSupabase().rpc('admin_clear_voice_greeting', { p_user_id: userId })
  if (error) throw error
}

/**
 * ホスト予約をリクエストし、コインをアトミックに確保する(create_booking RPC)。
 * この時点では予約は「承諾待ち(requested)」で、約束(トーク)はまだ成立しない。
 * ホストが承諾して初めてトークが開く。戻り値は booking_id。
 */
export async function createBookingRemote(hostId: string, durationMinutes: 30 | 60 | 120): Promise<string> {
  const { data, error } = await requireSupabase().rpc('create_booking', {
    p_host_id: hostId,
    p_duration_minutes: durationMinutes,
  })
  if (error) throw error
  return data as string
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

/** 自分(ホスト)宛の承諾待ち予約リクエストを、申込者の信頼情報つきで取得する。 */
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
