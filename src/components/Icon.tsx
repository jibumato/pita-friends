/**
 * インライン SVG アイコン集(stroke ベース, stroke-width 2.2〜2.6, linecap round)。
 * ハンドオフのコアフロープロトで使われている字形をそのまま移植。依存ライブラリなし。
 */
import type { CSSProperties } from 'react'

type IconProps = {
  size?: number
  color?: string
  strokeWidth?: number
  style?: CSSProperties
}

// stroke は currentColor 経由で解決(CSS変数を確実に反映するため色は style で指定)
function base(size: number, color: string, sw: number, style?: CSSProperties) {
  return {
    width: size,
    height: size,
    viewBox: '0 0 24 24',
    fill: 'none',
    stroke: 'currentColor',
    strokeWidth: sw,
    strokeLinecap: 'round' as const,
    strokeLinejoin: 'round' as const,
    style: { color, ...style },
  }
}

export function ChevronLeft({ size = 20, color = '#453D5C', strokeWidth = 2.6, style }: IconProps) {
  return (
    <svg {...base(size, color, strokeWidth, style)}>
      <path d="M15 5 L8 12 L15 19" />
    </svg>
  )
}

export function Bell({ size = 18, color = '#453D5C', strokeWidth = 2.2, style }: IconProps) {
  return (
    <svg {...base(size, color, strokeWidth, style)}>
      <path d="M6 9a6 6 0 0 1 12 0c0 5 2 6 2 6H4s2-1 2-6" />
      <path d="M10 19a2 2 0 0 0 4 0" />
    </svg>
  )
}

export function Home({ size = 22, color = '#A78BDF', strokeWidth = 2.6, style }: IconProps) {
  return (
    <svg {...base(size, color, strokeWidth, style)}>
      <path d="M3 11 L12 4 L21 11 V20 H3 Z" />
    </svg>
  )
}

export function Search({ size = 22, color = '#B9B3CC', strokeWidth = 2.6, style }: IconProps) {
  return (
    <svg {...base(size, color, strokeWidth, style)}>
      <circle cx="11" cy="11" r="7" />
      <path d="M16.5 16.5 L21 21" />
    </svg>
  )
}

export function PlusCircle({ size = 22, color = '#B9B3CC', strokeWidth = 2.6, style }: IconProps) {
  return (
    <svg {...base(size, color, strokeWidth, style)}>
      <circle cx="12" cy="12" r="9" />
      <path d="M12 8v8M8 12h8" />
    </svg>
  )
}

export function Chat({ size = 22, color = '#B9B3CC', strokeWidth = 2.6, style }: IconProps) {
  return (
    <svg {...base(size, color, strokeWidth, style)}>
      <rect x="3" y="5" width="18" height="13" rx="4" />
      <path d="M8 21 L10 18" />
    </svg>
  )
}

export function User({ size = 22, color = '#B9B3CC', strokeWidth = 2.6, style }: IconProps) {
  return (
    <svg {...base(size, color, strokeWidth, style)}>
      <circle cx="12" cy="8" r="4" />
      <path d="M4 20c1.5-4 6-5 8-5s6.5 1 8 5" />
    </svg>
  )
}

export function Shield({ size = 14, color = '#A78BDF', strokeWidth = 2.4, style }: IconProps) {
  return (
    <svg {...base(size, color, strokeWidth, style)}>
      <path d="M12 3 L20 6 V11 C20 16 17 19.5 12 21 C7 19.5 4 16 4 11 V6 Z" />
    </svg>
  )
}

export function Heart({ size = 19, color = '#453D5C', strokeWidth = 2.2, style }: IconProps) {
  return (
    <svg {...base(size, color, strokeWidth, style)}>
      <path d="M12 21 C7 16 3 13 3 8.5 A4.5 4.5 0 0 1 12 6 A4.5 4.5 0 0 1 21 8.5 C21 13 17 16 12 21 Z" />
    </svg>
  )
}

export function Phone({ size = 17, color = '#453D5C', strokeWidth = 2.2, style }: IconProps) {
  return (
    <svg {...base(size, color, strokeWidth, style)}>
      <path d="M5 4 H9 L11 9 L8.5 10.5 A11 11 0 0 0 13.5 15.5 L15 13 L20 15 V19 A2 2 0 0 1 18 21 A16 16 0 0 1 3 6 A2 2 0 0 1 5 4 Z" />
    </svg>
  )
}

export function Send({ size = 17, color = '#E4F0A0', strokeWidth = 2.4, style }: IconProps) {
  return (
    <svg {...base(size, color, strokeWidth, style)}>
      <path d="M4 12 L20 4 L14 20 L11 13 Z" />
    </svg>
  )
}

export function Upload({ size = 14, color = '#E4F0A0', strokeWidth = 2.4, style }: IconProps) {
  return (
    <svg {...base(size, color, strokeWidth, style)}>
      <path d="M4 20h16" />
      <path d="M12 4v11M7 10l5 5 5-5" />
    </svg>
  )
}

/** 双方向矢印(MATCH FOUND のユーザー間) */
export function SwapArrows({ size = 22, color = '#E4F0A0', strokeWidth = 2.6, style }: IconProps) {
  return (
    <svg {...base(size, color, strokeWidth, style)}>
      <path d="M4 12h16M14 6l6 6-6 6" />
      <path d="M20 12H4M10 18l-6-6 6-6" />
    </svg>
  )
}

/** 右向き矢印(RESULT のスコア上昇) */
export function ArrowRight({ size = 22, color = '#E4F0A0', strokeWidth = 2.6, style }: IconProps) {
  return (
    <svg {...base(size, color, strokeWidth, style)}>
      <path d="M4 12h16M14 6l6 6-6 6" />
    </svg>
  )
}

export function Plus({ size = 15, color = '#453D5C', strokeWidth = 3, style }: IconProps) {
  return (
    <svg {...base(size, color, strokeWidth, style)}>
      <path d="M12 5v14M5 12h14" />
    </svg>
  )
}

export function ChevronDown({ size = 14, color = '#453D5C', strokeWidth = 2.6, style }: IconProps) {
  return (
    <svg {...base(size, color, strokeWidth, style)}>
      <path d="M6 9 L12 15 L18 9" />
    </svg>
  )
}

export function Moon({ size = 34, color = '#5A5272', strokeWidth = 2.2, style }: IconProps) {
  return (
    <svg {...base(size, color, strokeWidth, style)}>
      <path d="M18 15a6 6 0 0 1-8-8 7 7 0 1 0 8 8Z" />
    </svg>
  )
}

export function MoonSmall({ size = 17, color = '#453D5C', strokeWidth = 2.2, style }: IconProps) {
  return (
    <svg {...base(size, color, strokeWidth, style)}>
      <path d="M20 13 A8 8 0 1 1 11 4 A7 7 0 0 0 20 13 Z" />
    </svg>
  )
}

export function Sun({ size = 17, color = '#E4F0A0', strokeWidth = 2.2, style }: IconProps) {
  return (
    <svg {...base(size, color, strokeWidth, style)}>
      <circle cx="12" cy="12" r="5" />
      <path d="M12 2v3M12 19v3M2 12h3M19 12h3M4.5 4.5l2 2M17.5 17.5l2 2M19.5 4.5l-2 2M6.5 17.5l-2 2" />
    </svg>
  )
}

export function Coin({ size = 17, color = '#453D5C', strokeWidth = 2.2, style }: IconProps) {
  return (
    <svg {...base(size, color, strokeWidth, style)}>
      <circle cx="12" cy="12" r="9" />
      <path d="M9.5 15.5c0 1 1 1.5 2.5 1.5s2.5-.6 2.5-1.6c0-2.4-5-1-5-3.4 0-1 1-1.6 2.5-1.6s2.5.5 2.5 1.5" />
      <path d="M12 7v1.3M12 15.7V17" />
    </svg>
  )
}

export function Clock({ size = 16, color = '#453D5C', strokeWidth = 2.2, style }: IconProps) {
  return (
    <svg {...base(size, color, strokeWidth, style)}>
      <circle cx="12" cy="12" r="9" />
      <path d="M12 7v5l3.5 2" />
    </svg>
  )
}

/** 横三点(メニュー) */
export function DotsHorizontal({ size = 20, color = '#fff', style }: IconProps) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="currentColor"
      style={{ color, ...style }}
    >
      <circle cx="5" cy="12" r="1.8" />
      <circle cx="12" cy="12" r="1.8" />
      <circle cx="19" cy="12" r="1.8" />
    </svg>
  )
}
