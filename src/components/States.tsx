/** 状態網羅の共通パーツ(空 / エラー / ローディングskeleton)。状態網羅ギャラリーを移植。 */
import type { ReactNode } from 'react'
import { color as C } from '../theme/tokens'
import { usePress } from '../hooks/usePress'

/** 中央寄せの空状態。大きなアイコンタイル + 見出し + 補足 + 任意CTA。 */
export function EmptyState({
  icon,
  tileColor = C.lavender,
  title,
  desc,
  cta,
  ctaVariant = 'primary',
  onCta,
}: {
  icon: ReactNode
  tileColor?: string
  title: ReactNode
  desc?: ReactNode
  cta?: string
  ctaVariant?: 'primary' | 'confirm'
  onCta?: () => void
}) {
  const shadow = ctaVariant === 'confirm' ? `3px 3px 0 ${C.shadowCol}` : `3px 3px 0 ${C.lavender}`
  const btn = usePress(shadow)
  return (
    <div
      style={{
        flex: 1,
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        justifyContent: 'center',
        gap: 18,
        padding: '0 34px',
        textAlign: 'center',
      }}
    >
      <div
        style={{
          width: 96,
          height: 96,
          borderRadius: 20,
          background: tileColor,
          border: `1.5px solid ${C.border}`,
          boxShadow: `4px 4px 0 ${C.shadowCol}`,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
        }}
      >
        {icon}
      </div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 6, alignItems: 'center' }}>
        <span style={{ fontSize: 16, color: C.ink, lineHeight: 1.5 }}>{title}</span>
        {desc && <span style={{ fontSize: 11.5, color: C.muted, lineHeight: 1.6 }}>{desc}</span>}
      </div>
      {cta && (
        <div
          className="pita-press"
          onClick={onCta}
          {...btn.handlers}
          style={{
            cursor: 'pointer',
            width: '100%',
            background: ctaVariant === 'confirm' ? C.lime : C.ctaBg,
            color: ctaVariant === 'confirm' ? C.ink : C.ctaFg,
            border: ctaVariant === 'confirm' ? `1.5px solid ${C.border}` : 'none',
            borderRadius: 8,
            padding: '14px 0',
            textAlign: 'center',
            fontSize: 14,
            ...btn.style,
          }}
        >
          {cta}
        </div>
      )}
    </div>
  )
}

/** 通信エラー(菱形の!アイコン + 再試行)。 */
export function ErrorState({
  title = '接続できませんでした',
  desc = '電波の良い場所で、もう一度お試しください',
  code,
  onRetry,
}: {
  title?: string
  desc?: ReactNode
  code?: string
  onRetry?: () => void
}) {
  const btn = usePress(`3px 3px 0 ${C.lavender}`)
  return (
    <div
      style={{
        flex: 1,
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        justifyContent: 'center',
        gap: 18,
        padding: '0 30px',
        textAlign: 'center',
      }}
    >
      <div
        style={{
          width: 92,
          height: 92,
          background: C.avatarOrange,
          border: `1.5px solid ${C.border}`,
          boxShadow: `4px 4px 0 ${C.shadowCol}`,
          transform: 'rotate(45deg)',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
        }}
      >
        <span style={{ transform: 'rotate(-45deg)', fontSize: 44, color: C.ink }}>!</span>
      </div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 6, alignItems: 'center' }}>
        <span style={{ fontSize: 16, color: C.ink }}>{title}</span>
        <span style={{ fontSize: 11.5, color: C.muted, lineHeight: 1.6 }}>{desc}</span>
      </div>
      <div
        className="pita-press"
        onClick={onRetry}
        {...btn.handlers}
        style={{
          cursor: 'pointer',
          width: '100%',
          background: C.ctaBg,
          color: C.ctaFg,
          borderRadius: 8,
          padding: '14px 0',
          textAlign: 'center',
          fontSize: 14,
          ...btn.style,
        }}
      >
        ↻ 再読み込み
      </div>
      {code && <span style={{ fontSize: 11, color: C.placeholder }}>エラーコード: {code}</span>}
    </div>
  )
}

/** シマー付きスケルトン矩形。 */
export function Skeleton({
  width = '100%',
  height = 12,
  radius = 4,
}: {
  width?: number | string
  height?: number
  radius?: number
}) {
  return (
    <div
      style={{
        width,
        height,
        borderRadius: radius,
        background:
          'linear-gradient(90deg,#E7E4F0 25%,#F4F2FA 50%,#E7E4F0 75%)',
        backgroundSize: '200% 100%',
        animation: 'shimmer 1.3s linear infinite',
      }}
    />
  )
}

/** 検索結果カードのスケルトン。 */
export function SkeletonCard({ dim = false }: { dim?: boolean }) {
  return (
    <div
      style={{
        background: C.white,
        border: `1.5px solid ${C.border}`,
        borderRadius: 12,
        boxShadow: `3px 3px 0 ${C.shadowCol}`,
        padding: 14,
        display: 'flex',
        flexDirection: 'column',
        gap: 11,
        opacity: dim ? 0.7 : 1,
      }}
    >
      <div style={{ display: 'flex', gap: 12, alignItems: 'center' }}>
        <Skeleton width={50} height={50} radius={8} />
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 7 }}>
          <Skeleton width="55%" height={13} />
          <Skeleton width="80%" height={10} />
        </div>
      </div>
      <div style={{ display: 'flex', gap: 6 }}>
        <Skeleton width={78} height={22} />
        <Skeleton width={64} height={22} />
      </div>
    </div>
  )
}
