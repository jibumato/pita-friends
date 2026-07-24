/** コイン残高/安心して遊べる/近日公開のパネル群。
 *  トップバーのハンバーガーメニューから開くドロップダウンの中身として使う。
 *  ランキングはホーム本文へ移設したため、ここには含めない。 */
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import { Coin } from './Icon'
import { clickable } from '../hooks/clickable'

function Panel({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div
      style={{
        background: C.white,
        border: `1.5px solid ${C.border}`,
        borderRadius: 12,
        boxShadow: `3px 3px 0 ${C.shadowCol}`,
        padding: 14,
        display: 'flex',
        flexDirection: 'column',
        gap: 10,
      }}
    >
      <span style={{ fontSize: 12.5, color: C.ink, fontWeight: 700 }}>{title}</span>
      {children}
    </div>
  )
}

export default function DesktopRightRail({ flow }: { flow: Flow }) {
  return (
    <div
      style={{
        width: 300,
        display: 'flex',
        flexDirection: 'column',
        gap: 14,
      }}
    >
      {/* 残高はトップバーのコインチップに常時表示されているため、ここでは繰り返さずチャージ動線のみ。 */}
      <div
        onClick={() => flow.go('wallet')}
        {...clickable(() => flow.go('wallet'), 'コインをチャージ')}
        style={{
          cursor: 'pointer',
          display: 'flex',
          alignItems: 'center',
          gap: 10,
          background: C.white,
          border: `1.5px solid ${C.border}`,
          borderRadius: 12,
          boxShadow: `3px 3px 0 ${C.shadowCol}`,
          padding: '12px 14px',
        }}
      >
        <div
          style={{
            width: 32,
            height: 32,
            borderRadius: 8,
            background: C.lime,
            border: `1.5px solid ${C.border}`,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            flex: 'none',
          }}
        >
          <Coin size={16} color={C.ink} />
        </div>
        <span style={{ flex: 1, fontSize: 12.5, color: C.ink }}>コインをチャージ</span>
        <span style={{ fontSize: 11, color: C.muted }}>›</span>
      </div>

      <Panel title="安心して遊べる">
        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
          {['本人確認', '承認制', '通報・ブロック'].map((t) => (
            <span
              key={t}
              style={{
                fontSize: 10.5,
                color: C.ink,
                background: C.surfaceLavender,
                border: `1.5px solid ${C.border}`,
                padding: '4px 9px',
                borderRadius: 4,
              }}
            >
              {t}
            </span>
          ))}
        </div>
      </Panel>

      <div
        style={{
          background: C.fill,
          border: `1.5px solid ${C.border}`,
          borderRadius: 12,
          padding: 14,
          display: 'flex',
          flexDirection: 'column',
          gap: 8,
        }}
      >
        <span
          style={{
            alignSelf: 'flex-start',
            fontSize: 11,
            color: C.ink,
            background: C.lime,
            border: `1.5px solid ${C.border}`,
            borderRadius: 20,
            padding: '3px 11px',
          }}
        >
          近日公開 🔜
        </span>
        <span style={{ fontSize: 12, color: '#fff', lineHeight: 1.7 }}>
          もうすぐピタフレがオープンします。今のうちにプロフィールを整えて、公開初日から遊びましょう。
        </span>
      </div>
    </div>
  )
}
