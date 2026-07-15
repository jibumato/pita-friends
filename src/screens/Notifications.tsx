import { useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { SubHeader } from '../components/Ui'
import { Bell } from '../components/Icon'
import { EmptyState } from '../components/States'
import { notifications } from '../data/mock'

export default function Notifications({ flow }: { flow: Flow }) {
  const [read, setRead] = useState(false)
  const items = read ? [] : notifications

  return (
    <Screen background={C.surface}>
      <StatusBar time="21:47" />
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', paddingRight: 20 }}>
        <SubHeader title="通知" onBack={() => flow.go('home')} />
        {items.length > 0 && (
          <span
            onClick={() => setRead(true)}
            style={{ cursor: 'pointer', fontSize: 11, color: C.lavender }}
          >
            すべて既読
          </span>
        )}
      </div>

      {items.length === 0 ? (
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
          style={{
            flex: 1,
            overflowY: 'auto',
            padding: '8px 20px 20px',
            display: 'flex',
            flexDirection: 'column',
            gap: 10,
          }}
        >
          {items.map((n, i) => (
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
                  <span style={{ flex: 1, fontSize: 12.5, color: C.ink, lineHeight: 1.4 }}>
                    {n.title}
                  </span>
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
