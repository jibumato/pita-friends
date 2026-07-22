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
  fetchBookingForPromise,
  fetchMessages,
  fetchThreadPartner,
  hasReviewedPromise,
  markThreadRead,
  sendMessage,
  submitReview,
  subscribeToMessages,
  type BookingInfo,
  type ChatMessage,
  type ThreadPartner,
} from '../lib/queries'
import { REVIEW_TAGS } from '../flow'
import { containsWarningPattern } from '../lib/ngWords'

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

/** 実データのトークルーム(promise)。 */
function RealTalk({ flow, promiseId }: { flow: Flow; promiseId: string }) {
  const [partner, setPartner] = useState<ThreadPartner | null>(null)
  const [messages, setMessages] = useState<ChatMessage[]>([])
  const [myId, setMyId] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [draft, setDraft] = useState('')
  const [warn, setWarn] = useState(false)
  const [sending, setSending] = useState(false)
  const [booking, setBooking] = useState<BookingInfo | null>(null)
  const [completing, setCompleting] = useState(false)
  const [completeError, setCompleteError] = useState<string | null>(null)
  const [cancelOpen, setCancelOpen] = useState(false)
  const [cancelling, setCancelling] = useState(false)
  const [reviewed, setReviewed] = useState<boolean | null>(null)
  const [stars, setStars] = useState(5)
  const [tags, setTags] = useState<string[]>([])
  const [submittingReview, setSubmittingReview] = useState(false)
  const [reviewError, setReviewError] = useState<string | null>(null)
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

  async function doSend() {
    const body = draft.trim()
    if (!body || sending) return
    setSending(true)
    setError(null)
    try {
      await sendMessage(promiseId, body)
      setDraft('')
      setWarn(false)
    } catch (e) {
      setError(e instanceof Error ? e.message : '送信に失敗しました')
    } finally {
      setSending(false)
    }
  }

  function handleSendClick() {
    if (!draft.trim()) return
    if (!warn && containsWarningPattern(draft)) {
      setWarn(true)
      return
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
            {booking.coins}コインの予約中です。プレイが終わったら、ゲストが「プレイ完了」を確定するとホストに報酬が届きます。
          </span>
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
          {!cancelOpen ? (
            <span
              onClick={() => setCancelOpen(true)}
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
              <span style={{ fontSize: 10.5, lineHeight: 1.6, color: C.body }}>
                {isGuestOfBooking
                  ? '開始1時間前まではコインが全額戻ります。1時間を切るとコインは戻らず(ホストの報酬になります)、ドタキャンとして記録されます。'
                  : 'ホスト都合のキャンセルはコインがゲストに全額戻り、あなたのドタキャン記録に残ります。'}
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
        {warn && (
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
              外部への連絡先交換や金銭のやり取りはアプリ内で完結させてください。それでも送信しますか?
            </span>
            <div style={{ display: 'flex', gap: 8 }}>
              <span
                onClick={() => setWarn(false)}
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
