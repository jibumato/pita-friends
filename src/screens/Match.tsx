import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { SwapArrows } from '../components/Icon'
import { usePress } from '../hooks/usePress'

export default function Match({ flow }: { flow: Flow }) {
  const cta = usePress(`3px 3px 0 ${C.ink}`)
  return (
    <Screen background={C.lavender} style={{ animation: 'scrIn .3s ease both' }}>
      {/* ストライプ地 */}
      <div
        style={{
          position: 'absolute',
          inset: 0,
          backgroundImage:
            'repeating-linear-gradient(-45deg,rgba(255,255,255,.06) 0 14px,transparent 14px 28px)',
        }}
      />
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
        <span style={{ fontSize: 12, color: C.lavenderText, letterSpacing: '.06em' }}>
          みなと さんが承諾しました！
        </span>
        <span
          style={{
            fontSize: 38,
            color: C.lime,
            letterSpacing: '.04em',
            textShadow: `4px 4px 0 ${C.ink}`,
            textAlign: 'center',
            lineHeight: 1.1,
            animation: 'popIn .55s cubic-bezier(.2,1.3,.4,1) both',
          }}
        >
          MATCH
          <br />
          FOUND!
        </span>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 6 }}>
            <div
              style={{
                width: 72,
                height: 72,
                borderRadius: 16,
                background: C.avatarOrange,
                border: `2px solid ${C.ink}`,
                boxShadow: `4px 4px 0 ${C.ink}`,
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                fontSize: 30,
                color: C.ink,
              }}
            >
              ユ
            </div>
            <span style={{ fontSize: 12, color: '#fff' }}>ユウキ</span>
          </div>
          <div
            style={{
              display: 'flex',
              flexDirection: 'column',
              alignItems: 'center',
              padding: '0 4px 20px',
            }}
          >
            <div
              style={{
                width: 44,
                height: 44,
                borderRadius: '50%',
                background: C.ink,
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
              }}
            >
              <SwapArrows />
            </div>
          </div>
          <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 6 }}>
            <div
              style={{
                width: 72,
                height: 72,
                borderRadius: 16,
                background: C.avatarAqua,
                border: `2px solid ${C.ink}`,
                boxShadow: `4px 4px 0 ${C.ink}`,
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                fontSize: 30,
                color: C.ink,
              }}
            >
              み
            </div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 4 }}>
              <span style={{ fontSize: 12, color: '#fff' }}>みなと</span>
              <span
                style={{
                  fontSize: 8,
                  color: C.ink,
                  background: C.lime,
                  padding: '1px 5px',
                  borderRadius: 4,
                }}
              >
                ✓
              </span>
            </div>
          </div>
        </div>
        <div
          style={{
            background: C.ink,
            border: `2px solid ${C.lime}`,
            borderRadius: 16,
            padding: '14px 28px',
            display: 'flex',
            flexDirection: 'column',
            alignItems: 'center',
            gap: 2,
            animation: 'popIn .55s .1s cubic-bezier(.2,1.3,.4,1) both',
          }}
        >
          <span style={{ fontSize: 42, color: C.lime, lineHeight: 1 }}>{flow.score}%</span>
          <span style={{ fontSize: 11, color: C.muted, letterSpacing: '.1em' }}>相性 SCORE</span>
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
          onClick={() => flow.go('party')}
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
          パーティを組む ▶
        </div>
        <span
          onClick={() => flow.go('home')}
          style={{ cursor: 'pointer', textAlign: 'center', fontSize: 12, color: C.lavenderText }}
        >
          ほかの候補も見る
        </span>
      </div>
    </Screen>
  )
}
