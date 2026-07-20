import { useEffect, useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import BottomTabs from '../components/BottomTabs'
import { Card, ListRow } from '../components/Ui'
import { Coin } from '../components/Icon'
import { isBackendConfigured } from '../lib/supabase'
import { fetchFriendCount, fetchPendingInviteCount } from '../lib/queries'

export default function MyPage({ flow }: { flow: Flow }) {
  const [friendCount, setFriendCount] = useState<number | null>(null)
  const [pendingCount, setPendingCount] = useState<number | null>(null)

  useEffect(() => {
    if (!isBackendConfigured) return
    let active = true
    fetchFriendCount()
      .then((n) => active && setFriendCount(n))
      .catch(() => active && setFriendCount(0))
    fetchPendingInviteCount()
      .then((n) => active && setPendingCount(n))
      .catch(() => active && setPendingCount(0))
    return () => {
      active = false
    }
  }, [])

  const dotakyanRate =
    flow.confirmedCount >= 3 ? `${Math.round((flow.dotakyanCount / flow.confirmedCount) * 100)}%` : '—'
  const STATS = [
    { v: `★${flow.mannerScore.toFixed(1)}`, l: 'マナー', fg: C.lavender },
    { v: dotakyanRate, l: 'ドタキャン', fg: C.ink },
    { v: String(flow.confirmedCount), l: 'プレイ回数', fg: C.ink },
    { v: isBackendConfigured ? (friendCount === null ? '…' : String(friendCount)) : '12', l: 'フレンド', fg: C.ink },
  ]
  return (
    <Screen background={C.surface}>
      <StatusBar time="21:47" />
      <div
        className="pita-scroll"
        style={{
          flex: 1,
          overflowY: 'auto',
          padding: '12px 20px 0',
          display: 'flex',
          flexDirection: 'column',
          gap: 14,
        }}
      >
        <span style={{ fontSize: 21, color: C.ink }}>▶ マイページ</span>

        {/* プロフィールサマリー */}
        <div
          style={{
            background: C.white,
            border: `1.5px solid ${C.border}`,
            borderRadius: 12,
            boxShadow: `3px 3px 0 ${C.shadowCol}`,
            padding: 14,
            display: 'flex',
            flexDirection: 'column',
            gap: 12,
          }}
        >
          <div style={{ display: 'flex', gap: 12, alignItems: 'center' }}>
            <div
              style={{
                width: 54,
                height: 54,
                borderRadius: 10,
                background: C.avatarOrange,
                border: `1.5px solid ${C.border}`,
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                fontSize: 22,
                color: C.ink,
              }}
            >
              {flow.nickname.charAt(0) || '?'}
            </div>
            <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 3 }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                <span style={{ fontSize: 16, color: C.ink }}>{flow.nickname || 'ニックネーム未設定'}</span>
                <span
                  style={{
                    fontSize: 9.5,
                    color: C.ink,
                    background: flow.isVerified ? C.lime : C.disabledBg,
                    border: `1.5px solid ${C.border}`,
                    padding: '2px 7px',
                    borderRadius: 4,
                  }}
                >
                  {flow.isVerified ? '✓ 本人確認済み' : '本人確認 未完了'}
                </span>
              </div>
              <span style={{ fontSize: 11, color: C.muted }}>
                {flow.hostSettings.games.length > 0 ? flow.hostSettings.games.join(' / ') : 'あそぶゲームを設定しよう'}
              </span>
            </div>
            <span
              onClick={() => flow.go('setup')}
              style={{ fontSize: 11, color: C.lavender, cursor: 'pointer' }}
            >
              編集
            </span>
          </div>
          <div style={{ display: 'flex', gap: 8 }}>
            {STATS.map((s) => (
              <div
                key={s.l}
                style={{
                  flex: 1,
                  background: C.surface,
                  border: `1.5px solid ${C.border}`,
                  borderRadius: 8,
                  padding: '8px 4px',
                  display: 'flex',
                  flexDirection: 'column',
                  alignItems: 'center',
                  gap: 1,
                }}
              >
                <span style={{ fontSize: 15, color: s.fg }}>{s.v}</span>
                <span style={{ fontSize: 9, color: C.muted }}>{s.l}</span>
              </div>
            ))}
          </div>
        </div>

        {/* コインウォレット */}
        <div
          onClick={() => flow.go('wallet')}
          style={{
            cursor: 'pointer',
            background: C.lavender,
            border: `1.5px solid ${C.border}`,
            borderRadius: 12,
            boxShadow: `3px 3px 0 ${C.shadowCol}`,
            padding: '13px 14px',
            display: 'flex',
            alignItems: 'center',
            gap: 12,
          }}
        >
          <div
            style={{
              width: 38,
              height: 38,
              borderRadius: 8,
              background: C.lime,
              border: `1.5px solid ${C.border}`,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              flex: 'none',
            }}
          >
            <Coin size={18} />
          </div>
          <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 2 }}>
            <span style={{ fontSize: 13, color: '#fff' }}>コインウォレット</span>
            <span style={{ fontSize: 10.5, color: C.lavenderText }}>
              残高 {flow.coinBalance.toLocaleString()} コイン
            </span>
          </div>
          <span
            style={{
              fontSize: 11,
              color: C.ink,
              background: C.lime,
              border: `1.5px solid ${C.border}`,
              padding: '6px 11px',
              borderRadius: 4,
            }}
          >
            チャージ
          </span>
        </div>

        {/* メニュー */}
        <Card>
          <ListRow
            label={flow.hostSettings.isHost ? 'ホスト設定' : 'ホストになる'}
            sub={
              flow.hostSettings.isHost
                ? `掲載中 · 1時間 ${flow.hostSettings.hourlyRate} コイン`
                : '一緒に遊ぶ時間をコインで提供できます'
            }
            onClick={() => flow.go('hostSettings')}
          />
          <ListRow
            label="受け取った誘い"
            sub="承認待ちのリクエスト"
            onClick={() => flow.go('requests')}
            right={
              (isBackendConfigured ? (pendingCount ?? 0) : 2) > 0 ? (
                <span
                  style={{
                    fontSize: 10,
                    color: C.ink,
                    background: C.lime,
                    border: `1.5px solid ${C.border}`,
                    borderRadius: 99,
                    minWidth: 18,
                    textAlign: 'center',
                    padding: '1px 6px',
                  }}
                >
                  {isBackendConfigured ? pendingCount : 2}
                </span>
              ) : undefined
            }
          />
          <ListRow
            label="安心設定"
            sub="誘いを受ける範囲・承認制・公開範囲"
            onClick={() => flow.go('safetyPrefs')}
          />
          <ListRow label="プロフィール編集" onClick={() => flow.go('setup')} />
          <ListRow
            label="本人確認ステータス"
            onClick={() => flow.go('verify')}
            right={
              <span
                style={{
                  fontSize: 10,
                  color: C.ink,
                  background: flow.isVerified ? C.lime : C.disabledBg,
                  border: `1.5px solid ${C.border}`,
                  padding: '2px 8px',
                  borderRadius: 4,
                }}
              >
                {flow.isVerified ? '確認済み' : '未確認'}
              </span>
            }
          />
          <ListRow label="ブロックリスト" onClick={() => flow.go('blockList')} />
          <ListRow label="設定" onClick={() => flow.go('settings')} />
          <ListRow label="安全センター・ヘルプ" onClick={() => flow.go('safety')} />
          <ListRow label="利用規約" onClick={() => flow.openLegalDoc('terms')} />
          <ListRow label="プライバシーポリシー" divider={false} onClick={() => flow.openLegalDoc('privacy')} />
        </Card>
        <span
          onClick={flow.signOut}
          style={{ textAlign: 'center', fontSize: 11.5, color: C.placeholder, cursor: 'pointer' }}
        >
          ログアウト
        </span>
      </div>
      <BottomTabs current={flow.screen} onNavigate={flow.go} />
    </Screen>
  )
}
