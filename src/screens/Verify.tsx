import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { ChevronLeft, Shield } from '../components/Icon'
import { usePress } from '../hooks/usePress'

function StepRow({
  n,
  title,
  sub,
  status,
}: {
  n: number
  title: string
  sub: string
  status: 'done' | 'pending'
}) {
  return (
    <div style={{ display: 'flex', gap: 12, alignItems: 'center' }}>
      <div
        style={{
          width: 36,
          height: 36,
          borderRadius: 8,
          background: C.lavender,
          border: `1.5px solid ${C.border}`,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          color: '#fff',
          fontSize: 15,
        }}
      >
        {n}
      </div>
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 2 }}>
        <span style={{ fontSize: 13, color: C.ink }}>{title}</span>
        <span style={{ fontSize: 10.5, color: C.muted }}>{sub}</span>
      </div>
      <span style={{ fontSize: 16, color: status === 'done' ? C.lime : C.placeholder }}>
        {status === 'done' ? '✓' : '…'}
      </span>
    </div>
  )
}

export default function Verify({ flow }: { flow: Flow }) {
  const cta = usePress(`3px 3px 0 ${C.lavender}`)
  return (
    <Screen background={C.surface}>
      <StatusBar time="21:44" />
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '8px 20px 0' }}>
        <div onClick={() => flow.go('welcome')} style={{ cursor: 'pointer' }}>
          <ChevronLeft />
        </div>
        <span style={{ fontSize: 11, color: C.muted }}>STEP 1 / 2</span>
      </div>
      <div
        style={{
          flex: 1,
          display: 'flex',
          flexDirection: 'column',
          padding: '16px 22px 0',
          gap: 18,
        }}
      >
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          <span style={{ fontSize: 22, color: C.ink, lineHeight: 1.4 }}>
            まず本人確認を
            <br />
            おねがいします
          </span>
          <span style={{ fontSize: 12, color: C.muted, lineHeight: 1.7 }}>
            安心して遊べる場をつくるため、全員に本人確認をお願いしています。確認済みバッジが付き、マッチ率も上がります。
          </span>
        </div>
        <div
          style={{
            background: C.white,
            border: `1.5px solid ${C.border}`,
            borderRadius: 12,
            boxShadow: `4px 4px 0 ${C.shadowCol}`,
            padding: 16,
            display: 'flex',
            flexDirection: 'column',
            gap: 14,
          }}
        >
          <StepRow n={1} title="本人確認書類を撮影" sub="運転免許証・マイナンバーカード等" status="done" />
          <div style={{ height: 1.5, background: C.divider }} />
          <StepRow n={2} title="顔写真で本人照合" sub="1分で完了 · 書類は暗号化保存" status="pending" />
        </div>
        <div
          style={{
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
            年齢確認を兼ねています。18歳未満はご利用いただけません。
          </span>
        </div>
      </div>
      <div style={{ padding: '12px 22px 30px' }}>
        <div
          className="pita-press"
          onClick={() => flow.go('setup')}
          {...cta.handlers}
          style={{
            cursor: 'pointer',
            background: C.ctaBg,
            color: C.ctaFg,
            borderRadius: 8,
            padding: '15px 0',
            textAlign: 'center',
            fontSize: 15,
            ...cta.style,
          }}
        >
          本人確認を始める ▶
        </div>
      </div>
    </Screen>
  )
}
