import { useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import BottomTabs from '../components/BottomTabs'
import { Plus, PlusCircle } from '../components/Icon'
import { EmptyState } from '../components/States'
import { boardPosts } from '../data/mock'

const FILTERS = ['すべて', '今夜', 'Apex', 'まったり']

export default function Board({ flow }: { flow: Flow }) {
  const [filter, setFilter] = useState('すべて')
  // 「まったり」だけは掲示板が空(状態網羅: B2)になるデモ
  const empty = filter === 'まったり'

  return (
    <Screen background={C.surface}>
      <StatusBar time="21:47" />
      <div style={{ padding: '12px 20px 0', display: 'flex', flexDirection: 'column', gap: 12 }}>
        <span style={{ fontSize: 21, color: C.ink }}>▶ 募集板</span>
        <div style={{ display: 'flex', gap: 7, flexWrap: 'wrap' }}>
          {FILTERS.map((f) => {
            const sel = filter === f
            return (
              <span
                key={f}
                onClick={() => setFilter(f)}
                style={{
                  cursor: 'pointer',
                  fontSize: 12,
                  color: sel ? C.lime : C.ink,
                  background: sel ? C.ink : C.white,
                  border: `1.5px solid ${C.ink}`,
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

      {empty ? (
        <EmptyState
          tileColor={C.avatarAqua}
          icon={<PlusCircle size={44} color={C.ink} strokeWidth={2.4} />}
          title={
            <>
              今この条件の募集は
              <br />
              まだありません
            </>
          }
          desc={
            <>
              最初の募集を出すと、
              <br />
              いちばん上に表示されます
            </>
          }
          cta="＋ 募集をつくる"
          onCta={() => flow.go('boardCreate')}
        />
      ) : (
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
          {boardPosts.map((p) => (
            <div
              key={p.title}
              style={{
                background: C.white,
                border: `1.5px solid ${C.ink}`,
                borderRadius: 12,
                boxShadow: `3px 3px 0 ${C.ink}`,
                padding: 14,
                display: 'flex',
                flexDirection: 'column',
                gap: 10,
              }}
            >
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <span style={{ fontSize: 14, color: C.ink }}>{p.title}</span>
                <span
                  style={{
                    fontSize: 11,
                    color: C.ink,
                    background: C.lime,
                    border: `1.5px solid ${C.ink}`,
                    padding: '3px 9px',
                    borderRadius: 4,
                  }}
                >
                  {p.slots}
                </span>
              </div>
              <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                {p.tags.map((t) => (
                  <span
                    key={t}
                    style={{
                      fontSize: 11,
                      color: C.ink,
                      background: C.surfaceLavender,
                      padding: '4px 10px',
                      borderRadius: 4,
                      border: `1.5px solid ${C.ink}`,
                    }}
                  >
                    {t}
                  </span>
                ))}
              </div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                <div
                  style={{
                    width: 30,
                    height: 30,
                    borderRadius: 6,
                    background: p.host.color,
                    border: `1.5px solid ${C.ink}`,
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'center',
                    fontSize: 13,
                    color: C.ink,
                  }}
                >
                  {p.host.initial}
                </div>
                <span style={{ fontSize: 11.5, color: C.ink }}>{p.host.name}</span>
                <span
                  style={{
                    fontSize: 9.5,
                    color: C.ink,
                    background: C.lime,
                    border: `1.5px solid ${C.ink}`,
                    padding: '1px 6px',
                    borderRadius: 4,
                  }}
                >
                  ✓
                </span>
                <span style={{ fontSize: 10.5, color: C.muted }}>{p.host.score}</span>
                <div style={{ flex: 1 }} />
                <span
                  onClick={() => flow.go('talk')}
                  style={{
                    cursor: 'pointer',
                    fontSize: 12,
                    color: C.lime,
                    background: C.ink,
                    padding: '7px 16px',
                    borderRadius: 4,
                    boxShadow: `2px 2px 0 ${C.lavender}`,
                  }}
                >
                  参加する
                </span>
              </div>
            </div>
          ))}
        </div>
      )}

      {/* FAB: 募集する */}
      {!empty && (
        <div
          onClick={() => flow.go('boardCreate')}
          style={{
            position: 'absolute',
            right: 18,
            bottom: 104,
            display: 'flex',
            alignItems: 'center',
            gap: 7,
            background: C.lime,
            border: `1.5px solid ${C.ink}`,
            borderRadius: 8,
            padding: '12px 16px',
            boxShadow: `3px 3px 0 ${C.ink}`,
            cursor: 'pointer',
          }}
        >
          <Plus />
          <span style={{ fontSize: 13, color: C.ink }}>募集する</span>
        </div>
      )}

      <BottomTabs current={flow.screen} onNavigate={flow.go} />
    </Screen>
  )
}
