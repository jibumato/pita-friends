import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen, { DotPattern } from '../components/Screen'
import StatusBar from '../components/StatusBar'
import Avatar from '../components/Avatar'
import PitaButton from '../components/PitaButton'

export default function Reminder({ flow }: { flow: Flow }) {
  return (
    <Screen background={C.ink}>
      <DotPattern />
      <div style={{ position: 'relative' }}>
        <StatusBar time="21:58" dark />
      </div>
      <div
        style={{
          position: 'relative',
          flex: 1,
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          justifyContent: 'center',
          gap: 22,
          padding: '0 30px',
        }}
      >
        <span style={{ fontSize: 12, color: C.lime, letterSpacing: '.1em' }}>
          🔔 まもなく約束の時間です
        </span>
        <div style={{ display: 'flex', alignItems: 'flex-end', gap: 2 }}>
          <Avatar initial="ユ" color={C.avatarOrange} size={56} />
          <Avatar initial="み" color={C.avatarAqua} size={66} verified />
        </div>
        <div
          style={{
            background: C.deepCard,
            border: `2px solid ${C.deepBorder}`,
            borderRadius: 16,
            padding: 20,
            display: 'flex',
            flexDirection: 'column',
            gap: 12,
            width: '100%',
          }}
        >
          <div style={{ display: 'flex', flexDirection: 'column', gap: 4, alignItems: 'center' }}>
            <span style={{ fontSize: 11, color: C.muted }}>▶ 今夜のクエスト</span>
            <span style={{ fontSize: 18, color: '#fff', textAlign: 'center' }}>
              {flow.game} ランクマッチ
            </span>
            <span style={{ fontSize: 12, color: C.lime }}>{flow.when} · PARTY 2/2</span>
          </div>
          <div style={{ height: 1.5, background: C.deepBorder }} />
          <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 4 }}>
            <span style={{ fontSize: 10, color: C.muted }}>開始まで</span>
            <div
              style={{
                background: C.ink,
                border: `1.5px solid ${C.lime}`,
                borderRadius: 8,
                padding: '8px 16px',
                display: 'flex',
                alignItems: 'baseline',
                gap: 4,
              }}
            >
              <span style={{ fontSize: 30, color: C.lime }}>02</span>
              <span style={{ fontSize: 12, color: '#5A5272' }}>分</span>
            </div>
          </div>
        </div>
      </div>
      <div
        style={{
          position: 'relative',
          display: 'flex',
          flexDirection: 'column',
          gap: 10,
          padding: '0 24px 40px',
        }}
      >
        <PitaButton label="合流する ▶" variant="confirm" full onClick={flow.goJoin} />
        <span style={{ textAlign: 'center', fontSize: 11, color: C.muted }}>
          遅れそうなときはトークで一言伝えましょう
        </span>
      </div>
    </Screen>
  )
}
