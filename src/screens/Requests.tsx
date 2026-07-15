import { useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { SubHeader } from '../components/Ui'
import { Shield } from '../components/Icon'
import { EmptyState } from '../components/States'
import { inviteRequests, type InviteRequest } from '../data/mock'

/** 相手の信頼情報タイル。 */
function TrustStat({ value, label }: { value: string; label: string }) {
  return (
    <div
      style={{
        flex: 1,
        background: C.surface,
        border: `1.5px solid ${C.border}`,
        borderRadius: 8,
        padding: '7px 4px',
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        gap: 1,
      }}
    >
      <span style={{ fontSize: 13, color: C.ink }}>{value}</span>
      <span style={{ fontSize: 9, color: C.muted }}>{label}</span>
    </div>
  )
}

function RequestCard({
  r,
  onApprove,
  onDecline,
  onReport,
}: {
  r: InviteRequest
  onApprove: () => void
  onDecline: () => void
  onReport: () => void
}) {
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
        gap: 11,
      }}
    >
      {/* 相手 + 通報 */}
      <div style={{ display: 'flex', gap: 12, alignItems: 'center' }}>
        <div
          style={{
            width: 48,
            height: 48,
            borderRadius: 10,
            background: r.color,
            border: `1.5px solid ${C.border}`,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            fontSize: 20,
            color: C.ink,
          }}
        >
          {r.initial}
        </div>
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 3 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
            <span style={{ fontSize: 15, color: C.ink }}>{r.name}</span>
            {r.verified && (
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
            )}
          </div>
          <div style={{ display: 'flex', gap: 5, flexWrap: 'wrap' }}>
            {r.common.map((t) => (
              <span
                key={t}
                style={{
                  fontSize: 10,
                  color: C.ink,
                  background: C.surfaceLavender,
                  padding: '2px 8px',
                  borderRadius: 4,
                  border: `1.5px solid ${C.border}`,
                }}
              >
                共通: {t}
              </span>
            ))}
          </div>
        </div>
        <span
          onClick={onReport}
          style={{ cursor: 'pointer', fontSize: 10, color: C.lavender, flex: 'none' }}
        >
          通報 ›
        </span>
      </div>

      {/* 信頼情報 */}
      <div style={{ display: 'flex', gap: 8 }}>
        <TrustStat value={r.manner} label="マナー" />
        <TrustStat value={r.dotakyan} label="ドタキャン" />
        <TrustStat value={String(r.plays)} label="プレイ回数" />
      </div>

      {/* 誘い内容 */}
      <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
        <span
          style={{
            fontSize: 11,
            color: C.ink,
            background: C.surfaceLavender,
            padding: '4px 10px',
            borderRadius: 4,
            border: `1.5px solid ${C.border}`,
          }}
        >
          {r.game}
        </span>
        <span
          style={{
            fontSize: 11,
            color: C.ink,
            background: C.surfaceLavender,
            padding: '4px 10px',
            borderRadius: 4,
            border: `1.5px solid ${C.border}`,
          }}
        >
          {r.when}
        </span>
      </div>
      <div
        style={{
          background: C.surface,
          border: `1.5px solid ${C.divider}`,
          borderRadius: 8,
          padding: '9px 12px',
        }}
      >
        <span style={{ fontSize: 11.5, color: C.body, lineHeight: 1.6 }}>{r.message}</span>
      </div>

      {/* アクション: 承認 / 辞退 */}
      <div style={{ display: 'flex', gap: 8 }}>
        <span
          onClick={onDecline}
          style={{
            flex: 1,
            textAlign: 'center',
            cursor: 'pointer',
            fontSize: 12.5,
            color: C.ink,
            background: C.white,
            border: `1.5px solid ${C.border}`,
            borderRadius: 8,
            padding: '10px 0',
          }}
        >
          辞退
        </span>
        <span
          onClick={onApprove}
          style={{
            flex: 1.6,
            textAlign: 'center',
            cursor: 'pointer',
            fontSize: 12.5,
            color: C.ink,
            background: C.lime,
            border: `1.5px solid ${C.border}`,
            borderRadius: 8,
            padding: '10px 0',
            boxShadow: `2px 2px 0 ${C.shadowCol}`,
          }}
        >
          ✓ 承認してトークへ
        </span>
      </div>
    </div>
  )
}

export default function Requests({ flow }: { flow: Flow }) {
  const [items, setItems] = useState<InviteRequest[]>(inviteRequests)
  const remove = (id: string) => setItems((xs) => xs.filter((x) => x.id !== id))

  return (
    <Screen background={C.surface}>
      <StatusBar time="21:47" />
      <SubHeader title="受け取った誘い" onBack={() => flow.go('mypage')} />
      {items.length === 0 ? (
        <EmptyState
          tileColor={C.avatarAqua}
          icon={<Shield size={42} color={C.ink} strokeWidth={2.2} />}
          title="承認待ちの誘いはありません"
          desc={
            <>
              あなたの安心設定を満たした誘いだけが、
              <br />
              ここにリクエストとして届きます
            </>
          }
        />
      ) : (
        <div
          className="pita-scroll"
          style={{
            flex: 1,
            overflowY: 'auto',
            padding: '10px 20px 20px',
            display: 'flex',
            flexDirection: 'column',
            gap: 14,
          }}
        >
          <div
            style={{
              background: C.surfaceLavender,
              border: `1.5px solid ${C.lavender}`,
              borderRadius: 8,
              padding: '9px 12px',
              display: 'flex',
              gap: 8,
              alignItems: 'center',
            }}
          >
            <Shield size={14} style={{ flex: 'none' }} />
            <span style={{ fontSize: 10.5, color: C.body, lineHeight: 1.6 }}>
              承認するまで、相手にトークや連絡先は開きません。相手の信頼情報を見て、あなたが決められます。
            </span>
          </div>
          {items.map((r) => (
            <RequestCard
              key={r.id}
              r={r}
              onApprove={() => flow.go('talk')}
              onDecline={() => remove(r.id)}
              onReport={flow.openReport}
            />
          ))}
        </div>
      )}
    </Screen>
  )
}
