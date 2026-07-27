/**
 * 未ログインの訪問者に、ログイン／新規登録を促すカード。
 *
 * 紹介用LPを廃止して未ログインでもアプリ本体に入れるようにしたため、
 * 「ログインしないと意味が無い場所」でこれを出す。
 *
 * **デモ用の初期値をそのまま見せないこと。** マイページは以前、未ログインでも
 * 「あおい / 本人確認済み / 残高500コイン」と出ていた。自分が誰かのアカウントに
 * 入っているように見えるうえ、存在しない残高を表示していた。
 */
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'

type Props = {
  flow: Flow
  /** 見出し。その画面で何ができるようになるかを書く */
  title: string
  /** 補足。1〜2文で、登録すると何が起きるか */
  body: string
  /** 上下の余白を詰めた形にする(ホームの本文中に挟むとき) */
  compact?: boolean
}

export default function SignedOutPrompt({ flow, title, body, compact = false }: Props) {
  return (
    <div
      style={{
        background: C.white,
        border: `1.5px solid ${C.border}`,
        borderRadius: 14,
        boxShadow: `4px 4px 0 ${C.lavender}`,
        padding: compact ? '18px 20px' : '26px 22px',
        display: 'flex',
        flexDirection: 'column',
        gap: 12,
        boxSizing: 'border-box',
      }}
    >
      <span style={{ fontSize: compact ? 15 : 17, color: C.ink, lineHeight: 1.5 }}>{title}</span>
      <span style={{ fontSize: 12, color: C.muted, lineHeight: 1.8 }}>{body}</span>
      <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap', marginTop: 2 }}>
        <button
          onClick={() => flow.go('signUp')}
          style={{
            cursor: 'pointer',
            flex: '1 1 150px',
            background: C.lime,
            color: C.ink,
            border: `1.5px solid ${C.border}`,
            boxShadow: `3px 3px 0 ${C.border}`,
            borderRadius: 10,
            padding: '13px 18px',
            fontSize: 14,
            fontFamily: 'inherit',
          }}
        >
          新規登録（無料）
        </button>
        <button
          onClick={flow.openLogin}
          style={{
            cursor: 'pointer',
            flex: '0 1 auto',
            background: C.white,
            color: C.ink,
            border: `1.5px solid ${C.border}`,
            borderRadius: 10,
            padding: '13px 18px',
            fontSize: 14,
            fontFamily: 'inherit',
            whiteSpace: 'nowrap',
          }}
        >
          ログイン
        </button>
      </div>
    </div>
  )
}
