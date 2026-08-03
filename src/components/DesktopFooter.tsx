/** デスクトップ版アプリ本体(ログイン後)の下部フッター。
 *  利用規約・プライバシーポリシー等の法務ページへの導線をどの画面からも辿れるようにする。 */
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import LegalLinks from './LegalLinks'

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
      <span style={{ fontSize: 11, color: C.muted }}>
        © 2026 ピタフレ — ゲーム仲間マッチングサービス　
        <span style={{ opacity: 0.7 }}>build {__BUILD_ID__}</span>
      </span>
      <LegalLinks flow={flow} align="flex-end" size={11.5} gap="6px 18px" />
    </footer>
  )
}
