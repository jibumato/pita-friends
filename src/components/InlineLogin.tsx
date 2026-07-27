import { useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import { usePress } from '../hooks/usePress'
import { signInWithEmail, sendPasswordReset, authErrorMessage } from '../lib/auth'

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

/**
 * ようこそ画面(メインページ)にインラインで出すログインフォーム。
 * 専用のログイン画面(旧SignIn)は廃止し、ここに統合した。
 */
export default function InlineLogin({ flow, onBack }: { flow: Flow; onBack: () => void }) {
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  // パスワードを忘れた場合の申請。ログインフォームと入れ替えて出す。
  const [forgotOpen, setForgotOpen] = useState(false)
  const [sent, setSent] = useState(false)
  const cta = usePress(`3px 3px 0 ${C.lavender}`)

  const emailOk = /.+@.+\..+/.test(email)
  const canSubmit = emailOk && password.length > 0 && !loading

  async function handleReset() {
    if (!emailOk || loading) return
    setLoading(true)
    setError(null)
    try {
      await sendPasswordReset(email)
      setSent(true)
    } catch (e) {
      setError(authErrorMessage(e))
    } finally {
      setLoading(false)
    }
  }

  async function handleSubmit() {
    if (!canSubmit) return
    setLoading(true)
    setError(null)
    try {
      const user = await signInWithEmail(email, password)
      await flow.hydrateAccount(user.id)
      flow.go('home')
    } catch (e) {
      setError(authErrorMessage(e))
    } finally {
      setLoading(false)
    }
  }

  // ---- パスワードを忘れた場合 ----
  if (forgotOpen) {
    return (
      <div style={{ display: 'flex', flexDirection: 'column', gap: 18 }}>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          <span style={{ fontSize: 22, color: C.ink, lineHeight: 1.4 }}>パスワードの再設定</span>
          <span style={{ fontSize: 12, color: C.muted, lineHeight: 1.7 }}>
            登録したメールアドレスに、再設定用のリンクをお送りします。
          </span>
        </div>

        {sent ? (
          <>
            {/* アドレスが登録済みかどうかは伝えない。ここで「登録がありません」と
                出すと、他人のアドレスが登録済みかを調べられてしまう。 */}
            <div
              style={{
                background: C.lime,
                border: `1.5px solid ${C.border}`,
                borderRadius: 8,
                padding: '12px 14px',
                fontSize: 12,
                color: C.ink,
                lineHeight: 1.7,
              }}
            >
              そのアドレスに登録があれば、再設定用のリンクをお送りしました。
              メールが届かない場合は、迷惑メールフォルダもご確認ください。
            </div>
            <span style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.7 }}>
              リンクには有効期限があります。切れていた場合は、もう一度この画面から送ってください。
            </span>
          </>
        ) : (
          <form
            onSubmit={(e) => {
              e.preventDefault()
              void handleReset()
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
              disabled={!emailOk || loading}
              {...(emailOk && !loading ? cta.handlers : {})}
              style={{
                cursor: emailOk && !loading ? 'pointer' : 'not-allowed',
                background: emailOk && !loading ? C.ctaBg : C.fill,
                color: emailOk && !loading ? C.ctaFg : C.placeholder,
                opacity: emailOk && !loading ? 1 : 0.55,
                border: 'none',
                borderRadius: 8,
                padding: '15px 0',
                textAlign: 'center',
                fontSize: 15,
                fontFamily: 'inherit',
                ...(emailOk && !loading ? cta.style : {}),
              }}
            >
              {loading ? '送信中…' : '再設定用のリンクを送る ▶'}
            </button>
          </form>
        )}

        <span
          onClick={() => {
            setForgotOpen(false)
            setSent(false)
            setError(null)
          }}
          style={{ cursor: 'pointer', textAlign: 'center', fontSize: 12, color: C.muted }}
        >
          ← ログインにもどる
        </span>
      </div>
    )
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 18 }}>
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
        onClick={() => {
          setForgotOpen(true)
          setError(null)
        }}
        style={{
          cursor: 'pointer',
          textAlign: 'center',
          fontSize: 12,
          color: C.lavender,
          textDecoration: 'underline',
        }}
      >
        パスワードをお忘れですか？
      </span>

      <span onClick={onBack} style={{ cursor: 'pointer', textAlign: 'center', fontSize: 12, color: C.muted }}>
        ← もどる
      </span>
    </div>
  )
}
