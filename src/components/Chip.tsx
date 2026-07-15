/**
 * Chip — 選択トグルチップ。選択=黒地ライム文字 / 非選択=白地。
 * 制御(selected + onToggle 指定)/ 非制御(内部 state)両対応。
 */
import { useState } from 'react'
import { color as C } from '../theme/tokens'

type ChipProps = {
  label?: string
  selected?: boolean
  onToggle?: () => void
}

export default function Chip({ label = 'Apex', selected, onToggle }: ChipProps) {
  const [internal, setInternal] = useState(false)
  const controlled = selected !== undefined
  const sel = controlled ? selected : internal

  return (
    <span
      onClick={() => {
        if (onToggle) onToggle()
        if (!controlled) setInternal((v) => !v)
      }}
      style={{
        display: 'inline-block',
        fontFamily: "'DotGothic16', monospace",
        fontSize: 12,
        color: sel ? C.lime : C.ink,
        background: sel ? C.fill : C.white,
        border: `1.5px solid ${C.border}`,
        padding: '7px 13px',
        borderRadius: 4,
        cursor: 'pointer',
        userSelect: 'none',
      }}
    >
      {label}
    </span>
  )
}
