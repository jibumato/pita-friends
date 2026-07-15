/** 5フェーズのフローレール(準備→探す→約束→合流→評価)。現在地をハイライト。 */
import { color as C } from '../theme/tokens'

const RAIL = ['準備', '探す', '約束', '合流', '評価']

export default function FlowRail({ step }: { step: number }) {
  return (
    <div style={{ width: '100%', maxWidth: 720, display: 'flex', gap: 8, marginBottom: 24 }}>
      {RAIL.map((label, i) => (
        <div key={label} style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 6 }}>
          <div
            style={{
              height: 6,
              borderRadius: 99,
              background: i <= step ? C.lime : C.white,
              border: `1.5px solid ${C.border}`,
            }}
          />
          <span
            style={{
              fontSize: 10.5,
              color: i === step ? C.ink : C.muted,
              textAlign: 'center',
            }}
          >
            {label}
          </span>
        </div>
      ))}
    </div>
  )
}
