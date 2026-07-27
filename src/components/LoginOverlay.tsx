/**
 * ログインフォームをいまの画面にかぶせて出す。
 *
 * 以前はようこそ画面(LP)の中に埋め込んでいたが、その画面を廃止したため
 * どの画面からでも開けるようにここへ移した。**画面を移動させない**ので、
 * 見ていたピタメイトのページから離れずにログインできる。
 */
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import InlineLogin from './InlineLogin'

export default function LoginOverlay({ flow }: { flow: Flow }) {
  if (!flow.welcomeLoginOpen) return null
  return (
    <div
      onClick={flow.closeLogin}
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
        style={{
          width: '100%',
          maxWidth: 360,
          background: C.white,
          border: `1.5px solid ${C.border}`,
          borderRadius: 16,
          boxShadow: `6px 6px 0 ${C.lavender}`,
          padding: '26px 24px',
          boxSizing: 'border-box',
        }}
      >
        <InlineLogin flow={flow} onBack={flow.closeLogin} />
      </div>
    </div>
  )
}
