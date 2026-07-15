import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen, { DotPattern } from '../components/Screen'
import Avatar from '../components/Avatar'

export default function Joining({ flow: _flow }: { flow: Flow }) {
  return (
    <Screen background={C.fill}>
      <DotPattern />
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
            style={{
              position: 'absolute',
              inset: 0,
              borderRadius: '50%',
              border: `3px solid ${C.deepCard}`,
            }}
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
          <div style={{ animation: 'floaty 2.4s ease-in-out infinite' }}>
            <Avatar initial="み" color={C.avatarAqua} size={66} />
          </div>
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 8 }}>
          <span style={{ fontSize: 18, color: '#fff', letterSpacing: '.06em' }}>
            ロビーに合流しています<span style={{ color: C.lime }}>…</span>
          </span>
          <span style={{ fontSize: 12, color: C.muted }}>みなと さんはすでに待機中です</span>
        </div>
      </div>
    </Screen>
  )
}
