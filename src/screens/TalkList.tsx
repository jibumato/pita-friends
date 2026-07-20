import { useEffect, useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import BottomTabs from '../components/BottomTabs'
import { Chat } from '../components/Icon'
import { EmptyState } from '../components/States'
import { talkThreads } from '../data/mock'
import { isBackendConfigured } from '../lib/supabase'
import { fetchChatThreads, type ChatThread } from '../lib/queries'

function timeLabel(iso: string | null): string {
  if (!iso) return ''
  const d = new Date(iso)
  const now = new Date()
  const sameDay = d.toDateString() === now.toDateString()
  if (sameDay) return d.toLocaleTimeString('ja-JP', { hour: '2-digit', minute: '2-digit' })
  const yesterday = new Date(now)
  yesterday.setDate(now.getDate() - 1)
  if (d.toDateString() === yesterday.toDateString()) return '昨日'
  return d.toLocaleDateString('ja-JP', { month: 'numeric', day: 'numeric' })
}

export default function TalkList({ flow }: { flow: Flow }) {
  // デモ: トークが無い状態(状態網羅 B1)も確認できるように
  const [cleared, setCleared] = useState(false)
  const [realThreads, setRealThreads] = useState<ChatThread[] | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (!isBackendConfigured) return
    let active = true
    fetchChatThreads()
      .then((data) => active && setRealThreads(data))
      .catch((e) => active && setError(e instanceof Error ? e.message : '取得に失敗しました'))
    return () => {
      active = false
    }
  }, [])

  const threads = isBackendConfigured ? (realThreads ?? []) : cleared ? [] : talkThreads

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
        {!isBackendConfigured && (
          <span
            onClick={() => setCleared((v) => !v)}
            style={{ cursor: 'pointer', fontSize: 10, color: C.muted }}
          >
            {cleared ? '例を表示' : '空の状態'}
          </span>
        )}
      </div>

      {error && (
        <div style={{ margin: '0 20px 10px', background: C.avatarPink, border: `1.5px solid ${C.border}`, borderRadius: 8, padding: '10px 12px', fontSize: 11.5, color: C.ink }}>
          {error}
        </div>
      )}

      {isBackendConfigured && realThreads === null && !error ? (
        <div style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          <span style={{ fontSize: 12, color: C.muted }}>読み込み中…</span>
        </div>
      ) : threads.length === 0 ? (
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
          {isBackendConfigured
            ? (threads as ChatThread[]).map((t) => (
                <div
                  key={t.promiseId}
                  onClick={() => flow.openThread(t.promiseId)}
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
                      background: t.partnerColor,
                      border: `1.5px solid ${C.border}`,
                      display: 'flex',
                      alignItems: 'center',
                      justifyContent: 'center',
                      fontSize: 20,
                      color: C.ink,
                      flex: 'none',
                    }}
                  >
                    {t.partnerInitial}
                  </div>
                  <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 3 }}>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 5 }}>
                      <span style={{ fontSize: 14, color: C.ink }}>{t.partnerName}</span>
                      {t.partnerVerified && (
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
                      {t.lastMessage ?? 'まだメッセージはありません'}
                    </span>
                  </div>
                  <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'flex-end', gap: 5 }}>
                    <span style={{ fontSize: 10, color: C.muted }}>{timeLabel(t.lastMessageAt)}</span>
                    {t.unreadCount > 0 && (
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
                        {t.unreadCount}
                      </span>
                    )}
                  </div>
                </div>
              ))
            : (threads as typeof talkThreads).map((t) => (
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
