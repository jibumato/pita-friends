/**
 * ペア相手の管理(0125)。ピタメイト設定に置く。
 *
 * 一覧(申請中・成立済み)と、新しく申請する検索欄をまとめて持つ。
 * ゲスト側の「ペアで予約」入口(PairPartnerBanner)は、ここで成立させた
 * active な関係だけを見る。
 */
import { useEffect, useState } from 'react'
import { color as C } from '../theme/tokens'
import {
  fetchMyPairPartners,
  proposePairPartner,
  respondPairPartner,
  endPairPartner,
  fetchDiscoverableHosts,
  type PairPartner,
} from '../lib/queries'

function Row({
  p,
  busy,
  onAccept,
  onDecline,
  onEnd,
}: {
  p: PairPartner
  busy: boolean
  onAccept: () => void
  onDecline: () => void
  onEnd: () => void
}) {
  return (
    <div
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: 10,
        padding: '10px 0',
        borderBottom: `1px solid ${C.divider}`,
      }}
    >
      <div
        style={{
          flex: 'none',
          width: 32,
          height: 32,
          borderRadius: '50%',
          background: p.partnerAvatarColor,
          border: `1.5px solid ${C.border}`,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          fontSize: 12,
          color: C.onPale,
        }}
      >
        {p.partnerAvatarInitial}
      </div>
      <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column' }}>
        <span style={{ fontSize: 12.5, color: C.ink, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
          {p.partnerNickname}
        </span>
        <span style={{ fontSize: 10, color: C.muted }}>
          {p.status === 'active' ? 'ペア相手' : p.requestedByMe ? '申請中（返事待ち）' : 'あなたへの申請'}
        </span>
      </div>
      {p.status === 'pending' && !p.requestedByMe && (
        <>
          <span
            onClick={busy ? undefined : onAccept}
            style={{
              cursor: busy ? 'default' : 'pointer',
              opacity: busy ? 0.5 : 1,
              fontSize: 11,
              color: C.onPale,
              background: C.lime,
              border: `1.5px solid ${C.border}`,
              borderRadius: 6,
              padding: '6px 10px',
            }}
          >
            承認
          </span>
          <span
            onClick={busy ? undefined : onDecline}
            style={{
              cursor: busy ? 'default' : 'pointer',
              opacity: busy ? 0.5 : 1,
              fontSize: 11,
              color: C.muted,
              padding: '6px 4px',
            }}
          >
            断る
          </span>
        </>
      )}
      {(p.status === 'active' || (p.status === 'pending' && p.requestedByMe)) && (
        <span
          onClick={busy ? undefined : onEnd}
          style={{
            cursor: busy ? 'default' : 'pointer',
            opacity: busy ? 0.5 : 1,
            fontSize: 11,
            color: C.muted,
            padding: '6px 4px',
          }}
        >
          {p.status === 'active' ? '解消' : '取り下げ'}
        </span>
      )}
    </div>
  )
}

export default function PairPartnerManager() {
  const [partners, setPartners] = useState<PairPartner[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busyId, setBusyId] = useState<string | null>(null)
  const [query, setQuery] = useState('')
  const [candidates, setCandidates] = useState<{ userId: string; nickname: string }[] | null>(null)
  const [searching, setSearching] = useState(false)

  function reload() {
    fetchMyPairPartners()
      .then(setPartners)
      .catch((e) => setError(e instanceof Error ? e.message : '取得に失敗しました'))
  }

  useEffect(reload, [])

  async function handleAccept(p: PairPartner) {
    setBusyId(p.id)
    setError(null)
    try {
      await respondPairPartner(p.id, true)
      reload()
    } catch (e) {
      setError(e instanceof Error ? e.message : '操作に失敗しました')
    } finally {
      setBusyId(null)
    }
  }
  async function handleDecline(p: PairPartner) {
    setBusyId(p.id)
    setError(null)
    try {
      await respondPairPartner(p.id, false)
      reload()
    } catch (e) {
      setError(e instanceof Error ? e.message : '操作に失敗しました')
    } finally {
      setBusyId(null)
    }
  }
  async function handleEnd(p: PairPartner) {
    setBusyId(p.id)
    setError(null)
    try {
      await endPairPartner(p.id)
      reload()
    } catch (e) {
      setError(e instanceof Error ? e.message : '操作に失敗しました')
    } finally {
      setBusyId(null)
    }
  }

  async function handleSearch(q: string) {
    setQuery(q)
    if (q.trim().length === 0) {
      setCandidates(null)
      return
    }
    setSearching(true)
    try {
      // 専用の検索APIが無いので、掲載中のピタメイト一覧を取ってニックネームで絞る。
      // 設定画面での稀な操作なので、通信の重さより実装の単純さを優先した。
      const hosts = await fetchDiscoverableHosts(null)
      const q2 = q.trim().toLowerCase()
      setCandidates(
        hosts
          .filter((h) => h.nickname.toLowerCase().includes(q2))
          .slice(0, 8)
          .map((h) => ({ userId: h.userId, nickname: h.nickname })),
      )
    } catch {
      setCandidates([])
    } finally {
      setSearching(false)
    }
  }

  async function handlePropose(userId: string) {
    setBusyId(userId)
    setError(null)
    try {
      await proposePairPartner(userId)
      setQuery('')
      setCandidates(null)
      reload()
    } catch (e) {
      setError(e instanceof Error ? e.message : '申請に失敗しました')
    } finally {
      setBusyId(null)
    }
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
      <span style={{ fontSize: 12, color: C.muted }}>ペア相手（任意）</span>
      <span style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.6, marginTop: -4 }}>
        複数人で遊ぶゲームで、2人まとめてゲストに予約してもらえるようになります。両方の承認で成立します。
      </span>

      {partners && partners.length > 0 && (
        <div style={{ background: C.white, border: `1.5px solid ${C.border}`, borderRadius: 10, padding: '2px 12px' }}>
          {partners.map((p) => (
            <Row
              key={p.id}
              p={p}
              busy={busyId === p.id}
              onAccept={() => void handleAccept(p)}
              onDecline={() => void handleDecline(p)}
              onEnd={() => void handleEnd(p)}
            />
          ))}
        </div>
      )}

      <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
        <input
          value={query}
          onChange={(e) => void handleSearch(e.target.value)}
          placeholder="ニックネームでペア相手を探す"
          style={{
            border: `1.5px solid ${C.border}`,
            borderRadius: 8,
            padding: '9px 11px',
            fontSize: 12.5,
            color: C.ink,
            fontFamily: 'inherit',
          }}
        />
        {searching && <span style={{ fontSize: 10.5, color: C.muted }}>さがしています…</span>}
        {candidates && candidates.length === 0 && !searching && (
          <span style={{ fontSize: 10.5, color: C.muted }}>見つかりませんでした</span>
        )}
        {candidates && candidates.length > 0 && (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
            {candidates.map((c) => (
              <div
                key={c.userId}
                style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '6px 2px' }}
              >
                <span style={{ fontSize: 12, color: C.ink }}>{c.nickname}</span>
                <span
                  onClick={busyId === c.userId ? undefined : () => void handlePropose(c.userId)}
                  style={{
                    cursor: busyId === c.userId ? 'default' : 'pointer',
                    opacity: busyId === c.userId ? 0.5 : 1,
                    fontSize: 11,
                    color: C.onPale,
                    background: C.lavender,
                    border: `1.5px solid ${C.border}`,
                    borderRadius: 6,
                    padding: '6px 10px',
                  }}
                >
                  申請する
                </span>
              </div>
            ))}
          </div>
        )}
      </div>

      {error && <span style={{ fontSize: 11, color: C.avatarPink }}>{error}</span>}
    </div>
  )
}
