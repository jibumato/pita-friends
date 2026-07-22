/**
 * 「いま遊べる」オンライン表示。Supabase Realtime Presenceを使う。
 * safety_prefs.show_online が true のユーザーだけが自分の在席を
 * ブロードキャストし、それ以外は購読(閲覧)のみを行う。
 *
 * 重要: 同じトピック名のチャンネルは supabase-js が同一インスタンスを返すため、
 * 「配信」と「購読」で別々に channel() を作ると、片方が subscribe() 済みの
 * チャンネルに後から .on() を足そうとして
 *   "cannot add `presence` callbacks ... after `subscribe()`"
 * で落ちる。これを避けるため、モジュール内で1つのチャンネルを共有し、
 * .on() は subscribe() の前に一度だけ登録する。配信の有無・購読者の数は
 * 参照カウントで管理し、誰も使わなくなったらチャンネルを閉じる。
 */
import { requireSupabase } from './supabase'
import type { RealtimeChannel } from '@supabase/supabase-js'

const CHANNEL_NAME = 'online-users'

export type OnlineUser = {
  userId: string
  nickname: string
  avatarInitial: string
  avatarColor: string
}

type Meta = { nickname: string; avatarInitial: string; avatarColor: string }

let channel: RealtimeChannel | null = null
let myKey: string | null = null
let subscribed = false
let selfMeta: Meta | null = null
const listeners = new Set<(users: OnlineUser[]) => void>()

function computeUsers(): OnlineUser[] {
  if (!channel) return []
  const state = channel.presenceState<Meta>()
  return Object.entries(state)
    .filter(([key]) => key !== myKey && key !== 'listener')
    .map(([key, metas]) => ({
      userId: key,
      nickname: metas[0]?.nickname ?? '?',
      avatarInitial: metas[0]?.avatarInitial ?? '?',
      avatarColor: metas[0]?.avatarColor ?? '#B3E5F2',
    }))
}

function emit() {
  const users = computeUsers()
  listeners.forEach((cb) => cb(users))
}

/** 必要なら共有チャンネルを1つだけ作る(.on()はsubscribe()前に一度だけ)。 */
function ensureChannel(key: string) {
  if (channel) return
  myKey = key
  const sb = requireSupabase()
  channel = sb.channel(CHANNEL_NAME, { config: { presence: { key } } })
  channel.on('presence', { event: 'sync' }, emit)
  channel.subscribe((status) => {
    if (status === 'SUBSCRIBED') {
      subscribed = true
      if (selfMeta) void channel!.track(selfMeta)
      emit()
    }
  })
}

/** 配信も購読も無くなったらチャンネルを閉じる。 */
function teardownIfIdle() {
  if (channel && selfMeta === null && listeners.size === 0) {
    requireSupabase().removeChannel(channel)
    channel = null
    myKey = null
    subscribed = false
  }
}

/** 自分の在席をブロードキャストする。戻り値の関数で停止する。 */
export function trackMyPresence(user: OnlineUser): () => void {
  selfMeta = { nickname: user.nickname, avatarInitial: user.avatarInitial, avatarColor: user.avatarColor }
  ensureChannel(user.userId)
  if (subscribed && channel) void channel.track(selfMeta)
  return () => {
    const ch = channel
    selfMeta = null
    if (ch && subscribed) void ch.untrack()
    teardownIfIdle()
  }
}

/** 現在オンラインのユーザー一覧を購読する(自分を除く)。戻り値の関数で解除する。 */
export function subscribeOnlineUsers(
  excludeUserId: string | null,
  onChange: (users: OnlineUser[]) => void,
): () => void {
  listeners.add(onChange)
  ensureChannel(excludeUserId ?? 'listener')
  if (subscribed) onChange(computeUsers())
  return () => {
    listeners.delete(onChange)
    teardownIfIdle()
  }
}
