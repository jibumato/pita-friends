/**
 * オンライン表示の共通ロジック。
 *
 * 在席の情報源は2つある。
 *  - Realtime Presence: 「いまアプリを開いている」= 確実にオンライン
 *  - profiles.last_seen_at: 最後に開いていた時刻。少し前までいた人も出せる
 * 前者が真なら最優先、無ければ last_seen_at からの経過時間で判定する。
 *
 * オンライン状態を非公開にしている人は last_seen_at が null のままなので、
 * 何も表示しない(unknown)。
 */
import type { PresenceStatus } from './database.types'

/** 何分以内なら「オンライン」とみなすか(last_seen_at は定期更新なので少し余裕を持たせる)。 */
const ONLINE_WINDOW_MIN = 5

export type PresenceKind = 'ready' | 'online' | 'busy' | 'recent' | 'offline' | 'unknown'

export type Presence = {
  kind: PresenceKind
  /** 「今すぐ遊べる」「オンライン」「5分前」など、そのまま出せる文言。 */
  label: string
  /** ドットの色。unknown のときは表示しない。 */
  dot: string
}

const DOT_READY = '#5FC26A'
const DOT_ONLINE = '#5FC26A'
const DOT_BUSY = '#F0A93B'
const DOT_RECENT = '#B9B2C9'

/** 経過時間を「5分前」「3時間前」「昨日」「3日前」に丸める。 */
function agoText(minutes: number): string {
  if (minutes < 60) return `${Math.max(1, Math.floor(minutes))}分前`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours}時間前`
  const days = Math.floor(hours / 24)
  if (days === 1) return '昨日'
  if (days < 7) return `${days}日前`
  return '1週間以上前'
}

/**
 * 表示用の在席状態を求める。
 * @param isLive Realtime Presence で在席が確認できているか
 * @param lastSeenAt profiles.last_seen_at(非公開・未記録は null)
 * @param status 本人が選んだ状態
 * @param now 判定時刻(テスト用)
 */
export function presenceOf(
  isLive: boolean,
  lastSeenAt: string | null | undefined,
  status: PresenceStatus = 'online',
  now: number = Date.now(),
): Presence {
  const seenMs = lastSeenAt ? Date.parse(lastSeenAt) : NaN
  const minutes = Number.isNaN(seenMs) ? Infinity : (now - seenMs) / 60000

  // いま開いている、または直近5分以内 = オンライン扱い。本人の状態を尊重する。
  if (isLive || minutes <= ONLINE_WINDOW_MIN) {
    if (status === 'ready') return { kind: 'ready', label: '今すぐ遊べる', dot: DOT_READY }
    if (status === 'busy') return { kind: 'busy', label: '取り込み中', dot: DOT_BUSY }
    return { kind: 'online', label: 'オンライン', dot: DOT_ONLINE }
  }

  // last_seen_at が無い = 非公開 or 一度も記録されていない。何も出さない。
  if (!Number.isFinite(minutes)) return { kind: 'unknown', label: '', dot: 'transparent' }

  // 24時間以内は「◯分前/◯時間前」、それ以上は控えめに。
  if (minutes < 60 * 24) return { kind: 'recent', label: agoText(minutes), dot: DOT_RECENT }
  return { kind: 'offline', label: agoText(minutes), dot: DOT_RECENT }
}

/** ステータス選択UI用のラベル。 */
export const presenceStatusLabel: Record<PresenceStatus, string> = {
  ready: '今すぐ遊べる',
  online: 'オンライン',
  busy: '取り込み中',
}

export const presenceStatusDot: Record<PresenceStatus, string> = {
  ready: DOT_READY,
  online: DOT_ONLINE,
  busy: DOT_BUSY,
}
