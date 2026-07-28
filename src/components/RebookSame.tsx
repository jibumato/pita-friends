import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import { durationLabel } from '../flow'
import type { PlayHistoryWith, ScheduleSlot } from '../lib/queries'

/**
 * 「前回と同じで予約」(0059)。
 *
 * 続けて遊ぶ相手が決まっているのに、毎回ゼロから時間と長さを選び直させていた。
 * ここが面倒だと「まあ今週はいいか」で終わる。値引きより、この摩擦を取るほうが
 * 繰り返しには効く。
 *
 * 出す時刻は「前回と同じ曜日・同じ時刻の次の回」。ただし**その枠が実際に
 * 空いているときだけ**にする。埋まっている時刻を勧めて、押した先でエラーに
 * するのは、何も出さないより悪い。
 */
export default function RebookSame({
  flow,
  history,
  host,
  schedule,
}: {
  flow: Flow
  history: PlayHistoryWith
  host: { userId: string; nickname: string; avatarInitial: string; avatarColor: string; hourlyRate: number }
  schedule: ScheduleSlot[]
}) {
  const minutes = history.lastDurationMinutes
  const prev = history.lastScheduledAt
  if (!minutes || !prev) return null

  const at = nextSameWeekdayHour(prev, schedule, minutes)
  if (!at) return null

  const go = () => {
    flow.startBooking({
      name: host.nickname,
      initial: host.avatarInitial,
      color: host.avatarColor,
      hourlyRate: host.hourlyRate,
      userId: host.userId,
    })
    flow.setBookingDuration(minutes)
    flow.setBookingWhen('scheduled')
    flow.setBookingStartAt(at)
  }

  return (
    <div
      onClick={go}
      role="button"
      tabIndex={0}
      onKeyDown={(e) => {
        if (e.key === 'Enter' || e.key === ' ') go()
      }}
      style={{
        cursor: 'pointer',
        display: 'flex',
        alignItems: 'center',
        gap: 10,
        background: C.white,
        border: `1.5px solid ${C.lime}`,
        borderRadius: 8,
        boxShadow: `2px 2px 0 ${C.shadowCol}`,
        padding: '11px 13px',
      }}
    >
      <span style={{ fontSize: 15 }}>🔁</span>
      <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 2 }}>
        <span style={{ fontSize: 12.5, color: C.ink }}>前回と同じで予約する</span>
        <span style={{ fontSize: 10.5, color: C.muted }}>
          {'日月火水木金土'[at.getDay()]}曜{at.getHours()}時 · {durationLabel(minutes)}
        </span>
      </div>
      <span style={{ fontSize: 12, color: C.lavenderText }}>›</span>
    </div>
  )
}

/**
 * 前回と同じ曜日・同じ時刻の、次に来る枠。
 * スケジュール上で open になっていて、必要な長さぶん続けて空いている場合だけ返す。
 */
function nextSameWeekdayHour(
  prev: Date,
  schedule: ScheduleSlot[],
  minutes: number,
): Date | null {
  const need = Math.ceil(minutes / 60)
  const open = new Set(
    schedule.filter((s) => s.state === 'open').map((s) => s.slotAt.getTime()),
  )
  const candidates = schedule
    .filter(
      (s) =>
        s.state === 'open' &&
        s.slotAt.getDay() === prev.getDay() &&
        s.slotAt.getHours() === prev.getHours(),
    )
    .map((s) => s.slotAt)
    .sort((a, b) => a.getTime() - b.getTime())

  for (const at of candidates) {
    // 60分より長い予約は、続く時間も空いていないと入らない
    let ok = true
    for (let i = 1; i < need; i++) {
      if (!open.has(at.getTime() + i * 3_600_000)) {
        ok = false
        break
      }
    }
    if (ok) return at
  }
  return null
}
