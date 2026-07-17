import { useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { ChevronLeft } from '../components/Icon'
import { usePress } from '../hooks/usePress'
import { signInWithEmail, authErrorMessage } from '../lib/auth'

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

export default function SignIn({ flow }: { flow: Flow }) {
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const cta = usePress(`3px 3px 0 ${C.lavender}`)

  const canSubmit = /.+@.+\..+/.test(email) && password.length > 0 && !loading

  async function handleSubmit() {
    if (!canSubmit) return
    setLoading(true)
    setError(null)
    try {
      await signInWithEmail(email, password)
      flow.go('home')
    } catch (e) {
      setError(authErrorMessage(e))
    } finally {
      setLoading(false)
    }
  }

  return (
    <Screen background={C.surface}>
      <StatusBar time="21:43" />
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '8px 20px 0' }}>
        <div onClick={() => flow.go('welcome')} style={{ cursor: 'pointer' }}>
          <ChevronLeft />
        </div>
        <span style={{ fontSize: 11, color: C.muted }}>ログイン</span>
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
          <span style={{ fontSize: 22, color: C.ink, lineHeight: 1.4 }}>おかえりなさい</span>
          <span style={{ fontSize: 12, color: C.muted, lineHeight: 1.7 }}>
            メールアドレスとパスワードでログインしてください。
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
              autoComplete="current-password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              placeholder="パスワード"
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
            {loading ? 'ログイン中…' : 'ログイン ▶'}
          </button>
        </form>

        <span
          onClick={() => flow.go('signUp')}
          style={{ cursor: 'pointer', textAlign: 'center', fontSize: 12, color: C.muted }}
        >
          アカウントをお持ちでないですか？ 作成する
        </span>
      </div>
    </Screen>
  )
}
