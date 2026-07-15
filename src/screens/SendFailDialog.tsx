import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import { usePress } from '../hooks/usePress'
import { clickable } from '../hooks/clickable'

/** 送信失敗ダイアログ(状態網羅 C2): 相手オフラインで誘いを送れなかったとき。 */
export default function SendFailDialog({ flow }: { flow: Flow }) {
  const reserve = usePress(`2px 2px 0 ${C.lavender}`)
  return (
    <div
      style={{
        position: 'absolute',
        inset: 0,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        padding: '0 26px',
      }}
      role="dialog"
      aria-modal="true"
      aria-label="誘いを送れませんでした"
    >
      <div
        onClick={flow.closeSendFail}
        {...clickable(flow.closeSendFail, '閉じる')}
        style={{
          position: 'absolute',
          inset: 0,
          background: 'rgba(22,18,31,.55)',
          animation: 'scrIn .2s ease both',
        }}
      />
      <div
        style={{
          position: 'relative',
          width: 264,
          maxWidth: '100%',
          background: C.surface,
          border: `1.5px solid ${C.border}`,
          borderRadius: 16,
          boxShadow: `6px 6px 0 ${C.shadowCol}`,
          padding: '22px 20px',
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          gap: 14,
          animation: 'popIn .4s cubic-bezier(.2,1.3,.4,1) both',
        }}
      >
        <div
          style={{
            width: 60,
            height: 60,
            background: C.avatarPink,
            border: `1.5px solid ${C.border}`,
            boxShadow: `3px 3px 0 ${C.shadowCol}`,
            transform: 'rotate(45deg)',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
          }}
        >
          <span style={{ transform: 'rotate(-45deg)', fontSize: 30, color: C.ink }}>!</span>
        </div>
        <div
          style={{ display: 'flex', flexDirection: 'column', gap: 6, alignItems: 'center', textAlign: 'center' }}
        >
          <span style={{ fontSize: 15, color: C.ink }}>誘いを送れませんでした</span>
          <span style={{ fontSize: 11, color: C.muted, lineHeight: 1.6 }}>
            みなと さんは今オフラインです。
            <br />
            予約付きで誘うと、次に来たとき
            <br />
            通知が届きます。
          </span>
        </div>
        <div style={{ width: '100%', display: 'flex', flexDirection: 'column', gap: 8 }}>
          <div
            className="pita-press"
            onClick={flow.reserveInvite}
            {...reserve.handlers}
            {...clickable(flow.reserveInvite, '予約付きで誘う')}
            style={{
              cursor: 'pointer',
              background: C.ctaBg,
              color: C.ctaFg,
              borderRadius: 8,
              padding: '12px 0',
              textAlign: 'center',
              fontSize: 13,
              ...reserve.style,
            }}
          >
            予約付きで誘う ▶
          </div>
          <div
            onClick={flow.closeSendFail}
            {...clickable(flow.closeSendFail, '閉じる')}
            style={{ color: C.muted, textAlign: 'center', fontSize: 12, padding: '6px 0', cursor: 'pointer' }}
          >
            閉じる
          </div>
        </div>
      </div>
    </div>
  )
}
