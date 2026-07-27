import { Fragment } from 'react'
import { color as C } from '../theme/tokens'
import { clickable } from '../hooks/clickable'

/**
 * 空き状況のタイル。1マス = 1時間(日本時間)。
 *
 * 縦に時間・横に日付を並べます。逆(縦に日付)にすると、24行あるので
 * 1画面に収まらず「一望できる」という目的が達成できません。
 * 横は7日ぶんで、狭い画面では横スクロールします。
 */
export type SlotState = 'past' | 'closed' | 'booked' | 'open'

/** 表示に使う色と説明。閲覧側と編集側で同じ語彙を使う。 */
const LOOK: Record<SlotState, { bg: string; label: string }> = {
  open: { bg: C.lime, label: '募集中' },
  booked: { bg: C.avatarPink, label: '予約済み' },
  closed: { bg: C.surface, label: '募集なし' },
  past: { bg: '#EFEFF4', label: '過去' },
}

/** 時間の行をどこから出すか。0〜23を全部出すと縦に長すぎる。 */
function hourRange(states: Map<string, SlotState>, days: Date[]): number[] {
  const used = new Set<number>()
  for (const d of days) {
    for (let h = 0; h < 24; h++) {
      const s = states.get(key(d, h))
      if (s === 'open' || s === 'booked') used.add(h)
    }
  }
  // 何も設定されていないときは、生活時間帯(10〜26時)を目安に出す
  if (used.size === 0) return Array.from({ length: 14 }, (_, i) => (10 + i) % 24)
  const min = Math.min(...used)
  const max = Math.max(...used)
  // 前後に1時間ずつ余白を持たせて、隣を埋められるようにする
  const from = Math.max(0, min - 1)
  const to = Math.min(23, max + 1)
  return Array.from({ length: to - from + 1 }, (_, i) => from + i)
}

function key(day: Date, hour: number): string {
  return `${day.getFullYear()}-${day.getMonth()}-${day.getDate()}-${hour}`
}

const WD = ['日', '月', '火', '水', '木', '金', '土']

export type ScheduleGridProps = {
  /** 表示する日(先頭が今日) */
  days: Date[]
  /** 各マスの状態。key(day, hour) で引ける形 */
  states: Map<string, SlotState>
  /** タップできる場合の処理(編集モード) */
  onToggle?: (day: Date, hour: number) => void
  /** 凡例を出すか */
  legend?: boolean
}

export function slotKey(day: Date, hour: number): string {
  return key(day, hour)
}

/**
 * サーバから来た1時間ごとの配列を、グリッドが使う形に組み替える。
 * 端末のタイムゾーンで日付・時を取るので、日本にいる利用者には
 * サーバ側(Asia/Tokyo)の判定と一致する。
 */
export function buildScheduleView(slots: { slotAt: Date; state: SlotState }[]): {
  days: Date[]
  states: Map<string, SlotState>
} {
  const states = new Map<string, SlotState>()
  const dayKeys: string[] = []
  const days: Date[] = []
  for (const s of slots) {
    const d = new Date(s.slotAt.getFullYear(), s.slotAt.getMonth(), s.slotAt.getDate())
    const dk = d.toDateString()
    if (!dayKeys.includes(dk)) {
      dayKeys.push(dk)
      days.push(d)
    }
    states.set(key(d, s.slotAt.getHours()), s.state)
  }
  return { days, states }
}

export default function ScheduleGrid({ days, states, onToggle, legend = true }: ScheduleGridProps) {
  const hours = hourRange(states, days)
  const editable = typeof onToggle === 'function'

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
      <div className="pita-scroll" style={{ overflowX: 'auto', paddingBottom: 2 }}>
        <div
          style={{
            display: 'grid',
            // 先頭列は時間の見出し
            gridTemplateColumns: `34px repeat(${days.length}, minmax(38px, 1fr))`,
            gap: 3,
            minWidth: 34 + days.length * 41,
          }}
        >
          {/* 見出しの行 */}
          <span />
          {days.map((d) => (
            <span
              key={d.toISOString()}
              style={{
                fontSize: 10,
                color: d.getDay() === 0 ? C.avatarOrange : d.getDay() === 6 ? C.avatarAqua : C.muted,
                textAlign: 'center',
                lineHeight: 1.3,
              }}
            >
              {d.getMonth() + 1}/{d.getDate()}
              <br />
              {WD[d.getDay()]}
            </span>
          ))}

          {hours.map((h) => (
            <Fragment key={`row-${h}`}>
              <span
                style={{
                  fontSize: 10,
                  color: C.muted,
                  textAlign: 'right',
                  paddingRight: 2,
                  alignSelf: 'center',
                  fontVariantNumeric: 'tabular-nums',
                }}
              >
                {h}時
              </span>
              {days.map((d) => {
                const state = states.get(key(d, h)) ?? 'closed'
                const look = LOOK[state]
                const tappable = editable && state !== 'past' && state !== 'booked'
                const label = `${d.getMonth() + 1}/${d.getDate()} ${h}時 ${look.label}`
                return (
                  <span
                    key={`${key(d, h)}`}
                    onClick={tappable ? () => onToggle?.(d, h) : undefined}
                    {...(tappable ? clickable(() => onToggle?.(d, h), label) : {})}
                    aria-label={label}
                    style={{
                      height: 22,
                      borderRadius: 4,
                      background: look.bg,
                      border: `1px solid ${state === 'closed' || state === 'past' ? C.border : C.ink}`,
                      cursor: tappable ? 'pointer' : 'default',
                      opacity: state === 'past' ? 0.45 : 1,
                    }}
                  />
                )
              })}
            </Fragment>
          ))}
        </div>
      </div>

      {legend && (
        <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap' }}>
          {(['open', 'booked', 'closed'] as SlotState[]).map((s) => (
            <span key={s} style={{ display: 'flex', alignItems: 'center', gap: 4, fontSize: 10, color: C.muted }}>
              <span
                style={{
                  width: 12,
                  height: 12,
                  borderRadius: 3,
                  background: LOOK[s].bg,
                  border: `1px solid ${s === 'closed' ? C.border : C.ink}`,
                }}
              />
              {LOOK[s].label}
            </span>
          ))}
        </div>
      )}
    </div>
  )
}
