/**
 * 「いま遊べる」オンライン表示。Supabase Realtime Presenceを使う。
 * safety_prefs.show_online が true のユーザーだけが自分の在席を
 * ブロードキャストし、それ以外は購読(閲覧)のみを行う。
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

/** 自分の在席をブロードキャストする。戻り値の関数で停止する。 */
export function trackMyPresence(user: OnlineUser): () => void {
  const sb = requireSupabase()
  const channel: RealtimeChannel = sb.channel(CHANNEL_NAME, { config: { presence: { key: user.userId } } })
  channel.subscribe(async (status) => {
    if (status === 'SUBSCRIBED') {
      await channel.track({
        nickname: user.nickname,
        avatarInitial: user.avatarInitial,
        avatarColor: user.avatarColor,
      })
    }
  })
  return () => {
    sb.removeChannel(channel)
  }
}

/** 現在オンラインのユーザー一覧を購読する(自分を除く)。戻り値の関数で解除する。 */
export function subscribeOnlineUsers(excludeUserId: string | null, onChange: (users: OnlineUser[]) => void): () => void {
  const sb = requireSupabase()
  const channel = sb.channel(CHANNEL_NAME, { config: { presence: { key: 'listener' } } })
  channel.on('presence', { event: 'sync' }, () => {
    const state = channel.presenceState<{ nickname: string; avatarInitial: string; avatarColor: string }>()
    const users: OnlineUser[] = Object.entries(state)
      .filter(([key]) => key !== excludeUserId && key !== 'listener')
      .map(([key, metas]) => ({
        userId: key,
        nickname: metas[0]?.nickname ?? '?',
        avatarInitial: metas[0]?.avatarInitial ?? '?',
        avatarColor: metas[0]?.avatarColor ?? '#B3E5F2',
      }))
    onChange(users)
  })
  channel.subscribe()
  return () => {
    sb.removeChannel(channel)
  }
}
