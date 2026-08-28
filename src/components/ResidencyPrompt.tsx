import { useState } from 'react'
import { color as C } from '../theme/tokens'
import { declareResidency } from '../lib/queries'

/**
 * 購入が「居住地未申告」で弾かれたときに、その場で申告してもらう(0119)。
 *
 * ■ なぜ要るか
 *   `declareResidency` を呼ぶ場所はもともと2つしかなかった——新規登録の画面と、
 *   本人確認を出す画面(ピタメイトになるとき)。**0119より前に登録した、
 *   ピタメイトにもならないゲストには、申告する手段がアプリのどこにも
 *   無かった。**
 *
 *   購入を弾いたときのメッセージが「登録時のチェックにもう一度」だと、
 *   このアカウントは登録画面へ二度と戻れないので、**案内そのものが詰みを
 *   指す**ことになる。ここでその場で答えられるようにして、詰みを解消する。
 *
 * ■ 「いいえ」を選んだ場合
 *   ここでは何もしない。「いいえ」は日本国内にお住まいでない、という
 *   申告そのものが結論で、直しようがない。フォームを消して、
 *   本体側(Wallet)がそのまま案内文を出す。
 */
export default function ResidencyPrompt({ onDeclared }: { onDeclared: () => void }) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [declinedJapan, setDeclinedJapan] = useState(false)

  const answer = async (japan: boolean) => {
    if (busy) return
    setBusy(true)
    setError(null)
    try {
      await declareResidency(japan)
      if (japan) {
        onDeclared()
      } else {
        setDeclinedJapan(true)
      }
    } catch {
      setError('送信できませんでした。時間をおいてお試しください')
    } finally {
      setBusy(false)
    }
  }

  if (declinedJapan) {
    return (
      <div
        style={{
          background: C.avatarPink,
          border: `1.5px solid ${C.border}`,
          borderRadius: 8,
          padding: '11px 13px',
          fontSize: 11.5,
          lineHeight: 1.7,
          color: C.ink,
        }}
      >
        ピタフレは日本国内にお住まいの方向けのサービスです。恐れ入りますが、コインの購入はご利用いただけません。
      </div>
    )
  }

  return (
    <div
      style={{
        background: C.surfaceLavender,
        border: `1.5px solid ${C.lavender}`,
        borderRadius: 8,
        padding: '11px 13px',
        display: 'flex',
        flexDirection: 'column',
        gap: 9,
      }}
    >
      <span style={{ fontSize: 11.5, color: C.ink, lineHeight: 1.7 }}>
        コインを購入する前に、お住まいを確認させてください（規約 第3条3項）。
        <br />
        <b>日本国内に居住していますか？</b>
      </span>
      {error && <span style={{ fontSize: 10.5, color: C.ink }}>{error}</span>}
      <div style={{ display: 'grid', gridAutoFlow: 'column', gap: 6 }}>
        <span
          onClick={() => void answer(true)}
          role="button"
          tabIndex={0}
          onKeyDown={(e) => {
            if (e.key === 'Enter' || e.key === ' ') void answer(true)
          }}
          style={{
            cursor: busy ? 'default' : 'pointer',
            fontSize: 12,
            color: C.ctaFg,
            background: C.ctaBg,
            textAlign: 'center',
            padding: '9px 0',
            borderRadius: 6,
            opacity: busy ? 0.6 : 1,
          }}
        >
          はい、居住しています
        </span>
        <span
          onClick={() => void answer(false)}
          role="button"
          tabIndex={0}
          onKeyDown={(e) => {
            if (e.key === 'Enter' || e.key === ' ') void answer(false)
          }}
          style={{
            cursor: busy ? 'default' : 'pointer',
            fontSize: 12,
            color: C.ink,
            background: C.white,
            border: `1.5px solid ${C.border}`,
            textAlign: 'center',
            padding: '8px 0',
            borderRadius: 6,
            opacity: busy ? 0.6 : 1,
          }}
        >
          いいえ
        </span>
      </div>
    </div>
  )
}
