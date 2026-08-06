/**
 * 規約・ポリシー類へのリンク列。
 *
 * **未ログインでも辿れる場所に置くこと。** 特定商取引法に基づく表記は
 * 「購入する前に読めること」が要件で、決済事業者・銀行の審査でも
 * ログインせずに開けるかを見られる。
 *
 * ⚠️ **役務提供に関するガイドラインも同じ理由でここに置く**（2026-08-06追加）。
 * 規約 第1条2項により**規約の一部を構成**するため、登録前に読めないと、
 * 第3条6項で求める同意が「読めない文書への同意」になってしまう。
 * 従前は設定画面からしか辿れず、未ログインでは到達できなかった。
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
  // ガイドラインは**規約の一部**（第1条2項）。登録の前に読めないと、
  // 第3条6項の同意（利用規約に同意します）が、読めない文書への同意になる。
  // 定型約款の組入れ（民法548条の2）の観点でも、表示は申込みの前が原則。
  { label: '役務提供に関するガイドライン', key: 'guideline' },
  // 事例集は規約の外だが、ガイドラインだけ読んでも具体像がつかめないので隣に置く
  { label: 'プレイの内容が約束と違ったとき', key: 'examples' },
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
