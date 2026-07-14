/**
 * Avatar — 頭文字 + パステル背景のアバター。
 * props: initial(頭文字), color(パステル5色), size(28–96px), verified(右下✓バッジ)。
 * サイズに応じて 角丸・フォント・影・バッジが連動。影は 50px 以上のみ。
 */
import { color as C } from '../theme/tokens'

type AvatarProps = {
  initial?: string
  color?: string
  size?: number
  verified?: boolean
}

export default function Avatar({
  initial = 'み',
  color = C.avatarAqua,
  size = 56,
  verified = false,
}: AvatarProps) {
  const radius = Math.max(4, Math.round(size * 0.17))
  const fontSize = Math.round(size * 0.42)
  const boxShadow = size >= 50 ? `3px 3px 0 ${C.ink}` : 'none'
  const badge = Math.round(size * 0.3)
  const badgeFont = Math.round(size * 0.16)

  return (
    <div style={{ position: 'relative', display: 'inline-flex' }}>
      <div
        style={{
          width: size,
          height: size,
          borderRadius: radius,
          background: color,
          border: `1.5px solid ${C.ink}`,
          boxShadow,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          fontSize,
          color: C.ink,
        }}
      >
        {initial}
      </div>
      {verified && (
        <div
          style={{
            position: 'absolute',
            right: -4,
            bottom: -4,
            width: badge,
            height: badge,
            borderRadius: '50%',
            background: C.lime,
            border: `1.5px solid ${C.ink}`,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            fontSize: badgeFont,
            color: C.ink,
          }}
        >
          ✓
        </div>
      )}
    </div>
  )
}
