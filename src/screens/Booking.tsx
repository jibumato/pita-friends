import { useEffect } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { SubHeader } from '../components/Ui'
import { Coin, Clock, Shield } from '../components/Icon'
import { BOOKING_DURATIONS, coinsForDuration, durationLabel } from '../flow'
import { usePress } from '../hooks/usePress'

export default function Booking({ flow }: { flow: Flow }) {
  const host = flow.bookingHost
  const confirm = usePress(`3px 3px 0 ${C.lavender}`)

  useEffect(() => {
    // 直接遷移してきた等、ホスト未指定の場合は安全にさがすへ戻す
    if (!host) flow.go('search')
  }, [host, flow])

  if (!host) return null

  const cost = coinsForDuration(host.hourlyRate, flow.bookingDuration)
  const short = flow.bookingInsufficient

  return (
    <Screen background={C.surface}>
      <StatusBar time="21:47" />
      <SubHeader title="予約する" onBack={() => flow.go('search')} />
      <div
        className="pita-scroll"
        style={{
          flex: 1,
          overflowY: 'auto',
          padding: '4px 20px 0',
          display: 'flex',
          flexDirection: 'column',
          gap: 16,
        }}
      >
        {/* 相手 */}
        <div
          style={{
            background: C.white,
            border: `1.5px solid ${C.border}`,
            borderRadius: 12,
            boxShadow: `3px 3px 0 ${C.shadowCol}`,
            padding: 14,
            display: 'flex',
            alignItems: 'center',
            gap: 12,
          }}
        >
          <div
            style={{
              width: 48,
              height: 48,
              borderRadius: 10,
              background: host.color,
              border: `1.5px solid ${C.border}`,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              fontSize: 20,
              color: C.ink,
            }}
          >
            {host.initial}
          </div>
          <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 2 }}>
            <span style={{ fontSize: 15, color: C.ink }}>{host.name}</span>
            <span style={{ fontSize: 10.5, color: C.muted }}>1時間 {host.hourlyRate} コイン</span>
          </div>
        </div>

        {/* 時間選択 */}
        <span style={{ fontSize: 12, color: C.muted }}>あそぶ時間</span>
        <div style={{ display: 'flex', gap: 6 }}>
          {BOOKING_DURATIONS.map((min) => {
            const sel = flow.bookingDuration === min
            return (
              <span
                key={min}
                onClick={() => flow.setBookingDuration(min)}
                style={{
                  flex: 1,
                  textAlign: 'center',
                  cursor: 'pointer',
                  fontSize: 13,
                  color: sel ? C.lime : C.ink,
                  background: sel ? C.fill : C.white,
                  border: `1.5px solid ${C.border}`,
                  padding: '11px 0',
                  borderRadius: 8,
                }}
              >
                {durationLabel(min)}
              </span>
            )
          })}
        </div>

        {/* 料金サマリー */}
        <div
          style={{
            background: C.lavender,
            border: `1.5px solid ${C.border}`,
            borderRadius: 12,
            boxShadow: `4px 4px 0 ${C.shadowCol}`,
            padding: 16,
            display: 'flex',
            flexDirection: 'column',
            gap: 10,
          }}
        >
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <Clock size={15} color="#fff" />
            <span style={{ fontSize: 12, color: '#fff' }}>{durationLabel(flow.bookingDuration)}の予約</span>
          </div>
          <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between' }}>
            <span style={{ fontSize: 11, color: '#E3DCFF' }}>消費コイン</span>
            <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
              <Coin size={18} color={C.lime} />
              <span style={{ fontSize: 24, color: C.lime }}>{cost}</span>
            </div>
          </div>
          <div style={{ height: 1.5, background: 'rgba(255,255,255,.3)' }} />
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
            <span style={{ fontSize: 11, color: '#E3DCFF' }}>あなたの残高</span>
            <span style={{ fontSize: 13, color: '#fff' }}>{flow.coinBalance} コイン</span>
          </div>
        </div>

        {short && (
          <div
            style={{
              background: C.avatarPink,
              border: `1.5px solid ${C.border}`,
              borderRadius: 8,
              padding: '11px 13px',
              display: 'flex',
              flexDirection: 'column',
              gap: 8,
            }}
          >
            <span style={{ fontSize: 12, color: C.ink }}>
              コインが不足しています(あと{cost - flow.coinBalance}コイン必要)
            </span>
            <span
              onClick={() => flow.go('wallet')}
              style={{
                cursor: 'pointer',
                fontSize: 12,
                color: C.ctaFg,
                background: C.ctaBg,
                textAlign: 'center',
                padding: '9px 0',
                borderRadius: 6,
              }}
            >
              コインをチャージする ▶
            </span>
          </div>
        )}

        {flow.bookingError && (
          <div
            style={{
              background: C.avatarPink,
              border: `1.5px solid ${C.border}`,
              borderRadius: 8,
              padding: '11px 13px',
              fontSize: 12,
              color: C.ink,
            }}
          >
            {flow.bookingError}
          </div>
        )}

        <div
          style={{
            background: C.surfaceLavender,
            border: `1.5px solid ${C.lavender}`,
            borderRadius: 8,
            padding: '11px 13px',
            display: 'flex',
            gap: 8,
            alignItems: 'flex-start',
          }}
        >
          <Shield size={14} style={{ flex: 'none', marginTop: 1 }} />
          <span style={{ fontSize: 10.5, lineHeight: 1.7, color: C.body }}>
            コインは予約確定時に消費されます。
            <br />
            ・<b style={{ color: C.ink }}>ホスト都合</b>のキャンセル・無断欠席 → コインを<b style={{ color: C.ink }}>全額再付与</b>
            <br />
            ・<b style={{ color: C.ink }}>あなたの都合</b>のキャンセル → 開始1時間前まで全額再付与
            <br />
            　（開始1時間を切ってからは再付与されず、コインはホストの報酬になります）
            <br />
            トラブル時はいつでも通報・相談ができます。
          </span>
        </div>

        <div
          onClick={() => flow.openReport({ userId: host.userId ?? null, nickname: host.name })}
          style={{
            cursor: 'pointer',
            textAlign: 'center',
            fontSize: 11.5,
            color: C.muted,
            textDecoration: 'underline',
            padding: '2px 0 6px',
          }}
        >
          {host.name} さんを通報・ブロックする
        </div>
      </div>
      <div style={{ padding: '12px 20px 26px', background: C.white, borderTop: `1.5px solid ${C.border}` }}>
        <div
          className="pita-press"
          onClick={flow.confirmBooking}
          {...confirm.handlers}
          style={{
            cursor: 'pointer',
            background: C.ctaBg,
            color: C.ctaFg,
            borderRadius: 8,
            padding: '14px 0',
            textAlign: 'center',
            fontSize: 14,
            ...confirm.style,
          }}
        >
          {cost} コインで予約を確定 ▶
        </div>
      </div>
    </Screen>
  )
}
