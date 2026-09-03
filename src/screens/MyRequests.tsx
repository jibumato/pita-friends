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
  fetchMyGuestRequests,
  fetchGuestRequestAnswers,
  cancelGuestRequest,
  type MyGuestRequest,
  type GuestRequestAnswer,
} from '../lib/queries'
import { coinsForDuration } from '../flow'

/**
 * 自分が出したリクエストと、応じてくれた人（0120）。
 *
 * ■ ここが「予約の入口」であって、遊びの場ではない
 *   応じてくれた人を押すと、**通常の予約画面**へ行く。トークも、連絡先の
 *   やりとりも、ここには置かない。置いた瞬間に、リクエストが
 *   「予約せずに遊ぶ経路」になる（0113 が閉じたもの）。
 *
 * ■ 「まだ返事がありません」を、失敗として書かない
 *   条件の合う人に届いてはいる。届いた人が全員いま画面を見ているわけでは
 *   ないので、待つ時間があること自体は正常。**取り下げも出し直しもできる**
 *   ことを添えて、詰まりに見えないようにする。
 */
function windowLabel(from: Date, to: Date): string {
  const d = (x: Date) => `${x.getMonth() + 1}/${x.getDate()}`
  const t = (x: Date) => `${x.getHours()}:${x.getMinutes().toString().padStart(2, '0')}`
  return from.toDateString() === to.toDateString()
    ? `${d(from)} ${t(from)}〜${t(to)}`
    : `${d(from)} ${t(from)}〜${d(to)} ${t(to)}`
}

function startLabel(d: Date): string {
  return `${d.getMonth() + 1}/${d.getDate()} ${d.getHours()}:${d.getMinutes().toString().padStart(2, '0')}〜`
}

const STATUS_LABEL: Record<MyGuestRequest['status'], string> = {
  open: '受付中',
  matched: '予約しました',
  cancelled: '取り下げ',
  expired: '受付終了',
}

function AnswerRow({
  request,
  answer,
  flow,
}: {
  request: MyGuestRequest
  answer: GuestRequestAnswer
  flow: Flow
}) {
  const rate = answer.hourlyRate ?? 0
  const cost = rate > 0 ? coinsForDuration(rate, request.durationMinutes) : null

  /**
   * 予約画面へ送る。**ここで予約は作らない**（0113 と同じ）。
   * 残高・キャンセル規定の同意・確定は、すべて予約画面が持っている。
   */
  function handleBook() {
    flow.startBooking(
      {
        name: answer.nickname,
        initial: answer.avatarInitial,
        color: answer.avatarColor,
        hourlyRate: rate,
        userId: answer.hostUserId,
        fromGuestRequestId: request.id,
        requestStartAt: answer.startsAt,
      },
      request.durationMinutes,
      answer.startsAt,
    )
  }

  return (
    <div
      onClick={handleBook}
      role="button"
      tabIndex={0}
      onKeyDown={(e) => {
        if (e.key === 'Enter' || e.key === ' ') handleBook()
      }}
      style={{
        cursor: 'pointer',
        display: 'flex',
        alignItems: 'center',
        gap: 10,
        background: C.white,
        border: `1.5px solid ${C.border}`,
        borderRadius: 8,
        padding: '10px 12px',
      }}
    >
      <div
        style={{
          flex: 'none',
          width: 34,
          height: 34,
          borderRadius: '50%',
          background: answer.avatarColor,
          border: `1.5px solid ${C.border}`,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          fontSize: 13,
          color: C.ink,
          overflow: 'hidden',
        }}
      >
        {answer.avatarUrl ? (
          <img src={answer.avatarUrl} alt="" style={{ width: '100%', height: '100%', objectFit: 'cover' }} />
        ) : (
          answer.avatarInitial
        )}
      </div>
      <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 2 }}>
        <span style={{ fontSize: 13, color: C.ink, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
          {answer.nickname}
        </span>
        <span style={{ fontSize: 10.5, color: C.muted }}>
          {startLabel(answer.startsAt)}
          {cost !== null && `・${cost} コイン`}
        </span>
      </div>
      <span style={{ flex: 'none', fontSize: 11.5, color: C.ink, background: C.lime, border: `1.5px solid ${C.border}`, borderRadius: 6, padding: '7px 11px' }}>
        予約する
      </span>
    </div>
  )
}

function RequestCard({
  r,
  flow,
  onCancelled,
}: {
  r: MyGuestRequest
  flow: Flow
  onCancelled: (id: string) => void
}) {
  const [answers, setAnswers] = useState<GuestRequestAnswer[] | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [confirmingCancel, setConfirmingCancel] = useState(false)

  useEffect(() => {
    if (r.responses === 0) {
      setAnswers([])
      return
    }
    let active = true
    fetchGuestRequestAnswers(r.id)
      .then((rows) => active && setAnswers(rows))
      .catch(() => active && setAnswers([]))
    return () => {
      active = false
    }
  }, [r.id, r.responses])

  async function handleCancel() {
    if (busy) return
    setBusy(true)
    setError(null)
    try {
      await cancelGuestRequest(r.id)
      onCancelled(r.id)
    } catch (e) {
      setError(e instanceof Error ? e.message : '取り下げに失敗しました')
      setConfirmingCancel(false)
    } finally {
      setBusy(false)
    }
  }

  const isOpen = r.status === 'open'

  return (
    <div
      style={{
        background: C.white,
        border: `1.5px solid ${isOpen ? C.lavender : C.border}`,
        borderRadius: 12,
        boxShadow: `3px 3px 0 ${isOpen ? C.lavender : C.shadowCol}`,
        padding: 14,
        display: 'flex',
        flexDirection: 'column',
        gap: 10,
        opacity: isOpen ? 1 : 0.75,
      }}
    >
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 8 }}>
        <span style={{ fontSize: 14, color: C.ink, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
          {r.game}
        </span>
        <span
          style={{
            flex: 'none',
            fontSize: 9.5,
            fontWeight: 700,
            color: C.ink,
            background: isOpen ? C.lime : C.surface,
            border: `1.5px solid ${C.border}`,
            padding: '2px 6px',
            borderRadius: 4,
          }}
        >
          {STATUS_LABEL[r.status]}
        </span>
      </div>

      <span style={{ fontSize: 11.5, color: C.body }}>
        {windowLabel(r.windowStart, r.windowEnd)}・{r.durationMinutes}分
      </span>
      {r.note && <span style={{ fontSize: 11, color: C.muted, lineHeight: 1.6 }}>{r.note}</span>}

      {isOpen &&
        (r.responses === 0 ? (
          <span style={{ fontSize: 11, color: C.muted, lineHeight: 1.7 }}>
            条件の合うピタメイトに届いています。応じた方が出ると、ここに並びます。
          </span>
        ) : answers === null ? (
          <span style={{ fontSize: 11, color: C.muted }}>読み込み中…</span>
        ) : (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
            {answers.map((a) => (
              <AnswerRow key={a.hostUserId} request={r} answer={a} flow={flow} />
            ))}
          </div>
        ))}

      {error && <span style={{ fontSize: 11, color: C.avatarPink }}>{error}</span>}

      {isOpen &&
        (confirmingCancel ? (
          <div style={{ display: 'flex', gap: 8 }}>
            <span
              onClick={() => setConfirmingCancel(false)}
              role="button"
              tabIndex={0}
              onKeyDown={(e) => {
                if (e.key === 'Enter' || e.key === ' ') setConfirmingCancel(false)
              }}
              style={{ flex: 1, textAlign: 'center', cursor: 'pointer', fontSize: 11.5, color: C.ink, background: C.white, border: `1.5px solid ${C.border}`, borderRadius: 6, padding: '8px 0' }}
            >
              やめる
            </span>
            <span
              onClick={() => void handleCancel()}
              role="button"
              tabIndex={0}
              onKeyDown={(e) => {
                if (e.key === 'Enter' || e.key === ' ') void handleCancel()
              }}
              style={{ flex: 1, textAlign: 'center', cursor: busy ? 'default' : 'pointer', fontSize: 11.5, color: C.ink, background: C.avatarPink, border: `1.5px solid ${C.border}`, borderRadius: 6, padding: '8px 0', opacity: busy ? 0.6 : 1 }}
            >
              取り下げる
            </span>
          </div>
        ) : (
          <span
            onClick={() => setConfirmingCancel(true)}
            role="button"
            tabIndex={0}
            onKeyDown={(e) => {
              if (e.key === 'Enter' || e.key === ' ') setConfirmingCancel(true)
            }}
            style={{ alignSelf: 'flex-start', cursor: 'pointer', fontSize: 11, color: C.muted }}
          >
            取り下げる
          </span>
        ))}
    </div>
  )
}

export default function MyRequests({ flow }: { flow: Flow }) {
  const [items, setItems] = useState<MyGuestRequest[] | null>(null)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(() => {
    if (!isBackendConfigured || flow.userId === null) return
    fetchMyGuestRequests()
      .then(setItems)
      .catch((e) => setError(e instanceof Error ? e.message : '読み込めませんでした'))
  }, [flow.userId])

  useEffect(load, [load])

  return (
    <Screen background={C.surface}>
      <StatusBar time="21:47" />
      <SubHeader title="出したリクエスト" onBack={() => flow.go('board')} />
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
            title="出したリクエストを見る"
            body="遊びたい日時とゲームを出しておくと、条件の合うピタメイトに届きます。掲示板には出ません。"
          />
        ) : error ? (
          <span style={{ fontSize: 12, color: C.avatarPink }}>{error}</span>
        ) : items === null ? (
          <span style={{ fontSize: 12, color: C.muted }}>読み込み中…</span>
        ) : items.length === 0 ? (
          <EmptyState
            tileColor={C.avatarAqua}
            icon={<PlusCircle size={44} color={C.ink} strokeWidth={2.4} />}
            title="まだリクエストがありません"
            desc="遊びたい日時とゲームを出しておくと、条件の合うピタメイトに届きます。掲示板には出ません。"
          />
        ) : (
          items.map((r) => (
            <RequestCard
              key={r.id}
              r={r}
              flow={flow}
              onCancelled={(id) =>
                setItems((prev) =>
                  (prev ?? []).map((x) => (x.id === id ? { ...x, status: 'cancelled' } : x)),
                )
              }
            />
          ))
        )}
        <span
          onClick={() => flow.go('requestCreate')}
          role="button"
          tabIndex={0}
          onKeyDown={(e) => {
            if (e.key === 'Enter' || e.key === ' ') flow.go('requestCreate')
          }}
          style={{
            cursor: 'pointer',
            textAlign: 'center',
            fontSize: 13,
            color: C.ctaFg,
            background: C.ctaBg,
            borderRadius: 8,
            padding: '13px 0',
          }}
        >
          リクエストを出す
        </span>
      </div>
    </Screen>
  )
}
