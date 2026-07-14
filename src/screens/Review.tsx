import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import Avatar from '../components/Avatar'
import Badge from '../components/Badge'
import PitaButton from '../components/PitaButton'
import { Shield } from '../components/Icon'
import { REVIEW_TAGS } from '../flow'

export default function Review({ flow }: { flow: Flow }) {
  return (
    <Screen background={C.surface}>
      <StatusBar time="23:31" />
      <div
        className="pita-scroll"
        style={{
          flex: 1,
          overflowY: 'auto',
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          padding: '20px 24px',
          gap: 20,
        }}
      >
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 6 }}>
          <span style={{ fontSize: 20, color: C.ink }}>GG! おつかれさま</span>
          <span style={{ fontSize: 12, color: C.muted }}>今夜のフレを評価しよう</span>
        </div>
        <Avatar initial="み" color={C.avatarAqua} size={80} verified />
        <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
          <span style={{ fontSize: 16, color: C.ink }}>みなと</span>
          <Badge variant="trust" />
        </div>
        {/* 星評価 */}
        <div style={{ display: 'flex', gap: 8 }}>
          {[1, 2, 3, 4, 5].map((n) => (
            <span
              key={n}
              onClick={() => flow.setReviewStars(n)}
              style={{
                cursor: 'pointer',
                fontSize: 40,
                color: n <= flow.reviewStars ? C.avatarOrange : C.starOff,
                lineHeight: 1,
              }}
            >
              ★
            </span>
          ))}
        </div>
        {/* よかった点タグ */}
        <div style={{ width: '100%', display: 'flex', flexDirection: 'column', gap: 10 }}>
          <span style={{ fontSize: 12, color: C.muted }}>よかった点(タップで選択)</span>
          <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
            {REVIEW_TAGS.map((t) => {
              const sel = flow.reviewTag === t
              return (
                <span
                  key={t}
                  onClick={() => flow.setReviewTag(t)}
                  style={{
                    cursor: 'pointer',
                    fontSize: 12,
                    color: sel ? C.lime : C.ink,
                    background: sel ? C.ink : C.white,
                    border: `1.5px solid ${C.ink}`,
                    padding: '8px 14px',
                    borderRadius: 4,
                  }}
                >
                  {t}
                </span>
              )
            })}
          </div>
        </div>
        <div
          style={{
            width: '100%',
            background: C.surfaceLavender,
            border: `1.5px solid ${C.lavender}`,
            borderRadius: 8,
            padding: '10px 12px',
            display: 'flex',
            gap: 8,
            alignItems: 'flex-start',
          }}
        >
          <Shield style={{ flex: 'none', marginTop: 1 }} />
          <span style={{ fontSize: 10.5, lineHeight: 1.6, color: C.body }}>
            お互いの評価がマナースコアになり、次のマッチの信頼につながります。
          </span>
        </div>
      </div>
      <div style={{ padding: '12px 24px 30px', background: C.white, borderTop: `1.5px solid ${C.ink}` }}>
        <PitaButton label="評価を送る ▶" variant="primary" full onClick={() => flow.go('result')} />
      </div>
    </Screen>
  )
}
