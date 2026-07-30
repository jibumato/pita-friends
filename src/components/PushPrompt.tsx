/**
 * 通知を受け取るか聞くシート(0064)。
 *
 * **本物のダイアログの前に必ずこれを出す。** ブラウザの許可ダイアログは
 * 一度しか出せず、断られたら二度と出せない。理由を先に説明しておけば
 * 本物のダイアログは形式的な確認になり、断られにくい。
 *
 * 何が届くのかを**具体的に**書く。「お知らせを受け取りますか」では
 * 何を許すのか分からないので、押す理由も断る理由も判断できない。
 */
import { useEffect, useState } from 'react'
import { color as C } from '../theme/tokens'
import { enablePush, snoozePushPrompt, pushState, type PushReason } from '../lib/push'

type Props = {
  reason: PushReason
  onClose: () => void
}

/** きっかけごとに、いちばん効く一行を先に出す。 */
const HEADLINE: Record<PushReason, string> = {
  favorite: 'お気に入りのピタメイトが枠を開けたら、すぐ知らせます',
  booking: '予約の連絡を取り逃さないように',
}

export default function PushPrompt({ reason, onClose }: Props) {
  const [busy, setBusy] = useState(false)
  const [denied, setDenied] = useState(false)
  const [failed, setFailed] = useState(false)

  // 開いている途中でブラウザ側の状態が変わっていたら畳む
  useEffect(() => {
    if (pushState() === 'denied') setDenied(true)
  }, [])

  function later() {
    snoozePushPrompt()
    onClose()
  }

  async function accept() {
    if (busy) return
    setBusy(true)
    setFailed(false)
    const r = await enablePush()
    setBusy(false)
    if (r === 'granted') {
      onClose()
      return
    }
    if (r === 'denied') {
      // もうダイアログは出せない。戻し方だけ伝えて終わる
      setDenied(true)
      return
    }
    setFailed(true)
  }

  return (
    <div
      onClick={denied ? onClose : later}
      style={{
        position: 'absolute',
        inset: 0,
        background: 'rgba(0,0,0,.45)',
        display: 'flex',
        alignItems: 'flex-end',
        zIndex: 60,
      }}
    >
      <div
        onClick={(e) => e.stopPropagation()}
        className="pita-scroll"
        role="dialog"
        aria-label="通知を受け取る"
        style={{
          width: '100%',
          maxHeight: '88%',
          overflowY: 'auto',
          background: C.surface,
          borderTop: `1.5px solid ${C.border}`,
          borderRadius: '16px 16px 0 0',
          padding: '16px 20px 26px',
          display: 'flex',
          flexDirection: 'column',
          gap: 12,
          boxSizing: 'border-box',
          animation: 'scrIn .25s ease both',
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 10 }}>
          <span style={{ fontSize: 15, color: C.ink }}>
            {denied ? '通知がブロックされています' : HEADLINE[reason]}
          </span>
          <span
            onClick={denied ? onClose : later}
            role="button"
            tabIndex={0}
            style={{ cursor: 'pointer', flex: 'none', fontSize: 13, color: C.muted }}
          >
            閉じる
          </span>
        </div>

        {denied ? (
          <>
            <span style={{ fontSize: 11.5, color: C.body, lineHeight: 1.8 }}>
              このサイトの通知が拒否されているため、アプリからは出し直せません。
              受け取るには<b style={{ color: C.ink }}>ブラウザの設定から許可し直してください</b>。
            </span>
            <Steps
              items={[
                'iPhone: 設定 →「通知」→ ピタフレ →「通知を許可」',
                'Android Chrome: アドレス欄の🔒 →「通知」→「許可」',
              ]}
            />
          </>
        ) : (
          <>
            <span style={{ fontSize: 11.5, color: C.body, lineHeight: 1.8 }}>
              アプリを開いていないときでも、次のことをお知らせできます。
            </span>
            <Steps
              items={[
                'お気に入りに追加した相手が、遊べる枠を開けたとき',
                '予約が承認された・変更された・キャンセルされたとき',
                'メッセージや誘いが届いたとき',
              ]}
            />
            {/* ここは正直に書く。ロック画面は他人の目に入る場所なので、
                何が出ないのかを先に言っておくほうが押しやすい。 */}
            <span style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.7 }}>
              メッセージとギフトは<b style={{ color: C.ink }}>相手の名前だけ</b>を出し、
              本文や金額はロック画面に表示しません。あとから設定でいつでも止められます。
              静かにしたい時間帯も設定できます。
            </span>
            {failed && (
              <div
                style={{
                  background: C.avatarPink,
                  border: `1.5px solid ${C.border}`,
                  borderRadius: 8,
                  padding: '10px 12px',
                  fontSize: 11.5,
                  color: C.ink,
                  lineHeight: 1.6,
                }}
              >
                通知の登録に失敗しました。通信状況を確かめて、もう一度お試しください。
              </div>
            )}
            <button
              onClick={() => void accept()}
              disabled={busy}
              style={{
                cursor: busy ? 'default' : 'pointer',
                background: C.ctaBg,
                color: C.ctaFg,
                opacity: busy ? 0.6 : 1,
                border: 'none',
                borderRadius: 10,
                padding: '14px 0',
                fontSize: 15,
                fontFamily: 'inherit',
              }}
            >
              {busy ? '設定中…' : '通知を受け取る ▶'}
            </button>
            <span
              onClick={later}
              role="button"
              tabIndex={0}
              style={{ cursor: 'pointer', textAlign: 'center', fontSize: 12, color: C.muted, padding: '2px 0' }}
            >
              あとで
            </span>
          </>
        )}
      </div>
    </div>
  )
}

function Steps({ items }: { items: string[] }) {
  return (
    <ul
      style={{
        margin: 0,
        listStyle: 'none',
        display: 'flex',
        flexDirection: 'column',
        gap: 8,
        background: C.white,
        border: `1.5px solid ${C.border}`,
        borderRadius: 10,
        padding: '13px 14px',
      }}
    >
      {items.map((t) => (
        <li key={t} style={{ display: 'flex', gap: 9, alignItems: 'flex-start' }}>
          <span aria-hidden style={{ flex: 'none', fontSize: 11, color: C.lavender, lineHeight: 1.6 }}>
            ●
          </span>
          <span style={{ fontSize: 12, color: C.ink, lineHeight: 1.6 }}>{t}</span>
        </li>
      ))}
    </ul>
  )
}
