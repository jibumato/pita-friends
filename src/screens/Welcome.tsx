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
          gap: 16,
          padding: '0 28px',
        }}
      >
        <img
          src="/logo.webp"
          alt="ピタフレ — ゲーム仲間マッチングサービス"
          style={{
            width: '88%',
            maxWidth: 320,
            display: 'block',
            animation: 'floaty 3s ease-in-out infinite',
          }}
        />
        <span style={{ fontSize: 12.5, color: C.muted, textAlign: 'center', lineHeight: 1.7 }}>
          ぴったりのゲーム仲間と、
          <br />
          今夜すぐつながる
        </span>
        <img
          src="/hero.webp"
          alt="離れた場所にいる2人がオンラインでつながって一緒にゲームを楽しむイラスト"
          style={{
            width: '100%',
            aspectRatio: '16 / 9',
            objectFit: 'cover',
            borderRadius: 12,
            border: `2px solid ${C.border}`,
            boxShadow: `5px 5px 0 ${C.lavender}`,
            display: 'block',
          }}
        />
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
