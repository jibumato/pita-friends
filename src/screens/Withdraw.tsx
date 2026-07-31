import { useEffect, useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { SubHeader, Card } from '../components/Ui'
import { isBackendConfigured } from '../lib/supabase'
import { clickable } from '../hooks/clickable'
import {
  fetchWithdrawalPreview,
  withdrawAccount,
  type WithdrawalPreview,
} from '../lib/queries'

/**
 * 退会(規約 第6条の2)。
 *
 * この画面が存在すること自体が条文の履行だが、**核心は「辞められること」
 * ではなく「辞めた後も、稼いだ分を回収できること」**にある。
 * 弁護士(総評3)の指摘:
 *   「換金できない残高を人質に離脱を妨げる外形は、優越的地位の濫用の
 *     評価において最も分の悪い事実になる」
 *
 * 画面の作りで守っていること:
 *   ・第3項「消滅するコインの数を**事前に表示する**」
 *     → 数を出せないうちは実行ボタンを出さない
 *   ・第4項「退会後90日は換金を申請できる」
 *     → 期限を日付で見せる。**本人確認や口座が未登録なら、
 *       退会前に済ませるよう警告する**(退会後はやり直せない)
 *   ・第2項「成立済みの予約は先に片付ける」
 *     → 件数を出して、実行させない
 */
function fmtDate(iso: string): string {
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return ''
  return `${d.getFullYear()}年${d.getMonth() + 1}月${d.getDate()}日`
}

export default function Withdraw({ flow }: { flow: Flow }) {
  const [preview, setPreview] = useState<WithdrawalPreview | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [confirming, setConfirming] = useState(false)
  const [busy, setBusy] = useState(false)
  const [done, setDone] = useState<WithdrawalPreview | null>(null)

  useEffect(() => {
    if (!isBackendConfigured) return
    let active = true
    fetchWithdrawalPreview()
      .then((p) => active && setPreview(p))
      .catch((e) => active && setError(e instanceof Error ? e.message : '取得に失敗しました'))
    return () => {
      active = false
    }
  }, [])

  async function run() {
    if (busy || !preview?.canWithdraw) return
    setBusy(true)
    setError(null)
    try {
      setDone(await withdrawAccount(null))
    } catch (e) {
      const msg = e instanceof Error ? e.message : ''
      setError(
        msg === 'HAS_ACTIVE_BOOKINGS'
          ? '進行中の予約が残っています。完了またはキャンセルしてからお手続きください'
          : msg === 'ALREADY_WITHDRAWN'
            ? 'すでに退会済みです'
            : msg || '退会の手続に失敗しました',
      )
      setConfirming(false)
    } finally {
      setBusy(false)
    }
  }

  const body = (() => {
    if (!isBackendConfigured) {
      return <P>ログインするとお手続きできます。</P>
    }
    if (done) {
      return (
        <>
          <H>退会の手続が完了しました</H>
          <P>ご利用ありがとうございました。</P>
          {done.earnedBalance > 0 && (
            <Notice>
              報酬コイン <b>{done.earnedBalance.toLocaleString()}枚</b> の換金は、
              <b>{fmtDate(done.payoutDeadline)}まで</b>申請できます。期限を過ぎると消滅します。
              <br />
              コインウォレットからお手続きください。
            </Notice>
          )}
          <Action label="コインウォレットへ" onClick={() => flow.go('wallet')} />
        </>
      )
    }
    if (error && !preview) {
      return <P style={{ color: C.avatarPink }}>{error}</P>
    }
    if (!preview) {
      return <P>読み込んでいます…</P>
    }
    if (preview.withdrawnAt) {
      return (
        <>
          <H>すでに退会済みです</H>
          <P>{fmtDate(preview.withdrawnAt)}に退会のお手続きが完了しています。</P>
          {preview.earnedBalance > 0 && (
            <Notice>
              報酬コイン <b>{preview.earnedBalance.toLocaleString()}枚</b> の換金は
              <b>{fmtDate(preview.payoutDeadline)}まで</b>申請できます。
            </Notice>
          )}
        </>
      )
    }

    return (
      <>
        <H>退会するとどうなるか</H>

        {/* 第6条の2第3項: 消滅する数を**事前に**表示する */}
        <Row label="消滅するコイン" danger>
          {(preview.expiringPaid + preview.expiringBonus).toLocaleString()}枚
        </Row>
        <P>
          購入したコインは退会と同時に消滅し、<b>返金はできません</b>(規約 第7条3項)。
          使い切ってから退会するか、このまま進めるかをお選びください。
        </P>

        {/* 第6条の2第4項: 稼いだ分は回収できる */}
        <Row label="換金できる報酬コイン">{preview.earnedBalance.toLocaleString()}枚</Row>
        {preview.earnedBalance > 0 && (
          <Notice>
            報酬コインは<b>退会後{preview.payoutDays}日間</b>
            (〜{fmtDate(preview.payoutDeadline)})に限り換金を申請できます。
            期限を過ぎると消滅します。
            {(!preview.verified || !preview.hasBankAccount) && (
              <>
                <br />
                <b style={{ color: C.avatarPink }}>
                  ⚠️ {!preview.verified && '本人確認'}
                  {!preview.verified && !preview.hasBankAccount && 'と'}
                  {!preview.hasBankAccount && '振込先口座の登録'}
                  が未完了です。退会後はお手続きできません。
                  先に済ませてから退会してください。
                </b>
              </>
            )}
          </Notice>
        )}

        {preview.blockingBookings > 0 && (
          <Notice danger>
            進行中の予約が<b>{preview.blockingBookings}件</b>あります。
            相手のあるお約束なので、<b>完了またはキャンセルしてから</b>退会できます
            (規約 第6条の2第2項)。
          </Notice>
        )}

        <P style={{ marginTop: 4 }}>
          プロフィールや投稿は表示されなくなります。取引の記録は、法令に基づく保存の
          ために当社が保持します(規約 第6条の2第5項)。
        </P>
        <P>
          退会後もログインはできますが、ご利用いただけるのは<b>報酬コインの換金のみ</b>です。
          データの削除をご希望の場合は、設定の「アカウントを削除」から別途ご請求ください。
        </P>

        {error && <P style={{ color: C.avatarPink }}>{error}</P>}

        {preview.canWithdraw ? (
          confirming ? (
            <>
              <Notice danger>
                <b>この操作は取り消せません。</b>
                {preview.expiringPaid + preview.expiringBonus > 0 && (
                  <>
                    {' '}
                    コイン{(preview.expiringPaid + preview.expiringBonus).toLocaleString()}枚が
                    消滅します。
                  </>
                )}
              </Notice>
              <Action
                label={busy ? '手続中…' : '退会する'}
                danger
                onClick={() => void run()}
              />
              <Action label="やめる" onClick={() => setConfirming(false)} />
            </>
          ) : (
            <Action label="退会の手続きに進む" danger onClick={() => setConfirming(true)} />
          )
        ) : (
          <P style={{ color: C.muted }}>いまは退会のお手続きができません。</P>
        )}
      </>
    )
  })()

  return (
    <Screen background={C.surface}>
      <StatusBar time="21:47" />
      <SubHeader title="退会" onBack={() => flow.go('settings')} />
      <div
        className="pita-scroll"
        style={{
          flex: 1,
          overflowY: 'auto',
          padding: '4px 20px 24px',
          display: 'flex',
          flexDirection: 'column',
          gap: 14,
        }}
      >
        <Card>
          <div style={{ padding: '14px 16px', display: 'flex', flexDirection: 'column', gap: 10 }}>
            {body}
          </div>
        </Card>
      </div>
    </Screen>
  )
}

function H({ children }: { children: React.ReactNode }) {
  return <div style={{ fontSize: 14, fontWeight: 700, color: C.body }}>{children}</div>
}

function P({ children, style }: { children: React.ReactNode; style?: React.CSSProperties }) {
  return (
    <div style={{ fontSize: 11.5, lineHeight: 1.7, color: C.body, ...style }}>{children}</div>
  )
}

function Row({
  label,
  children,
  danger,
}: {
  label: string
  children: React.ReactNode
  danger?: boolean
}) {
  return (
    <div
      style={{
        display: 'flex',
        alignItems: 'baseline',
        justifyContent: 'space-between',
        gap: 12,
        padding: '8px 0',
        borderBottom: `1px solid ${C.border}`,
      }}
    >
      <span style={{ fontSize: 11.5, color: C.muted }}>{label}</span>
      <span
        style={{
          fontSize: 15,
          fontWeight: 700,
          color: danger ? C.avatarPink : C.body,
          fontVariantNumeric: 'tabular-nums',
        }}
      >
        {children}
      </span>
    </div>
  )
}

function Notice({ children, danger }: { children: React.ReactNode; danger?: boolean }) {
  return (
    <div
      style={{
        background: danger ? C.white : C.surfaceLavender,
        border: `1.5px solid ${danger ? C.avatarPink : C.lavender}`,
        borderRadius: 8,
        padding: '10px 12px',
        fontSize: 11.5,
        lineHeight: 1.7,
        color: C.body,
      }}
    >
      {children}
    </div>
  )
}

function Action({
  label,
  onClick,
  danger,
}: {
  label: string
  onClick: () => void
  danger?: boolean
}) {
  return (
    <div
      onClick={onClick}
      {...clickable(onClick, label)}
      style={{
        marginTop: 4,
        textAlign: 'center',
        padding: '11px 12px',
        borderRadius: 999,
        border: `1.5px solid ${danger ? C.avatarPink : C.border}`,
        background: danger ? C.avatarPink : C.white,
        color: danger ? C.white : C.body,
        fontSize: 12.5,
        fontWeight: 700,
        cursor: 'pointer',
      }}
    >
      {label}
    </div>
  )
}
