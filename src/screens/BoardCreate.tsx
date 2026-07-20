import { useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { SubHeader, Toggle } from '../components/Ui'
import { usePress } from '../hooks/usePress'
import { isBackendConfigured } from '../lib/supabase'
import { createBoardPost } from '../lib/queries'
import { GAMES, WHENS } from '../flow'
import type { BoardMood, BoardVc, BoardAudience } from '../lib/database.types'

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
    <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
      {options.map((o) => {
        const sel = value === o
        return (
          <span
            key={o}
            onClick={() => onPick(o)}
            style={{
              flex: options.length <= 4 ? 1 : undefined,
              textAlign: 'center',
              cursor: 'pointer',
              fontSize: 12,
              color: sel ? C.lime : C.ink,
              background: sel ? C.fill : C.white,
              border: `1.5px solid ${C.border}`,
              padding: '9px 12px',
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
  const [game, setGame] = useState<string>(GAMES[0])
  const [mood, setMood] = useState('エンジョイ')
  const [whenText, setWhenText] = useState<string>(WHENS[0])
  const [vc, setVc] = useState('どちらでも')
  const [count, setCount] = useState(2)
  const [audience, setAudience] = useState('全員')
  const [verifiedOnly, setVerifiedOnly] = useState(true)
  const [note, setNote] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const submit = usePress(`3px 3px 0 ${C.lavender}`)

  async function handleSubmit() {
    if (busy) return
    if (!isBackendConfigured) {
      flow.go('board')
      return
    }
    setBusy(true)
    setError(null)
    try {
      await createBoardPost({
        game,
        mood: mood as BoardMood,
        whenText,
        capacity: count,
        vc: vc as BoardVc,
        audience: audience as BoardAudience,
        verifiedOnly,
        note: note.trim(),
      })
      flow.go('board')
    } catch (e) {
      setError(e instanceof Error ? e.message : '募集の作成に失敗しました')
      setBusy(false)
    }
  }

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
        <Field label="ゲーム（必須）">
          <SegRow options={[...GAMES]} value={game} onPick={setGame} />
        </Field>
        <Field label="目的・温度感">
          <SegRow options={['エンジョイ', 'ランク上げ', 'ガチ']} value={mood} onPick={setMood} />
        </Field>
        <div style={{ display: 'flex', gap: 10, alignItems: 'flex-end' }}>
          <div style={{ flex: 1 }}>
            <Field label="日時">
              <SegRow options={[...WHENS]} value={whenText} onPick={setWhenText} />
            </Field>
          </div>
        </div>
        <Field label="募集人数">
          <div
            style={{
              width: 140,
              background: C.white,
              border: `1.5px solid ${C.border}`,
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
        <Field label="ボイスチャット">
          <SegRow options={['必須', 'どちらでも', 'なし']} value={vc} onPick={setVc} />
        </Field>
        <Field label="参加を受け付ける範囲">
          <SegRow options={['全員', '同性のみ']} value={audience} onPick={setAudience} />
        </Field>
        <span style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.6, marginTop: -8 }}>
          安心して遊ぶための受付制限です。特定の性別を指定して募ることはできません。
        </span>
        <div
          style={{
            background: C.white,
            border: `1.5px solid ${C.border}`,
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
          <textarea
            value={note}
            onChange={(e) => setNote(e.target.value)}
            maxLength={200}
            placeholder="初心者歓迎です！笑いながらやりましょう〜"
            style={{
              background: C.white,
              border: `1.5px solid ${C.border}`,
              borderRadius: 8,
              padding: '12px 14px',
              minHeight: 64,
              fontSize: 12.5,
              color: C.ink,
              resize: 'none',
              fontFamily: 'inherit',
              outline: 'none',
            }}
          />
        </Field>
        {error && <span style={{ fontSize: 11, color: C.avatarPink, lineHeight: 1.6 }}>{error}</span>}
      </div>
      <div style={{ padding: '12px 20px 26px', background: C.white, borderTop: `1.5px solid ${C.border}` }}>
        <div
          className="pita-press"
          onClick={handleSubmit}
          {...(busy ? {} : submit.handlers)}
          style={{
            cursor: busy ? 'not-allowed' : 'pointer',
            opacity: busy ? 0.6 : 1,
            background: C.ctaBg,
            color: C.ctaFg,
            borderRadius: 8,
            padding: '14px 0',
            textAlign: 'center',
            fontSize: 14,
            ...(busy ? {} : submit.style),
          }}
        >
          {busy ? '作成中…' : '募集を出す ▶'}
        </div>
      </div>
    </Screen>
  )
}
