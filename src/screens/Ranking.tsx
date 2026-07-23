import { useEffect, useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { SubHeader } from '../components/Ui'
import { isBackendConfigured } from '../lib/supabase'
import { fetchHostRanking, type RankingEntry, type RankingPeriod } from '../lib/queries'

const PERIODS: { key: RankingPeriod; label: string }[] = [
  { key: 'daily', label: 'デイリー' },
  { key: 'weekly', label: 'ウィークリー' },
  { key: 'monthly', label: 'マンスリー' },
]

/** デモ表示用の固定ランキング(バックエンド未接続時)。 */
const DEMO: RankingEntry[] = [
  { rank: 1, hostId: '', nickname: 'ののか', avatarInitial: 'の', avatarColor: '#FFC7D9', completedCount: 18, mannerScore: 4.9, score: 17.6, isVerified: true },
  { rank: 2, hostId: '', nickname: 'みなと', avatarInitial: 'み', avatarColor: '#B3E5F2', completedCount: 15, mannerScore: 4.8, score: 14.4, isVerified: true },
  { rank: 3, hostId: '', nickname: 'りく', avatarInitial: 'り', avatarColor: '#C9F2C7', completedCount: 13, mannerScore: 4.7, score: 12.2, isVerified: false },
  { rank: 4, hostId: '', nickname: 'あおい', avatarInitial: 'あ', avatarColor: '#E3DCFF', completedCount: 10, mannerScore: 4.8, score: 9.6, isVerified: true },
  { rank: 5, hostId: '', nickname: 'ハル', avatarInitial: 'ハ', avatarColor: '#FFE1B3', completedCount: 8, mannerScore: 4.6, score: 7.4, isVerified: false },
]

function medal(rank: number): { bg: string; fg: string } | null {
  if (rank === 1) return { bg: '#F6C945', fg: C.ink }
  if (rank === 2) return { bg: '#C9CDD6', fg: C.ink }
  if (rank === 3) return { bg: '#E0A66B', fg: C.ink }
  return null
}

export default function Ranking({ flow }: { flow: Flow }) {
  const [period, setPeriod] = useState<RankingPeriod>('weekly')
  const [rows, setRows] = useState<RankingEntry[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (!isBackendConfigured) {
      setRows(DEMO)
      setLoading(false)
      return
    }
    let active = true
    setLoading(true)
    setError(null)
    fetchHostRanking(period)
      .then((r) => active && setRows(r))
      .catch((e) => active && setError(e instanceof Error ? e.message : '読み込みに失敗しました'))
      .finally(() => active && setLoading(false))
    return () => {
      active = false
    }
  }, [period])

  return (
    <Screen background={C.surface}>
      <StatusBar time="21:47" />
      <SubHeader title="ランキング" onBack={() => flow.go('home')} />

      <div style={{ padding: '4px 20px 0', display: 'flex', flexDirection: 'column', gap: 12, flex: 1, overflow: 'hidden' }}>
        {/* 期間タブ */}
        <div style={{ display: 'flex', gap: 6 }}>
          {PERIODS.map((p) => {
            const sel = period === p.key
            return (
              <span
                key={p.key}
                onClick={() => setPeriod(p.key)}
                style={{
                  flex: 1,
                  textAlign: 'center',
                  cursor: 'pointer',
                  fontSize: 13,
                  color: sel ? C.ink : C.muted,
                  background: sel ? C.lime : C.white,
                  border: `1.5px solid ${C.border}`,
                  padding: '9px 0',
                  borderRadius: 8,
                }}
              >
                {p.label}
              </span>
            )
          })}
        </div>

        <div className="pita-scroll" style={{ flex: 1, overflowY: 'auto', display: 'flex', flexDirection: 'column', gap: 8, paddingBottom: 8 }}>
          {loading ? (
            <span style={{ fontSize: 12, color: C.muted, textAlign: 'center', padding: '24px 0' }}>読み込み中…</span>
          ) : error ? (
            <span style={{ fontSize: 12, color: C.avatarPink, textAlign: 'center', padding: '24px 0' }}>{error}</span>
          ) : rows.length === 0 ? (
            <span style={{ fontSize: 12, color: C.muted, textAlign: 'center', padding: '24px 0' }}>
              この期間の記録はまだありません
            </span>
          ) : (
            rows.map((r) => {
              const m = medal(r.rank)
              return (
                <div
                  key={r.rank + r.nickname}
                  onClick={() => r.hostId && flow.openProfile(r.hostId)}
                  style={{
                    cursor: r.hostId ? 'pointer' : 'default',
                    display: 'flex',
                    alignItems: 'center',
                    gap: 12,
                    background: C.white,
                    border: `1.5px solid ${C.border}`,
                    borderRadius: 12,
                    boxShadow: m ? `3px 3px 0 ${C.lavender}` : `2px 2px 0 ${C.shadowCol}`,
                    padding: '11px 13px',
                  }}
                >
                  <div
                    style={{
                      width: 30,
                      height: 30,
                      flex: 'none',
                      borderRadius: 8,
                      background: m ? m.bg : C.fill,
                      border: `1.5px solid ${C.border}`,
                      display: 'flex',
                      alignItems: 'center',
                      justifyContent: 'center',
                      fontSize: 13,
                      color: m ? m.fg : C.ink,
                    }}
                  >
                    {r.rank}
                  </div>
                  <div
                    style={{
                      width: 40,
                      height: 40,
                      flex: 'none',
                      borderRadius: 10,
                      background: r.avatarColor,
                      border: `1.5px solid ${C.border}`,
                      display: 'flex',
                      alignItems: 'center',
                      justifyContent: 'center',
                      fontSize: 17,
                      color: C.ink,
                    }}
                  >
                    {r.avatarInitial || r.nickname.charAt(0)}
                  </div>
                  <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 2, minWidth: 0 }}>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                      <span style={{ fontSize: 14, color: C.ink, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                        {r.nickname}
                      </span>
                      {r.isVerified && (
                        <span style={{ fontSize: 9, color: C.ink, background: C.lime, border: `1.5px solid ${C.border}`, padding: '1px 5px', borderRadius: 4, flex: 'none' }}>
                          ✓
                        </span>
                      )}
                    </div>
                    <span style={{ fontSize: 10.5, color: C.muted }}>
                      今期 {r.completedCount} 回プレイ · マナー ★{r.mannerScore.toFixed(1)}
                    </span>
                  </div>
                  <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'flex-end', flex: 'none' }}>
                    <span style={{ fontSize: 10, color: C.muted }}>スコア</span>
                    <span style={{ fontSize: 15, color: C.lavender }}>{r.score.toFixed(1)}</span>
                  </div>
                </div>
              )
            })
          )}

          <div
            style={{
              marginTop: 4,
              background: C.surfaceLavender,
              border: `1.5px solid ${C.lavender}`,
              borderRadius: 8,
              padding: '10px 12px',
            }}
          >
            <span style={{ fontSize: 10.5, lineHeight: 1.7, color: C.body }}>
              ランキングは<b style={{ color: C.ink }}>プレイ実績・評価・信頼性（応答/ドタキャンの少なさ）</b>で決まります。
              投げ銭やコインの購入額・稼いだ額は<b style={{ color: C.ink }}>一切含まれません</b>。
            </span>
          </div>
        </div>
      </div>
    </Screen>
  )
}
