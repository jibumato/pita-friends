import { color as C } from '../theme/tokens'

/**
 * ピタメイトの「ひとこと」(0056)。
 *
 * 推しがいる人がホームに来る目的は「その人の様子を見ること」。
 * 名前も料金も昨日と同じ画面では、開く理由が続かない。
 *
 * **いつのものかを必ず添える。** 「今夜21時から!」が3日前のものだと、
 * 添えていなければ今夜のことだと読まれてしまう。
 * 14日を過ぎたものはサーバ側で落ちてくるので、ここには来ない。
 */
export default function HostStatus({
  text,
  at,
  compact = false,
}: {
  text: string | null
  at: string | null
  compact?: boolean
}) {
  if (!text) return null
  return (
    <div
      style={{
        display: 'flex',
        alignItems: 'baseline',
        gap: 6,
        background: C.surface,
        border: `1.5px solid ${C.border}`,
        borderLeft: `3px solid ${C.lavender}`,
        borderRadius: 6,
        padding: compact ? '5px 7px' : '7px 10px',
        minWidth: 0,
      }}
    >
      <span
        style={{
          fontSize: compact ? 10.5 : 12,
          color: C.ink,
          lineHeight: 1.5,
          minWidth: 0,
          overflow: 'hidden',
          textOverflow: 'ellipsis',
          whiteSpace: compact ? 'nowrap' : 'normal',
        }}
      >
        {text}
      </span>
      {at && !compact && (
        <span style={{ flex: 'none', fontSize: 9.5, color: C.muted, marginLeft: 'auto' }}>
          {statusAgo(at)}
        </span>
      )}
    </div>
  )
}

/** 「たった今」「3時間前」「2日前」。14日より古いものはここには来ない。 */
export function statusAgo(at: string): string {
  const min = Math.floor((Date.now() - new Date(at).getTime()) / 60_000)
  if (min < 1) return 'たった今'
  if (min < 60) return `${min}分前`
  const hours = Math.floor(min / 60)
  if (hours < 24) return `${hours}時間前`
  return `${Math.floor(hours / 24)}日前`
}
