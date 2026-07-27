import { useEffect, useRef, useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { ChevronLeft, Shield, Send } from '../components/Icon'
import { usePress } from '../hooks/usePress'
import { isBackendConfigured } from '../lib/supabase'
import {
  cancelBooking,
  completeBooking,
  extendBooking,
  fetchBookingForPromise,
  fetchMessages,
  fetchMyRefundQuote,
  type RefundQuote,
  fetchCheckinState,
  checkInBooking,
  type CheckinState,
  fetchPaidBalance,
  fetchThreadPartner,
  hasReviewedPromise,
  markThreadRead,
  sendGift,
  sendMessage,
  submitReview,
  subscribeToMessages,
  GIFT_AMOUNTS,
  type BookingInfo,
  type ChatMessage,
  type ThreadPartner,
} from '../lib/queries'
import { REVIEW_TAGS } from '../flow'
import { clickable } from '../hooks/clickable'
import { inspectText, guardWarningText, type GuardHit } from '../lib/contentGuard'
import { recordContentFlag } from '../lib/queries'

function Bubble({ side, children }: { side: 'left' | 'right'; children: React.ReactNode }) {
  const left = side === 'left'
  return (
    <div
      style={{
        alignSelf: left ? 'flex-start' : 'flex-end',
        maxWidth: '75%',
        background: left ? C.white : C.lime,
        border: `1.5px solid ${C.border}`,
        borderRadius: left ? '2px 10px 10px 10px' : '10px 2px 10px 10px',
        padding: '10px 13px',
      }}
    >
      <span style={{ fontSize: 12.5, lineHeight: 1.6, color: C.ink }}>{children}</span>
    </div>
  )
}

/** ギフト(投げ銭)を贈るボトムシート。 */
function GiftSheet({
  promiseId,
  partnerName,
  onClose,
  onSent,
}: {
  promiseId: string
  partnerName: string
  onClose: () => void
  onSent: () => void
}) {
  const [amount, setAmount] = useState<number>(GIFT_AMOUNTS[1])
  const [message, setMessage] = useState('')
  const [balance, setBalance] = useState<number | null>(null)
  const [sending, setSending] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let active = true
    fetchPaidBalance()
      .then((b) => active && setBalance(b))
      .catch(() => active && setBalance(null))
    return () => {
      active = false
    }
  }, [])

  const short = balance !== null && balance < amount

  async function handleSend() {
    if (sending || short) return
    setSending(true)
    setError(null)
    try {
      await sendGift(promiseId, amount, message)
      onSent()
      onClose()
    } catch (e) {
      setError(e instanceof Error ? e.message : 'ギフトの送信に失敗しました')
    } finally {
      setSending(false)
    }
  }

  return (
    <div
      onClick={onClose}
      style={{
        position: 'absolute',
        inset: 0,
        background: 'rgba(0,0,0,.35)',
        display: 'flex',
        alignItems: 'flex-end',
        zIndex: 50,
      }}
    >
      <div
        onClick={(e) => e.stopPropagation()}
        style={{
          width: '100%',
          background: C.surface,
          borderTop: `1.5px solid ${C.border}`,
          borderRadius: '16px 16px 0 0',
          padding: '16px 20px 26px',
          display: 'flex',
          flexDirection: 'column',
          gap: 12,
          animation: 'scrIn .25s ease both',
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
          <span style={{ fontSize: 15, color: C.ink }}>🎁 {partnerName}さんにありがとうギフト</span>
          <span onClick={onClose} style={{ cursor: 'pointer', fontSize: 13, color: C.muted }}>
            閉じる
          </span>
        </div>

        <span style={{ fontSize: 11, color: C.muted, lineHeight: 1.6 }}>
          一緒に遊んでくれた感謝の気持ちを、コインで贈れます。相手の報酬(換金可能・受領から7日後)になります。
          原資は購入コインのみ・返金はできません。
        </span>

        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
          {GIFT_AMOUNTS.map((a) => {
            const sel = amount === a
            return (
              <span
                key={a}
                onClick={() => setAmount(a)}
                style={{
                  cursor: 'pointer',
                  fontSize: 13,
                  color: sel ? C.ink : C.body,
                  background: sel ? C.lime : C.white,
                  border: `1.5px solid ${C.border}`,
                  padding: '9px 14px',
                  borderRadius: 8,
                }}
              >
                {a}
              </span>
            )
          })}
        </div>

        <input
          value={message}
          onChange={(e) => setMessage(e.target.value)}
          placeholder="ひとこと添える(任意)"
          maxLength={100}
          style={{
            background: C.white,
            border: `1.5px solid ${C.border}`,
            borderRadius: 8,
            padding: '11px 14px',
            fontSize: 12.5,
            color: C.ink,
            outline: 'none',
            fontFamily: 'inherit',
          }}
        />

        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
          <span style={{ fontSize: 11, color: C.muted }}>購入コイン残高</span>
          <span style={{ fontSize: 12.5, color: short ? C.avatarPink : C.ink }}>
            {balance === null ? '—' : `${balance} コイン`}
          </span>
        </div>

        {short && (
          <span style={{ fontSize: 11, color: C.avatarPink }}>
            残高が足りません。ギフトは購入コインからのみ贈れます。
          </span>
        )}
        {error && <span style={{ fontSize: 11, color: C.avatarPink }}>{error}</span>}

        <div
          onClick={handleSend}
          style={{
            cursor: sending || short ? 'not-allowed' : 'pointer',
            opacity: sending || short ? 0.55 : 1,
            textAlign: 'center',
            fontSize: 14,
            color: C.ctaFg,
            background: C.ctaBg,
            borderRadius: 8,
            padding: '13px 0',
          }}
        >
          {sending ? '送信中…' : `${amount} コインを贈る 🎁`}
        </div>
      </div>
    </div>
  )
}

/** 実データのトークルーム(promise)。 */
function RealTalk({ flow, promiseId }: { flow: Flow; promiseId: string }) {
  const [partner, setPartner] = useState<ThreadPartner | null>(null)
  const [messages, setMessages] = useState<ChatMessage[]>([])
  const [myId, setMyId] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [draft, setDraft] = useState('')
  /** 検知ヒット(空でなければ確認バナーを出す)。 */
  const [hits, setHits] = useState<GuardHit[]>([])
  const [sending, setSending] = useState(false)
  const [booking, setBooking] = useState<BookingInfo | null>(null)
  /** 延長の選択肢を開いているか。誤タップで課金しないよう一段挟む。 */
  const [extendOpen, setExtendOpen] = useState(false)
  const [extending, setExtending] = useState(false)
  const [extendMsg, setExtendMsg] = useState<string | null>(null)
  const [completing, setCompleting] = useState(false)
  const [completeError, setCompleteError] = useState<string | null>(null)
  const [cancelOpen, setCancelOpen] = useState(false)
  const [cancelling, setCancelling] = useState(false)
  /** いまキャンセルしたら何%戻るか(サーバ判定)。確認を開いた時点で取り直す。 */
  const [refundQuote, setRefundQuote] = useState<RefundQuote | null>(null)
  // プレイ開始の申告(0050)。押しても何も確定しないが、相手が現れなければ
  // サーバが自動でコインの確定を止める。
  const [checkin, setCheckin] = useState<CheckinState | null>(null)
  const [checkingIn, setCheckingIn] = useState(false)
  const [reviewed, setReviewed] = useState<boolean | null>(null)
  const [stars, setStars] = useState(5)
  const [tags, setTags] = useState<string[]>([])
  const [submittingReview, setSubmittingReview] = useState(false)
  const [reviewError, setReviewError] = useState<string | null>(null)
  const [giftOpen, setGiftOpen] = useState(false)
  const scrollRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    setMyId(flow.userId ?? null)
  }, [flow.userId])

  useEffect(() => {
    let active = true
    setLoading(true)
    Promise.all([
      fetchThreadPartner(promiseId),
      fetchMessages(promiseId),
      fetchBookingForPromise(promiseId),
      hasReviewedPromise(promiseId).catch(() => false),
    ])
      .then(([p, m, b, r]) => {
        if (!active) return
        setPartner(p)
        setMessages(m)
        setBooking(b)
        setReviewed(r)
        void markThreadRead(promiseId)
      })
      .catch((e) => active && setError(e instanceof Error ? e.message : '読み込みに失敗しました'))
      .finally(() => active && setLoading(false))
    const unsubscribe = subscribeToMessages(promiseId, (m) => {
      setMessages((xs) => (xs.some((x) => x.id === m.id) ? xs : [...xs, m]))
      void markThreadRead(promiseId)
    })
    return () => {
      active = false
      unsubscribe()
    }
  }, [promiseId])

  useEffect(() => {
    scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight })
  }, [messages])

  // 開始の申告の状況を取る。メッセージを送ると自動でチェックイン扱いになる
  // (0050)ので、messages が動いたら取り直す。
  const bookingId = booking?.id ?? null
  const bookingStatus = booking?.status ?? null
  useEffect(() => {
    if (!isBackendConfigured || !bookingId || bookingStatus !== 'confirmed') {
      setCheckin(null)
      return
    }
    let active = true
    fetchCheckinState(bookingId)
      .then((s) => {
        if (active) setCheckin(s)
      })
      .catch(() => {
        if (active) setCheckin(null)
      })
    return () => {
      active = false
    }
  }, [bookingId, bookingStatus, messages.length])

  async function handleCheckIn() {
    if (!bookingId || checkingIn) return
    setCheckingIn(true)
    try {
      await checkInBooking(bookingId)
      setCheckin(await fetchCheckinState(bookingId))
    } catch {
      // 押せなかっただけなので、静かに戻す(次の描画で状態を取り直す)
    } finally {
      setCheckingIn(false)
    }
  }

  async function doSend() {
    const body = draft.trim()
    if (!body || sending) return
    setSending(true)
    setError(null)
    try {
      // 警告を見たうえで送った場合は「続行した」として記録する(§4.2)
      if (hits.length > 0) {
        for (const h of hits) void recordContentFlag(h.category, 'message', h.matched, true)
      }
      await sendMessage(promiseId, body)
      setDraft('')
      setHits([])
    } catch (e) {
      setError(e instanceof Error ? e.message : '送信に失敗しました')
    } finally {
      setSending(false)
    }
  }

  function handleSendClick() {
    if (!draft.trim()) return
    if (hits.length === 0) {
      const result = inspectText(draft)
      if (result.hits.length > 0) {
        // 送信はブロックせず、確認を挟む(§4.2-2)
        setHits(result.hits)
        return
      }
    }
    void doSend()
  }

  async function handleComplete() {
    if (!booking || completing) return
    setCompleting(true)
    setCompleteError(null)
    try {
      await completeBooking(booking.id)
      setBooking({ ...booking, status: 'completed' })
    } catch (e) {
      setCompleteError(e instanceof Error ? e.message : '確定に失敗しました')
    } finally {
      setCompleting(false)
    }
  }

  async function handleCancel() {
    if (!booking || cancelling) return
    setCancelling(true)
    setCompleteError(null)
    try {
      await cancelBooking(booking.id)
      setBooking({
        ...booking,
        status: myId === booking.hostId ? 'cancelled_by_host' : 'cancelled_by_guest',
      })
      setCancelOpen(false)
    } catch (e) {
      setCompleteError(e instanceof Error ? e.message : 'キャンセルに失敗しました')
    } finally {
      setCancelling(false)
    }
  }

  async function handleSubmitReview() {
    if (!partner || submittingReview) return
    setSubmittingReview(true)
    setReviewError(null)
    try {
      await submitReview(promiseId, partner.userId, stars, tags)
      setReviewed(true)
    } catch (e) {
      setReviewError(e instanceof Error ? e.message : '評価の送信に失敗しました')
    } finally {
      setSubmittingReview(false)
    }
  }

  async function handleExtend(minutes: 30 | 60) {
    if (!booking || extending) return
    setExtending(true)
    setExtendMsg(null)
    try {
      const added = await extendBooking(booking.id, minutes)
      // サーバが確定した追加コイン数で手元の表示を更新する
      setBooking({
        ...booking,
        coins: booking.coins + added,
        // 延長は通常価格なので、定価にも同額を積む(0039)
        listCoins: booking.listCoins + added,
        durationMinutes: booking.durationMinutes + minutes,
      })
      setExtendOpen(false)
      setExtendMsg(`${minutes}分延長しました(+${added}コイン)`)
    } catch (e) {
      setExtendMsg(e instanceof Error ? e.message : '延長できませんでした')
    } finally {
      setExtending(false)
    }
  }

  /**
   * 延長の見積り。単価は「定価 ÷ 時間」から逆算する。
   * 実支払額(coins)で割ってはいけない。初回お試し割引が効いている予約だと
   * 割引後の安い単価になり、通常価格で請求される延長分を過小に見せてしまう
   * (延長は割引の対象外。0039)。確定額はサーバ側が決める。
   */
  function estimateExtendCoins(minutes: number): number {
    if (!booking || booking.durationMinutes <= 0) return 0
    return Math.round((booking.listCoins / booking.durationMinutes) * minutes)
  }

  const isGuestOfBooking = booking && myId === booking.guestId
  const isCancelledBooking = booking?.status.startsWith('cancelled') || booking?.status.startsWith('no_show')

  return (
    <Screen background={C.surface}>
      <StatusBar time="21:49" />
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: 10,
          padding: '10px 20px',
          borderBottom: `1.5px solid ${C.border}`,
          background: C.white,
        }}
      >
        <div onClick={() => flow.go(flow.threadReturn)} style={{ cursor: 'pointer' }}>
          <ChevronLeft />
        </div>
        <div
          style={{
            width: 36,
            height: 36,
            borderRadius: 8,
            background: partner?.color ?? C.avatarAqua,
            border: `1.5px solid ${C.border}`,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            fontSize: 15,
            color: C.ink,
          }}
        >
          {partner?.initial ?? '?'}
        </div>
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
            <span style={{ fontSize: 14, color: C.ink }}>{partner?.name ?? '読み込み中…'}</span>
            {partner?.verified && (
              <span
                style={{
                  fontSize: 9,
                  color: C.ink,
                  background: C.lime,
                  border: `1.5px solid ${C.border}`,
                  padding: '1px 5px',
                  borderRadius: 4,
                }}
              >
                ✓
              </span>
            )}
          </div>
        </div>
      </div>

      <div
        onClick={() => partner && flow.openReport({ userId: partner.userId, nickname: partner.name })}
        style={{
          cursor: 'pointer',
          background: C.surfaceLavender,
          borderBottom: `1.5px solid ${C.lavender}`,
          padding: '8px 20px',
          display: 'flex',
          gap: 8,
          alignItems: 'center',
        }}
      >
        <Shield size={13} style={{ flex: 'none' }} />
        <span style={{ flex: 1, fontSize: 10, color: C.body }}>
          やり取りはアプリ内が安全です。外部アプリへの誘導・直接の金銭要求が出たら通報してください。
        </span>
        <span style={{ fontSize: 10, color: C.lavender }}>通報 ›</span>
      </div>

      {booking && booking.status === 'confirmed' && (
        <div
          style={{
            margin: '10px 20px 0',
            background: C.lavender,
            border: `1.5px solid ${C.border}`,
            borderRadius: 10,
            padding: '12px 14px',
            display: 'flex',
            flexDirection: 'column',
            gap: 8,
          }}
        >
          <span style={{ fontSize: 12, color: '#fff' }}>
            {booking.coins}コインの予約中です。プレイが終わったら、ゲストが「プレイ完了」を確定するとピタメイトに報酬が届きます。
          </span>

          {/* プレイ開始の申告(0050)。
              押しても何も確定しない。ゲストが押したうえで相手が現れなければ、
              サーバが開始+猶予でコインの確定を自動で止める。相手が来ないのに
              8時間待つ、という状態をなくすためのもの。 */}
          {checkin?.started && !checkin.myCheckedIn && (
            <div
              onClick={handleCheckIn}
              {...clickable(handleCheckIn, 'はじめました')}
              style={{
                cursor: checkingIn ? 'not-allowed' : 'pointer',
                opacity: checkingIn ? 0.6 : 1,
                textAlign: 'center',
                fontSize: 12.5,
                color: C.ink,
                background: C.white,
                border: `1.5px solid ${C.border}`,
                borderRadius: 6,
                padding: '9px 0',
              }}
            >
              {checkingIn ? '記録中…' : '▶ はじめました'}
            </div>
          )}
          {checkin?.started && checkin.myCheckedIn && !checkin.partnerCheckedIn && !checkin.heldForNoShow && (
            <span style={{ fontSize: 10.5, color: '#E3DCFF' }}>
              相手の開始がまだ確認できていません。開始から{checkin.graceMinutes}分たっても
              確認できない場合は、コインの確定を自動で止めます。
            </span>
          )}
          {checkin?.heldForNoShow && (
            <span style={{ fontSize: 10.5, color: '#E3DCFF' }}>
              {checkin.iAmGuest
                ? '相手の参加が確認できないため、コインの確定を止めています。相手が参加すれば自動で戻ります。このまま反応がなければ、コインは全額お返しします。'
                : 'まだ開始が確認できていません。「はじめました」を押すか、メッセージを送ってください。このまま反応がないと、無断欠席としてコインがゲストへ返還されます。'}
            </span>
          )}
          {isGuestOfBooking ? (
            <div
              onClick={handleComplete}
              style={{
                cursor: completing ? 'not-allowed' : 'pointer',
                opacity: completing ? 0.6 : 1,
                textAlign: 'center',
                fontSize: 12.5,
                color: C.ink,
                background: C.lime,
                border: `1.5px solid ${C.border}`,
                borderRadius: 6,
                padding: '9px 0',
              }}
            >
              {completing ? '処理中…' : '✓ プレイ完了・支払いを確定する'}
            </div>
          ) : (
            <span style={{ fontSize: 10.5, color: '#E3DCFF' }}>ゲスト側の確定をお待ちください(72時間で自動確定)</span>
          )}
          {/* 延長はゲストのみ。プレイ中に「もう少し遊びたい」と思った瞬間に押せる位置に置く。 */}
          {isGuestOfBooking &&
            (!extendOpen ? (
              <span
                onClick={() => setExtendOpen(true)}
                {...clickable(() => setExtendOpen(true), 'プレイ時間を延長する')}
                style={{
                  cursor: 'pointer',
                  textAlign: 'center',
                  fontSize: 12,
                  color: C.ink,
                  background: C.white,
                  border: `1.5px solid ${C.border}`,
                  borderRadius: 6,
                  padding: '8px 0',
                }}
              >
                ＋ プレイ時間を延長する
              </span>
            ) : (
              <div
                style={{
                  background: C.white,
                  border: `1.5px solid ${C.border}`,
                  borderRadius: 8,
                  padding: '9px 11px',
                  display: 'flex',
                  flexDirection: 'column',
                  gap: 8,
                }}
              >
                <span style={{ fontSize: 10.5, lineHeight: 1.6, color: C.body }}>
                  延長すると、その場でコインを追加でお支払いいただきます。金額は
                  ピタメイトさんの時給レートで計算されます。
                </span>
                {/* 初回割引が効いていた予約では、延長が割引対象外であることを
                    ここで必ず伝える(割引価格のつもりで押されないように)。 */}
                {booking.discountPercent > 0 && (
                  <span
                    style={{
                      fontSize: 10,
                      lineHeight: 1.6,
                      color: C.ink,
                      background: C.surfaceLavender,
                      border: `1.5px solid ${C.lavender}`,
                      borderRadius: 6,
                      padding: '8px 10px',
                    }}
                  >
                    初回お試し割引（{booking.discountPercent}% OFF）は最初に予約した分のみが対象です。
                    <b>延長分は通常価格</b>になります。
                  </span>
                )}
                <div style={{ display: 'flex', gap: 8 }}>
                  {([30, 60] as const).map((min) => (
                    <span
                      key={min}
                      onClick={() => handleExtend(min)}
                      {...clickable(() => handleExtend(min), `${min}分延長する`)}
                      style={{
                        flex: 1,
                        textAlign: 'center',
                        cursor: extending ? 'not-allowed' : 'pointer',
                        opacity: extending ? 0.6 : 1,
                        fontSize: 11.5,
                        color: C.ink,
                        background: C.lime,
                        border: `1.5px solid ${C.border}`,
                        borderRadius: 6,
                        padding: '8px 0',
                      }}
                    >
                      +{min}分
                      <br />
                      <span style={{ fontSize: 10, color: C.body }}>
                        約{estimateExtendCoins(min).toLocaleString()}コイン
                      </span>
                    </span>
                  ))}
                </div>
                <span
                  onClick={() => setExtendOpen(false)}
                  {...clickable(() => setExtendOpen(false), 'やめる')}
                  style={{
                    cursor: 'pointer',
                    textAlign: 'center',
                    fontSize: 11,
                    color: C.muted,
                  }}
                >
                  やめる
                </span>
              </div>
            ))}
          {extendMsg && (
            <span style={{ fontSize: 10.5, color: '#E3DCFF', textAlign: 'center' }}>{extendMsg}</span>
          )}
          {!cancelOpen ? (
            <span
              onClick={() => {
                setCancelOpen(true)
                // 確認を開いた瞬間の値を取る。時間が経つと額が変わるため、
                // 画面を開きっぱなしにしていた古い値を出さない。
                setRefundQuote(null)
                fetchMyRefundQuote(booking.id)
                  .then(setRefundQuote)
                  .catch(() => setRefundQuote(null))
              }}
              style={{ cursor: 'pointer', fontSize: 10.5, color: '#E3DCFF', textDecoration: 'underline', textAlign: 'center' }}
            >
              予約をキャンセルする…
            </span>
          ) : (
            <div
              style={{
                background: C.white,
                border: `1.5px solid ${C.border}`,
                borderRadius: 8,
                padding: '9px 11px',
                display: 'flex',
                flexDirection: 'column',
                gap: 7,
              }}
            >
              {/* 一般論ではなく「いま取り消したら実際にいくら戻るか」を出す。
                  0048で没収額に上限を入れたので、率からの掛け算では実額が出ない。
                  ここでは計算せず、サーバが返した額をそのまま表示する。 */}
              <span style={{ fontSize: 10.5, lineHeight: 1.6, color: C.body }}>
                {!isGuestOfBooking
                  ? 'あなた都合のキャンセルはコインが相手に全額戻り、あなたのドタキャン記録に残ります。'
                  : refundQuote === null
                    ? '確認しています…'
                    : refundQuote.refundCoins >= refundQuote.coins
                      ? `いまキャンセルすると、${refundQuote.coins.toLocaleString()}コインが全額戻ります。`
                      : refundQuote.refundCoins === 0
                        ? `いまキャンセルすると、${refundQuote.coins.toLocaleString()}コインは戻らず相手の報酬になります。ドタキャンとして記録されます。`
                        : `いまキャンセルすると、${refundQuote.refundCoins.toLocaleString()}コインが戻ります。残りの${refundQuote.forfeitCoins.toLocaleString()}コインは相手の報酬になり、ドタキャンとして記録されます。`}
              </span>
              <div style={{ display: 'flex', gap: 8 }}>
                <span
                  onClick={() => setCancelOpen(false)}
                  style={{ flex: 1, textAlign: 'center', cursor: 'pointer', fontSize: 11.5, color: C.ink, background: C.surface, border: `1.5px solid ${C.border}`, borderRadius: 6, padding: '7px 0' }}
                >
                  やめる
                </span>
                <span
                  onClick={handleCancel}
                  style={{ flex: 1, textAlign: 'center', cursor: cancelling ? 'not-allowed' : 'pointer', opacity: cancelling ? 0.6 : 1, fontSize: 11.5, color: C.ink, background: C.avatarPink, border: `1.5px solid ${C.border}`, borderRadius: 6, padding: '7px 0' }}
                >
                  {cancelling ? '処理中…' : 'キャンセルする'}
                </span>
              </div>
            </div>
          )}
          {completeError && <span style={{ fontSize: 10.5, color: C.avatarPink }}>{completeError}</span>}
        </div>
      )}
      {booking && isCancelledBooking && (
        <div
          style={{
            margin: '10px 20px 0',
            background: C.fill,
            border: `1.5px solid ${C.border}`,
            borderRadius: 10,
            padding: '10px 14px',
            textAlign: 'center',
          }}
        >
          <span style={{ fontSize: 11.5, color: C.muted }}>この予約はキャンセルされました</span>
        </div>
      )}
      {booking && booking.status === 'completed' && (
        <div
          style={{
            margin: '10px 20px 0',
            background: C.fill,
            border: `1.5px solid ${C.border}`,
            borderRadius: 10,
            padding: '10px 14px',
            display: 'flex',
            flexDirection: 'column',
            gap: 8,
          }}
        >
          <span style={{ fontSize: 11.5, color: C.lime, textAlign: 'center' }}>✓ プレイ完了・お支払いが確定しました</span>
          {reviewed === false && partner && (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 7 }}>
              <span style={{ fontSize: 11, color: C.ink }}>{partner.name}さんを評価しましょう</span>
              <div style={{ display: 'flex', gap: 6, justifyContent: 'center' }}>
                {[1, 2, 3, 4, 5].map((n) => (
                  <span
                    key={n}
                    onClick={() => setStars(n)}
                    style={{ cursor: 'pointer', fontSize: 26, lineHeight: 1, color: n <= stars ? C.avatarOrange : C.starOff }}
                  >
                    ★
                  </span>
                ))}
              </div>
              <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                {REVIEW_TAGS.map((t) => {
                  const sel = tags.includes(t)
                  return (
                    <span
                      key={t}
                      onClick={() => setTags((xs) => (sel ? xs.filter((x) => x !== t) : [...xs, t]))}
                      style={{
                        cursor: 'pointer',
                        fontSize: 10.5,
                        color: sel ? C.lime : C.ink,
                        background: sel ? C.fill : C.white,
                        border: `1.5px solid ${C.border}`,
                        padding: '5px 10px',
                        borderRadius: 4,
                      }}
                    >
                      {t}
                    </span>
                  )
                })}
              </div>
              <div
                onClick={handleSubmitReview}
                style={{
                  cursor: submittingReview ? 'not-allowed' : 'pointer',
                  opacity: submittingReview ? 0.6 : 1,
                  textAlign: 'center',
                  fontSize: 12,
                  color: C.ink,
                  background: C.lime,
                  border: `1.5px solid ${C.border}`,
                  borderRadius: 6,
                  padding: '8px 0',
                }}
              >
                {submittingReview ? '送信中…' : '評価を送る'}
              </div>
              {reviewError && <span style={{ fontSize: 10.5, color: C.avatarPink }}>{reviewError}</span>}
            </div>
          )}
          {reviewed === true && (
            <span style={{ fontSize: 10.5, color: C.muted, textAlign: 'center' }}>評価を送りました。ありがとうございました</span>
          )}
          {partner && (
            <div
              onClick={() => setGiftOpen(true)}
              style={{
                cursor: 'pointer',
                textAlign: 'center',
                fontSize: 12,
                color: C.ink,
                background: C.white,
                border: `1.5px solid ${C.border}`,
                boxShadow: `2px 2px 0 ${C.lavender}`,
                borderRadius: 6,
                padding: '9px 0',
              }}
            >
              🎁 {partner.name}さんにありがとうギフトを贈る
            </div>
          )}
        </div>
      )}

      <div
        ref={scrollRef}
        className="pita-scroll"
        style={{ flex: 1, overflowY: 'auto', padding: '16px 20px', display: 'flex', flexDirection: 'column', gap: 12 }}
      >
        {loading ? (
          <span style={{ fontSize: 12, color: C.muted, textAlign: 'center' }}>読み込み中…</span>
        ) : messages.length === 0 ? (
          <span style={{ fontSize: 12, color: C.muted, textAlign: 'center', padding: '20px 0' }}>
            まだメッセージはありません。あいさつしてみましょう
          </span>
        ) : (
          messages.map((m) => (
            <Bubble key={m.id} side={m.senderId === myId ? 'right' : 'left'}>
              {m.body}
            </Bubble>
          ))
        )}
      </div>

      <div style={{ padding: '0 20px', background: C.surface }}>
        {error && <span style={{ fontSize: 10.5, color: C.avatarPink }}>{error}</span>}
        {hits.length > 0 && (
          <div
            style={{
              background: C.avatarPink,
              border: `1.5px solid ${C.border}`,
              borderRadius: 8,
              padding: '9px 12px',
              display: 'flex',
              flexDirection: 'column',
              gap: 6,
              marginBottom: 8,
            }}
          >
            <span style={{ fontSize: 11, color: C.ink, lineHeight: 1.6 }}>
              {guardWarningText(hits)}それでも送信しますか?
            </span>
            <div style={{ display: 'flex', gap: 8 }}>
              <span
                onClick={() => setHits([])}
                style={{ flex: 1, textAlign: 'center', cursor: 'pointer', fontSize: 11.5, color: C.ink, background: C.white, border: `1.5px solid ${C.border}`, borderRadius: 6, padding: '7px 0' }}
              >
                やめる
              </span>
              <span
                onClick={() => void doSend()}
                style={{ flex: 1, textAlign: 'center', cursor: 'pointer', fontSize: 11.5, color: C.ink, background: C.lime, border: `1.5px solid ${C.border}`, borderRadius: 6, padding: '7px 0' }}
              >
                送信する
              </span>
            </div>
          </div>
        )}
      </div>

      <div
        style={{
          display: 'flex',
          gap: 8,
          padding: '12px 16px 26px',
          background: C.white,
          borderTop: `1.5px solid ${C.border}`,
          alignItems: 'center',
        }}
      >
        <input
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter') handleSendClick()
          }}
          placeholder="メッセージを入力"
          maxLength={2000}
          style={{
            flex: 1,
            background: C.surface,
            border: `1.5px solid ${C.border}`,
            borderRadius: 8,
            padding: '11px 14px',
            fontSize: 12.5,
            color: C.ink,
            outline: 'none',
            fontFamily: 'inherit',
          }}
        />
        <div
          onClick={handleSendClick}
          style={{
            cursor: draft.trim() && !sending ? 'pointer' : 'not-allowed',
            opacity: draft.trim() && !sending ? 1 : 0.5,
            width: 44,
            height: 44,
            flex: 'none',
            borderRadius: 8,
            background: C.fill,
            boxShadow: `2px 2px 0 ${C.lavender}`,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
          }}
        >
          <Send />
        </div>
      </div>

      {giftOpen && partner && (
        <GiftSheet
          promiseId={promiseId}
          partnerName={partner.name}
          onClose={() => setGiftOpen(false)}
          onSent={() => void markThreadRead(promiseId)}
        />
      )}
    </Screen>
  )
}

/** デモの演出フロー(マッチングのオンボーディング体験)。 */
function DemoTalk({ flow }: { flow: Flow }) {
  const goDay = usePress(`3px 3px 0 ${C.shadowCol}`)
  return (
    <Screen background={C.surface}>
      <StatusBar time="21:49" />
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: 10,
          padding: '10px 20px',
          borderBottom: `1.5px solid ${C.border}`,
          background: C.white,
        }}
      >
        <div onClick={() => flow.go('party')} style={{ cursor: 'pointer' }}>
          <ChevronLeft />
        </div>
        <div
          style={{
            width: 36,
            height: 36,
            borderRadius: 8,
            background: C.avatarAqua,
            border: `1.5px solid ${C.border}`,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            fontSize: 15,
            color: C.ink,
          }}
        >
          み
        </div>
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
            <span style={{ fontSize: 14, color: C.ink }}>みなと</span>
            <span
              style={{
                fontSize: 9,
                color: C.ink,
                background: C.lime,
                border: `1.5px solid ${C.border}`,
                padding: '1px 5px',
                borderRadius: 4,
              }}
            >
              ✓
            </span>
          </div>
          <span style={{ fontSize: 10, color: C.lavender }}>オンライン</span>
        </div>
      </div>
      <div
        onClick={() => flow.openReport({ userId: null, nickname: 'みなと' })}
        style={{
          cursor: 'pointer',
          background: C.surfaceLavender,
          borderBottom: `1.5px solid ${C.lavender}`,
          padding: '8px 20px',
          display: 'flex',
          gap: 8,
          alignItems: 'center',
        }}
      >
        <Shield size={13} style={{ flex: 'none' }} />
        <span style={{ flex: 1, fontSize: 10, color: C.body }}>
          通話はアプリ内が安全です。予約はコインで完結します。外部アプリへの誘導・直接の金銭要求が出たら通報してください。
        </span>
        <span style={{ fontSize: 10, color: C.lavender }}>通報 ›</span>
      </div>
      <div
        className="pita-scroll"
        style={{ flex: 1, overflowY: 'auto', padding: '16px 20px', display: 'flex', flexDirection: 'column', gap: 12 }}
      >
        <Bubble side="left">はじめまして！誘いありがとうございます。今夜22時から大丈夫です🙌</Bubble>
        <Bubble side="right">よろしくお願いします！ゴールド帯でランク回しましょ〜</Bubble>

        <div
          style={{
            alignSelf: 'center',
            width: '100%',
            background: C.lavender,
            border: `1.5px solid ${C.border}`,
            borderRadius: 10,
            boxShadow: `3px 3px 0 ${C.shadowCol}`,
            padding: '13px 14px',
            display: 'flex',
            flexDirection: 'column',
            gap: 9,
          }}
        >
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <span style={{ fontSize: 12, color: C.lavenderText }}>あそぶ約束</span>
            <span
              style={{
                fontSize: 10,
                color: C.ink,
                background: flow.dealDone ? C.lime : C.avatarOrange,
                border: `1.5px solid ${C.border}`,
                padding: '2px 8px',
                borderRadius: 4,
              }}
            >
              {flow.dealDone ? '確定済み' : '確定待ち'}
            </span>
          </div>
          <span style={{ fontSize: 14, color: '#fff' }}>
            {flow.when} · {flow.game} ランク
          </span>
          {!flow.dealDone && (
            <div style={{ display: 'flex', gap: 8 }}>
              <span
                onClick={flow.confirmDeal}
                style={{
                  cursor: 'pointer',
                  flex: 1,
                  textAlign: 'center',
                  fontSize: 12,
                  color: C.ink,
                  background: C.lime,
                  border: `1.5px solid ${C.border}`,
                  padding: '9px 0',
                  borderRadius: 4,
                }}
              >
                ✓ 確定する
              </span>
            </div>
          )}
          {flow.dealDone && (
            <div
              style={{
                background: C.fill,
                borderRadius: 6,
                padding: '8px 10px',
                display: 'flex',
                gap: 7,
                alignItems: 'center',
                justifyContent: 'center',
              }}
            >
              <span style={{ fontSize: 12, color: C.lime }}>✓ 約束が確定しました</span>
            </div>
          )}
        </div>

        {flow.dealDone && (
          <>
            <div style={{ animation: 'scrIn .3s ease both' }}>
              <Bubble side="left">確定しました！フレンドコード送りますね🎮</Bubble>
            </div>
            <div
              style={{
                alignSelf: 'center',
                background: C.deepCard,
                borderRadius: 8,
                padding: '8px 14px',
                animation: 'scrIn .3s .15s ease both',
              }}
            >
              <span style={{ fontSize: 10.5, color: C.lime }}>🔓 フレンドコード交換が解放されました</span>
            </div>
            <div
              className="pita-press"
              onClick={() => flow.go('reminder')}
              {...goDay.handlers}
              style={{
                cursor: 'pointer',
                alignSelf: 'center',
                width: '100%',
                boxSizing: 'border-box',
                background: C.lime,
                color: C.ink,
                border: `1.5px solid ${C.border}`,
                borderRadius: 8,
                padding: '12px 0',
                textAlign: 'center',
                fontSize: 13,
                animation: 'scrIn .3s .3s ease both',
                ...goDay.style,
              }}
            >
              ▶ 約束当日にすすむ(デモ)
            </div>
          </>
        )}
      </div>
      <div
        style={{
          display: 'flex',
          gap: 8,
          padding: '12px 16px 26px',
          background: C.white,
          borderTop: `1.5px solid ${C.border}`,
          alignItems: 'center',
        }}
      >
        <div
          style={{
            flex: 1,
            background: C.surface,
            border: `1.5px solid ${C.border}`,
            borderRadius: 8,
            padding: '11px 14px',
          }}
        >
          <span style={{ fontSize: 12.5, color: C.placeholder }}>メッセージを入力</span>
        </div>
        <div
          style={{
            width: 44,
            height: 44,
            borderRadius: 8,
            background: C.fill,
            boxShadow: `2px 2px 0 ${C.lavender}`,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
          }}
        >
          <Send />
        </div>
      </div>
    </Screen>
  )
}

export default function Talk({ flow }: { flow: Flow }) {
  if (isBackendConfigured && flow.activeThreadId) {
    return <RealTalk flow={flow} promiseId={flow.activeThreadId} />
  }
  return <DemoTalk flow={flow} />
}
