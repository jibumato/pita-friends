import { useEffect, useMemo, useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { SubHeader } from '../components/Ui'
import { Coin, Clock, Shield } from '../components/Icon'
import { BOOKING_DURATIONS, COIN_PACKS, coinsForDuration, coinsPer30, durationLabel, discountedCoins } from '../flow'
import { usePress } from '../hooks/usePress'
import { clickable } from '../hooks/clickable'
import { isBackendConfigured } from '../lib/supabase'
import { fetchMyTrialDiscount, fetchBusySlots, type BusySlot } from '../lib/queries'
import { CANCELLATION_POLICY_LINES } from '../content/bookingPolicy'
import {
  startTimeOptions,
  startTimeOptionsInRange,
  formatStart,
  formatStartRange,
  MIN_LEAD_MINUTES,
  MAX_LEAD_DAYS,
  NEXT_STEPS,
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
  const [allStartOptions] = useState(() => startTimeOptions(new Date()))
  // 0114: 募集板から来た場合、その募集が受け付けている範囲に候補を絞る。
  // **開始だけでなく終了も範囲に収まること**——告知した時間を超える申込みは
  // サーバ側(create_booking_from_board)でも弾かれる。
  const startOptions = useMemo(() => {
    const from = host?.boardWindowStart
    const to = host?.boardWindowEnd
    if (!from || !to) return allStartOptions
    // ★絞り込みではなく作り直す。`startTimeOptions` はいまから8時間ぶんしか
    //   作らないので、「来週の土日」のような範囲だと候補がゼロになる
    return startTimeOptionsInRange(from, to, flow.bookingDuration)
  }, [allStartOptions, host?.boardWindowStart, host?.boardWindowEnd, flow.bookingDuration])
  /**
   * 0120: リクエストに応じてもらった枠は、開始時刻も長さも**もう決まっている。**
   *
   * 応じた行そのものが「その時間が開いている」根拠なので、別の時刻を選ぶと
   * サーバ側で HOST_NOT_OPEN になる。**選ばせてから弾くのではなく、
   * はじめから選ばせない。**
   */
  const fixedStart = host?.fromGuestRequestId ? (host.requestStartAt ?? null) : null

  // 募集の範囲があるときは、選べる時間の説明をそちらに差し替える。
  // 「30分後〜35日先まで」のままだと、実際に押せる範囲と食い違って読める
  const boardWindow =
    host?.boardWindowStart && host?.boardWindowEnd
      ? { from: host.boardWindowStart, to: host.boardWindowEnd }
      : null
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
  const shortfall = Math.max(0, totalCost - flow.coinBalance)

  /**
   * 不足を満たす、いちばん小さいパック(0117)。
   *
   * サーバ側のパック定義(coin_packs)が権威だが、ここは**買う前の案内**なので
   * コード側の定義で足りる。実際の金額はウォレットがサーバから引き直す。
   *
   * ※ ここから下は `if (!host) return null` より後ろなので、
   *   **useMemo を使わないこと。** 条件付きでフックを呼ぶことになる。
   *   どちらも要素が十数個の走査で、覚えておく価値のある計算ではない。
   */
  const neededPack = COIN_PACKS.find((p) => p.coins >= shortfall) ?? null

  /**
   * いまの残高で収まる、いちばん長い時間(0117)。
   *
   * 「買ってください」の前に「短くすれば、いま予約できます」を出す。
   * まとめ予約をしているときは出さない——回数の掛け算が絡んで、
   * 提示した額と実際の請求がずれやすい。
   */
  const affordable = (() => {
    if (!short || repeat > 1) return null
    for (const m of [...BOOKING_DURATIONS].sort((a, b) => b - a)) {
      if (m >= flow.bookingDuration) continue
      const c = discountedCoins(coinsForDuration(host.hourlyRate, m), discount)
      if (c <= flow.coinBalance) return { minutes: m, cost: c }
    }
    return null
  })()

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
        {fixedStart ? (
          <div
            style={{
              background: C.surfaceLavender,
              border: `1.5px solid ${C.lavender}`,
              borderRadius: 8,
              padding: '11px 13px',
              fontSize: 12,
              lineHeight: 1.7,
              color: C.ink,
            }}
          >
            <b>{formatStart(fixedStart)}から{durationLabel(flow.bookingDuration)}</b>
            <br />
            <span style={{ fontSize: 10.5, color: C.muted }}>
              あなたのリクエストに、この時間で応じてもらいました。時間と長さは変更できません。
            </span>
          </div>
        ) : (
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
        )}

        {!fixedStart && flow.bookingWhen === 'scheduled' && (
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
            {boardWindow && startOptions.length === 0 && (
              <span style={{ fontSize: 11, color: C.ink, lineHeight: 1.7 }}>
                いまの「あそぶ時間」だと、この募集の受付時間に収まる開始時刻がありません。
                あそぶ時間を短くするか、別の募集をさがしてください。
              </span>
            )}
            <span style={{ fontSize: 10, color: C.muted, lineHeight: 1.6, marginTop: -6 }}>
              {boardWindow
                ? `この募集は ${formatStart(boardWindow.from)}〜${formatStart(boardWindow.to)} のあいだで受け付けています。`
                : `${MIN_LEAD_MINUTES}分後〜${MAX_LEAD_DAYS}日先まで選べます。`}
              {busy.length > 0 && '　取り消し線の時刻は、あそぶ時間のぶんが埋まっています。'}
              {flow.bookingStartAt && `　選択中: ${formatStartRange(flow.bookingStartAt, flow.bookingDuration)}`}
            </span>
          </>
        )}

        {/* あそぶ時間。4時間までは30分刻み・それ以降は1時間刻みで14択あるので横スクロール。
            0120: リクエストに応じてもらった枠は、開けてもらったのがその長さぶん
            なので変えられない（長さを変えると枠からはみ出して弾かれる）。 */}
        {!fixedStart && (
        <>
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
        </>
        )}

        {/* 終了時刻。あそぶ時間と同じ値の別の見方なので、どちらを触っても連動する。
            開始時刻が決まっていないと終了時刻は決められないため、時間指定のときだけ出す。 */}
        {!fixedStart && flow.bookingWhen === 'scheduled' && flow.bookingStartAt && (
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
        {!fixedStart && flow.bookingWhen === 'scheduled' && flow.bookingStartAt && (
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
              コインが不足しています（あと{shortfall}コイン必要）
            </span>
            {/* 0117: いくら買えば足りるのかを暗算させない。
                不足を満たす**いちばん小さいパック**を名指しする */}
            {neededPack && (
              <span style={{ fontSize: 10.5, color: C.body, lineHeight: 1.7 }}>
                {neededPack.coins.toLocaleString()}コイン（{neededPack.priceYen.toLocaleString()}円）を購入すると、この予約ができます。
              </span>
            )}
            <span
              onClick={() => flow.goCharge(shortfall)}
              {...clickable(() => flow.goCharge(shortfall), 'コインをチャージする')}
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
            {/* 0117: 短くすれば**いま買わずに**予約できるなら、それを先に出す。
                前払いの壁は金額の大小ではなく「踏み出す単位の大きさ」の問題 */}
            {affordable && (
              <span
                onClick={() => flow.setBookingDuration(affordable.minutes)}
                {...clickable(
                  () => flow.setBookingDuration(affordable.minutes),
                  `あそぶ時間を${affordable.minutes}分にする`,
                )}
                style={{
                  cursor: 'pointer',
                  fontSize: 11.5,
                  color: C.ink,
                  background: C.white,
                  border: `1.5px solid ${C.border}`,
                  textAlign: 'center',
                  padding: '8px 0',
                  borderRadius: 6,
                }}
              >
                {affordable.minutes}分（{affordable.cost}コイン）なら、いまの残高で予約できます
              </span>
            )}
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
          {/* 文面は content/cancellationPolicy.ts が出典。**ここに直接書かない。**
              申込時に「表示した文面」として policy_consents に記録するので、
              画面とログが別々にあると、直したときに黙ってずれる（ずれた瞬間、
              「この文面を見せた」と言えなくなり証跡の価値が消える）。 */}
          <span style={{ fontSize: 10.5, lineHeight: 1.7, color: C.body }}>
            {CANCELLATION_POLICY_LINES.map((line, i) => (
              <span key={i}>
                {i > 0 && <br />}
                {line.split('**').map((part, j) =>
                  j % 2 === 1 ? (
                    <b key={j} style={{ color: C.ink }}>
                      {part}
                    </b>
                  ) : (
                    <span key={j}>{part}</span>
                  ),
                )}
              </span>
            ))}
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
        {/* 0117: 押す前に「このあと何が起きるか」を出す。
            承諾を待つ画面(BookingRequested)に同じことは書いてあるが、
            **押したあとに読むのと、押す前に読むのとでは別物。**
            初めての人が止まるのは、押す直前の一瞬。 */}
        <div
          style={{
            display: 'flex',
            flexDirection: 'column',
            gap: 3,
            marginBottom: 10,
            fontSize: 10.5,
            lineHeight: 1.7,
            color: C.muted,
          }}
        >
          {NEXT_STEPS.map((line, i) => (
            <span key={i}>
              <span style={{ color: C.lavender }}>{i + 1}.</span> {line}
            </span>
          ))}
        </div>
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
