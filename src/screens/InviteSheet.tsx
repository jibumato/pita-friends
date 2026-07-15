import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import { Shield } from '../components/Icon'
import { GAMES, WHENS } from '../flow'
import { usePress } from '../hooks/usePress'

function PickRow({
  options,
  value,
  onPick,
}: {
  options: readonly string[]
  value: string
  onPick: (v: string) => void
}) {
  return (
    <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
      {options.map((o) => {
        const sel = value === o
        return (
          <span
            key={o}
            onClick={() => onPick(o)}
            style={{
              cursor: 'pointer',
              fontSize: 12,
              color: sel ? C.lime : C.ink,
              background: sel ? C.fill : C.white,
              border: `1.5px solid ${C.border}`,
              padding: '7px 13px',
              borderRadius: 4,
            }}
          >
            {o}
          </span>
        )
      })}
    </div>
  )
}

export default function InviteSheet({ flow }: { flow: Flow }) {
  const send = usePress(`3px 3px 0 ${C.lavender}`)
  return (
    <div
      style={{
        position: 'absolute',
        inset: 0,
        display: 'flex',
        flexDirection: 'column',
        justifyContent: 'flex-end',
      }}
    >
      <div
        onClick={() => flow.go('profile')}
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
          background: C.surface,
          borderTop: `1.5px solid ${C.border}`,
          borderRadius: '20px 20px 0 0',
          padding: '14px 20px 30px',
          display: 'flex',
          flexDirection: 'column',
          gap: 14,
          animation: 'sheetUp .3s cubic-bezier(.2,.9,.3,1) both',
        }}
      >
        <div
          style={{ width: 44, height: 5, borderRadius: 99, background: C.placeholder, margin: '0 auto' }}
        />
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <div
            style={{
              width: 44,
              height: 44,
              borderRadius: 8,
              background: C.avatarAqua,
              border: `1.5px solid ${C.border}`,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              fontSize: 19,
              color: C.ink,
            }}
          >
            み
          </div>
          <span style={{ fontSize: 16, color: C.ink }}>みなとさんを誘う</span>
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          <span style={{ fontSize: 12, color: C.muted }}>ゲーム</span>
          <PickRow options={GAMES} value={flow.game} onPick={flow.setGame} />
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          <span style={{ fontSize: 12, color: C.muted }}>日時</span>
          <PickRow options={WHENS} value={flow.when} onPick={flow.setWhen} />
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          <span style={{ fontSize: 12, color: C.muted }}>メッセージ(任意)</span>
          <div
            style={{
              background: C.white,
              border: `1.5px solid ${C.border}`,
              borderRadius: 8,
              padding: '12px 14px',
              minHeight: 44,
            }}
          >
            <span style={{ fontSize: 12.5, color: C.placeholder }}>
              はじめまして！ゴールド帯でランク回しませんか?
            </span>
          </div>
        </div>
        <div
          style={{
            background: C.surfaceLavender,
            border: `1.5px solid ${C.lavender}`,
            borderRadius: 8,
            padding: '10px 12px',
            display: 'flex',
            gap: 8,
            alignItems: 'flex-start',
          }}
        >
          <Shield style={{ flex: 'none', marginTop: 1 }} />
          <span style={{ fontSize: 10.5, lineHeight: 1.6, color: C.body }}>
            やり取りと通話はアプリ内で完結します。外部アプリへの誘導や金銭のやり取りは通報の対象です。
          </span>
        </div>
        <div
          className="pita-press"
          onClick={flow.sendInvite}
          {...send.handlers}
          style={{
            cursor: 'pointer',
            background: C.ctaBg,
            color: C.ctaFg,
            borderRadius: 8,
            padding: '14px 0',
            textAlign: 'center',
            fontSize: 14,
            ...send.style,
          }}
        >
          誘いを送る ▶
        </div>
        <span
          onClick={flow.openSendFail}
          style={{ cursor: 'pointer', textAlign: 'center', fontSize: 10.5, color: C.placeholder }}
        >
          相手がオフラインのとき(デモ) →
        </span>
      </div>
    </div>
  )
}
