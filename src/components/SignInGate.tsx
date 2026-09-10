import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import type { PendingAction } from '../lib/pendingIntent'

/**
 * 未ログインの人が、登録が要る操作を押したときに出す関所。
 *
 * ■ なぜこれが要るか（直す前に何が起きていたか）
 *   ・**予約**… `confirmBooking` が未ログインだとデモ経路に落ち、
 *     偽の残高を減らして「送信中 → マッチ」を再生していた。
 *     **予約できたと思って帰る人が出る。** いちばん取り返しがつかない
 *   ・**メッセージ**… 誘いの画面には行けるが、実データが無いので成立しない
 *   ::・**お気に入り**… ⭐が一瞬つくが、書き込みが認証で落ちて元に戻る。
 *     理由が出ないので、**壊れているようにしか見えない**
 *
 * ■ 画面を移動させない
 *   `LoginOverlay` と同じ考え方。見ていた相手のページから離れずに答えられる。
 *   閉じれば、さっきまで見ていたものがそのまま残っている。
 *
 * ■ 「登録が必要です」だけで終わらせない
 *   **何をしようとして出たのか**と、**登録すると何ができるのか**を書く。
 *   出す理由が読めないと、ただ止められたようにしか受け取られない。
 *
 * ■ ここで課金は起きないと書く
 *   予約はコインを使うので、「登録＝支払い」だと受け取られやすい。
 *   登録が無料であることを、押す前にその場で言う。
 */

type Copy = { title: string; body: string; note?: string }

const COPY: Record<PendingAction, (name: string) => Copy> = {
  booking: (n) => ({
    title: n ? `${n}さんに予約するには、登録が必要です` : '予約するには、登録が必要です',
    body: '予約はゲストとピタメイトの間の約束なので、お互いが誰なのか分かる必要があります。登録は無料で、ここで料金はかかりません。',
    note: 'コインは予約を確定するときに使います。登録しただけでは何も引き落とされません。',
  }),
  message: (n) => ({
    title: n ? `${n}さんに送るには、登録が必要です` : 'メッセージを送るには、登録が必要です',
    body: 'やりとりは登録した人どうしだけで行われます。知らない人からいきなり届くことがないように、双方に登録をお願いしています。',
  }),
  favorite: (n) => ({
    title: n ? `${n}さんをお気に入りに入れるには、登録が必要です` : 'お気に入りに入れるには、登録が必要です',
    body: 'お気に入りはあなたのアカウントに保存されます。登録すると、この方が枠を開けたときに知らせを受け取れます。',
    note: 'お気に入りに入れたことは、相手にも他の人にも伝わりません。',
  }),
}

export default function SignInGate({ flow }: { flow: Flow }) {
  const gate = flow.signInGate
  if (!gate) return null
  const c = COPY[gate.action](gate.name)

  return (
    <div
      onClick={flow.closeSignInGate}
      style={{
        position: 'fixed',
        inset: 0,
        zIndex: 60,
        background: 'rgba(40,30,80,.45)',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        padding: 22,
      }}
    >
      <div
        onClick={(e) => e.stopPropagation()}
        role="dialog"
        aria-modal="true"
        aria-label={c.title}
        style={{
          width: '100%',
          maxWidth: 360,
          background: C.white,
          border: `1.5px solid ${C.border}`,
          borderRadius: 16,
          boxShadow: `6px 6px 0 ${C.lavender}`,
          padding: '24px 22px',
          boxSizing: 'border-box',
          display: 'flex',
          flexDirection: 'column',
          gap: 14,
        }}
      >
        <span style={{ fontSize: 15, color: C.ink, lineHeight: 1.6 }}>{c.title}</span>
        <span style={{ fontSize: 11.5, color: C.body, lineHeight: 1.8 }}>{c.body}</span>
        {c.note && (
          <span
            style={{
              fontSize: 10.5,
              color: C.ink,
              lineHeight: 1.7,
              background: C.surfaceLavender,
              border: `1.5px solid ${C.lavender}`,
              borderRadius: 8,
              padding: '9px 11px',
            }}
          >
            {c.note}
          </span>
        )}

        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          <span
            onClick={flow.goSignUpFromGate}
            role="button"
            tabIndex={0}
            onKeyDown={(e) => {
              if (e.key === 'Enter' || e.key === ' ') flow.goSignUpFromGate()
            }}
            style={{
              cursor: 'pointer',
              textAlign: 'center',
              fontSize: 14,
              color: C.ctaFg,
              background: C.ctaBg,
              borderRadius: 8,
              padding: '13px 0',
            }}
          >
            無料で登録する ▶
          </span>
          <span
            onClick={flow.goLoginFromGate}
            role="button"
            tabIndex={0}
            onKeyDown={(e) => {
              if (e.key === 'Enter' || e.key === ' ') flow.goLoginFromGate()
            }}
            style={{
              cursor: 'pointer',
              textAlign: 'center',
              fontSize: 13,
              color: C.ink,
              background: C.white,
              border: `1.5px solid ${C.border}`,
              borderRadius: 8,
              padding: '11px 0',
            }}
          >
            アカウントをお持ちの方はログイン
          </span>
        </div>

        <span
          onClick={flow.closeSignInGate}
          role="button"
          tabIndex={0}
          onKeyDown={(e) => {
            if (e.key === 'Enter' || e.key === ' ') flow.closeSignInGate()
          }}
          style={{ cursor: 'pointer', fontSize: 11, color: C.muted, textAlign: 'center' }}
        >
          あとで
        </span>
      </div>
    </div>
  )
}
