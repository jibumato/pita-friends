/**
 * 「◯◯さんとペアで予約できます」(0126)。
 *
 * このピタメイトに active なペア相手(0125)がいれば、まとめて2人を
 * 予約できる入口をプロフィールに出す。**3回以上遊んだ相手にしか出ない
 * RebookSame等とは違い、掲載条件を満たしてさえいれば誰にでも出す**——
 * ペア予約は初回のゲストにこそ有効な施策(卓が埋まる)なので絞る理由が無い。
 */
import { useEffect, useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import { fetchPairPartnersOf, type PublicPairPartner } from '../lib/queries'

export default function PairPartnerBanner({
  flow,
  hostId,
  hostNickname,
}: {
  flow: Flow
  hostId: string
  hostNickname: string
}) {
  const [partners, setPartners] = useState<PublicPairPartner[] | null>(null)

  useEffect(() => {
    let active = true
    fetchPairPartnersOf(hostId)
      .then((rows) => active && setPartners(rows))
      // 取れなくても、この案内が消えるだけでプロフィール本体には影響しない
      .catch(() => active && setPartners([]))
    return () => {
      active = false
    }
  }, [hostId])

  if (!partners || partners.length === 0) return null
  // 相手が複数いても、まずは先頭の1人を案内する(複数からの選択UIは今回のリリース範囲外)。
  const partner = partners[0]

  return (
    <div
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: 10,
        background: C.surfaceLavender,
        border: `1.5px solid ${C.lavender}`,
        borderRadius: 10,
        padding: '11px 13px',
      }}
    >
      <span style={{ fontSize: 18, flex: 'none' }}>🤝</span>
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 2 }}>
        <span style={{ fontSize: 12, color: C.ink }}>
          {hostNickname}さんは{partner.nickname}さんとペアで予約できます
        </span>
        <span style={{ fontSize: 10, color: C.muted }}>複数人のゲームで、2人まとめて申し込めます</span>
      </div>
      <span
        onClick={() => {
          if (!flow.requireSignIn('booking', { userId: hostId, name: hostNickname })) return
          flow.openPairBooking(hostId, partner.partnerId)
        }}
        role="button"
        tabIndex={0}
        onKeyDown={(e) => {
          if (e.key !== 'Enter' && e.key !== ' ') return
          if (!flow.requireSignIn('booking', { userId: hostId, name: hostNickname })) return
          flow.openPairBooking(hostId, partner.partnerId)
        }}
        style={{
          cursor: 'pointer',
          flex: 'none',
          fontSize: 11.5,
          color: C.onPale,
          background: C.lavender,
          border: `1.5px solid ${C.border}`,
          borderRadius: 8,
          padding: '8px 11px',
          whiteSpace: 'nowrap',
        }}
      >
        ペアで予約
      </span>
    </div>
  )
}
