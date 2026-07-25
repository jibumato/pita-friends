/**
 * オンライン状態の共通表示。プロフィール・カード・トーク一覧で同じ見え方にする。
 *  - dot     : アイコンに重ねる小さな丸だけ(一覧のサムネ用)
 *  - inline  : 丸 + 文言(「今すぐ遊べる」「5分前」)
 * 非公開・未記録(unknown)のときは何も描画しない。
 */
import { color as C } from '../theme/tokens'
import { presenceOf } from '../lib/presenceLabel'
import type { PresenceStatus } from '../lib/database.types'

type Props = {
  /** Realtime Presence で在席が確認できているか。 */
  live?: boolean
  lastSeenAt?: string | null
  status?: PresenceStatus
  variant?: 'dot' | 'inline'
  /** dot のとき: 丸の直径。 */
  size?: number
  /** inline のとき: 文字サイズ。 */
  fontSize?: number
  /** dot の縁取り色(重ねる相手の背景に合わせる)。 */
  ringColor?: string
}

export default function OnlineBadge({
  live = false,
  lastSeenAt = null,
  status = 'online',
  variant = 'inline',
  size = 11,
  fontSize = 10,
  ringColor = C.surface,
}: Props) {
  const p = presenceOf(live, lastSeenAt, status)
  if (p.kind === 'unknown') return null

  if (variant === 'dot') {
    // 「少し前にいた」だけの人まで緑の点にすると誤解を生むので、
    // オンライン系(ready/online/busy)のときだけ点を出す。
    if (p.kind === 'recent' || p.kind === 'offline') return null
    return (
      <span
        aria-label={p.label}
        title={p.label}
        style={{
          width: size,
          height: size,
          borderRadius: '50%',
          background: p.dot,
          border: `2px solid ${ringColor}`,
          display: 'inline-block',
          boxSizing: 'border-box',
        }}
      />
    )
  }

  const live5 = p.kind === 'ready' || p.kind === 'online' || p.kind === 'busy'
  return (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 4, fontSize, color: live5 ? C.ink : C.muted }}>
      <span
        aria-hidden
        style={{ width: 7, height: 7, borderRadius: '50%', background: p.dot, flex: 'none' }}
      />
      {p.label}
    </span>
  )
}
