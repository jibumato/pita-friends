import { useCallback, useEffect, useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { SubHeader } from '../components/Ui'
import { EmptyState } from '../components/States'
import { PlusCircle } from '../components/Icon'
import { isBackendConfigured } from '../lib/supabase'
import SignedOutPrompt from '../components/SignedOutPrompt'
import {
  fetchGuestRequestsForHost,
  respondToGuestRequest,
  type HostInboxRequest,
} from '../lib/queries'
import { MIN_LEAD_MINUTES } from '../content/bookingPolicy'
import { coinsForDuration } from '../flow'

/**
 * 届いたゲストのリクエスト（0120・ピタメイト側）。
 *
 * ■ 「応じる」が何をするかを、押す前に書ききる
 *   応じると**その時間が空き枠として開く。** そして
 *   ・予約はまだ成立していない（相手が予約して初めて成立する）
 *   ・開いた枠は**ほかの方からも予約できる**（取り置きではない）
 *   の2つが、いちばん誤解されやすい。ボタンの手前に置く。
 *
 * ■ 開始時刻は毎正時だけ
 *   応じた行そのものが「その時間が開いている」根拠で、予約は時間の枡ごとに
 *   判定される。30分ずらすと枡が合わず、応じたのに予約できない状態になる。
 *   だから候補を毎正時に作る（サーバ側も START_MUST_BE_ON_THE_HOUR で弾く）。
 */
function windowLabel(from: Date, to: Date): string {
  const d = (x: Date) => `${x.getMonth() + 1}/${x.getDate()}`
  const t = (x: Date) => `${x.getHours()}:${x.getMinutes().toString().padStart(2, '0')}`
  return from.toDateString() === to.toDateString()
    ? `${d(from)} ${t(from)}〜${t(to)}`
    : `${d(from)} ${t(from)}〜${d(to)} ${t(to)}`
}

/** 「9/7(日) 21:00」。応じた時刻を1行で書き戻すときに使う。 */
function dayHourLabel(d: Date): string {
  return `${d.getMonth() + 1}/${d.getDate()}(${DOW[d.getDay()]}) ${d.getHours()}:00`
}

/** 選べる時刻を日ごとにまとめる。見出しは「9/7(日)」の形。 */
const DOW = ['日', '月', '火', '水', '木', '金', '土']
function groupByDay(list: Date[]): [string, Date[]][] {
  const out: [string, Date[]][] = []
  for (const d of list) {
    const key = `${d.getMonth() + 1}/${d.getDate()}(${DOW[d.getDay()]})`
    const last = out[out.length - 1]
    if (last && last[0] === key) last[1].push(d)
    else out.push([key, [d]])
  }
  return out
}

/**
 * 応じられる開始時刻の候補（毎正時）。
 *
 * 範囲の頭を次の正時に**切り上げて**から1時間ずつ進め、終わりが範囲に
 * 収まるものだけを返す。切り下げると、範囲の外を候補に出してしまう。
 */
function hourlyStarts(from: Date, to: Date, minutes: number, cap = 48): Date[] {
  const first = new Date(from)
  if (first.getMinutes() > 0 || first.getSeconds() > 0 || first.getMilliseconds() > 0) {
    first.setHours(first.getHours() + 1)
  }
  first.setMinutes(0, 0, 0)
  const earliest = Date.now() + MIN_LEAD_MINUTES * 60_000
  const out: Date[] = []
  for (let t = first.getTime(); out.length < cap; t += 3600_000) {
    if (t + minutes * 60_000 > to.getTime()) break
    if (t >= earliest) out.push(new Date(t))
  }
  return out
}

/**
 * 「応じる」が何をするかの説明。**画面に1回だけ。**
 * カードごとに繰り返すと、5件並んだときに画面が説明文で埋まる。
 */
function RespondNote() {
  return (
    <div
      style={{
        background: C.surfaceLavender,
        border: `1.5px solid ${C.lavender}`,
        borderRadius: 10,
        padding: '11px 13px',
        fontSize: 10.5,
        lineHeight: 1.8,
        color: C.ink,
      }}
    >
      応じると<b>その時間が空き枠として開きます。</b>
      予約はまだ成立していません（相手が予約して成立します）。
      <br />
      開いた枠は<b>ほかの方からも予約できます</b>——特定の方のための取り置きではありません。
    </div>
  )
}

function RequestCard({
  r,
  hourlyRate,
  onAnswered,
}: {
  r: HostInboxRequest
  hourlyRate: number
  onAnswered: (id: string, at: Date) => void
}) {
  const starts = hourlyStarts(r.windowStart, r.windowEnd, r.durationMinutes)
  const byDay = groupByDay(starts)
  const [picked, setPicked] = useState<Date | null>(r.myStartsAt)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const earns = hourlyRate > 0 ? coinsForDuration(hourlyRate, r.durationMinutes) : null

  async function handleRespond() {
    if (busy || !picked) return
    setBusy(true)
    setError(null)
    try {
      await respondToGuestRequest(r.id, picked)
      onAnswered(r.id, picked)
    } catch (e) {
      setError(e instanceof Error ? e.message : '応じられませんでした')
    } finally {
      setBusy(false)
    }
  }

  return (
    <div
      style={{
        background: C.white,
        border: `1.5px solid ${r.answered ? C.lavender : C.border}`,
        borderRadius: 12,
        boxShadow: `3px 3px 0 ${r.answered ? C.lavender : C.shadowCol}`,
        padding: 14,
        display: 'flex',
        flexDirection: 'column',
        gap: 10,
      }}
    >
      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
        <div
          style={{
            flex: 'none',
            width: 34,
            height: 34,
            borderRadius: '50%',
            background: r.guestColor,
            border: `1.5px solid ${C.border}`,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            fontSize: 13,
            color: C.ink,
          }}
        >
          {r.guestInitial}
        </div>
        <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 2 }}>
          <span style={{ fontSize: 14, color: C.ink, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
            {r.game}
          </span>
          <span style={{ fontSize: 10.5, color: C.muted }}>
            {r.guestName}・{r.durationMinutes}分
            {earns !== null && `・${earns} コイン`}
          </span>
        </div>
        {r.answered && (
          <span
            style={{
              flex: 'none',
              fontSize: 9.5,
              fontWeight: 700,
              color: C.ink,
              background: C.lime,
              border: `1.5px solid ${C.border}`,
              padding: '2px 6px',
              borderRadius: 4,
            }}
          >
            応じました
          </span>
        )}
      </div>

      <span style={{ fontSize: 11.5, color: C.body }}>{windowLabel(r.windowStart, r.windowEnd)}</span>
      {r.note && <span style={{ fontSize: 11, color: C.muted, lineHeight: 1.6 }}>{r.note}</span>}

      {starts.length === 0 ? (
        <span style={{ fontSize: 11, color: C.muted, lineHeight: 1.7 }}>
          この範囲に、いまから応じられる時刻がありません。
        </span>
      ) : (
        <>
          <span style={{ fontSize: 11.5, color: C.muted }}>
            {r.answered ? '時刻を変える' : '何時からなら空けられますか'}
          </span>
          {r.answered && r.myStartsAt && (
            <span style={{ fontSize: 10.5, color: C.ink, marginTop: -4 }}>
              いまは <b>{dayHourLabel(r.myStartsAt)}</b> で開けています
            </span>
          )}
          {/*
            **日ごとに分ける。** 1本の横スクロールに全部並べると、「今週末」の
            ような範囲では 40 個以上の「M/D H:00」が横一列になり、
            どこが何日なのか読めない。日付は行の見出しに出して、
            チップは「時」だけにする。
          */}
          <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
            {byDay.map(([dayKey, hours]) => (
              <div key={dayKey} style={{ display: 'flex', flexDirection: 'column', gap: 5 }}>
                <span style={{ fontSize: 10.5, color: C.muted }}>{dayKey}</span>
                <div
                  className="pita-scroll"
                  style={{ display: 'flex', gap: 6, overflowX: 'auto', paddingBottom: 2 }}
                >
                  {hours.map((d) => {
                    const sel = picked?.getTime() === d.getTime()
                    return (
                      <span
                        key={d.toISOString()}
                        onClick={() => setPicked(d)}
                        role="button"
                        tabIndex={0}
                        aria-pressed={sel}
                        onKeyDown={(e) => {
                          if (e.key === 'Enter' || e.key === ' ') setPicked(d)
                        }}
                        style={{
                          flex: 'none',
                          cursor: 'pointer',
                          fontSize: 12,
                          color: sel ? C.ink : C.body,
                          background: sel ? C.lime : C.white,
                          border: `1.5px solid ${C.border}`,
                          padding: '9px 13px',
                          borderRadius: 8,
                          whiteSpace: 'nowrap',
                        }}
                      >
                        {d.getHours()}:00
                      </span>
                    )
                  })}
                </div>
              </div>
            ))}
          </div>

          {/* ⚠️ ここに説明を置かないこと。**カードごとに同じ4行が繰り返されて、
              5件並ぶと画面が説明文で埋まる。** 説明は画面の先頭に1回だけ
              （`RespondNote`）。カードには、押した結果だけを短く書く */}
          {error && <span style={{ fontSize: 11, color: C.avatarPink, lineHeight: 1.6 }}>{error}</span>}

          <span
            onClick={() => void handleRespond()}
            role="button"
            tabIndex={0}
            onKeyDown={(e) => {
              if (e.key === 'Enter' || e.key === ' ') void handleRespond()
            }}
            style={{
              cursor: busy || !picked ? 'not-allowed' : 'pointer',
              opacity: busy || !picked ? 0.5 : 1,
              textAlign: 'center',
              fontSize: 13,
              color: C.ctaFg,
              background: C.ctaBg,
              borderRadius: 8,
              padding: '11px 0',
            }}
          >
            {busy ? '送信中…' : r.answered ? 'この時刻に変える' : 'この時間で応じる'}
          </span>
        </>
      )}
    </div>
  )
}

export default function RequestInbox({ flow }: { flow: Flow }) {
  const [items, setItems] = useState<HostInboxRequest[] | null>(null)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(() => {
    if (!isBackendConfigured || flow.userId === null) return
    fetchGuestRequestsForHost()
      .then(setItems)
      .catch((e) => setError(e instanceof Error ? e.message : '読み込めませんでした'))
  }, [flow.userId])

  useEffect(load, [load])

  const isHost = flow.hostSettings.isHost
  const games = flow.hostSettings.games

  return (
    <Screen background={C.surface}>
      <StatusBar time="21:47" />
      <SubHeader title="届いたリクエスト" onBack={() => flow.go('board')} />
      <div
        className="pita-scroll"
        style={{
          flex: 1,
          overflowY: 'auto',
          padding: '4px 20px 24px',
          display: 'flex',
          flexDirection: 'column',
          gap: 12,
        }}
      >
        {!isBackendConfigured || flow.userId === null ? (
          <SignedOutPrompt
            flow={flow}
            title="届いたリクエストを見る"
            body="ゲストが出した「この日時で遊びたい」が、同じゲームを登録しているピタメイトに届きます。"
          />
        ) : !isHost ? (
          <EmptyState
            tileColor={C.avatarAqua}
            icon={<PlusCircle size={44} color={C.ink} strokeWidth={2.4} />}
            title="ピタメイトになると届きます"
            desc="ゲストの「この日時で遊びたい」は、掲載中のピタメイトにだけ届きます。"
            cta="ピタメイト設定へ"
            onCta={() => flow.go('hostSettings')}
          />
        ) : games.length === 0 ? (
          /* **ここを黙って空にしない。** ゲームが未登録だと1件も届かないが、
             画面上は「リクエストが無い」と区別がつかず、原因に辿り着けない */
          <EmptyState
            tileColor={C.avatarOrange}
            icon={<PlusCircle size={44} color={C.ink} strokeWidth={2.4} />}
            title="遊ぶゲームを登録してください"
            desc="リクエストは、登録しているゲームが一致するピタメイトにだけ届きます。1つも登録がないと届きません。"
            cta="ピタメイト設定へ"
            onCta={() => flow.go('hostSettings')}
          />
        ) : error ? (
          <span style={{ fontSize: 12, color: C.avatarPink }}>{error}</span>
        ) : items === null ? (
          <span style={{ fontSize: 12, color: C.muted }}>読み込み中…</span>
        ) : items.length === 0 ? (
          <EmptyState
            tileColor={C.avatarAqua}
            icon={<PlusCircle size={44} color={C.ink} strokeWidth={2.4} />}
            title="いま届いているリクエストはありません"
            desc={`登録しているゲーム（${games.join('・')}）で、ゲストがリクエストを出すとここに並びます。`}
          />
        ) : (
          <>
            <RespondNote />
            {items.map((r) => (
              <RequestCard
                key={r.id}
                r={r}
                hourlyRate={flow.hostSettings.hourlyRate}
                onAnswered={(id, at) =>
                  setItems((prev) =>
                    (prev ?? []).map((x) =>
                      x.id === id ? { ...x, answered: true, myStartsAt: at } : x,
                    ),
                  )
                }
              />
            ))}
          </>
        )}
      </div>
    </Screen>
  )
}
