/**
 * 公開前の事前登録フォーム。ランディング(PC)とようこそ画面(スマホ)の両方で使う。
 *
 * 集めるのはメールアドレスだけ。**利用目的を画面に書くこと**(個人情報保護法)。
 * 「公開のお知らせにのみ使う」と明記し、プライバシーポリシーへ導線を出している。
 *
 * 送信後は「登録しました」ではなく「お知らせします」と出す。DB側が重複を
 * 握りつぶすため、成功しても新規とは限らないため(アドレスの存否を漏らさない)。
 */
import { useState } from 'react'
import { color as C } from '../theme/tokens'
import { canPreRegister, looksLikeEmail, preRegister, preRegisterErrorMessage } from '../lib/preRegister'

type Props = {
  /** 流入元の目印。SNSごとの効き目を見るのに使う */
  source?: string
  /** プライバシーポリシーを開く。渡さなければリンクを出さない */
  onOpenPrivacy?: () => void
  /** 濃い背景の上に置くとき(スマホのようこそ画面)は true */
  onDark?: boolean
  /** 横幅の上限。既定は親に合わせる */
  maxWidth?: number
  /** 見出しが別にある場所で、同じ文言を二重に出さないための逃げ道 */
  hideLabel?: boolean
}

export default function PreRegisterForm({ source, onOpenPrivacy, onDark = false, maxWidth, hideLabel = false }: Props) {
  const [email, setEmail] = useState('')
  const [state, setState] = useState<'idle' | 'sending' | 'done'>('idle')
  const [error, setError] = useState<string | null>(null)

  const valid = looksLikeEmail(email)
  const canSubmit = valid && state !== 'sending' && canPreRegister

  const labelColor = onDark ? C.lavenderText : C.muted
  const noteColor = onDark ? '#B3ABC9' : C.muted

  async function handleSubmit() {
    if (!canSubmit) return
    setState('sending')
    setError(null)
    try {
      await preRegister(email, source)
      setState('done')
    } catch (e) {
      setError(preRegisterErrorMessage(e))
      setState('idle')
    }
  }

  if (state === 'done') {
    return (
      <div
        style={{
          maxWidth,
          background: onDark ? 'rgba(255,255,255,.08)' : C.white,
          border: `1.5px solid ${onDark ? C.deepBorder : C.border}`,
          borderRadius: 12,
          padding: '18px 20px',
          display: 'flex',
          flexDirection: 'column',
          gap: 8,
          boxSizing: 'border-box',
        }}
      >
        <span style={{ fontSize: 15, color: onDark ? '#fff' : C.ink }}>ありがとうございます 🎉</span>
        <span style={{ fontSize: 12, color: noteColor, lineHeight: 1.8 }}>
          公開の準備ができましたら、このアドレスにお知らせします。それまでメールは送りません。
        </span>
      </div>
    )
  }

  return (
    <div style={{ maxWidth, display: 'flex', flexDirection: 'column', gap: 10, boxSizing: 'border-box' }}>
      {!hideLabel && (
        <span style={{ fontSize: 12, color: labelColor }}>公開したらお知らせを受け取る</span>
      )}
      <form
        onSubmit={(e) => {
          e.preventDefault()
          void handleSubmit()
        }}
        style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}
      >
        <input
          type="email"
          autoComplete="email"
          inputMode="email"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          placeholder="you@example.com"
          aria-label="メールアドレス"
          style={{
            flex: '1 1 200px',
            minWidth: 0,
            background: C.white,
            border: `1.5px solid ${C.border}`,
            borderRadius: 10,
            padding: '13px 14px',
            fontSize: 14,
            color: C.ink,
            outline: 'none',
            fontFamily: 'inherit',
            boxSizing: 'border-box',
          }}
        />
        <button
          type="submit"
          disabled={!canSubmit}
          style={{
            cursor: canSubmit ? 'pointer' : 'not-allowed',
            background: canSubmit ? C.lime : C.fill,
            color: canSubmit ? C.ink : C.placeholder,
            opacity: canSubmit ? 1 : 0.55,
            border: `2px solid ${C.border}`,
            borderRadius: 10,
            boxShadow: canSubmit ? `3px 3px 0 ${C.border}` : 'none',
            padding: '13px 22px',
            fontSize: 14,
            fontFamily: 'inherit',
            whiteSpace: 'nowrap',
          }}
        >
          {state === 'sending' ? '送信中…' : '登録する'}
        </button>
      </form>

      {error && (
        <span style={{ fontSize: 11.5, color: onDark ? C.avatarOrange : C.avatarOrange }}>{error}</span>
      )}

      {!canPreRegister && (
        <span style={{ fontSize: 11, color: noteColor }}>
          （プレビュー表示のため、この画面からの登録は受け付けていません）
        </span>
      )}

      <span style={{ fontSize: 11, color: noteColor, lineHeight: 1.8 }}>
        いただいたアドレスは<b style={{ color: onDark ? '#fff' : C.ink }}>公開のお知らせにのみ</b>使います。
        アカウント登録ではありません。
        {onOpenPrivacy && (
          <>
            {' '}
            <span
              onClick={onOpenPrivacy}
              style={{ cursor: 'pointer', textDecoration: 'underline', color: onDark ? C.lavenderText : C.muted }}
            >
              プライバシーポリシー
            </span>
          </>
        )}
      </span>
    </div>
  )
}
