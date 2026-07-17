import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen, { DotPattern } from '../components/Screen'
import { usePress } from '../hooks/usePress'
import { isBackendConfigured } from '../lib/supabase'

export default function Welcome({ flow }: { flow: Flow }) {
  const start = usePress(`3px 3px 0 ${C.lavender}`)
  return (
    <Screen background={C.fill} style={{ animation: 'scrIn .34s ease both' }}>
      <DotPattern />
      <div
        style={{
          position: 'relative',
          flex: 1,
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          justifyContent: 'center',
          gap: 22,
          padding: '0 34px',
        }}
      >
        <div
          style={{
            width: 76,
            height: 76,
            borderRadius: 16,
            background: C.lime,
            border: `2px solid ${C.border}`,
            boxShadow: `5px 5px 0 ${C.lavender}`,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            fontSize: 36,
            color: C.ink,
            animation: 'floaty 3s ease-in-out infinite',
          }}
        >
          ピ
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 8 }}>
          <span style={{ fontSize: 30, color: '#fff', letterSpacing: '.08em' }}>ピタフレ</span>
          <span
            style={{ fontSize: 12.5, color: C.muted, textAlign: 'center', lineHeight: 1.7 }}
          >
            ぴったりのゲーム仲間と、
            <br />
            今夜すぐつながる
          </span>
        </div>
        <div style={{ display: 'flex', gap: 8, marginTop: 6 }}>
          {['✓ 本人確認あり', '✓ マナースコア'].map((t) => (
            <span
              key={t}
              style={{
                fontSize: 10.5,
                color: C.lime,
                background: C.deepCard,
                border: `1.5px solid ${C.deepBorder}`,
                padding: '6px 11px',
                borderRadius: 4,
              }}
            >
              {t}
            </span>
          ))}
        </div>
        <span
          style={{
            fontSize: 10,
            color: C.muted,
            textAlign: 'center',
            lineHeight: 1.7,
            maxWidth: 260,
          }}
        >
          ここはゲームを一緒に楽しむ場です。出会い目的の利用は禁止。
          <br />
          安心して遊べるよう、みんなの安全を最優先にしています。
        </span>
      </div>
      <div
        style={{
          position: 'relative',
          display: 'flex',
          flexDirection: 'column',
          gap: 12,
          padding: '0 28px 44px',
        }}
      >
        <div
          className="pita-press"
          onClick={() => flow.go(isBackendConfigured ? 'signUp' : 'consent')}
          {...start.handlers}
          style={{
            cursor: 'pointer',
            background: C.lime,
            color: C.ink,
            borderRadius: 8,
            padding: '16px 0',
            textAlign: 'center',
            fontSize: 16,
            ...start.style,
          }}
        >
          ▶ PRESS START
        </div>
        <span
          onClick={() => flow.go(isBackendConfigured ? 'signIn' : 'home')}
          style={{ cursor: 'pointer', textAlign: 'center', fontSize: 12, color: C.muted }}
        >
          アカウントを持っている(ログイン)
        </span>
      </div>
    </Screen>
  )
}
