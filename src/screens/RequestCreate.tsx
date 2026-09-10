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
              // ⚠️ **等幅（flex:1）だけだと長いラベルが割れる。**
              //    「日時を選ぶ」が実機で「日時を選／ぶ」の2行になっていた。
              //    折り返さないと決めたうえで、はみ出す前提の余白を持たせる
              whiteSpace: 'nowrap',
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

/**
 * いつ遊びたいか。プリセット3つ＋自由入力。
 * ラベルは**4つ並べて割れない長さ**にすること（実機で「日時を選ぶ」が
 * 2行になっていた）。
 */
const CUSTOM_WHEN = '指定する'
const WHEN_OPTIONS = [...TIME_WINDOWS.map((w) => w.label), CUSTOM_WHEN]

export default function RequestCreate({ flow }: { flow: Flow }) {
  const [game, setGame] = useState<string>(GAMES[0])
  /** ゲームの一覧を全部ひらいたか。既定は先頭だけ（上の Field のコメント参照）。 */
  const [allGames, setAllGames] = useState(false)
  const [duration, setDuration] = useState(60)
  const [whenLabel, setWhenLabel] = useState<string>(TIME_WINDOWS[0].label)
  const [from, setFrom] = useState('')
  const [to, setTo] = useState('')
  const [note, setNote] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [hits, setHits] = useState<GuardHit[]>([])
  const submit = usePress(`3px 3px 0 ${C.lavender}`)

  const custom = whenLabel === CUSTOM_WHEN

  /** 出すゲーム。畳んでいるときも、選択中のものは必ず含める。 */
  const visibleGames = useMemo<string[]>(() => {
    if (allGames) return [...GAMES]
    const head: string[] = GAMES.slice(0, 8)
    return head.includes(game) ? head : [...head, game]
  }, [allGames, game])

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

  /**
   * 出す前に自分で気づけること（サーバの検査と同じ順で見る）。
   *
   * ⚠️ **「範囲が無い」も、ここで理由を出す。** 以前は範囲が null のとき
   *    warning も null になり、ボタンは押せる見た目のまま `handleSubmit` の
   *    先頭で黙って return していた。**押しても何も起きない**画面になっていて、
   *    利用者からは壊れているのと区別がつかない。
   */
  const blocker = useMemo<string | null>(() => {
    if (!range) return '遊びたい時間の「から」と「まで」を入れてください。'
    if (!(range.to > range.from)) return '終わりは、始まりより後にしてください。'
    if (range.to.getTime() - range.from.getTime() < duration * 60_000)
      return '遊ぶ長さより広い範囲にしてください。'
    if (range.to.getTime() - range.from.getTime() > 7 * 24 * 3600_000)
      return '範囲が広すぎます。7日以内にしてください。'
    return null
  }, [range, duration])

  function handleSubmitClick() {
    if (busy || blocker) return
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
    if (busy || !range || blocker) return
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
          {/* **できることを先に言う。** 「掲示板には出ません」から始めると、
              何ができるのかが読み終わるまで分からない */}
          <b style={{ fontSize: 11.5 }}>遊びたい日時を出すと、条件の合うピタメイトに届きます。</b>
          <br />
          <span style={{ fontSize: 10.5, color: C.muted }}>
            掲示板には出ません。応じた方だけが、あなたに表示されます。
          </span>
        </div>

        {/*
          ゲームは27個ある。**全部出すと、この画面の半分がゲーム一覧になる。**
          実機で見たら、日時を決める欄までスクロールしないと辿り着けなかった。

          募集作成（BoardCreate）は同じ形で全部出しているが、あちらは
          **ピタメイトが繰り返し使う画面**。リクエストは**ゲストが初めて使う
          画面**なので、同じ重さでよいはずがない。

          先頭8つだけ出して、残りは畳む。選んでいるものが畳んだ側にあるときは
          必ず見せる（**いま何を選んでいるか分からない状態を作らない**）。
        */}
        <Field label="ゲーム・ジャンル（必須）">
          <SegRow options={visibleGames} value={game} onPick={setGame} />
          {!allGames && (
            <span
              onClick={() => setAllGames(true)}
              role="button"
              tabIndex={0}
              onKeyDown={(e) => {
                if (e.key === 'Enter' || e.key === ' ') setAllGames(true)
              }}
              style={{ alignSelf: 'flex-start', cursor: 'pointer', fontSize: 11.5, color: C.lavender }}
            >
              ほかのゲームから選ぶ（{GAMES.length - visibleGames.length}件）▾
            </span>
          )}
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
              <b style={{ color: C.ink }}>{rangeLabel}</b> のあいだで探します。広く取るほど応じてもらいやすくなります。
            </span>
          )
        )}

        {/* **入れたものが正しくないときだけ**赤く出す。未入力の段階で
            赤い帯を出すのは、まだ何もしていない人を叱ることになる
            （未入力の理由はボタンの直上に静かに置いている） */}
        {range && blocker && (
          <div
            style={{
              background: C.avatarPink,
              border: `1.5px solid ${C.border}`,
              borderRadius: 8,
              padding: '10px 12px',
              fontSize: 11,
              lineHeight: 1.7,
              color: C.onPale,
              marginTop: -8,
            }}
          >
            {blocker}
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

        {/* ⚠️ ここに「3件まで・7日以内」の制限を並べていたが、外した。
            **まだ何も間違えていない人に、先回りして制限を読ませることになる。**
            7日を超えたら `blocker` が理由ごと出るし、3件の上限は
            「出したリクエスト」の画面で、実際に上限に達したときに出している */}

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
                style={{ flex: 1, textAlign: 'center', cursor: 'pointer', fontSize: 11.5, color: C.onPale, background: C.lime, border: `1.5px solid ${C.border}`, borderRadius: 6, padding: '8px 0' }}
              >
                このまま出す
              </span>
            </div>
          </div>
        )}
      </div>
      <div
        style={{
          padding: '12px 20px 26px',
          background: C.white,
          borderTop: `1.5px solid ${C.border}`,
          display: 'flex',
          flexDirection: 'column',
          gap: 9,
        }}
      >
        {/* 押す前に「このあと何が起きるか」を出す（S5 で予約画面に入れたのと
            同じ考え方）。押したあとに読むのと、押す前に読むのとでは別物 */}
        {blocker ? (
          <span style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.6 }}>{blocker}</span>
        ) : (
          <span style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.7 }}>
            出すと、条件の合うピタメイトに届きます。応じた方が出たら通知が来ます。
            <b style={{ color: C.ink }}>まだ予約にはなりません</b>
            ——予約は、応じた方を選んでから行います。いつでも取り下げられます。
          </span>
        )}
        <div
          className="pita-press"
          onClick={handleSubmitClick}
          {...(busy || blocker ? {} : submit.handlers)}
          aria-disabled={busy || !!blocker}
          style={{
            cursor: busy || blocker ? 'not-allowed' : 'pointer',
            opacity: busy || blocker ? 0.45 : 1,
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
