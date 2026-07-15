import type { Flow } from '../App'
import { color as C } from '../theme/tokens'

const REASONS = [
  '外部アプリ(LINE等)への誘導',
  'アプリ外での直接の金銭・RMTの要求',
  '出会い・恋愛目的の勧誘',
  '暴言・ハラスメント',
  'なりすまし・年齢詐称',
]

export default function ReportSheet({ flow }: { flow: Flow }) {
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
        onClick={flow.closeReport}
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
        <span style={{ fontSize: 16, color: C.ink }}>みなと さんを通報 / ブロック</span>
        <span style={{ fontSize: 11, color: C.muted, lineHeight: 1.6 }}>
          下記に当てはまる場合は通報してください。運営が確認し、悪質なユーザーには利用制限を行います。
        </span>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          {REASONS.map((r) => (
            <div
              key={r}
              style={{
                background: C.white,
                border: `1.5px solid ${C.border}`,
                borderRadius: 8,
                padding: '12px 14px',
                fontSize: 12.5,
                color: C.ink,
                cursor: 'pointer',
              }}
            >
              {r}
            </div>
          ))}
        </div>
        <div
          style={{
            background: C.fill,
            color: C.avatarPink,
            borderRadius: 8,
            padding: '14px 0',
            textAlign: 'center',
            fontSize: 14,
            boxShadow: `3px 3px 0 ${C.avatarPink}`,
            cursor: 'pointer',
          }}
        >
          ブロックして通報する
        </div>
        <span
          onClick={flow.closeReport}
          style={{ cursor: 'pointer', textAlign: 'center', fontSize: 12, color: C.muted }}
        >
          閉じる
        </span>
      </div>
    </div>
  )
}
