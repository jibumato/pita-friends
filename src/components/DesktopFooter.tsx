/** デスクトップ版アプリ本体(ログイン後)の下部フッター。
 *  利用規約・プライバシーポリシー等の法務ページへの導線をどの画面からも辿れるようにする。 */
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import type { LegalDocKey } from '../content/legalDocs'

const LEGAL_LINKS: { label: string; key: LegalDocKey }[] = [
  { label: '利用規約', key: 'terms' },
  { label: 'プライバシーポリシー', key: 'privacy' },
  { label: '特定商取引法に基づく表記', key: 'tokushoho' },
  { label: '資金決済法に基づく表示', key: 'shikin' },
]

export default function DesktopFooter({ flow }: { flow: Flow }) {
  return (
    <footer
      style={{
        flex: 'none',
        borderTop: `1.5px solid ${C.border}`,
        background: C.white,
        padding: '16px 24px',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between',
        flexWrap: 'wrap',
        gap: 10,
      }}
    >
      <span style={{ fontSize: 11, color: C.muted }}>© 2026 ピタフレ — ゲーム仲間マッチングサービス</span>
      <div style={{ display: 'flex', gap: 18, flexWrap: 'wrap' }}>
        {LEGAL_LINKS.map(({ label, key }) => (
          <span
            key={key}
            onClick={() => flow.openLegalDoc(key)}
            style={{ cursor: 'pointer', fontSize: 11.5, color: C.muted, textDecoration: 'underline' }}
          >
            {label}
          </span>
        ))}
      </div>
    </footer>
  )
}
