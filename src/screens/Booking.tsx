import { useEffect, useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { SubHeader } from '../components/Ui'
import { Coin, Clock, Shield } from '../components/Icon'
import { BOOKING_DURATIONS, coinsForDuration, coinsPer30, durationLabel, discountedCoins } from '../flow'
import { usePress } from '../hooks/usePress'
import { clickable } from '../hooks/clickable'
import { isBackendConfigured } from '../lib/supabase'
import { fetchMyTrialDiscount, fetchBusySlots, type BusySlot } from '../lib/queries'
import {
  startTimeOptions,
  formatStart,
  formatStartRange,
  MIN_LEAD_MINUTES,
  MAX_LEAD_DAYS,
} from '../content/bookingPolicy'

/**
 * その開始時刻で申し込めるか。埋まっている時間帯と重なっていたら false。
 * サーバ(_booking_slot_conflict)と同じ半開区間 [start, end) で判定する。
 */
function overlapsBusy(start: Date, minutes: number, busy: BusySlot[]): BusySlot | null {
  const end = new Date(start.getTime() + minutes * 60_000)
  return (
    busy.find((b) => b.startsAt.getTime() < end.getTime() && start.getTime() < b.endsAt.getTime()) ??
    null
  )
}

export default function Booking({ flow }: { flow: Flow }) {
  const host = flow.bookingHost
  const confirm = usePress(`3px 3px 0 ${C.lavender}`)
  // このピタメイトで自分に適用される初回お試し割引(0038)。表示専用で、
  // 実際の請求額はサーバ(create_booking)が同じ式で決める。
  const [discount, setDiscount] = useState(0)
  const hostUserId = host?.userId ?? null
  // 開始時刻の候補は画面を開いた時点で固定する(毎描画で作り直すと、
  // 選んだ時刻のオブジェクトが候補側と一致しなくなり選択が外れる)
  const [startOptions] = useState(() => startTimeOptions(new Date()))
  // 既に埋まっている時間帯(0049)。ここに重なる開始時刻は選べない。
  // 判定はサーバでも行われるので、これは「申し込む前に分かる」ための表示。
  const [busy, setBusy] = useState<BusySlot[]>([])

  useEffect(() => {
    // 直接遷移してきた等、ピタメイト未指定の場合は安全にさがすへ戻す
    if (!host) flow.go('search')
  }, [host, flow])

  useEffect(() => {
    if (!isBackendConfigured || !hostUserId) return
    let active = true
    fetchBusySlots(hostUserId)
      .then((rows) => {
        if (active) setBusy(rows)
      })
      .catch(() => {
        // 取れなくても申し込みはできる(サーバ側で弾かれる)。黙って諦める。
        if (active) setBusy([])
      })
    return () => {
      active = false
    }
  }, [hostUserId])

  // あそぶ時間を伸ばすと、選んでいた開始時刻が埋まった枠に食い込むことがある。
  // 選択したまま申し込むとサーバで弾かれるので、選び直してもらう。
  useEffect(() => {
    if (!flow.bookingStartAt) return
    if (overlapsBusy(flow.bookingStartAt, flow.bookingDuration, busy)) {
      flow.setBookingStartAt(null)
    }
  }, [flow, busy])

  useEffect(() => {
    if (!isBackendConfigured || !hostUserId) return
    let active = true
    fetchMyTrialDiscount(hostUserId)
      .then((p) => active && setDiscount(p))
      .catch(() => {
        /* 取れなければ割引なしとして通常価格を出す(請求はサーバが決める) */
      })
    return () => {
      active = false
    }
  }, [hostUserId])

  if (!host) return null

  const listCost = coinsForDuration(host.hourlyRate, flow.bookingDuration)
  const cost = discountedCoins(listCost, discount)
  // まとめ予約(0061)。初回お試し割引が効くのは**1回目だけ**で、2回目以降は
  // 通常価格になる。サーバ側も同じ判定(申込済みの予約があれば割引対象外)なので、
  // ここで違う合計を出すと画面と実際の引き落としがずれる。
  const repeat = flow.bookingWhen === 'scheduled' && flow.bookingStartAt ? flow.bookingRepeat : 1
  const totalCost = cost + listCost * (repeat - 1)
  const short = flow.bookingInsufficient

  return (
    <Screen background={C.surface}>
      <StatusBar time="21:47" />
      <SubHeader title="予約する" onBack={() => flow.go('search')} />
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
        {/* 相手 */}
        <div
          style={{
            background: C.white,
            border: `1.5px solid ${C.border}`,
            borderRadius: 12,
            boxShadow: `3px 3px 0 ${C.shadowCol}`,
            padding: 14,
            display: 'flex',
            alignItems: 'center',
            gap: 12,
          }}
        >
          <div
            style={{
              width: 48,
              height: 48,
              borderRadius: 10,
              background: host.color,
              border: `1.5px solid ${C.border}`,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              fontSize: 20,
              color: C.ink,
            }}
          >
            {host.initial}
          </div>
          <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 2 }}>
            <span style={{ fontSize: 15, color: C.ink }}>{host.name}</span>
            <span style={{ fontSize: 10.5, color: C.muted }}>30分 {coinsPer30(host.hourlyRate)} コイン</span>
          </div>
        </div>

        {/* 開始時刻。「今すぐ」と「時間を指定」の2本立て。
            指定できるようにしたことで、はじめて「開始◯時間前まで」という
            キャンセル規定が実際に意味を持つようになった(0040)。 */}
        <span style={{ fontSize: 12, color: C.muted }}>いつあそぶ</span>
        <div style={{ display: 'flex', gap: 6 }}>
          {([
            { key: 'now' as const, label: '今すぐ' },
            { key: 'scheduled' as const, label: '時間を指定' },
          ]).map((m) => {
            const sel = flow.bookingWhen === m.key
            return (
              <span
                key={m.key}
                onClick={() => flow.setBookingWhen(m.key)}
                {...clickable(() => flow.setBookingWhen(m.key), m.label)}
                style={{
                  flex: 1,
                  textAlign: 'center',
                  cursor: 'pointer',
                  fontSize: 13,
                  color: sel ? C.lime : C.ink,
                  background: sel ? C.fill : C.white,
                  border: `1.5px solid ${C.border}`,
                  padding: '11px 0',
                  borderRadius: 8,
                }}
              >
                {m.label}
              </span>
            )
          })}
        </div>

        {flow.bookingWhen === 'scheduled' && (
          <>
            <div
              className="pita-scroll"
              style={{ display: 'flex', gap: 6, overflowX: 'auto', paddingBottom: 2 }}
            >
              {startOptions.map((d) => {
                const sel = flow.bookingStartAt?.getTime() === d.getTime()
                const taken = overlapsBusy(d, flow.bookingDuration, busy)
                const label = taken
                  ? `${formatStart(d)}(${taken.who === 'me' ? '自分の予約あり' : '予約済み'})`
                  : formatStart(d)
                return (
                  <span
                    key={d.toISOString()}
                    onClick={taken ? undefined : () => flow.setBookingStartAt(d)}
                    {...(taken ? {} : clickable(() => flow.setBookingStartAt(d), label))}
                    aria-disabled={taken ? true : undefined}
                    style={{
                      flex: 'none',
                      cursor: taken ? 'not-allowed' : 'pointer',
                      fontSize: 12,
                      color: taken ? C.muted : sel ? C.ink : C.body,
                      background: taken ? C.surface : sel ? C.lime : C.white,
                      border: `1.5px solid ${C.border}`,
                      padding: '9px 13px',
                      borderRadius: 8,
                      whiteSpace: 'nowrap',
                      opacity: taken ? 0.55 : 1,
                      textDecoration: taken ? 'line-through' : 'none',
                    }}
                  >
                    {formatStart(d)}
                  </span>
                )
              })}
            </div>
            <span style={{ fontSize: 10, color: C.muted, lineHeight: 1.6, marginTop: -6 }}>
              {MIN_LEAD_MINUTES}分後〜{MAX_LEAD_DAYS}日先まで選べます。
              {busy.length > 0 && '　取り消し線の時刻は、あそぶ時間のぶんが埋まっています。'}
              {flow.bookingStartAt && `　選択中: ${formatStartRange(flow.bookingStartAt, flow.bookingDuration)}`}
            </span>
          </>
        )}

        {/* あそぶ時間。4時間までは30分刻み・それ以降は1時間刻みで14択あるので横スクロール。 */}
        <span style={{ fontSize: 12, color: C.muted }}>あそぶ時間</span>
        <div className="pita-scroll" style={{ display: 'flex', gap: 6, overflowX: 'auto', paddingBottom: 2 }}>
          {BOOKING_DURATIONS.map((min) => {
            const sel = flow.bookingDuration === min
            return (
              <span
                key={min}
                onClick={() => flow.setBookingDuration(min)}
                {...clickable(() => flow.setBookingDuration(min), durationLabel(min))}
                style={{
                  flex: 'none',
                  textAlign: 'center',
                  cursor: 'pointer',
                  fontSize: 12.5,
                  color: sel ? C.lime : C.ink,
                  background: sel ? C.fill : C.white,
                  border: `1.5px solid ${C.border}`,
                  padding: '10px 14px',
                  borderRadius: 8,
                  whiteSpace: 'nowrap',
                }}
              >
                {durationLabel(min)}
              </span>
            )
          })}
        </div>

        {/* 終了時刻。あそぶ時間と同じ値の別の見方なので、どちらを触っても連動する。
            開始時刻が決まっていないと終了時刻は決められないため、時間指定のときだけ出す。 */}
        {flow.bookingWhen === 'scheduled' && flow.bookingStartAt && (
          <>
            <span style={{ fontSize: 12, color: C.muted }}>終わる時刻</span>
            <div
              className="pita-scroll"
              style={{ display: 'flex', gap: 6, overflowX: 'auto', paddingBottom: 2 }}
            >
              {BOOKING_DURATIONS.map((min) => {
                const end = new Date(flow.bookingStartAt!.getTime() + min * 60_000)
                const sel = flow.bookingDuration === min
                return (
                  <span
                    key={min}
                    onClick={() => flow.setBookingDuration(min)}
                    {...clickable(() => flow.setBookingDuration(min), `${formatStart(end)}まで`)}
                    style={{
                      flex: 'none',
                      cursor: 'pointer',
                      fontSize: 12.5,
                      color: sel ? C.lime : C.ink,
                      background: sel ? C.fill : C.white,
                      border: `1.5px solid ${C.border}`,
                      padding: '10px 14px',
                      borderRadius: 8,
                      whiteSpace: 'nowrap',
                    }}
                  >
                    {formatStart(end)}
                  </span>
                )
              })}
            </div>
          </>
        )}

        {/* まとめ予約(0061)。毎週同じ時刻が決まっている二人に、毎回ゼロから
            予約させない。ピタメイト側も先の予定が立つ。
            **時間指定のときだけ出す。**「今すぐ」を4回くり返すのは意味が通らない。 */}
        {flow.bookingWhen === 'scheduled' && flow.bookingStartAt && (
          <>
            <span style={{ fontSize: 12, color: C.muted }}>毎週くり返す（任意）</span>
            <div style={{ display: 'flex', gap: 6 }}>
              {[1, 2, 3, 4].map((n) => {
                const sel = flow.bookingRepeat === n
                return (
                  <span
                    key={n}
                    onClick={() => flow.setBookingRepeat(n)}
                    {...clickable(() => flow.setBookingRepeat(n), n === 1 ? 'くり返さない' : `${n}回分まとめて予約`)}
                    style={{
                      flex: 1,
                      cursor: 'pointer',
                      textAlign: 'center',
                      fontSize: 12.5,
                      color: sel ? C.lime : C.ink,
                      background: sel ? C.fill : C.white,
                      border: `1.5px solid ${C.border}`,
                      padding: '10px 0',
                      borderRadius: 8,
                    }}
                  >
                    {n === 1 ? 'なし' : `${n}回分`}
                  </span>
                )
              })}
            </div>
            {flow.bookingRepeat > 1 && flow.bookingStartAt && (
              <span style={{ fontSize: 10.5, color: C.body, lineHeight: 1.7 }}>
                {Array.from({ length: flow.bookingRepeat }, (_, i) =>
                  formatStart(new Date(flow.bookingStartAt!.getTime() + i * 7 * 86_400_000)),
                ).join(' / ')}
                <br />
                <b>1回でも空いていなければ、どれも予約されません。</b>
                コインはまとめて引かれ、キャンセルの扱いは1回ずつ従来どおりです。
              </span>
            )}
          </>
        )}

        {/* 料金サマリー */}
        <div
          style={{
            background: C.lavender,
            border: `1.5px solid ${C.border}`,
            borderRadius: 12,
            boxShadow: `4px 4px 0 ${C.shadowCol}`,
            padding: 16,
            display: 'flex',
            flexDirection: 'column',
            gap: 10,
          }}
        >
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <Clock size={15} color="#fff" />
            <span style={{ fontSize: 12, color: '#fff' }}>{durationLabel(flow.bookingDuration)}の予約</span>
            {discount > 0 && (
              <span
                style={{
                  fontSize: 10,
                  color: C.ink,
                  background: C.lime,
                  border: `1.5px solid ${C.border}`,
                  padding: '2px 7px',
                  borderRadius: 4,
                }}
              >
                初回 {discount}% OFF
              </span>
            )}
          </div>
          <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between' }}>
            <span style={{ fontSize: 11, color: '#E3DCFF' }}>消費コイン</span>
            <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
              {discount > 0 && (
                <span style={{ fontSize: 13, color: '#C6BCE8', textDecoration: 'line-through' }}>
                  {listCost.toLocaleString()}
                </span>
              )}
              <Coin size={18} color={C.lime} />
              <span style={{ fontSize: 24, color: C.lime }}>{totalCost.toLocaleString()}</span>
            </div>
          </div>
          {repeat > 1 && (
            <span style={{ fontSize: 10, color: '#E3DCFF', lineHeight: 1.7 }}>
              {repeat}回分の合計です（
              {discount > 0
                ? `初回 ${cost.toLocaleString()} ＋ 2回目以降 ${listCost.toLocaleString()} × ${repeat - 1}`
                : `${listCost.toLocaleString()} × ${repeat}`}
              ）。
              {discount > 0 && (
                <>
                  <br />
                  初回割引が効くのは<b style={{ color: '#fff' }}>1回目だけ</b>です。
                </>
              )}
            </span>
          )}
          {discount > 0 && (
            <span style={{ fontSize: 10, color: '#E3DCFF', lineHeight: 1.7 }}>
              このピタメイトと初めて遊ぶ方向けの割引です。2回目以降は通常価格（
              {listCost.toLocaleString()} コイン）になります。
              <br />
              割引は<b style={{ color: '#fff' }}>いま予約する分だけ</b>が対象です。
              あとから延長する分は通常価格になるため、はじめから長めに予約したほうがお得です。
            </span>
          )}
          <div style={{ height: 1.5, background: 'rgba(255,255,255,.3)' }} />
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
            <span style={{ fontSize: 11, color: '#E3DCFF' }}>あなたの残高</span>
            <span style={{ fontSize: 13, color: '#fff' }}>{flow.coinBalance} コイン</span>
          </div>
        </div>

        {short && (
          <div
            style={{
              background: C.avatarPink,
              border: `1.5px solid ${C.border}`,
              borderRadius: 8,
              padding: '11px 13px',
              display: 'flex',
              flexDirection: 'column',
              gap: 8,
            }}
          >
            <span style={{ fontSize: 12, color: C.ink }}>
              コインが不足しています(あと{totalCost - flow.coinBalance}コイン必要)
            </span>
            <span
              onClick={() => flow.go('wallet')}
              style={{
                cursor: 'pointer',
                fontSize: 12,
                color: C.ctaFg,
                background: C.ctaBg,
                textAlign: 'center',
                padding: '9px 0',
                borderRadius: 6,
              }}
            >
              コインをチャージする ▶
            </span>
          </div>
        )}

        {flow.bookingError && (
          <div
            style={{
              background: C.avatarPink,
              border: `1.5px solid ${C.border}`,
              borderRadius: 8,
              padding: '11px 13px',
              fontSize: 12,
              color: C.ink,
            }}
          >
            {flow.bookingError}
          </div>
        )}

        <div
          style={{
            background: C.surfaceLavender,
            border: `1.5px solid ${C.lavender}`,
            borderRadius: 8,
            padding: '11px 13px',
            display: 'flex',
            gap: 8,
            alignItems: 'flex-start',
          }}
        >
          <Shield size={14} style={{ flex: 'none', marginTop: 1 }} />
          <span style={{ fontSize: 10.5, lineHeight: 1.7, color: C.body }}>
            コインは申し込んだ時点で確保され、相手が承諾すると予約が成立します。
            <br />
            ・承諾される<b style={{ color: C.ink }}>前</b>の取り消し → <b style={{ color: C.ink }}>全額戻ります</b>
            <br />
            ・<b style={{ color: C.ink }}>ピタメイト都合</b>のキャンセル・無断欠席 → <b style={{ color: C.ink }}>全額戻ります</b>
            <br />
            ・<b style={{ color: C.ink }}>あなたの都合</b>のキャンセル
            <br />
            　→ 承諾から5分以内、または開始1時間前までは<b style={{ color: C.ink }}>全額戻ります</b>
            <br />
            　→ 開始1時間前を切ってから開始までは<b style={{ color: C.ink }}>半額戻ります</b>
            <br />
            　→ 開始後・無断欠席は戻らず、コインは相手の報酬になります
            <br />
            　※ただし相手の報酬になるのは、
            <b style={{ color: C.ink }}>すでに経過した時間ぶん＋3時間ぶんまで</b>です。
            長い予約でも、それを超える分は戻ります。
            <br />
            　※戻るのはコインです。日本円での返金はできません。
            <br />
            トラブル時はいつでも通報・相談ができます。
          </span>
        </div>

        <div
          onClick={() => flow.openReport({ userId: host.userId ?? null, nickname: host.name })}
          style={{
            cursor: 'pointer',
            textAlign: 'center',
            fontSize: 11.5,
            color: C.muted,
            textDecoration: 'underline',
            padding: '2px 0 6px',
          }}
        >
          {host.name} さんを通報・ブロックする
        </div>
      </div>
      <div style={{ padding: '12px 20px 26px', background: C.white, borderTop: `1.5px solid ${C.border}` }}>
        <div
          className="pita-press"
          onClick={flow.confirmBooking}
          {...confirm.handlers}
          style={{
            cursor: 'pointer',
            background: C.ctaBg,
            color: C.ctaFg,
            borderRadius: 8,
            padding: '14px 0',
            textAlign: 'center',
            fontSize: 14,
            ...confirm.style,
          }}
        >
          {totalCost} コインで{repeat > 1 ? `${repeat}回分を` : ''}予約を確定 ▶
        </div>
      </div>
    </Screen>
  )
}
