import { useMemo, useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { SubHeader } from '../components/Ui'
import { usePress } from '../hooks/usePress'
import { isBackendConfigured } from '../lib/supabase'
import { createGuestRequest, recordContentFlag } from '../lib/queries'
import { inspectText, guardWarningText, type GuardHit } from '../lib/contentGuard'
import { GAMES } from '../flow'
import { MIN_LEAD_MINUTES, TIME_WINDOWS, timeWindowRange, type TimeWindowKey } from '../content/bookingPolicy'

/**
 * ゲストのリクエストを出す画面（0120）。
 *
 * ■ 募集板（BoardCreate）との違いを、画面の上でもはっきりさせる
 *   募集板は**ピタメイトが空き枠を告知する場**で、誰でも見られる。
 *   リクエストは**公開されない。** 条件の合うピタメイトへ通知として届き、
 *   応じた人だけが本人に見える。ここを混ぜると、リクエストが
 *   「無料で相手を募る掲示板」として使われはじめる。
 *
 * ■ 「予約はまだ成立しない」ことを、出す前に書く
 *   応じた人が出てから、いつもどおり予約して初めて成立する。
 *   ここを曖昧にすると「リクエストを出した＝約束できた」と受け取られ、
 *   誰も来なかったときの落差が大きくなる。
 */
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

const inputStyle: React.CSSProperties = {
  width: '100%',
  background: C.white,
  color: C.ink,
  border: `1.5px solid ${C.border}`,
  borderRadius: 8,
  padding: '9px 10px',
  fontSize: 13,
  fontFamily: 'inherit',
}

/** `<input type="datetime-local">` に渡せる文字列（ローカル時刻）にする。 */
function toLocalInput(d: Date): string {
  const p = (n: number) => n.toString().padStart(2, '0')
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`
}

const WHEN_OPTIONS = [...TIME_WINDOWS.map((w) => w.label), '日時を選ぶ']

export default function RequestCreate({ flow }: { flow: Flow }) {
  const [game, setGame] = useState<string>(GAMES[0])
  const [duration, setDuration] = useState(60)
  const [whenLabel, setWhenLabel] = useState<string>(TIME_WINDOWS[0].label)
  const [from, setFrom] = useState('')
  const [to, setTo] = useState('')
  const [note, setNote] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [hits, setHits] = useState<GuardHit[]>([])
  const submit = usePress(`3px 3px 0 ${C.lavender}`)

  const custom = whenLabel === '日時を選ぶ'

  /**
   * 送る範囲。プリセットは `timeWindowRange` をそのまま使う。
   *
   * ⚠️ プリセットの開始は「いま」に寄せられる（今夜を22時に押したら22時から）。
   *    サーバは**いまから30分より先**しか受け付けないので、ここで押し出す。
   *    押し出さないと、押した瞬間に WINDOW_TOO_SOON で弾かれる。
   */
  const range = useMemo<{ from: Date; to: Date } | null>(() => {
    if (custom) {
      if (!from || !to) return null
      return { from: new Date(from), to: new Date(to) }
    }
    const key = TIME_WINDOWS.find((w) => w.label === whenLabel)?.key as TimeWindowKey
    const r = timeWindowRange(key)
    const earliest = new Date(Date.now() + (MIN_LEAD_MINUTES + 5) * 60_000)
    return { from: r.from < earliest ? earliest : r.from, to: r.to }
  }, [custom, from, to, whenLabel])

  /** 出す前に自分で気づける警告（サーバの検査と同じ順で見る）。 */
  const warning = useMemo<string | null>(() => {
    if (!range) return null
    if (!(range.to > range.from)) return '終わりは、始まりより後にしてください。'
    if (range.to.getTime() - range.from.getTime() < duration * 60_000)
      return '遊ぶ長さより広い範囲にしてください。'
    if (range.to.getTime() - range.from.getTime() > 7 * 24 * 3600_000)
      return '範囲が広すぎます。7日以内にしてください。'
    return null
  }, [range, duration])

  function handleSubmitClick() {
    if (busy) return
    if (hits.length === 0) {
      const result = inspectText(note)
      if (result.hits.length > 0) {
        setHits(result.hits)
        return
      }
    }
    void handleSubmit()
  }

  async function handleSubmit() {
    if (busy || !range || warning) return
    if (hits.length > 0) {
      for (const h of hits) void recordContentFlag(h.category, 'board', h.matched, true)
    }
    if (!isBackendConfigured) {
      flow.go('myRequests')
      return
    }
    setBusy(true)
    setError(null)
    try {
      await createGuestRequest({
        game,
        windowStart: range.from,
        windowEnd: range.to,
        durationMinutes: duration,
        note: note.trim(),
      })
      flow.go('myRequests')
    } catch (e) {
      setError(e instanceof Error ? e.message : 'リクエストを出せませんでした')
      setBusy(false)
    }
  }

  const rangeLabel = range
    ? `${range.from.toLocaleString('ja-JP', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' })} 〜 ${range.to.toLocaleString('ja-JP', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' })}`
    : null

  return (
    <Screen background={C.surface}>
      <StatusBar time="21:47" />
      <SubHeader title="リクエストを出す" onBack={() => flow.go('board')} />
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
        <div
          style={{
            background: C.surfaceLavender,
            border: `1.5px solid ${C.lavender}`,
            borderRadius: 8,
            padding: '11px 13px',
            fontSize: 11,
            lineHeight: 1.8,
            color: C.ink,
          }}
        >
          リクエストは<b>掲示板には出ません。</b>
          同じゲームを登録しているピタメイトにだけ届き、応じた方があなたにだけ表示されます。
          <br />
          応じた方が出たら、
          <b>いつもどおり予約して成立</b>です（この画面では予約になりません）。
        </div>

        <Field label="ゲーム・ジャンル（必須）">
          <SegRow options={[...GAMES]} value={game} onPick={setGame} />
        </Field>

        <Field label="遊びたい長さ">
          <SegRow
            options={['30分', '60分', '90分', '120分']}
            value={`${duration}分`}
            onPick={(v) => setDuration(Number(v.replace('分', '')))}
          />
        </Field>

        <Field label="いつ遊びたいか">
          <SegRow options={WHEN_OPTIONS} value={whenLabel} onPick={setWhenLabel} />
        </Field>

        {custom ? (
          <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap' }}>
            <div style={{ flex: '1 1 180px' }}>
              <Field label="この時間から">
                <input
                  type="datetime-local"
                  value={from}
                  min={toLocalInput(new Date(Date.now() + MIN_LEAD_MINUTES * 60_000))}
                  onChange={(e) => setFrom(e.target.value)}
                  style={inputStyle}
                />
              </Field>
            </div>
            <div style={{ flex: '1 1 180px' }}>
              <Field label="この時間まで">
                <input
                  type="datetime-local"
                  value={to}
                  onChange={(e) => setTo(e.target.value)}
                  style={inputStyle}
                />
              </Field>
            </div>
          </div>
        ) : (
          rangeLabel && (
            <span style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.6, marginTop: -8 }}>
              {rangeLabel} のあいだで探します。
              <b style={{ color: C.ink }}>広く取るほど応じてもらいやすくなります。</b>
            </span>
          )
        )}

        {warning && (
          <div
            style={{
              background: C.avatarPink,
              border: `1.5px solid ${C.border}`,
              borderRadius: 8,
              padding: '10px 12px',
              fontSize: 11,
              lineHeight: 1.7,
              color: C.ink,
              marginTop: -8,
            }}
          >
            {warning}
          </div>
        )}

        <Field label="ひとこと（任意）">
          <textarea
            value={note}
            onChange={(e) => setNote(e.target.value)}
            maxLength={300}
            placeholder="初心者です。まったり遊べたら嬉しいです"
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

        <span style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.7 }}>
          受付中のリクエストは3件まで、範囲は7日以内です。受付の終わりを過ぎると自動的に閉じます。
        </span>

        {error && <span style={{ fontSize: 11, color: C.avatarPink, lineHeight: 1.6 }}>{error}</span>}

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
              {guardWarningText(hits)}このまま出しますか?
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
                このまま出す
              </span>
            </div>
          </div>
        )}
      </div>
      <div style={{ padding: '12px 20px 26px', background: C.white, borderTop: `1.5px solid ${C.border}` }}>
        <div
          className="pita-press"
          onClick={handleSubmitClick}
          {...(busy || !!warning ? {} : submit.handlers)}
          style={{
            cursor: busy || warning ? 'not-allowed' : 'pointer',
            opacity: busy || warning ? 0.6 : 1,
            background: C.ctaBg,
            color: C.ctaFg,
            borderRadius: 8,
            padding: '14px 0',
            textAlign: 'center',
            fontSize: 14,
          }}
        >
          {busy ? '送信中…' : 'リクエストを出す'}
        </div>
      </div>
    </Screen>
  )
}
