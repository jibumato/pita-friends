/** 周辺画面で使う小さめの共通UI(サブヘッダー / トグル / リスト行 / セクション見出し)。 */
import type { ReactNode } from 'react'
import { color as C } from '../theme/tokens'
import { ChevronLeft } from './Icon'
import { clickable, switchable } from '../hooks/clickable'

/** 戻る矢印 + タイトルのサブヘッダー。 */
export function SubHeader({ title, onBack }: { title: string; onBack?: () => void }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '12px 20px' }}>
      {onBack && (
        <div
          onClick={onBack}
          {...clickable(onBack, '戻る')}
          style={{ cursor: 'pointer', display: 'flex' }}
        >
          <ChevronLeft />
        </div>
      )}
      <span style={{ fontSize: 18, color: C.ink }}>{title}</span>
    </div>
  )
}

/** セクション小見出し。 */
export function SectionLabel({ children }: { children: ReactNode }) {
  return <span style={{ fontSize: 11.5, color: C.muted }}>{children}</span>
}

/** ネオブルータリズムのトグルスイッチ(表示専用 or onToggle 制御)。 */
export function Toggle({
  on,
  onToggle,
  label,
}: {
  on: boolean
  onToggle?: () => void
  label?: string
}) {
  return (
    <div
      onClick={onToggle}
      {...switchable(on, onToggle, label)}
      style={{
        width: 46,
        height: 26,
        borderRadius: 99,
        background: on ? C.lime : C.white,
        border: `1.5px solid ${C.border}`,
        display: 'flex',
        alignItems: 'center',
        justifyContent: on ? 'flex-end' : 'flex-start',
        padding: '0 2px',
        cursor: onToggle ? 'pointer' : 'default',
        transition: 'background .15s ease',
        flex: 'none',
      }}
    >
      <div
        style={{
          width: 20,
          height: 20,
          borderRadius: '50%',
          background: on ? C.fill : C.placeholder,
        }}
      />
    </div>
  )
}

/** 白カード内のリスト行(右側は → か任意ノード)。区切り線付き。 */
export function ListRow({
  label,
  sub,
  right,
  danger = false,
  divider = true,
  onClick,
}: {
  label: string
  sub?: string
  right?: ReactNode
  danger?: boolean
  divider?: boolean
  onClick?: () => void
}) {
  return (
    <div
      onClick={onClick}
      {...clickable(onClick, label)}
      style={{
        padding: '13px 14px',
        display: 'flex',
        justifyContent: 'space-between',
        alignItems: 'center',
        borderBottom: divider ? `1.5px solid ${C.divider}` : 'none',
        cursor: onClick ? 'pointer' : 'default',
        gap: 10,
      }}
    >
      <div style={{ display: 'flex', flexDirection: 'column', gap: 1 }}>
        <span style={{ fontSize: 13, color: danger ? '#E5484D' : C.ink }}>{label}</span>
        {sub && <span style={{ fontSize: 10, color: C.muted }}>{sub}</span>}
      </div>
      {right ?? <span style={{ color: C.placeholder }}>→</span>}
    </div>
  )
}

/** リスト行をまとめる白カード枠。 */
export function Card({ children }: { children: ReactNode }) {
  return (
    <div
      style={{
        background: C.white,
        border: `1.5px solid ${C.border}`,
        borderRadius: 12,
        overflow: 'hidden',
      }}
    >
      {children}
    </div>
  )
}
