import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { SubHeader, Card } from '../components/Ui'

const REPORTS = [
  '暴言・ハラスメント',
  'アプリ外での直接の金銭要求',
  '出会い目的・不適切な誘い',
  'ドタキャン・無断欠席',
  'なりすまし・偽プロフィール',
  'その他',
]

export default function SafetyCenter({ flow }: { flow: Flow }) {
  return (
    <Screen background={C.surface}>
      <StatusBar time="21:47" />
      <SubHeader title="安全センター" onBack={() => flow.go('mypage')} />
      <div
        className="pita-scroll"
        style={{
          flex: 1,
          overflowY: 'auto',
          padding: '4px 20px 24px',
          display: 'flex',
          flexDirection: 'column',
          gap: 14,
        }}
      >
        <div
          style={{
            background: C.lime,
            border: `1.5px solid ${C.border}`,
            borderRadius: 12,
            boxShadow: `3px 3px 0 ${C.shadowCol}`,
            padding: 14,
            display: 'flex',
            gap: 12,
            alignItems: 'center',
          }}
        >
          <svg
            width="30"
            height="30"
            viewBox="0 0 24 24"
            fill="none"
            stroke={C.ink}
            strokeWidth={2}
            strokeLinecap="round"
            strokeLinejoin="round"
            style={{ flex: 'none' }}
          >
            <path d="M12 3 L20 6 V11 C20 16 17 19.5 12 21 C7 19.5 4 16 4 11 V6 Z" />
            <path d="M9 12 L11 14 L15 9.5" />
          </svg>
          <span style={{ fontSize: 12, lineHeight: 1.7, color: C.ink }}>
            通報は原則24時間以内に内容の確認に着手するよう努めます。緊急の危険を感じた場合は警察(110)へ連絡してください。
          </span>
        </div>

        <span style={{ fontSize: 13, color: C.ink }}>▶ こんな時は、その相手を通報してください</span>
        <Card>
          {REPORTS.map((r, i) => (
            <div
              key={r}
              style={{
                padding: '13px 14px',
                borderBottom: i < REPORTS.length - 1 ? `1.5px solid ${C.divider}` : 'none',
              }}
            >
              <span style={{ fontSize: 13, color: C.ink }}>{r}</span>
            </div>
          ))}
        </Card>
        <span style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.6, marginTop: -6 }}>
          通報はトーク画面やプロフィール画面の「通報」から、その相手を選んで行えます。
        </span>

        <div style={{ display: 'flex', gap: 10 }}>
          <div
            onClick={() => flow.go('blockList')}
            style={{
              cursor: 'pointer',
              flex: 1,
              background: C.white,
              border: `1.5px solid ${C.border}`,
              borderRadius: 10,
              boxShadow: `2px 2px 0 ${C.shadowCol}`,
              padding: 13,
              display: 'flex',
              flexDirection: 'column',
              gap: 3,
            }}
          >
            <span style={{ fontSize: 13, color: C.ink }}>ブロックリスト</span>
            <span style={{ fontSize: 10, color: C.muted }}>ブロック中の相手を確認・解除</span>
          </div>
          <div
            onClick={() => flow.openLegalDoc('mimamori')}
            style={{
              cursor: 'pointer',
              flex: 1,
              background: C.white,
              border: `1.5px solid ${C.border}`,
              borderRadius: 10,
              boxShadow: `2px 2px 0 ${C.shadowCol}`,
              padding: 13,
              display: 'flex',
              flexDirection: 'column',
              gap: 3,
            }}
          >
            <span style={{ fontSize: 13, color: C.ink }}>安全ガイド</span>
            <span style={{ fontSize: 10, color: C.muted }}>安心して遊ぶコツ</span>
          </div>
        </div>

        <div
          style={{
            background: C.surfaceLavender,
            border: `1.5px solid ${C.lavender}`,
            borderRadius: 8,
            padding: '11px 13px',
            display: 'flex',
            flexDirection: 'column',
            gap: 5,
          }}
        >
          <span style={{ fontSize: 11.5, color: C.ink }}>ピタフレの約束</span>
          <span style={{ fontSize: 10.5, lineHeight: 1.7, color: C.body }}>
            ・全ユーザーが本人確認済み
            <br />
            ・違反者は再登録不可(身分証ベースで排除)
            <br />
            ・通話・メッセージはアプリ内で完結。予約はコイン決済のみで、アプリ外での直接の金銭要求は禁止
          </span>
        </div>
      </div>
    </Screen>
  )
}
