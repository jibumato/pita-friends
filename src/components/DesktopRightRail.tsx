/** デスクトップ専用の右レール(コイン残高/週間ランキング/安心して遊べる/近日公開)。
 *  ホーム/さがす画面の右側に共通表示。 */
import { useEffect, useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import { Coin } from './Icon'
import { clickable } from '../hooks/clickable'
import { isBackendConfigured } from '../lib/supabase'
import { fetchHostRanking, type RankingEntry } from '../lib/queries'

const MEDAL = ['🥇', '🥈', '🥉']

const DEMO_RANKING: RankingEntry[] = [
  { rank: 1, hostId: 'd1', nickname: 'ののか', avatarInitial: 'の', avatarColor: '#FFC7D9', completedCount: 58, mannerScore: 4.9, score: 98, isVerified: true },
  { rank: 2, hostId: 'd2', nickname: 'みなと', avatarInitial: 'み', avatarColor: '#B3E5F2', completedCount: 51, mannerScore: 4.8, score: 94, isVerified: true },
  { rank: 3, hostId: 'd3', nickname: 'あおい', avatarInitial: 'あ', avatarColor: '#E3DCFF', completedCount: 47, mannerScore: 4.8, score: 91, isVerified: true },
  { rank: 4, hostId: 'd4', nickname: 'りく', avatarInitial: 'り', avatarColor: '#C9F2C7', completedCount: 40, mannerScore: 4.7, score: 87, isVerified: false },
  { rank: 5, hostId: 'd5', nickname: 'そら', avatarInitial: 'そ', avatarColor: '#FBD79E', completedCount: 36, mannerScore: 4.7, score: 84, isVerified: true },
]

function Panel({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div
      style={{
        background: C.white,
        border: `1.5px solid ${C.border}`,
        borderRadius: 12,
        boxShadow: `3px 3px 0 ${C.shadowCol}`,
        padding: 14,
        display: 'flex',
        flexDirection: 'column',
        gap: 10,
      }}
    >
      <span style={{ fontSize: 12.5, color: C.ink, fontWeight: 700 }}>{title}</span>
      {children}
    </div>
  )
}

export default function DesktopRightRail({ flow }: { flow: Flow }) {
  const [ranking, setRanking] = useState<RankingEntry[] | null>(null)

  useEffect(() => {
    if (!isBackendConfigured) return
    let active = true
    fetchHostRanking('weekly', 5)
      .then((rows) => active && setRanking(rows))
      .catch(() => {})
    return () => {
      active = false
    }
  }, [])

  const rows = isBackendConfigured ? (ranking ?? []) : DEMO_RANKING

  return (
    <div
      style={{
        flex: 'none',
        width: 304,
        display: 'flex',
        flexDirection: 'column',
        gap: 14,
        padding: 18,
        borderLeft: `1.5px solid ${C.border}`,
        background: C.surface,
        overflowY: 'auto',
      }}
    >
      <Panel title="コイン残高">
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <Coin size={20} color={C.ink} />
          <span style={{ fontSize: 22, color: C.ink, fontVariantNumeric: 'tabular-nums' }}>
            {flow.coinBalance.toLocaleString()}
          </span>
        </div>
        <div
          onClick={() => flow.go('wallet')}
          {...clickable(() => flow.go('wallet'), 'コインをチャージ')}
          style={{
            cursor: 'pointer',
            textAlign: 'center',
            fontSize: 12,
            color: C.ink,
            background: C.lime,
            border: `1.5px solid ${C.border}`,
            borderRadius: 8,
            padding: '9px 0',
          }}
        >
          チャージする
        </div>
        <span style={{ fontSize: 10, color: C.muted }}>コインの有効期限は最終購入日から180日</span>
      </Panel>

      <Panel title="今週のランキング">
        <div
          onClick={() => flow.go('ranking')}
          {...clickable(() => flow.go('ranking'), 'ランキングをすべて見る')}
          style={{ cursor: 'pointer', display: 'flex', flexDirection: 'column', gap: 8 }}
        >
          {rows.length === 0 ? (
            <span style={{ fontSize: 11, color: C.muted }}>まだ実績がありません</span>
          ) : (
            rows.map((r) => (
              <div key={r.hostId} style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                <span style={{ width: 18, fontSize: 13, textAlign: 'center', flex: 'none' }}>
                  {MEDAL[r.rank - 1] ?? r.rank}
                </span>
                <div
                  style={{
                    width: 26,
                    height: 26,
                    borderRadius: 6,
                    background: r.avatarColor,
                    border: `1.5px solid ${C.border}`,
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'center',
                    fontSize: 11,
                    color: C.ink,
                    flex: 'none',
                  }}
                >
                  {r.avatarInitial}
                </div>
                <span style={{ flex: 1, fontSize: 11.5, color: C.ink, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                  {r.nickname}
                </span>
                <span style={{ fontSize: 10.5, color: C.muted }}>★{r.mannerScore.toFixed(1)}</span>
              </div>
            ))
          )}
        </div>
      </Panel>

      <Panel title="安心して遊べる">
        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
          {['本人確認', '承認制', '通報・ブロック'].map((t) => (
            <span
              key={t}
              style={{
                fontSize: 10.5,
                color: C.ink,
                background: C.surfaceLavender,
                border: `1.5px solid ${C.border}`,
                padding: '4px 9px',
                borderRadius: 4,
              }}
            >
              {t}
            </span>
          ))}
        </div>
      </Panel>

      <div
        style={{
          background: C.fill,
          border: `1.5px solid ${C.border}`,
          borderRadius: 12,
          padding: 14,
          display: 'flex',
          flexDirection: 'column',
          gap: 8,
        }}
      >
        <span
          style={{
            alignSelf: 'flex-start',
            fontSize: 11,
            color: C.ink,
            background: C.lime,
            border: `1.5px solid ${C.border}`,
            borderRadius: 20,
            padding: '3px 11px',
          }}
        >
          近日公開 🔜
        </span>
        <span style={{ fontSize: 12, color: '#fff', lineHeight: 1.7 }}>
          もうすぐピタフレがオープンします。今のうちにプロフィールを整えて、公開初日から遊びましょう。
        </span>
      </div>
    </div>
  )
}
