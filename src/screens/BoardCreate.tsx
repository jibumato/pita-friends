import { useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { SubHeader, Toggle } from '../components/Ui'
import { ChevronDown } from '../components/Icon'
import { usePress } from '../hooks/usePress'

function SegRow({
  options,
  value,
  onPick,
}: {
  options: string[]
  value: string
  onPick: (v: string) => void
}) {
  return (
    <div style={{ display: 'flex', gap: 6 }}>
      {options.map((o) => {
        const sel = value === o
        return (
          <span
            key={o}
            onClick={() => onPick(o)}
            style={{
              flex: 1,
              textAlign: 'center',
              cursor: 'pointer',
              fontSize: 12,
              color: sel ? C.lime : C.ink,
              background: sel ? C.ink : C.white,
              border: `1.5px solid ${C.ink}`,
              padding: '9px 0',
              borderRadius: 4,
            }}
          >
            {o}
          </span>
        )
      })}
    </div>
  )
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
      <span style={{ fontSize: 12, color: C.muted }}>{label}</span>
      {children}
    </div>
  )
}

export default function BoardCreate({ flow }: { flow: Flow }) {
  const [mood, setMood] = useState('エンジョイ')
  const [vc, setVc] = useState('必須')
  const [count, setCount] = useState(2)
  const [verifiedOnly, setVerifiedOnly] = useState(true)
  const submit = usePress(`3px 3px 0 ${C.lavender}`)

  return (
    <Screen background={C.surface}>
      <StatusBar time="21:47" />
      <SubHeader title="募集を作成" onBack={() => flow.go('board')} />
      <div
        className="pita-scroll"
        style={{
          flex: 1,
          overflowY: 'auto',
          padding: '4px 20px 0',
          display: 'flex',
          flexDirection: 'column',
          gap: 16,
        }}
      >
        <Field label="ゲーム">
          <div
            style={{
              background: C.white,
              border: `1.5px solid ${C.ink}`,
              borderRadius: 8,
              padding: '12px 14px',
              display: 'flex',
              justifyContent: 'space-between',
              alignItems: 'center',
            }}
          >
            <span style={{ fontSize: 13, color: C.ink }}>Apex Legends</span>
            <ChevronDown />
          </div>
        </Field>
        <Field label="目的・温度感">
          <SegRow options={['エンジョイ', 'ランク上げ', 'ガチ']} value={mood} onPick={setMood} />
        </Field>
        <div style={{ display: 'flex', gap: 10 }}>
          <div style={{ flex: 1 }}>
            <Field label="日時">
              <div
                style={{
                  background: C.white,
                  border: `1.5px solid ${C.ink}`,
                  borderRadius: 8,
                  padding: '12px 14px',
                }}
              >
                <span style={{ fontSize: 13, color: C.ink }}>今夜 21:30〜</span>
              </div>
            </Field>
          </div>
          <div style={{ width: 120 }}>
            <Field label="募集人数">
              <div
                style={{
                  background: C.white,
                  border: `1.5px solid ${C.ink}`,
                  borderRadius: 8,
                  padding: '9px 12px',
                  display: 'flex',
                  justifyContent: 'space-between',
                  alignItems: 'center',
                }}
              >
                <span
                  onClick={() => setCount((n) => Math.max(1, n - 1))}
                  style={{ cursor: 'pointer', fontSize: 16, color: C.ink, userSelect: 'none' }}
                >
                  −
                </span>
                <span style={{ fontSize: 14, color: C.ink }}>{count}</span>
                <span
                  onClick={() => setCount((n) => Math.min(4, n + 1))}
                  style={{ cursor: 'pointer', fontSize: 16, color: C.ink, userSelect: 'none' }}
                >
                  ＋
                </span>
              </div>
            </Field>
          </div>
        </div>
        <Field label="ボイスチャット">
          <SegRow options={['必須', 'どちらでも', 'なし']} value={vc} onPick={setVc} />
        </Field>
        <div
          style={{
            background: C.white,
            border: `1.5px solid ${C.ink}`,
            borderRadius: 8,
            padding: '13px 14px',
            display: 'flex',
            justifyContent: 'space-between',
            alignItems: 'center',
          }}
        >
          <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
            <span style={{ fontSize: 13, color: C.ink }}>本人確認済みのみ参加可</span>
            <span style={{ fontSize: 10.5, color: C.muted }}>安心のためオンを推奨します</span>
          </div>
          <Toggle on={verifiedOnly} onToggle={() => setVerifiedOnly((v) => !v)} />
        </div>
        <Field label="ひとことメモ(任意)">
          <div
            style={{
              background: C.white,
              border: `1.5px solid ${C.ink}`,
              borderRadius: 8,
              padding: '12px 14px',
              minHeight: 64,
            }}
          >
            <span style={{ fontSize: 12.5, color: C.placeholder }}>
              初心者歓迎です！笑いながらやりましょう〜
            </span>
          </div>
        </Field>
      </div>
      <div style={{ padding: '12px 20px 26px', background: C.white, borderTop: `1.5px solid ${C.ink}` }}>
        <div
          className="pita-press"
          onClick={() => flow.go('board')}
          {...submit.handlers}
          style={{
            cursor: 'pointer',
            background: C.ink,
            color: C.lime,
            borderRadius: 8,
            padding: '14px 0',
            textAlign: 'center',
            fontSize: 14,
            ...submit.style,
          }}
        >
          募集を出す ▶
        </div>
      </div>
    </Screen>
  )
}
