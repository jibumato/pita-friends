/**
 * 画面の共通ラッパ。
 * - モバイル: 端末フレームいっぱいに position:absolute inset:0 + 内部スクロール(従来通り)。
 * - デスクトップ: ヒーローを含むページ全体がスクロールできるよう、絶対配置・高さ固定はせず
 *   自然な高さで流し込む(内容が長ければページごとスクロールする)。
 */
import type { CSSProperties, ReactNode } from 'react'
import { useIsMobile } from '../hooks/useMediaQuery'

export default function Screen({
  background,
  children,
  style,
}: {
  background: string
  children: ReactNode
  style?: CSSProperties
}) {
  const mobile = useIsMobile()
  return (
    <div
      style={{
        position: mobile ? 'absolute' : 'relative',
        inset: mobile ? 0 : undefined,
        minHeight: mobile ? undefined : '100%',
        background,
        display: 'flex',
        flexDirection: 'column',
        overflow: mobile ? 'hidden' : 'visible',
        animation: 'scrIn .34s ease both',
        ...style,
      }}
    >
      {children}
    </div>
  )
}

/** 濃背景画面のドットパターン(radial-gradient)。 */
export function DotPattern() {
  return (
    <div
      style={{
        position: 'absolute',
        inset: 0,
        backgroundImage: 'radial-gradient(circle,#5A5175 1.5px,transparent 1.5px)',
        backgroundSize: '22px 22px',
        opacity: 0.6,
      }}
    />
  )
}
