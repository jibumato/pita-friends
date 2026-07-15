import { useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import BottomTabs from '../components/BottomTabs'
import { Chat } from '../components/Icon'
import { EmptyState } from '../components/States'
import { talkThreads } from '../data/mock'

export default function TalkList({ flow }: { flow: Flow }) {
  // デモ: トークが無い状態(状態網羅 B1)も確認できるように
  const [cleared, setCleared] = useState(false)
  const threads = cleared ? [] : talkThreads

  return (
    <Screen background={C.surface}>
      <StatusBar time="21:47" />
      <div
        style={{
          padding: '12px 20px 4px',
          display: 'flex',
          justifyContent: 'space-between',
          alignItems: 'center',
        }}
      >
        <span style={{ fontSize: 21, color: C.ink }}>▶ トーク</span>
        <span
          onClick={() => setCleared((v) => !v)}
          style={{ cursor: 'pointer', fontSize: 10, color: C.muted }}
        >
          {cleared ? '例を表示' : '空の状態'}
        </span>
      </div>

      {threads.length === 0 ? (
        <EmptyState
          tileColor={C.lavender}
          icon={<Chat size={44} color="#fff" strokeWidth={2.2} />}
          title="まだトークはありません"
          desc={
            <>
              気になる仲間を誘うと、
              <br />
              ここにトークルームができます
            </>
          }
          cta="仲間をさがす ▶"
          ctaVariant="confirm"
          onCta={() => flow.go('search')}
        />
      ) : (
        <div
          className="pita-scroll"
          style={{ flex: 1, overflowY: 'auto', padding: '10px 16px 0' }}
        >
          {threads.map((t) => (
            <div
              key={t.name}
              onClick={() => flow.go('talk')}
              style={{
                cursor: 'pointer',
                display: 'flex',
                gap: 12,
                alignItems: 'center',
                padding: '13px 8px',
                borderBottom: `1.5px solid ${C.divider}`,
              }}
            >
              <div
                style={{
                  width: 48,
                  height: 48,
                  borderRadius: 10,
                  background: t.color,
                  border: `1.5px solid ${C.border}`,
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  fontSize: 20,
                  color: C.ink,
                  flex: 'none',
                }}
              >
                {t.initial}
              </div>
              <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 3 }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 5 }}>
                  <span style={{ fontSize: 14, color: C.ink }}>{t.name}</span>
                  {t.verified && (
                    <span
                      style={{
                        fontSize: 8.5,
                        color: C.ink,
                        background: C.lime,
                        border: `1.5px solid ${C.border}`,
                        padding: '1px 5px',
                        borderRadius: 4,
                      }}
                    >
                      ✓
                    </span>
                  )}
                </div>
                <span
                  style={{
                    fontSize: 11.5,
                    color: C.muted,
                    overflow: 'hidden',
                    textOverflow: 'ellipsis',
                    whiteSpace: 'nowrap',
                  }}
                >
                  {t.last}
                </span>
              </div>
              <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'flex-end', gap: 5 }}>
                <span style={{ fontSize: 10, color: C.muted }}>{t.time}</span>
                {t.unread && (
                  <span
                    style={{
                      fontSize: 10,
                      color: C.ink,
                      background: C.lime,
                      border: `1.5px solid ${C.border}`,
                      borderRadius: 99,
                      minWidth: 18,
                      textAlign: 'center',
                      padding: '0 5px',
                    }}
                  >
                    {t.unread}
                  </span>
                )}
              </div>
            </div>
          ))}
        </div>
      )}

      <BottomTabs current={flow.screen} onNavigate={flow.go} />
    </Screen>
  )
}
