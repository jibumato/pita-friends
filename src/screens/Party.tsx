import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen, { DotPattern } from '../components/Screen'
import StatusBar from '../components/StatusBar'
import Confetti from '../components/Confetti'
import { usePress } from '../hooks/usePress'

const MEMBERS = [
  { initial: 'ユ', color: C.avatarOrange, size: 60, mx: 0, z: 1 },
  { initial: 'み', color: C.avatarAqua, size: 70, mx: -6, z: 2 },
  { initial: 'る', color: C.avatarPink, size: 60, mx: 0, z: 1 },
]

export default function Party({ flow }: { flow: Flow }) {
  const cta = usePress(`3px 3px 0 ${C.lavender}`)
  return (
    <Screen background={C.fill} style={{ animation: 'scrIn .3s ease both' }}>
      <DotPattern />
      <Confetti />
      <div style={{ position: 'relative' }}>
        <StatusBar time="21:48" dark />
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
        <span
          style={{
            fontSize: 15,
            color: C.lavender,
            letterSpacing: '.2em',
            animation: 'popIn .5s cubic-bezier(.2,1.3,.4,1) both',
          }}
        >
          ▶ PARTY成立!
        </span>
        <div style={{ display: 'flex', alignItems: 'flex-end' }}>
          {MEMBERS.map((m, i) => (
            <div
              key={i}
              style={{
                width: m.size,
                height: m.size,
                borderRadius: 14,
                background: m.color,
                border: `2px solid ${C.border}`,
                boxShadow: `3px 3px 0 ${C.lavender}`,
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                fontSize: Math.round(m.size * 0.4),
                color: C.ink,
                margin: `0 ${m.mx}px`,
                zIndex: m.z,
              }}
            >
              {m.initial}
            </div>
          ))}
        </div>
        <div
          style={{
            background: C.deepCard,
            border: `2px solid ${C.deepBorder}`,
            borderRadius: 16,
            padding: 20,
            display: 'flex',
            flexDirection: 'column',
            gap: 14,
            width: '100%',
          }}
        >
          <div
            style={{ display: 'flex', flexDirection: 'column', gap: 5, alignItems: 'center' }}
          >
            <span style={{ fontSize: 11, color: C.muted, letterSpacing: '.1em' }}>
              ▶ 次のクエスト
            </span>
            <span style={{ fontSize: 20, color: '#fff', textAlign: 'center' }}>
              {flow.game} ランクマッチ
            </span>
            <span style={{ fontSize: 13, color: C.lime }}>{flow.when} · PARTY 3/3</span>
          </div>
          <div style={{ height: 1.5, background: C.deepBorder }} />
          <div
            style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 4 }}
          >
            <span style={{ fontSize: 10, color: C.muted }}>クエスト開始まで</span>
            <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
              <TimeBox value="00" unit="時間" />
              <span style={{ fontSize: 20, color: C.lime }}>:</span>
              <TimeBox value="38" unit="分" />
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
        <div
          className="pita-press"
          onClick={() => flow.go('talk')}
          {...cta.handlers}
          style={{
            cursor: 'pointer',
            background: C.lime,
            color: C.ink,
            borderRadius: 8,
            padding: '15px 0',
            textAlign: 'center',
            fontSize: 15,
            ...cta.style,
          }}
        >
          トークルームへ ▶
        </div>
        <span style={{ textAlign: 'center', fontSize: 12, color: C.muted }}>
          開始15分前にリマインドします
        </span>
      </div>
    </Screen>
  )
}

function TimeBox({ value, unit }: { value: string; unit: string }) {
  return (
    <div
      style={{
        background: C.fill,
        border: `1.5px solid ${C.lime}`,
        borderRadius: 8,
        padding: '8px 12px',
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
      }}
    >
      <span style={{ fontSize: 24, color: C.lime }}>{value}</span>
      <span style={{ fontSize: 8, color: '#5A5272' }}>{unit}</span>
    </div>
  )
}
