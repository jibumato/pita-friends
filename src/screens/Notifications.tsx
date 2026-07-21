import { useEffect, useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { SubHeader } from '../components/Ui'
import { Bell } from '../components/Icon'
import { EmptyState } from '../components/States'
import { notifications } from '../data/mock'
import { isBackendConfigured } from '../lib/supabase'
import {
  fetchNotifications,
  markAllNotificationsRead,
  resolvePromiseIdForInvite,
  type AppNotification,
} from '../lib/queries'
import type { NotificationType } from '../lib/database.types'

const ICON_BY_TYPE: Record<NotificationType, { icon: string; tint: string }> = {
  invite_received: { icon: '💌', tint: C.avatarPink },
  invite_approved: { icon: '✅', tint: C.lime },
  message_received: { icon: '💬', tint: C.avatarAqua },
  verification_approved: { icon: '🛡️', tint: C.lime },
  verification_rejected: { icon: '⚠️', tint: C.avatarOrange },
  board_joined: { icon: '🎮', tint: C.lavender },
  booking_cancelled: { icon: '🚫', tint: C.avatarOrange },
  booking_completed: { icon: '🪙', tint: C.lime },
}

function timeLabel(iso: string): string {
  const d = new Date(iso)
  const now = new Date()
  const sameDay = d.toDateString() === now.toDateString()
  if (sameDay) return d.toLocaleTimeString('ja-JP', { hour: '2-digit', minute: '2-digit' })
  const yesterday = new Date(now)
  yesterday.setDate(now.getDate() - 1)
  if (d.toDateString() === yesterday.toDateString()) return '昨日'
  return d.toLocaleDateString('ja-JP', { month: 'numeric', day: 'numeric' })
}

export default function Notifications({ flow }: { flow: Flow }) {
  const [read, setRead] = useState(false)
  const [realItems, setRealItems] = useState<AppNotification[] | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (!isBackendConfigured) return
    let active = true
    fetchNotifications()
      .then((data) => active && setRealItems(data))
      .catch((e) => active && setError(e instanceof Error ? e.message : '取得に失敗しました'))
    return () => {
      active = false
    }
  }, [])

  const items = isBackendConfigured ? realItems ?? [] : read ? [] : notifications

  async function handleMarkAllRead() {
    if (isBackendConfigured) {
      setRealItems((xs) => (xs ? xs.map((x) => ({ ...x, read: true })) : xs))
      try {
        await markAllNotificationsRead()
      } catch {
        /* 失敗しても表示上は既読のままにしておく(次回取得時に再同期される) */
      }
    } else {
      setRead(true)
    }
  }

  async function handleTap(n: AppNotification) {
    switch (n.type) {
      case 'invite_received':
        flow.go('requests')
        return
      case 'message_received':
        if (n.relatedId) flow.openThread(n.relatedId)
        return
      case 'invite_approved': {
        if (!n.relatedId) return
        try {
          const promiseId = await resolvePromiseIdForInvite(n.relatedId)
          if (promiseId) flow.openThread(promiseId)
        } catch {
          /* 解決できなければ何もしない */
        }
        return
      }
      case 'board_joined':
        flow.go('board')
        return
      case 'verification_rejected':
        flow.go('verify')
        return
      case 'verification_approved':
        flow.go('mypage')
        return
      case 'booking_cancelled':
        flow.go('talkList')
        return
      case 'booking_completed':
        flow.go('wallet')
        return
    }
  }

  const hasUnread = isBackendConfigured ? (realItems ?? []).some((n) => !n.read) : items.some((n) => 'unread' in n && n.unread)

  return (
    <Screen background={C.surface}>
      <StatusBar time="21:47" />
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', paddingRight: 20 }}>
        <SubHeader title="通知" onBack={() => flow.go('home')} />
        {items.length > 0 && hasUnread && (
          <span onClick={handleMarkAllRead} style={{ cursor: 'pointer', fontSize: 11, color: C.lavender }}>
            すべて既読
          </span>
        )}
      </div>

      {error && (
        <div style={{ margin: '0 20px 10px', background: C.avatarPink, border: `1.5px solid ${C.border}`, borderRadius: 8, padding: '10px 12px', fontSize: 11.5, color: C.ink }}>
          {error}
        </div>
      )}

      {isBackendConfigured && realItems === null && !error ? (
        <div style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          <span style={{ fontSize: 12, color: C.muted }}>読み込み中…</span>
        </div>
      ) : items.length === 0 ? (
        <EmptyState
          tileColor={C.avatarOrange}
          icon={<Bell size={42} color={C.ink} strokeWidth={2.2} />}
          title="新しい通知はありません"
          desc={
            <>
              誘いや約束のリマインドは
              <br />
              ここに届きます
            </>
          }
        />
      ) : (
        <div
          className="pita-scroll"
          style={{ flex: 1, overflowY: 'auto', padding: '8px 20px 20px', display: 'flex', flexDirection: 'column', gap: 10 }}
        >
          {isBackendConfigured
            ? (items as AppNotification[]).map((n) => {
                const meta = ICON_BY_TYPE[n.type]
                return (
                  <div
                    key={n.id}
                    onClick={() => handleTap(n)}
                    style={{
                      cursor: 'pointer',
                      background: n.read ? C.white : C.surfaceLavender,
                      border: `1.5px solid ${C.border}`,
                      borderRadius: 12,
                      boxShadow: `2px 2px 0 ${C.shadowCol}`,
                      padding: '12px 13px',
                      display: 'flex',
                      gap: 11,
                      alignItems: 'flex-start',
                    }}
                  >
                    <div
                      style={{
                        width: 38,
                        height: 38,
                        borderRadius: 8,
                        background: meta.tint,
                        border: `1.5px solid ${C.border}`,
                        display: 'flex',
                        alignItems: 'center',
                        justifyContent: 'center',
                        fontSize: 18,
                        flex: 'none',
                      }}
                    >
                      {meta.icon}
                    </div>
                    <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 3 }}>
                      <div style={{ display: 'flex', alignItems: 'baseline', gap: 6 }}>
                        <span style={{ flex: 1, fontSize: 12.5, color: C.ink, lineHeight: 1.4 }}>{n.title}</span>
                        <span style={{ fontSize: 9.5, color: C.muted, flex: 'none' }}>{timeLabel(n.createdAt)}</span>
                      </div>
                      {n.body && <span style={{ fontSize: 11, color: C.body, lineHeight: 1.6 }}>{n.body}</span>}
                    </div>
                    {!n.read && (
                      <div
                        style={{
                          width: 8,
                          height: 8,
                          borderRadius: '50%',
                          background: C.lavender,
                          border: `1.5px solid ${C.border}`,
                          flex: 'none',
                          marginTop: 4,
                        }}
                      />
                    )}
                  </div>
                )
              })
            : (items as typeof notifications).map((n, i) => (
                <div
                  key={i}
                  style={{
                    background: n.unread ? C.surfaceLavender : C.white,
                    border: `1.5px solid ${C.border}`,
                    borderRadius: 12,
                    boxShadow: `2px 2px 0 ${C.shadowCol}`,
                    padding: '12px 13px',
                    display: 'flex',
                    gap: 11,
                    alignItems: 'flex-start',
                  }}
                >
                  <div
                    style={{
                      width: 38,
                      height: 38,
                      borderRadius: 8,
                      background: n.tint,
                      border: `1.5px solid ${C.border}`,
                      display: 'flex',
                      alignItems: 'center',
                      justifyContent: 'center',
                      fontSize: 18,
                      flex: 'none',
                    }}
                  >
                    {n.icon}
                  </div>
                  <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 3 }}>
                    <div style={{ display: 'flex', alignItems: 'baseline', gap: 6 }}>
                      <span style={{ flex: 1, fontSize: 12.5, color: C.ink, lineHeight: 1.4 }}>{n.title}</span>
                      <span style={{ fontSize: 9.5, color: C.muted, flex: 'none' }}>{n.time}</span>
                    </div>
                    <span style={{ fontSize: 11, color: C.body, lineHeight: 1.6 }}>{n.body}</span>
                  </div>
                  {n.unread && (
                    <div
                      style={{
                        width: 8,
                        height: 8,
                        borderRadius: '50%',
                        background: C.lavender,
                        border: `1.5px solid ${C.border}`,
                        flex: 'none',
                        marginTop: 4,
                      }}
                    />
                  )}
                </div>
              ))}
        </div>
      )}
    </Screen>
  )
}
