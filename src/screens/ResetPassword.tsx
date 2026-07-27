import { useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import { usePress } from '../hooks/usePress'
import { updatePassword, signOut, authErrorMessage, PASSWORD_MIN_LENGTH } from '../lib/auth'

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

const MIN_LENGTH = PASSWORD_MIN_LENGTH

/**
 * パスワード再設定のリンクから戻ってきたときに出す画面。
 *
 * この時点では**復旧セッションでログイン済み**の状態になっている。
 * ここで新しいパスワードを設定させずにホームへ通してしまうと、
 * 「メールのリンクを開いた人が、パスワードを知らないまま入れてしまう」
 * ことになるので、App側でこの画面に固定している。
 */
export default function ResetPassword({ flow }: { flow: Flow }) {
  const [password, setPassword] = useState('')
  const [confirm, setConfirm] = useState('')
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const cta = usePress(`3px 3px 0 ${C.lavender}`)

  const tooShort = password.length > 0 && password.length < MIN_LENGTH
  const mismatch = confirm.length > 0 && password !== confirm
  const canSubmit = password.length >= MIN_LENGTH && password === confirm && !loading

  async function handleSubmit() {
    if (!canSubmit) return
    setLoading(true)
    setError(null)
    try {
      await updatePassword(password)
      // 復旧セッションのまま入るのではなく、新しいパスワードで入り直してもらう。
      // 「変えたパスワードで入れる」ことを本人が確かめられる。
      await signOut()
      flow.go('welcome')
      flow.openLogin()
    } catch (e) {
      setError(authErrorMessage(e))
    } finally {
      setLoading(false)
    }
  }

  /** リンクが切れていた等でやり直す場合。復旧セッションを捨てる。 */
  async function handleGiveUp() {
    try {
      await signOut()
    } catch {
      /* 失敗しても、ようこそ画面に戻れれば申請し直せる */
    }
    flow.go('welcome')
  }

  return (
    <Screen background={C.surface}>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 18, padding: '28px 20px' }}>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          <span style={{ fontSize: 22, color: C.ink, lineHeight: 1.4 }}>新しいパスワード</span>
          <span style={{ fontSize: 12, color: C.muted, lineHeight: 1.7 }}>
            新しいパスワードを設定してください。設定すると、
            <b style={{ color: C.ink }}>他の端末のログインは解除されます</b>。
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
            <span style={{ fontSize: 12, color: C.muted }}>新しいパスワード（{MIN_LENGTH}文字以上）</span>
            <input
              type="password"
              autoComplete="new-password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              placeholder="新しいパスワード"
              style={inputStyle}
            />
            {tooShort && (
              <span style={{ fontSize: 10.5, color: C.avatarOrange }}>
                あと{MIN_LENGTH - password.length}文字必要です
              </span>
            )}
          </div>

          <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
            <span style={{ fontSize: 12, color: C.muted }}>確認のためもう一度</span>
            <input
              type="password"
              autoComplete="new-password"
              value={confirm}
              onChange={(e) => setConfirm(e.target.value)}
              placeholder="もう一度入力"
              style={inputStyle}
            />
            {mismatch && (
              <span style={{ fontSize: 10.5, color: C.avatarOrange }}>一致していません</span>
            )}
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
            {loading ? '設定中…' : 'このパスワードにする ▶'}
          </button>
        </form>

        <span
          onClick={() => void handleGiveUp()}
          style={{ cursor: 'pointer', textAlign: 'center', fontSize: 12, color: C.muted }}
        >
          あとにする
        </span>
      </div>
    </Screen>
  )
}
