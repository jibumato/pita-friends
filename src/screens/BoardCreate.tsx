import { useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { SubHeader, Toggle } from '../components/Ui'
import { usePress } from '../hooks/usePress'
import { isBackendConfigured } from '../lib/supabase'
import { createBoardPost, recordContentFlag } from '../lib/queries'
import { inspectText, guardWarningText, type GuardHit } from '../lib/contentGuard'
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
  // 0113: 募集人数 → 1枠の長さ。募集は「空き枠の告知」で、予約は1対1なので
  const [duration, setDuration] = useState(60)
  const [audience, setAudience] = useState('全員')
  const [verifiedOnly, setVerifiedOnly] = useState(true)
  const [note, setNote] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  /** 「みまもり」検知のヒット(空でなければ確認を挟む)。 */
  const [hits, setHits] = useState<GuardHit[]>([])
  const submit = usePress(`3px 3px 0 ${C.lavender}`)

  function handleSubmitClick() {
    if (busy) return
    if (hits.length === 0) {
      const result = inspectText(note)
      if (result.hits.length > 0) {
        // 投稿はブロックせず、確認を挟む(docs/trust-safety-spec.md §4.2)
        setHits(result.hits)
        return
      }
    }
    void handleSubmit()
  }

  async function handleSubmit() {
    if (busy) return
    if (hits.length > 0) {
      for (const h of hits) void recordContentFlag(h.category, 'board', h.matched, true)
    }
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
        durationMinutes: duration,
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
      <SubHeader title="空き枠を募集する" onBack={() => flow.go('board')} />
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
        <Field label="ゲーム・ジャンル（必須）">
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
        <Field label="1枠の長さ">
          <SegRow
            options={['30分', '60分', '90分', '120分']}
            value={`${duration}分`}
            onPick={(v) => setDuration(Number(v.replace('分', '')))}
          />
        </Field>
        <span style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.6, marginTop: -8 }}>
          ゲストが予約を申し込むときの初期値になります。申し込みが1件入ると、この募集は
          自動的に締め切られます。
        </span>
        <Field label="ボイスチャット">
          <SegRow options={['必須', 'どちらでも', 'なし']} value={vc} onPick={setVc} />
        </Field>
        <Field label="申し込みを受け付ける範囲">
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
        {/* 「みまもり」検知の確認。投稿はブロックせず本人の判断に委ねる。 */}
        {hits.length > 0 && (
          <div
            style={{
              background: C.avatarPink,
              border: `1.5px solid ${C.border}`,
              borderRadius: 8,
              padding: '10px 12px',
              display: 'flex',
              flexDirection: 'column',
              gap: 8,
            }}
          >
            <span style={{ fontSize: 11, color: C.ink, lineHeight: 1.6 }}>
              {guardWarningText(hits)}このまま投稿しますか?
            </span>
            <div style={{ display: 'flex', gap: 8 }}>
              <span
                onClick={() => setHits([])}
                style={{ flex: 1, textAlign: 'center', cursor: 'pointer', fontSize: 11.5, color: C.ink, background: C.white, border: `1.5px solid ${C.border}`, borderRadius: 6, padding: '8px 0' }}
              >
                書き直す
              </span>
              <span
                onClick={() => void handleSubmit()}
                style={{ flex: 1, textAlign: 'center', cursor: 'pointer', fontSize: 11.5, color: C.ink, background: C.lime, border: `1.5px solid ${C.border}`, borderRadius: 6, padding: '8px 0' }}
              >
                このまま投稿
              </span>
            </div>
          </div>
        )}
      </div>
      <div style={{ padding: '12px 20px 26px', background: C.white, borderTop: `1.5px solid ${C.border}` }}>
        <div
          className="pita-press"
          onClick={handleSubmitClick}
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
