import { useEffect, useState } from 'react'
import { color as C } from '../theme/tokens'
import { isBackendConfigured } from '../lib/supabase'
import { fetchMyPurchaseLimit, type PurchaseLimit } from '../lib/queries'

/**
 * 購入上限の表示（規約 第8条の6第5項1号）。
 *
 * ■ 当たる前に見せる
 *   上限に当たったときのメッセージは既に金額つきで出る（`functionErrorMessage`）。
 *   ただし**それは壁にぶつかってから**の話で、押す前は分からなかった。
 *   買おうとして弾かれる体験は、前払いの壁をさらに高くする。
 *
 * ■ 理由を必ず書く
 *   `purchase_limit_status` は、なぜ上限が付いているかを3つのフラグで返す。
 *   0087 の注記のとおり、**理由の分からない上限は問い合わせを生むだけでなく、
 *   優越的地位の濫用の評価でも説明できない措置**になる。だから理由を出す。
 *
 * ■ 上限が無い人には何も出さない
 *   大半の利用者には関係が無い。常設すると「自分も制限されている」という
 *   誤解になる。
 */
export default function PurchaseLimitNotice() {
  const [limit, setLimit] = useState<PurchaseLimit | null>(null)

  useEffect(() => {
    if (!isBackendConfigured) return
    let active = true
    fetchMyPurchaseLimit()
      .then((l) => active && setLimit(l))
      // 取れなければ出さない。購入そのものは止めない
      .catch(() => {})
    return () => {
      active = false
    }
  }, [])

  if (!limit || !limit.isNewUser) return null

  const yen = (v: number | null) => (v == null ? '—' : `${v.toLocaleString()}円`)

  const reasons: string[] = []
  if (limit.reasonUnverified) reasons.push('本人確認がまだのため')
  if (limit.reasonNewAccount) reasons.push(`ご登録から${limit.periodDays}日以内のため`)
  if (limit.reasonDisputed) reasons.push('過去の決済に取り消しがあったため')

  return (
    <div
      style={{
        background: C.surfaceLavender,
        border: `1.5px solid ${C.lavender}`,
        borderRadius: 8,
        padding: '11px 13px',
        display: 'flex',
        flexDirection: 'column',
        gap: 5,
      }}
    >
      <span style={{ fontSize: 11.5, color: C.ink }}>
        いまは <b>1回 {yen(limit.perPurchaseMaxYen)}</b> ・{' '}
        <b>
          {limit.periodDays}日で {yen(limit.periodMaxYen)}
        </b>{' '}
        までの購入に制限しています
      </span>
      <span style={{ fontSize: 10.5, color: C.body, lineHeight: 1.7 }}>
        {reasons.length > 0 && <>{reasons.join('、')}です。</>}
        この期間に <b style={{ color: C.ink }}>{yen(limit.spentYen)}</b> 購入されていて、あと{' '}
        <b style={{ color: C.ink }}>{yen(limit.remainingYen)}</b> 購入できます。
        {limit.reasonUnverified && (
          <>
            <br />
            <b style={{ color: C.ink }}>本人確認を済ませると解除されます。</b>
          </>
        )}
      </span>
    </div>
  )
}
