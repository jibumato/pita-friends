/**
 * 規約・ポリシー類へのリンク列。
 *
 * **未ログインでも辿れる場所に置くこと。** 特定商取引法に基づく表記は
 * 「購入する前に読めること」が要件で、決済事業者・銀行の審査でも
 * ログインせずに開けるかを見られる。
 *
 * 置き場所は3つ:
 *   ・デスクトップのフッター(`DesktopFooter`)
 *   ・モバイルのホーム最下部(未ログイン時。モバイルにはフッターが無い)
 *   ・登録画面
 *
 * URLで直接開く場合は `/legal/tokushoho` 等(`App.tsx` の `LEGAL_PATHS`)。
 */
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import type { LegalDocKey } from '../content/legalDocs'

export const LEGAL_LINKS: { label: string; key: LegalDocKey }[] = [
  { label: '利用規約', key: 'terms' },
  { label: 'プライバシーポリシー', key: 'privacy' },
  { label: '特定商取引法に基づく表記', key: 'tokushoho' },
  { label: '資金決済法に基づく表示', key: 'shikin' },
]

export default function LegalLinks({
  flow,
  align = 'center',
  size = 11,
  gap = '6px 16px',
}: {
  flow: Flow
  align?: 'center' | 'flex-start' | 'flex-end'
  size?: number
  gap?: string
}) {
  return (
    <div style={{ display: 'flex', flexWrap: 'wrap', justifyContent: align, gap }}>
      {LEGAL_LINKS.map(({ label, key }) => (
        <span
          key={key}
          role="link"
          tabIndex={0}
          onClick={() => flow.openLegalDoc(key)}
          onKeyDown={(e) => {
            if (e.key === 'Enter' || e.key === ' ') {
              e.preventDefault()
              flow.openLegalDoc(key)
            }
          }}
          style={{ cursor: 'pointer', fontSize: size, color: C.muted, textDecoration: 'underline' }}
        >
          {label}
        </span>
      ))}
    </div>
  )
}
