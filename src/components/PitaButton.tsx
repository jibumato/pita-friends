/**
 * PitaButton — ネオブルータリズムの主要ボタン。
 * variant: primary(黒地に紫影) / confirm(ライム地に黒影) / secondary(白地) / disabled。
 * full で block 化。ホバー/押下で押し込み。
 */
import type { ReactNode } from 'react'
import { color as C } from '../theme/tokens'
import { usePress } from '../hooks/usePress'

export type PitaVariant = 'primary' | 'confirm' | 'secondary' | 'disabled'

type PitaButtonProps = {
  label?: ReactNode
  variant?: PitaVariant
  full?: boolean
  onClick?: () => void
}

const variantMap: Record<PitaVariant, { bg: string; fg: string; border: string; shadow: string }> =
  {
    primary: { bg: C.ctaBg, fg: C.ctaFg, border: C.ctaBg, shadow: `3px 3px 0 ${C.lavender}` },
    confirm: { bg: C.lime, fg: C.ink, border: C.border, shadow: `3px 3px 0 ${C.shadowCol}` },
    secondary: { bg: C.white, fg: C.ink, border: C.border, shadow: `2px 2px 0 ${C.shadowCol}` },
    disabled: {
      bg: C.disabledBg,
      fg: C.disabledFg,
      border: C.disabledBorder,
      shadow: 'none',
    },
  }

export default function PitaButton({
  label = 'ボタン',
  variant = 'primary',
  full = false,
  onClick,
}: PitaButtonProps) {
  const s = variantMap[variant] ?? variantMap.primary
  const enabled = variant !== 'disabled'
  const { style: pressStyle, handlers } = usePress(s.shadow)

  return (
    <div
      className="pita-press"
      onClick={enabled ? onClick : undefined}
      {...(enabled ? handlers : {})}
      style={{
        display: full ? 'block' : 'inline-block',
        fontFamily: "'DotGothic16', monospace",
        background: s.bg,
        color: s.fg,
        border: `1.5px solid ${s.border}`,
        borderRadius: 8,
        padding: '13px 22px',
        textAlign: 'center',
        fontSize: 14,
        cursor: enabled ? 'pointer' : 'not-allowed',
        userSelect: 'none',
        boxSizing: 'border-box',
        ...pressStyle,
      }}
    >
      {label}
    </div>
  )
}
