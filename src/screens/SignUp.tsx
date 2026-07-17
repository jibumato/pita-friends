import { useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { ChevronLeft } from '../components/Icon'
import { usePress } from '../hooks/usePress'
import { signUpWithEmail, authErrorMessage } from '../lib/auth'

const inputStyle = {
  background: C.white,
  border: `1.5px solid ${C.border}`,
  borderRadius: 8,
  padding: '12px 14px',
  fontSize: 13,
  color: C.ink,
  boxShadow: `2px 2px 0 ${C.shadowCol}`,
  outline: 'none',
  fontFamily: 'inherit',
  width: '100%',
  boxSizing: 'border-box' as const,
}

export default function SignUp({ flow }: { flow: Flow }) {
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [needsConfirmation, setNeedsConfirmation] = useState(false)
  const cta = usePress(`3px 3px 0 ${C.lavender}`)

  const canSubmit = /.+@.+\..+/.test(email) && password.length >= 6 && !loading

  async function handleSubmit() {
    if (!canSubmit) return
    setLoading(true)
    setError(null)
    try {
      const { session } = await signUpWithEmail(email, password)
      if (session) {
        flow.go('consent')
      } else {
        // プロジェクト設定でメール確認が必須な場合、この時点ではまだログインできていない
        setNeedsConfirmation(true)
      }
    } catch (e) {
      setError(authErrorMessage(e))
    } finally {
      setLoading(false)
    }
  }

  if (needsConfirmation) {
    return (
      <Screen background={C.surface}>
        <StatusBar time="21:43" />
        <div
          style={{
            flex: 1,
            display: 'flex',
            flexDirection: 'column',
            alignItems: 'center',
            justifyContent: 'center',
            gap: 14,
            padding: '0 28px',
            textAlign: 'center',
          }}
        >
          <span style={{ fontSize: 34 }}>📩</span>
          <span style={{ fontSize: 16, color: C.ink }}>確認メールを送信しました</span>
          <span style={{ fontSize: 12, color: C.muted, lineHeight: 1.8 }}>
            {email} 宛てのメール内のリンクをクリックすると、アカウントが有効になります。確認後、ログインしてください。
          </span>
          <div
            className="pita-press"
            onClick={() => flow.go('signIn')}
            {...cta.handlers}
            style={{
              cursor: 'pointer',
              background: C.ctaBg,
              color: C.ctaFg,
              borderRadius: 8,
              padding: '13px 26px',
              fontSize: 13,
              marginTop: 8,
              ...cta.style,
            }}
          >
            ログイン画面へ ▶
          </div>
        </div>
      </Screen>
    )
  }

  return (
    <Screen background={C.surface}>
      <StatusBar time="21:43" />
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '8px 20px 0' }}>
        <div onClick={() => flow.go('welcome')} style={{ cursor: 'pointer' }}>
          <ChevronLeft />
        </div>
        <span style={{ fontSize: 11, color: C.muted }}>アカウント作成</span>
      </div>
      <div
        style={{
          flex: 1,
          display: 'flex',
          flexDirection: 'column',
          padding: '16px 22px 0',
          gap: 18,
        }}
      >
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          <span style={{ fontSize: 22, color: C.ink, lineHeight: 1.4 }}>
            アカウントを
            <br />
            つくりましょう
          </span>
          <span style={{ fontSize: 12, color: C.muted, lineHeight: 1.7 }}>
            メールアドレスとパスワードを設定してください。この後、本人確認に進みます。
          </span>
        </div>

        <form
          onSubmit={(e) => {
            e.preventDefault()
            void handleSubmit()
          }}
          style={{ display: 'flex', flexDirection: 'column', gap: 14 }}
        >
          <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
            <span style={{ fontSize: 12, color: C.muted }}>メールアドレス</span>
            <input
              type="email"
              autoComplete="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              placeholder="you@example.com"
              style={inputStyle}
            />
          </div>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
            <span style={{ fontSize: 12, color: C.muted }}>パスワード</span>
            <input
              type="password"
              autoComplete="new-password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              placeholder="6文字以上"
              style={inputStyle}
            />
          </div>

          {error && (
            <div
              style={{
                background: C.avatarPink,
                border: `1.5px solid ${C.border}`,
                borderRadius: 8,
                padding: '10px 12px',
                fontSize: 11.5,
                color: C.ink,
              }}
            >
              {error}
            </div>
          )}

          <button
            type="submit"
            className="pita-press"
            disabled={!canSubmit}
            {...(canSubmit ? cta.handlers : {})}
            style={{
              cursor: canSubmit ? 'pointer' : 'not-allowed',
              background: canSubmit ? C.ctaBg : C.fill,
              color: canSubmit ? C.ctaFg : C.placeholder,
              opacity: canSubmit ? 1 : 0.55,
              border: 'none',
              borderRadius: 8,
              padding: '15px 0',
              textAlign: 'center',
              fontSize: 15,
              fontFamily: 'inherit',
              ...(canSubmit ? cta.style : {}),
            }}
          >
            {loading ? '作成中…' : 'アカウントを作成 ▶'}
          </button>
        </form>

        <span
          onClick={() => flow.go('signIn')}
          style={{ cursor: 'pointer', textAlign: 'center', fontSize: 12, color: C.muted }}
        >
          すでにアカウントをお持ちですか？ ログイン
        </span>
      </div>
    </Screen>
  )
}
