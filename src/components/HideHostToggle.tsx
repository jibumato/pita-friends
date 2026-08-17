import { useEffect, useState } from 'react'
import { color as C } from '../theme/tokens'
import { fetchHiddenHosts, setHostHidden } from '../lib/queries'

/**
 * 「この人を検索に出さない」(0116)。
 *
 * ■ なぜ通報・ブロックとは別に要るか
 *   いまある出口はどちらも**相手に非がある**ことを前提にした重い操作で、
 *   「悪くはないが自分には合わない」に当たるものが無かった。
 *   出口が重すぎると、使われないか、誤用されるかのどちらかになる。
 *   相性の問題が通報に流れ込むと、本当に危ない通報が埋もれる。
 *
 * ■ 文言で必ず伝えること
 *   **相手には何も起きない。** ここを曖昧にすると「ブロックの弱い版」と
 *   読まれ、押すのをためらわれる(=軽い出口として機能しなくなる)。
 *   逆に、押せば相手に効くと誤解されるのも困る。
 *
 * ■ 見た目を目立たせない
 *   プロフィールを開いた人の大半には不要な操作なので、CTAの近くには置かない。
 */
export default function HideHostToggle({
  hostId,
  hostName,
}: {
  hostId: string
  hostName: string
}) {
  const [on, setOn] = useState<boolean | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let active = true
    fetchHiddenHosts()
      .then((rows) => active && setOn(rows.some((r) => r.hostUserId === hostId)))
      // 取れなければ何も出さない。分からない状態でチェックを描くと、
      // 実際の設定と食い違ったものを見せることになる
      .catch(() => {})
    return () => {
      active = false
    }
  }, [hostId])

  if (on === null) return null

  const toggle = () => {
    if (busy) return
    setBusy(true)
    setError(null)
    const next = !on
    setHostHidden(hostId, next)
      .then(() => setOn(next))
      .catch(() => setError('設定を変更できませんでした'))
      .finally(() => setBusy(false))
  }

  return (
    <div
      style={{
        background: C.white,
        border: `1.5px solid ${C.border}`,
        borderRadius: 8,
        padding: '11px 13px',
        display: 'flex',
        flexDirection: 'column',
        gap: 7,
      }}
    >
      <div
        onClick={toggle}
        role="button"
        tabIndex={0}
        aria-pressed={on}
        onKeyDown={(e) => {
          if (e.key === 'Enter' || e.key === ' ') toggle()
        }}
        style={{ cursor: busy ? 'default' : 'pointer', display: 'flex', alignItems: 'center', gap: 9 }}
      >
        <span
          aria-hidden
          style={{
            flex: 'none',
            width: 20,
            height: 20,
            borderRadius: 5,
            border: `1.5px solid ${C.border}`,
            background: on ? C.lime : C.white,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            fontSize: 12,
            color: C.ink,
          }}
        >
          {on ? '✓' : ''}
        </span>
        <span style={{ flex: 1, fontSize: 12.5, color: C.ink, lineHeight: 1.5 }}>
          {hostName}さんを、さがす画面に出さない
        </span>
      </div>
      <span style={{ fontSize: 10, color: C.muted, lineHeight: 1.7 }}>
        <b style={{ color: C.ink }}>相手には何も起きません。</b>
        通知は届かず、これまでどおり予約もトークもできます。
        自分のさがす画面に出なくなるだけです。設定 &gt; ブロック・非表示にした人 からいつでも戻せます。
        <br />
        迷惑行為を受けている場合は、こちらではなく<b>通報・ブロック</b>を使ってください。
      </span>
      {error && <span style={{ fontSize: 10.5, color: C.avatarPink }}>{error}</span>}
    </div>
  )
}
