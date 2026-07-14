/** 画面の共通ラッパ。position:absolute inset:0 + scrIn 入場アニメ。 */
import type { CSSProperties, ReactNode } from 'react'

export default function Screen({
  background,
  children,
  style,
}: {
  background: string
  children: ReactNode
  style?: CSSProperties
}) {
  return (
    <div
      style={{
        position: 'absolute',
        inset: 0,
        background,
        display: 'flex',
        flexDirection: 'column',
        overflow: 'hidden',
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
