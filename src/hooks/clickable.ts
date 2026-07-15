import type { KeyboardEvent } from 'react'

/**
 * onClick を持つ非ボタン要素(div/span)にキーボード操作とセマンティクスを付与。
 * Enter / Space で発火し、role="button" とフォーカス可能な tabIndex を返す。
 */
export function clickable(onClick?: () => void, label?: string) {
  if (!onClick) return {}
  return {
    role: 'button' as const,
    tabIndex: 0,
    'aria-label': label,
    onKeyDown: (e: KeyboardEvent) => {
      if (e.key === 'Enter' || e.key === ' ') {
        e.preventDefault()
        onClick()
      }
    },
  }
}

/** トグルスイッチ用(role="switch" + aria-checked)。 */
export function switchable(on: boolean, onToggle?: () => void, label?: string) {
  if (!onToggle) return { role: 'switch' as const, 'aria-checked': on }
  return {
    role: 'switch' as const,
    'aria-checked': on,
    tabIndex: 0,
    'aria-label': label,
    onKeyDown: (e: KeyboardEvent) => {
      if (e.key === 'Enter' || e.key === ' ') {
        e.preventDefault()
        onToggle()
      }
    },
  }
}
