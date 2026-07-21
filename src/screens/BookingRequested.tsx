import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import PitaButton from '../components/PitaButton'
import { Shield } from '../components/Icon'

/** 予約リクエスト送信後、ホストの承諾を待つ画面(バックエンド予約フロー)。 */
export default function BookingRequested({ flow }: { flow: Flow }) {
  const host = flow.bookingHost
  return (
    <Screen background={C.surface}>
      <StatusBar time="21:48" />
      <div
        className="pita-scroll"
        style={{
          flex: 1,
          overflowY: 'auto',
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          justifyContent: 'center',
          padding: '24px',
          gap: 18,
          textAlign: 'center',
        }}
      >
        <div
          style={{
            width: 84,
            height: 84,
            borderRadius: 20,
            background: C.lime,
            border: `2px solid ${C.border}`,
            boxShadow: `4px 4px 0 ${C.shadowCol}`,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            fontSize: 40,
          }}
        >
          📨
        </div>
        <span style={{ fontSize: 20, color: C.ink }}>リクエストを送信しました</span>
        <span style={{ fontSize: 12.5, color: C.body, lineHeight: 1.8 }}>
          {host ? `${host.name}さん` : 'ホスト'}が承諾すると、トークが開いて予約が成立します。
          <br />
          コインは確保されています。辞退・24時間の無応答のときは
          <br />
          全額返却されます。
        </span>

        <div
          style={{
            width: '100%',
            background: C.surfaceLavender,
            border: `1.5px solid ${C.lavender}`,
            borderRadius: 8,
            padding: '10px 12px',
            display: 'flex',
            gap: 8,
            alignItems: 'flex-start',
          }}
        >
          <Shield style={{ flex: 'none', marginTop: 1 }} />
          <span style={{ fontSize: 10.5, lineHeight: 1.6, color: C.body, textAlign: 'left' }}>
            承諾されるまで、相手にトークや連絡先は開きません。結果は通知でお知らせします。
          </span>
        </div>
      </div>
      <div style={{ padding: '12px 24px 30px', background: C.white, borderTop: `1.5px solid ${C.border}`, display: 'flex', flexDirection: 'column', gap: 10 }}>
        <PitaButton label="ホームに戻る ▶" variant="primary" full onClick={() => flow.go('home')} />
        <span
          onClick={() => flow.go('notifications')}
          style={{ cursor: 'pointer', textAlign: 'center', fontSize: 12, color: C.lavenderText }}
        >
          通知を見る
        </span>
      </div>
    </Screen>
  )
}
