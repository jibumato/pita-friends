import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { SubHeader, Card, ListRow } from '../components/Ui'

const REPORTS = [
  '暴言・ハラスメント',
  '金銭の要求・勧誘',
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
            border: `1.5px solid ${C.ink}`,
            borderRadius: 12,
            boxShadow: `3px 3px 0 ${C.ink}`,
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
            通報は24時間以内に対応します。緊急の危険を感じた場合は警察(110)へ連絡してください。
          </span>
        </div>

        <span style={{ fontSize: 13, color: C.ink }}>▶ 困ったことがありましたか?</span>
        <Card>
          {REPORTS.map((r, i) => (
            <ListRow key={r} label={r} divider={i < REPORTS.length - 1} />
          ))}
        </Card>

        <div style={{ display: 'flex', gap: 10 }}>
          <div
            style={{
              flex: 1,
              background: C.white,
              border: `1.5px solid ${C.ink}`,
              borderRadius: 10,
              boxShadow: `2px 2px 0 ${C.ink}`,
              padding: 13,
              display: 'flex',
              flexDirection: 'column',
              gap: 3,
            }}
          >
            <span style={{ fontSize: 13, color: C.ink }}>ブロックする</span>
            <span style={{ fontSize: 10, color: C.muted }}>相手に通知されません</span>
          </div>
          <div
            style={{
              flex: 1,
              background: C.white,
              border: `1.5px solid ${C.ink}`,
              borderRadius: 10,
              boxShadow: `2px 2px 0 ${C.ink}`,
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
            ・通話・メッセージはアプリ内で完結、金銭のやり取りは禁止
          </span>
        </div>
      </div>
    </Screen>
  )
}
