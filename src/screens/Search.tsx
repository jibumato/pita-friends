import { useEffect, useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import BottomTabs from '../components/BottomTabs'
import { Search as SearchIcon, Coin } from '../components/Icon'
import { EmptyState, ErrorState, SkeletonCard } from '../components/States'
import { searchUsers } from '../data/mock'

type Phase = 'loading' | 'results' | 'empty' | 'error'
const FILTERS = ['今夜あそべる', 'Apex', 'ゴールド帯', 'エンジョイ', '✓ 本人確認済みのみ']

export default function Search({ flow }: { flow: Flow }) {
  const [phase, setPhase] = useState<Phase>('loading')
  const [selected, setSelected] = useState<Record<string, boolean>>({
    今夜あそべる: true,
    Apex: true,
    '✓ 本人確認済みのみ': true,
  })

  // 初回マウントで検索中 → 結果
  useEffect(() => {
    if (phase !== 'loading') return
    const t = setTimeout(() => setPhase('results'), 850)
    return () => clearTimeout(t)
  }, [phase])

  return (
    <Screen background={C.surface}>
      <StatusBar time="21:47" />
      <div style={{ padding: '12px 20px 0', display: 'flex', flexDirection: 'column', gap: 12 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <span style={{ fontSize: 21, color: C.ink }}>▶ さがす</span>
          {/* デモ状態スイッチャ(ハーネス上での状態網羅プレビュー) */}
          <div style={{ display: 'flex', gap: 4 }}>
            {(
              [
                ['results', '結果'],
                ['loading', '検索中'],
                ['empty', '0件'],
                ['error', 'エラー'],
              ] as [Phase, string][]
            ).map(([p, label]) => (
              <span
                key={p}
                onClick={() => setPhase(p)}
                style={{
                  cursor: 'pointer',
                  fontSize: 9,
                  color: phase === p ? C.lime : C.muted,
                  background: phase === p ? C.fill : 'transparent',
                  border: `1.5px solid ${phase === p ? C.ink : C.placeholder}`,
                  padding: '2px 6px',
                  borderRadius: 4,
                }}
              >
                {label}
              </span>
            ))}
          </div>
        </div>
        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: 10,
            background: C.white,
            border: `1.5px solid ${C.border}`,
            borderRadius: 8,
            padding: '12px 14px',
            boxShadow: `2px 2px 0 ${C.shadowCol}`,
          }}
        >
          <SearchIcon size={16} color={C.ink} strokeWidth={2.4} />
          <span style={{ fontSize: 13, color: C.placeholder }}>ゲーム名・プレイスタイルで検索</span>
        </div>
        <div style={{ display: 'flex', gap: 7, flexWrap: 'wrap' }}>
          {FILTERS.map((f) => {
            const sel = !!selected[f]
            const isVerify = f.startsWith('✓')
            return (
              <span
                key={f}
                onClick={() => setSelected((s) => ({ ...s, [f]: !s[f] }))}
                style={{
                  cursor: 'pointer',
                  fontSize: 12,
                  color: sel ? (isVerify ? C.ink : C.lime) : C.ink,
                  background: sel ? (isVerify ? C.lime : C.ink) : C.white,
                  border: `1.5px solid ${C.border}`,
                  padding: '7px 13px',
                  borderRadius: 4,
                }}
              >
                {f}
              </span>
            )
          })}
        </div>
      </div>

      {phase === 'results' && (
        <div
          className="pita-scroll"
          style={{
            flex: 1,
            overflowY: 'auto',
            padding: '16px 20px 0',
            display: 'flex',
            flexDirection: 'column',
            gap: 12,
          }}
        >
          <span style={{ fontSize: 11.5, color: C.muted }}>24人が条件にマッチ · 相性順</span>
          <div
            style={{
              background: C.surfaceLavender,
              border: `1.5px solid ${C.lavender}`,
              borderRadius: 8,
              padding: '8px 11px',
              display: 'flex',
              gap: 8,
              alignItems: 'center',
            }}
          >
            <span style={{ fontSize: 13, flex: 'none' }}>🛡️</span>
            <span style={{ fontSize: 10, color: C.body, lineHeight: 1.5 }}>
              「安心設定」で受け身にしている人は表示されません。誘いは相手の設定により承認制になります。
            </span>
          </div>
          {searchUsers.map((u) => (
            <div
              key={u.name}
              onClick={() => flow.go('profile')}
              style={{
                cursor: 'pointer',
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
              <div style={{ display: 'flex', gap: 12, alignItems: 'center' }}>
                <div
                  style={{
                    width: 50,
                    height: 50,
                    borderRadius: 8,
                    background: u.color,
                    border: `1.5px solid ${C.border}`,
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'center',
                    fontSize: 20,
                    color: C.ink,
                  }}
                >
                  {u.initial}
                </div>
                <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 2 }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 6, flexWrap: 'wrap' }}>
                    <span style={{ fontSize: 15, color: C.ink }}>{u.name}</span>
                    <span
                      style={{
                        fontSize: 9.5,
                        color: C.ink,
                        background: C.lime,
                        border: `1.5px solid ${C.border}`,
                        padding: '2px 7px',
                        borderRadius: 4,
                      }}
                    >
                      ✓ 本人確認済み
                    </span>
                    <span
                      style={{
                        fontSize: 9.5,
                        color: C.ink,
                        background: u.gender === '女性' ? C.avatarPink : C.avatarAqua,
                        border: `1.5px solid ${C.border}`,
                        padding: '2px 7px',
                        borderRadius: 4,
                      }}
                    >
                      {u.gender}
                    </span>
                  </div>
                  <span style={{ fontSize: 10.5, color: C.muted }}>{u.meta}</span>
                </div>
                <span style={{ fontSize: 17, color: C.lavender }}>{u.score}%</span>
              </div>
              <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                {u.tags.map((t) => (
                  <span
                    key={t}
                    style={{
                      fontSize: 11,
                      color: C.ink,
                      background: C.surfaceLavender,
                      padding: '4px 10px',
                      borderRadius: 4,
                      border: `1.5px solid ${C.border}`,
                    }}
                  >
                    {t}
                  </span>
                ))}
              </div>
              {u.hourlyRate != null && (
                <div
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    gap: 8,
                    borderTop: `1.5px solid ${C.divider}`,
                    paddingTop: 10,
                  }}
                >
                  <Coin size={14} />
                  <span style={{ flex: 1, fontSize: 12, color: C.ink }}>
                    1時間 {u.hourlyRate} コインでホスト中
                  </span>
                  <span
                    onClick={(e) => {
                      e.stopPropagation()
                      flow.startBooking({
                        name: u.name,
                        initial: u.initial,
                        color: u.color,
                        hourlyRate: u.hourlyRate!,
                      })
                    }}
                    style={{
                      cursor: 'pointer',
                      fontSize: 12,
                      color: C.ctaFg,
                      background: C.ctaBg,
                      padding: '7px 14px',
                      borderRadius: 4,
                      boxShadow: `2px 2px 0 ${C.lavender}`,
                    }}
                  >
                    予約する
                  </span>
                </div>
              )}
            </div>
          ))}
        </div>
      )}

      {phase === 'loading' && (
        <div
          style={{
            flex: 1,
            padding: '16px 20px 0',
            display: 'flex',
            flexDirection: 'column',
            gap: 12,
          }}
        >
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <div
              style={{
                width: 16,
                height: 16,
                borderRadius: '50%',
                border: '2.5px solid #E3DEF0',
                borderTopColor: C.lavender,
                borderRightColor: C.lavender,
                animation: 'ringSpin .9s linear infinite',
              }}
            />
            <span style={{ fontSize: 11.5, color: C.muted }}>条件に合う仲間をさがしています…</span>
          </div>
          <SkeletonCard />
          <SkeletonCard dim />
        </div>
      )}

      {phase === 'empty' && (
        <EmptyState
          tileColor={C.white}
          icon={
            <svg width="42" height="42" viewBox="0 0 24 24" fill="none" stroke={C.placeholder} strokeWidth={2.2} strokeLinecap="round">
              <circle cx="11" cy="11" r="7" />
              <path d="M16.5 16.5 L21 21" />
              <path d="M8.5 11 h5" stroke={C.avatarPink} />
            </svg>
          }
          title={
            <>
              条件に合う仲間が
              <br />
              見つかりませんでした
            </>
          }
          desc={
            <>
              条件をすこしゆるめると、
              <br />
              候補がぐっと増えます
            </>
          }
          cta="募集を出して待つ ▶"
          onCta={() => flow.go('board')}
        />
      )}

      {phase === 'error' && <ErrorState code="NET-503" onRetry={() => setPhase('loading')} />}

      <BottomTabs current={flow.screen} onNavigate={flow.go} />
    </Screen>
  )
}
