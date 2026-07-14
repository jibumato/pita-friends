/** 端末ステータスバー(時刻 + 電池)。dark=濃背景画面用に白で描画。 */
import { color as C } from '../theme/tokens'

export default function StatusBar({ time, dark = false }: { time: string; dark?: boolean }) {
  const fg = dark ? '#fff' : C.ink
  return (
    <div
      style={{
        display: 'flex',
        justifyContent: 'space-between',
        alignItems: 'center',
        padding: '14px 24px 4px',
        color: fg,
        fontSize: 13,
      }}
    >
      <span>{time}</span>
      <div style={{ display: 'flex', gap: 5, alignItems: 'center' }}>
        <div style={{ width: 16, height: 9, borderRadius: 2, background: fg }} />
        <div style={{ width: 20, height: 9, borderRadius: 3, border: `1.5px solid ${fg}` }} />
      </div>
    </div>
  )
}
