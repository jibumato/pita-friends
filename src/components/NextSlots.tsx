import { useEffect, useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import { fetchHostSchedule, fetchPublicProfile } from '../lib/queries'

/**
 * 「次はいつ遊ぶ?」— 相手の近い順の空き枠を数個だけ出す。
 *
 * 遊び終わった直後は、また遊びたい気持ちがいちばん強い。
 * そこで「探し直してください」と突き放すと、その気持ちは翌日には消えている。
 * 押せば時間まで入った状態で予約画面に着くところまでを一続きにする。
 *
 * 出さない条件はゆるくしていない:
 *   ・相手がピタメイトとして掲載していない → 何も出さない
 *   ・空き枠がない → 何も出さない
 * 予約できない相手に「次の枠」を見せるのは、押せないボタンを置くのと同じ。
 */
export default function NextSlots({
  flow,
  hostUserId,
  hostName,
  max = 3,
}: {
  flow: Flow
  hostUserId: string
  hostName: string
  max?: number
}) {
  const [slots, setSlots] = useState<Date[]>([])
  const [host, setHost] = useState<{ initial: string; color: string; hourlyRate: number } | null>(null)

  useEffect(() => {
    let active = true
    Promise.all([fetchPublicProfile(hostUserId), fetchHostSchedule(hostUserId, 7)])
      .then(([p, rows]) => {
        if (!active || !p?.isHost) return
        setHost({ initial: p.avatarInitial, color: p.avatarColor, hourlyRate: p.hourlyRate })
        setSlots(
          rows
            .filter((r) => r.state === 'open')
            .map((r) => r.slotAt)
            .sort((a, b) => a.getTime() - b.getTime())
            .slice(0, max),
        )
      })
      // 取れなければ黙って出さない。予約への近道であって、必須の情報ではない
      .catch(() => active && setSlots([]))
    return () => {
      active = false
    }
  }, [hostUserId, max])

  if (!host || slots.length === 0) return null

  const pick = (at: Date) => {
    flow.startBooking({
      name: hostName,
      initial: host.initial,
      color: host.color,
      hourlyRate: host.hourlyRate,
      userId: hostUserId,
    })
    // startBooking は「今すぐ」で始まるので、押された枠の時刻に上書きする
    flow.setBookingWhen('scheduled')
    flow.setBookingStartAt(at)
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 8, width: '100%' }}>
      <span style={{ fontSize: 12, color: C.muted, textAlign: 'center' }}>
        {hostName}さんの あいている時間
      </span>
      <div style={{ display: 'flex', gap: 8, justifyContent: 'center', flexWrap: 'wrap' }}>
        {slots.map((at) => (
          <button
            key={at.toISOString()}
            onClick={() => pick(at)}
            style={{
              cursor: 'pointer',
              background: C.deepCard,
              border: `1.5px solid ${C.lime}`,
              borderRadius: 8,
              color: C.lime,
              fontSize: 12,
              padding: '9px 13px',
              lineHeight: 1.4,
            }}
          >
            {slotLabel(at)}
          </button>
        ))}
      </div>
    </div>
  )
}

/** 「今日 21:00」「木 22:00」。7日以内しか出ないので日付は省く。 */
function slotLabel(at: Date): string {
  const hhmm = at.toLocaleTimeString('ja-JP', { hour: '2-digit', minute: '2-digit', hour12: false })
  const days = Math.floor(
    (startOfDay(at).getTime() - startOfDay(new Date()).getTime()) / 86_400_000,
  )
  if (days === 0) return `今日 ${hhmm}`
  if (days === 1) return `明日 ${hhmm}`
  return `${'日月火水木金土'[at.getDay()]} ${hhmm}`
}

function startOfDay(d: Date): Date {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate())
}
