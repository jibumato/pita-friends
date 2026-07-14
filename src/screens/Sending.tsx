import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen, { DotPattern } from '../components/Screen'
import StatusBar from '../components/StatusBar'

/** リング回転スピナー + 浮遊アバター。 */
function Spinner({ children }: { children: React.ReactNode }) {
  return (
    <div
      style={{
        position: 'relative',
        width: 120,
        height: 120,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
      }}
    >
      <div
        style={{ position: 'absolute', inset: 0, borderRadius: '50%', border: `3px solid ${C.deepCard}` }}
      />
      <div
        style={{
          position: 'absolute',
          inset: 0,
          borderRadius: '50%',
          border: '3px solid transparent',
          borderTopColor: C.lime,
          borderRightColor: C.lime,
          animation: 'ringSpin 1s linear infinite',
        }}
      />
      {children}
    </div>
  )
}

export default function Sending({ flow }: { flow: Flow }) {
  return (
    <Screen background={C.ink}>
      <DotPattern />
      <div style={{ position: 'relative' }}>
        <StatusBar time="21:47" dark />
      </div>
      <div
        style={{
          position: 'relative',
          flex: 1,
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          justifyContent: 'center',
          gap: 26,
          padding: '0 32px',
        }}
      >
        <Spinner>
          <div
            style={{
              width: 66,
              height: 66,
              borderRadius: 16,
              background: C.avatarAqua,
              border: `1.5px solid ${C.ink}`,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              fontSize: 26,
              color: C.ink,
              animation: 'floaty 2.4s ease-in-out infinite',
            }}
          >
            み
          </div>
        </Spinner>
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 8 }}>
          <span style={{ fontSize: 19, color: '#fff', letterSpacing: '.06em' }}>
            返事を待っています<span style={{ color: C.lime }}>…</span>
          </span>
          <span style={{ fontSize: 12, color: C.muted }}>みなと さんに誘いが届きました</span>
        </div>
        <div style={{ display: 'flex', gap: 7 }}>
          {[flow.game, flow.when].map((t) => (
            <span
              key={t}
              style={{
                fontSize: 11,
                color: C.lime,
                background: C.deepCard,
                border: `1.5px solid ${C.deepBorder}`,
                padding: '6px 12px',
                borderRadius: 4,
              }}
            >
              {t}
            </span>
          ))}
        </div>
        <div
          style={{
            width: '100%',
            background: C.deepCard,
            border: `1.5px solid ${C.deepBorder}`,
            borderRadius: 10,
            padding: '12px 14px',
            display: 'flex',
            gap: 9,
            alignItems: 'center',
          }}
        >
          <span
            style={{
              fontSize: 9,
              color: C.ink,
              background: C.lime,
              padding: '2px 7px',
              borderRadius: 4,
              flex: 'none',
            }}
          >
            TIPS
          </span>
          <span style={{ fontSize: 10.5, lineHeight: 1.6, color: C.muted }}>
            初対面はあいさつから。マナーの良さは信用スコアに積み上がります。
          </span>
        </div>
      </div>
      <div style={{ position: 'relative', padding: '0 24px 40px' }}>
        <div
          onClick={() => flow.go('profile')}
          style={{
            cursor: 'pointer',
            border: `1.5px solid ${C.deepBorder}`,
            color: C.muted,
            borderRadius: 8,
            padding: '13px 0',
            textAlign: 'center',
            fontSize: 12,
          }}
        >
          キャンセル
        </div>
      </div>
    </Screen>
  )
}
