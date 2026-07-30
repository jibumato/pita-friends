/**
 * 運営コンソール(0066)。
 *
 * これまで**締切のある作業が全部 Supabase の SQL Editor 送り**になっていた。
 *   ・保留の解除 … その間ピタメイトの報酬が凍結され続ける(0042の督促は14日)
 *   ・換金申請 … 毎週日曜締め・翌週金曜払い
 *   ・通報の審査 … 安全に直結する
 *   ・開示・削除請求 … 個人情報保護法の期限がある
 * ワンオペで毎回SQLを手打ちするのは破綻するし、間違ったUPDATEで台帳が壊れる。
 *
 * 画面の作りで意識していること:
 *   ・**古いものを上に出す。** 放置しているものが目に入るようにする
 *   ・**取り消せない操作には理由の入力を必須にする。** 記録に残るので、
 *     後から「なぜその判断か」を説明できる(金銭トラブル・税務・弁護士対応)
 *   ・**判定はDB側。** この画面を隠すだけの制御にはしていない
 *     (隠しても叩けるなら意味がない。0066で全RPCに管理者判定がある)
 */
import { useCallback, useEffect, useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { SubHeader } from '../components/Ui'
import { isBackendConfigured } from '../lib/supabase'
import {
  fetchAdminSummary,
  fetchAdminReports,
  fetchAdminHeldBookings,
  fetchAdminPendingPayouts,
  fetchAdminAccountRequests,
  fetchAdminHealth,
  fetchAdminActions,
  resolveReportAsAdmin,
  releaseHoldComplete,
  releaseHoldRefund,
  markPayoutPaid,
  markPayoutFailed,
  setAccountRequestStatus,
  type AdminSummary,
  type AdminReport,
  type AdminHeldBooking,
  type AdminPayout,
  type AdminAccountRequest,
  type AdminHealth,
  type AdminAction,
  fetchAdminDisputes,
  resolveDispute,
  type AdminDispute,
} from '../lib/queries'

type Tab = 'summary' | 'reports' | 'holds' | 'payouts' | 'requests' | 'disputes' | 'health' | 'log'

const TABS: { key: Tab; label: string }[] = [
  { key: 'summary', label: 'やること' },
  { key: 'holds', label: '保留' },
  { key: 'reports', label: '通報' },
  { key: 'payouts', label: '換金' },
  { key: 'requests', label: '請求' },
  { key: 'disputes', label: '異議申立て' },
  { key: 'health', label: '健全性' },
  { key: 'log', label: '操作記録' },
]

/** 件数が0でないときだけ色を変える(0のものを目立たせない)。 */
function badgeColor(key: string, n: number): string {
  if (n === 0) return C.muted
  if (key.includes('保留') || key.includes('整合性') || key.includes('諦めた')) return '#E5484D'
  return C.ink
}

export default function AdminConsole({ flow }: { flow: Flow }) {
  const [tab, setTab] = useState<Tab>('summary')
  const [summary, setSummary] = useState<AdminSummary | null>(null)
  const [error, setError] = useState<string | null>(null)

  const loadSummary = useCallback(() => {
    if (!isBackendConfigured) return
    fetchAdminSummary()
      .then(setSummary)
      .catch((e) => setError(e instanceof Error ? e.message : '読み込めませんでした'))
  }, [])

  useEffect(loadSummary, [loadSummary])

  return (
    <Screen background={C.surface}>
      <StatusBar time="21:47" />
      <SubHeader title="運営コンソール" onBack={() => flow.go('settings')} />

      {/* タブ */}
      <div
        className="pita-scroll"
        style={{
          display: 'flex',
          gap: 6,
          padding: '0 20px 10px',
          overflowX: 'auto',
          flex: 'none',
        }}
      >
        {TABS.map((t) => {
          const on = tab === t.key
          return (
            <span
              key={t.key}
              onClick={() => setTab(t.key)}
              role="button"
              tabIndex={0}
              style={{
                cursor: 'pointer',
                flex: 'none',
                fontSize: 12,
                color: on ? C.ink : C.body,
                background: on ? C.lime : C.white,
                border: `1.5px solid ${C.border}`,
                borderRadius: 8,
                padding: '8px 12px',
              }}
            >
              {t.label}
            </span>
          )
        })}
      </div>

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
        {!isBackendConfigured && (
          <Note>バックエンド未接続のため、運営コンソールは使えません。</Note>
        )}
        {error && <ErrorBox>{error}</ErrorBox>}

        {tab === 'summary' && <SummaryTab summary={summary} onGo={setTab} onReload={loadSummary} />}
        {tab === 'holds' && <HoldsTab onChanged={loadSummary} />}
        {tab === 'reports' && <ReportsTab onChanged={loadSummary} />}
        {tab === 'payouts' && <PayoutsTab onChanged={loadSummary} />}
        {tab === 'requests' && <RequestsTab onChanged={loadSummary} />}
        {tab === 'disputes' && <DisputesTab />}
        {tab === 'health' && <HealthTab />}
        {tab === 'log' && <LogTab />}
      </div>
    </Screen>
  )
}

// ------------------------------------------------------------
// 共通の見た目
// ------------------------------------------------------------

function Card({ children, alert = false }: { children: React.ReactNode; alert?: boolean }) {
  return (
    <div
      style={{
        background: C.white,
        border: `1.5px solid ${alert ? '#E5484D' : C.border}`,
        borderRadius: 10,
        padding: '12px 14px',
        display: 'flex',
        flexDirection: 'column',
        gap: 8,
      }}
    >
      {children}
    </div>
  )
}

function Note({ children }: { children: React.ReactNode }) {
  return (
    <span style={{ fontSize: 11, color: C.muted, lineHeight: 1.7 }}>{children}</span>
  )
}

function ErrorBox({ children }: { children: React.ReactNode }) {
  return (
    <div
      style={{
        background: C.avatarPink,
        border: `1.5px solid ${C.border}`,
        borderRadius: 8,
        padding: '10px 12px',
        fontSize: 11.5,
        color: C.ink,
        lineHeight: 1.6,
      }}
    >
      {children}
    </div>
  )
}

function Btn({
  onClick,
  children,
  danger = false,
  disabled = false,
}: {
  onClick: () => void
  children: React.ReactNode
  danger?: boolean
  disabled?: boolean
}) {
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      style={{
        cursor: disabled ? 'default' : 'pointer',
        background: disabled ? C.disabledBg : danger ? '#E5484D' : C.lime,
        color: disabled ? C.disabledFg : danger ? '#fff' : C.ink,
        border: `1.5px solid ${C.border}`,
        borderRadius: 8,
        padding: '9px 12px',
        fontSize: 12,
        fontFamily: 'inherit',
        // flex は付けない。縦並び(column)の中では flex:1 が「高さ」を伸ばして
        // ボタンが画面いっぱいになる。横並びの幅揃えは呼び側の grid で行う
      }}
    >
      {children}
    </button>
  )
}

function Field({
  value,
  onChange,
  placeholder,
}: {
  value: string
  onChange: (v: string) => void
  placeholder: string
}) {
  return (
    <input
      value={value}
      onChange={(e) => onChange(e.target.value)}
      placeholder={placeholder}
      maxLength={300}
      style={{
        background: C.white,
        border: `1.5px solid ${C.border}`,
        borderRadius: 8,
        padding: '9px 11px',
        fontSize: 12,
        color: C.ink,
        outline: 'none',
        fontFamily: 'inherit',
        width: '100%',
        boxSizing: 'border-box',
      }}
    />
  )
}

/** 一覧を読み込む定型。空・エラー・読み込み中の3状態をここで吸収する。 */
function useList<T>(load: () => Promise<T[]>, deps: unknown[] = []) {
  const [items, setItems] = useState<T[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const reload = useCallback(() => {
    if (!isBackendConfigured) {
      setItems([])
      return
    }
    setError(null)
    load()
      .then(setItems)
      .catch((e) => setError(e instanceof Error ? e.message : '読み込めませんでした'))
    // load は毎回別の関数になるので依存に入れない(呼び側の deps で制御する)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps)
  useEffect(reload, [reload])
  return { items, error, reload }
}

const jst = (iso: string) =>
  new Date(iso).toLocaleString('ja-JP', {
    timeZone: 'Asia/Tokyo',
    month: 'numeric',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  })

// ------------------------------------------------------------
// やること
// ------------------------------------------------------------

function SummaryTab({
  summary,
  onGo,
  onReload,
}: {
  summary: AdminSummary | null
  onGo: (t: Tab) => void
  onReload: () => void
}) {
  if (!summary) return <Note>読み込み中…</Note>

  const entries = Object.entries(summary)
  const jump: Record<string, Tab> = {
    未対応の通報: 'reports',
    保留中の予約: 'holds',
    保留の最長日数: 'holds',
    未処理の換金申請: 'payouts',
    換金申請の合計コイン: 'payouts',
    '未処理の開示・削除請求': 'requests',
    整合性の警告: 'health',
    プッシュ送信待ち: 'health',
    プッシュ諦めた件数: 'health',
    台帳バックアップ経過時間: 'health',
  }

  return (
    <>
      <Note>
        件数だけを出します。中身は各タブで読み込みます（開いたぶんだけ読む作りにしてあります）。
      </Note>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 1 }}>
        {entries.map(([k, v]) => {
          const n = v ?? 0
          const t = jump[k]
          return (
            <div
              key={k}
              onClick={t ? () => onGo(t) : undefined}
              role={t ? 'button' : undefined}
              tabIndex={t ? 0 : undefined}
              style={{
                cursor: t ? 'pointer' : 'default',
                background: C.white,
                border: `1.5px solid ${C.border}`,
                borderRadius: 8,
                padding: '11px 13px',
                display: 'flex',
                justifyContent: 'space-between',
                alignItems: 'center',
                gap: 10,
              }}
            >
              <span style={{ fontSize: 12, color: C.ink }}>{k}</span>
              <span
                style={{
                  fontSize: 15,
                  color: badgeColor(k, n),
                  fontVariantNumeric: 'tabular-nums',
                }}
              >
                {v === null ? '—' : n.toLocaleString()}
              </span>
            </div>
          )
        })}
      </div>
      <Btn onClick={onReload}>再読み込み</Btn>
      <Note>
        <b style={{ color: C.ink }}>保留</b>のあいだ、ピタメイトの報酬は凍結されたままです。
        14日を超えているものは最優先で片付けてください。
        <b style={{ color: C.ink }}>台帳バックアップ経過時間</b>が「—」のときは、
        まだ一度も成功していません（`workers/ledger-export` の未デプロイ）。
      </Note>
    </>
  )
}

// ------------------------------------------------------------
// 保留中の予約
// ------------------------------------------------------------

function HoldsTab({ onChanged }: { onChanged: () => void }) {
  const { items, error, reload } = useList<AdminHeldBooking>(fetchAdminHeldBookings, [])
  const [openId, setOpenId] = useState<string | null>(null)
  const [note, setNote] = useState('')
  const [percent, setPercent] = useState(50)
  const [busy, setBusy] = useState(false)
  const [actionError, setActionError] = useState<string | null>(null)

  async function run(fn: () => Promise<void>) {
    if (busy) return
    if (note.trim().length === 0) {
      setActionError('理由を入力してください（記録に残ります）')
      return
    }
    setBusy(true)
    setActionError(null)
    try {
      await fn()
      setOpenId(null)
      setNote('')
      reload()
      onChanged()
    } catch (e) {
      setActionError(e instanceof Error ? e.message : '処理できませんでした')
    } finally {
      setBusy(false)
    }
  }

  if (error) return <ErrorBox>{error}</ErrorBox>
  if (!items) return <Note>読み込み中…</Note>
  if (items.length === 0) return <Note>保留中の予約はありません。</Note>

  return (
    <>
      <Note>
        申し出や通報で自動確定を止めている予約です（0042）。
        <b style={{ color: C.ink }}>解除するまでピタメイトの報酬は凍結されたまま</b>なので、
        古いものから片付けてください。
      </Note>
      {items.map((b) => (
        <Card key={b.id} alert={b.heldDays >= 14}>
          <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10 }}>
            <span style={{ fontSize: 12.5, color: C.ink }}>
              {b.guestName} → {b.hostName}
            </span>
            <span
              style={{
                fontSize: 11,
                color: b.heldDays >= 14 ? '#E5484D' : C.muted,
                flex: 'none',
              }}
            >
              保留{b.heldDays}日
            </span>
          </div>
          <span style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.7 }}>
            {jst(b.scheduledAt)}開始 / {b.durationMinutes}分 / 凍結{' '}
            <b style={{ color: C.ink }}>{b.coins.toLocaleString()}コイン</b>
            （うち購入コイン {b.paidCoins.toLocaleString()}）
            <br />
            理由: {b.holdReason ?? '(なし)'} / この2人の通報 {b.reportCount}件
          </span>

          {openId === b.id ? (
            <>
              <Field value={note} onChange={setNote} placeholder="判断の理由（記録に残ります）" />
              <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                <span style={{ fontSize: 11, color: C.muted, flex: 'none' }}>返還する割合</span>
                <select
                  value={percent}
                  onChange={(e) => setPercent(Number(e.target.value))}
                  aria-label="返還する割合"
                  style={{
                    background: C.white,
                    color: C.ink,
                    border: `1.5px solid ${C.border}`,
                    borderRadius: 8,
                    padding: '7px 8px',
                    fontSize: 12,
                    fontFamily: 'inherit',
                  }}
                >
                  {[0, 25, 50, 75, 100].map((p) => (
                    <option key={p} value={p}>
                      {p}%
                    </option>
                  ))}
                </select>
                <span style={{ fontSize: 10, color: C.muted }}>
                  ゲストへ {Math.round((b.coins * percent) / 100).toLocaleString()} /
                  ピタメイトへ {(b.coins - Math.round((b.coins * percent) / 100)).toLocaleString()}
                </span>
              </div>
              {actionError && <ErrorBox>{actionError}</ErrorBox>}
              <div style={{ display: 'grid', gridAutoFlow: 'column', gap: 6 }}>
                <Btn disabled={busy} onClick={() => void run(() => releaseHoldRefund(b.id, percent, note))}>
                  返還して解除
                </Btn>
                <Btn
                  disabled={busy}
                  onClick={() => void run(() => releaseHoldComplete(b.id, note))}
                >
                  申し出を退けて確定
                </Btn>
              </div>
              <span
                onClick={() => {
                  setOpenId(null)
                  setActionError(null)
                }}
                role="button"
                tabIndex={0}
                style={{ cursor: 'pointer', fontSize: 11, color: C.muted, textAlign: 'center' }}
              >
                やめる
              </span>
            </>
          ) : (
            <Btn onClick={() => setOpenId(b.id)}>この保留を処理する</Btn>
          )}
        </Card>
      ))}
    </>
  )
}

// ------------------------------------------------------------
// 通報
// ------------------------------------------------------------

const CATEGORY_LABEL: Record<string, string> = {
  external_invite: '外部への誘導',
  money_request: '金銭の要求',
  dating_solicitation: '出会い目的の勧誘',
  harassment: '嫌がらせ',
  impersonation: 'なりすまし',
  no_show: '無断欠席',
  other: 'その他',
}

function ReportsTab({ onChanged }: { onChanged: () => void }) {
  const { items, error, reload } = useList<AdminReport>(() => fetchAdminReports('open'), [])
  const [openId, setOpenId] = useState<string | null>(null)
  const [note, setNote] = useState('')
  const [points, setPoints] = useState(0)
  const [busy, setBusy] = useState(false)
  const [actionError, setActionError] = useState<string | null>(null)

  async function run(status: 'resolved' | 'dismissed', id: string) {
    if (busy) return
    if (note.trim().length === 0) {
      setActionError('処分の理由を入力してください（記録に残ります）')
      return
    }
    setBusy(true)
    setActionError(null)
    try {
      await resolveReportAsAdmin(id, note.trim(), status, points > 0 ? points : null)
      setOpenId(null)
      setNote('')
      setPoints(0)
      reload()
      onChanged()
    } catch (e) {
      setActionError(e instanceof Error ? e.message : '処理できませんでした')
    } finally {
      setBusy(false)
    }
  }

  if (error) return <ErrorBox>{error}</ErrorBox>
  if (!items) return <Note>読み込み中…</Note>
  if (items.length === 0) return <Note>未対応の通報はありません。</Note>

  return (
    <>
      <Note>重いものと古いものが上に来ます。減点すると相手のマナースコアに反映されます。</Note>
      {items.map((r) => (
        <Card key={r.id} alert={r.severity === 'high' || r.severity === 'critical'}>
          <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10 }}>
            <span style={{ fontSize: 12.5, color: C.ink }}>
              {CATEGORY_LABEL[r.category] ?? r.category}
            </span>
            <span style={{ fontSize: 10.5, color: C.muted, flex: 'none' }}>{jst(r.createdAt)}</span>
          </div>
          <span style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.7 }}>
            {r.reporterName} → <b style={{ color: C.ink }}>{r.reportedName}</b>
            （深刻度 {r.severity} / この人への通報は通算{r.reportedReportCount}件 / マナー{' '}
            {r.reportedManner ?? '—'}）
          </span>
          {r.messageSnapshot != null && (
            <pre
              className="pita-scroll"
              style={{
                margin: 0,
                maxHeight: 120,
                overflow: 'auto',
                background: C.surface,
                border: `1.5px solid ${C.divider}`,
                borderRadius: 8,
                padding: '8px 10px',
                fontSize: 10,
                color: C.body,
                whiteSpace: 'pre-wrap',
                wordBreak: 'break-all',
                fontFamily: 'inherit',
              }}
            >
              {JSON.stringify(r.messageSnapshot, null, 1)}
            </pre>
          )}

          {openId === r.id ? (
            <>
              <Field value={note} onChange={setNote} placeholder="処分の理由（記録に残ります）" />
              <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                <span style={{ fontSize: 11, color: C.muted, flex: 'none' }}>減点</span>
                <select
                  value={points}
                  onChange={(e) => setPoints(Number(e.target.value))}
                  aria-label="減点"
                  style={{
                    background: C.white,
                    color: C.ink,
                    border: `1.5px solid ${C.border}`,
                    borderRadius: 8,
                    padding: '7px 8px',
                    fontSize: 12,
                    fontFamily: 'inherit',
                  }}
                >
                  {[0, 1, 3, 5, 10].map((p) => (
                    <option key={p} value={p}>
                      {p === 0 ? 'なし' : `-${p}`}
                    </option>
                  ))}
                </select>
              </div>
              {actionError && <ErrorBox>{actionError}</ErrorBox>}
              <div style={{ display: 'grid', gridAutoFlow: 'column', gap: 6 }}>
                <Btn disabled={busy} onClick={() => void run('resolved', r.id)}>
                  違反として処分
                </Btn>
                <Btn disabled={busy} onClick={() => void run('dismissed', r.id)}>
                  違反なしで終了
                </Btn>
              </div>
              <span
                onClick={() => {
                  setOpenId(null)
                  setActionError(null)
                }}
                role="button"
                tabIndex={0}
                style={{ cursor: 'pointer', fontSize: 11, color: C.muted, textAlign: 'center' }}
              >
                やめる
              </span>
            </>
          ) : (
            <Btn onClick={() => setOpenId(r.id)}>審査する</Btn>
          )}
        </Card>
      ))}
    </>
  )
}

// ------------------------------------------------------------
// 換金申請
// ------------------------------------------------------------

/** 銀行の一括振込に貼れる形でCSVを作る。Excelで開けるようBOM付き。 */
function payoutsCsv(rows: AdminPayout[]): string {
  const head = [
    '申請ID',
    '申請日時',
    'ニックネーム',
    '金融機関名',
    '金融機関コード',
    '支店名',
    '支店コード',
    '預金種目',
    '口座番号',
    '口座名義',
    '振込額(円)',
    '手数料(円)',
    '申請コイン',
  ]
  const esc = (v: string | number) => `"${String(v).replace(/"/g, '""')}"`
  const body = rows.map((r) =>
    [
      r.id,
      jst(r.createdAt),
      r.nickname,
      r.bankName,
      r.bankCode,
      r.branchName,
      r.branchCode,
      r.accountType,
      r.accountNumber,
      r.accountHolderKana,
      r.amountYen,
      r.feeYen,
      r.coins,
    ]
      .map(esc)
      .join(','),
  )
  return '﻿' + [head.map(esc).join(','), ...body].join('\r\n')
}

function PayoutsTab({ onChanged }: { onChanged: () => void }) {
  const { items, error, reload } = useList<AdminPayout>(fetchAdminPendingPayouts, [])
  const [openId, setOpenId] = useState<string | null>(null)
  const [note, setNote] = useState('')
  const [busy, setBusy] = useState(false)
  const [actionError, setActionError] = useState<string | null>(null)

  function download() {
    if (!items || items.length === 0) return
    const blob = new Blob([payoutsCsv(items)], { type: 'text/csv;charset=utf-8' })
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = `payouts-${new Date().toISOString().slice(0, 10)}.csv`
    a.click()
    URL.revokeObjectURL(url)
  }

  async function run(fn: () => Promise<void>) {
    if (busy) return
    setBusy(true)
    setActionError(null)
    try {
      await fn()
      setOpenId(null)
      setNote('')
      reload()
      onChanged()
    } catch (e) {
      setActionError(e instanceof Error ? e.message : '処理できませんでした')
    } finally {
      setBusy(false)
    }
  }

  if (error) return <ErrorBox>{error}</ErrorBox>
  if (!items) return <Note>読み込み中…</Note>

  const total = items.reduce((n, r) => n + r.amountYen, 0)

  return (
    <>
      {/* 弁護士の確認が済むまで実際の振込は行わない、という運用上のゲート */}
      <ErrorBox>
        <b>弁護士の確認が済むまで、実際の銀行振込は行わないでください。</b>
        <br />
        申請は溜めておいて構いません（報酬コインは失効しません）。この画面は申請の確認とCSV出力までを担います。
        「振込済みにする」は<b>実際に振り込んだ後の記録</b>で、取り消せません。
      </ErrorBox>
      {items.length === 0 ? (
        <Note>未処理の換金申請はありません。</Note>
      ) : (
        <>
          <Note>
            {items.length}件 / 振込額の合計 <b style={{ color: C.ink }}>{total.toLocaleString()}円</b>
            。締めは毎週日曜23:59、支払いは翌週金曜です（手順は docs/payouts-bank-operations.md）。
            <br />
            この一覧を開いたことは操作記録に残ります（誰がいつ口座情報を見たか）。
          </Note>
          <Btn onClick={download}>CSVをダウンロード</Btn>
          {items.map((p) => (
            <Card key={p.id} alert={!p.isVerified}>
              <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10 }}>
                <span style={{ fontSize: 12.5, color: C.ink }}>{p.nickname}</span>
                <span style={{ fontSize: 13, color: C.ink, flex: 'none', fontVariantNumeric: 'tabular-nums' }}>
                  {p.amountYen.toLocaleString()}円
                </span>
              </div>
              {!p.isVerified && (
                <span style={{ fontSize: 11, color: '#E5484D' }}>
                  ⚠️ 本人確認が未完了です。振り込まないでください。
                </span>
              )}
              <span style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.8 }}>
                {jst(p.createdAt)}申請 / 申請{p.coins.toLocaleString()}コイン（手数料{p.feeYen}円）
                <br />
                {p.bankName}（{p.bankCode}） {p.branchName}（{p.branchCode}） {p.accountType}
                <br />
                {p.accountNumber} / {p.accountHolderKana}
              </span>

              {openId === p.id ? (
                <>
                  <Field value={note} onChange={setNote} placeholder="メモ / 失敗の理由" />
                  {actionError && <ErrorBox>{actionError}</ErrorBox>}
                  <div style={{ display: 'grid', gridAutoFlow: 'column', gap: 6 }}>
                    <Btn
                      danger
                      disabled={busy}
                      onClick={() => void run(() => markPayoutPaid(p.id, note))}
                    >
                      振込済みにする
                    </Btn>
                    <Btn
                      disabled={busy || note.trim().length === 0}
                      onClick={() => void run(() => markPayoutFailed(p.id, note.trim()))}
                    >
                      振込失敗（全額戻す）
                    </Btn>
                  </div>
                  <span
                    onClick={() => {
                      setOpenId(null)
                      setActionError(null)
                    }}
                    role="button"
                    tabIndex={0}
                    style={{ cursor: 'pointer', fontSize: 11, color: C.muted, textAlign: 'center' }}
                  >
                    やめる
                  </span>
                </>
              ) : (
                <Btn onClick={() => setOpenId(p.id)}>消し込む</Btn>
              )}
            </Card>
          ))}
        </>
      )}
    </>
  )
}

// ------------------------------------------------------------
// 開示・削除請求
// ------------------------------------------------------------

function RequestsTab({ onChanged }: { onChanged: () => void }) {
  const { items, error, reload } = useList<AdminAccountRequest>(fetchAdminAccountRequests, [])
  const [busy, setBusy] = useState(false)

  async function run(id: string, status: 'processing' | 'completed') {
    if (busy) return
    setBusy(true)
    try {
      await setAccountRequestStatus(id, status)
      reload()
      onChanged()
    } finally {
      setBusy(false)
    }
  }

  if (error) return <ErrorBox>{error}</ErrorBox>
  if (!items) return <Note>読み込み中…</Note>
  if (items.length === 0) return <Note>未処理の請求はありません。</Note>

  return (
    <>
      <Note>
        個人情報保護法の開示・削除請求です。<b style={{ color: C.ink }}>期限があります。</b>
        <br />
        ⚠️ <b style={{ color: C.ink }}>削除請求で実際にデータを匿名化するのは `anonymize_user()`（0046）です。</b>
        ここで「対応済み」にしても、データは消えません。取り違えると復旧できないので、
        匿名化を実行してから押してください（手順は docs/data-integrity.md）。
      </Note>
      {items.map((a) => (
        <Card key={a.id} alert={a.waitingDays >= 10}>
          <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10 }}>
            <span style={{ fontSize: 12.5, color: C.ink }}>
              {a.type === 'data_export' ? 'データの開示請求' : 'アカウント削除請求'}
            </span>
            <span
              style={{ fontSize: 11, color: a.waitingDays >= 10 ? '#E5484D' : C.muted, flex: 'none' }}
            >
              {a.waitingDays}日経過
            </span>
          </div>
          <span style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.7 }}>
            {a.nickname} / {jst(a.createdAt)}申請 / 状態 {a.status}
            <br />
            対象のユーザーID: {a.userId}
          </span>
          <div style={{ display: 'grid', gridAutoFlow: 'column', gap: 6 }}>
            {a.status === 'pending' && (
              <Btn disabled={busy} onClick={() => void run(a.id, 'processing')}>
                着手中にする
              </Btn>
            )}
            <Btn disabled={busy} onClick={() => void run(a.id, 'completed')}>
              対応済みにする
            </Btn>
          </div>
        </Card>
      ))}
    </>
  )
}

// ------------------------------------------------------------
// 異議申立て(チャージバック)。0075。
// ------------------------------------------------------------
// ⚠️ **解除するとコインが使えるようになる。** lost(返金が確定した)場合は、
//    残高の調整を済ませてから解除すること。順序を逆にすると、返金された
//    うえにコインも使われる。
// ------------------------------------------------------------

function DisputesTab() {
  const { items, error, reload } = useList<AdminDispute>(fetchAdminDisputes, [])
  const [note, setNote] = useState<Record<string, string>>({})
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)

  async function run(id: string) {
    if (busy) return
    setBusy(true)
    setErr(null)
    try {
      await resolveDispute(id, note[id] ?? '')
      setNote((n) => ({ ...n, [id]: '' }))
      reload()
    } catch (e) {
      setErr(e instanceof Error ? e.message : '解除に失敗しました')
    } finally {
      setBusy(false)
    }
  }

  if (error) return <ErrorBox>{error}</ErrorBox>
  if (!items) return <Note>読み込み中…</Note>
  if (items.length === 0) return <Note>未処理の異議申立てはありません。</Note>

  return (
    <>
      <Note>
        Stripeで異議申立て（チャージバック）を受けている決済です。
        <b style={{ color: C.ink }}>この間、対象の方はコインを使えません</b>
        （新しい予約・ギフト。すでに成立した予約の進行は止まりません）。
        <br />
        ⚠️ <b style={{ color: C.ink }}>
          lost（返金が確定）の場合は、先に残高を調整してから解除してください。
        </b>
        順序を逆にすると、返金されたうえにコインも使われます。
      </Note>
      {err && <ErrorBox>{err}</ErrorBox>}
      {items.map((d) => (
        <Card key={d.id} alert={d.status === 'lost'}>
          <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10 }}>
            <span style={{ fontSize: 12.5, color: C.ink }}>
              {d.nickname ?? '（購入と紐づかない申立て）'}
            </span>
            <span
              style={{
                fontSize: 11,
                flex: 'none',
                color: d.status === 'lost' ? '#E5484D' : C.muted,
              }}
            >
              {d.status}
            </span>
          </div>
          <span style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.7 }}>
            {d.amountYen != null ? `¥${d.amountYen.toLocaleString()}` : '金額不明'} /{' '}
            {d.reason ?? '理由なし'} / {jst(d.createdAt)}
            <br />
            残高 {d.coinBalance.toLocaleString()}コイン / 報酬{' '}
            {d.earnedBalance.toLocaleString()}コイン
            <br />
            Stripe: {d.stripeDisputeId}
            {d.userId && (
              <>
                <br />
                対象のユーザーID: {d.userId}
              </>
            )}
          </span>
          <Field
            value={note[d.id] ?? ''}
            onChange={(v) => setNote((n) => ({ ...n, [d.id]: v }))}
            placeholder="解除の理由（必須）例: 返金分を残高から差し引いたうえで解除"
          />
          <Btn disabled={busy} onClick={() => void run(d.id)}>
            凍結を解除する
          </Btn>
        </Card>
      ))}
    </>
  )
}

// ------------------------------------------------------------
// 健全性
// ------------------------------------------------------------

function HealthTab() {
  const [h, setH] = useState<AdminHealth | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (!isBackendConfigured) return
    let active = true
    fetchAdminHealth()
      .then((x) => active && setH(x))
      .catch((e) => active && setError(e instanceof Error ? e.message : '読み込めませんでした'))
    return () => {
      active = false
    }
  }, [])

  if (error) return <ErrorBox>{error}</ErrorBox>
  if (!h) return <Note>読み込み中…</Note>

  const stale =
    h.ledgerExport === null ||
    Date.now() - new Date(h.ledgerExport.ran_at).getTime() > 36 * 3600 * 1000

  return (
    <>
      <span style={{ fontSize: 12, color: C.ink }}>取引データの整合性（0043）</span>
      {h.integrity.length === 0 ? (
        <Note>まだ一度も走っていません（pg_cron の設定を確認してください）。</Note>
      ) : (
        h.integrity.map((c) => {
          const bad = c.severity !== 'ok' && c.affected_count > 0
          return (
            <Card key={c.check_name} alert={bad}>
              <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10 }}>
                <span style={{ fontSize: 12, color: C.ink }}>{c.check_name}</span>
                <span style={{ fontSize: 11, color: bad ? '#E5484D' : C.muted, flex: 'none' }}>
                  {bad ? `${c.severity} / ${c.affected_count}件` : 'OK'}
                </span>
              </div>
              <span style={{ fontSize: 10, color: C.muted }}>
                {jst(c.ran_at)}
                {c.total_gap != null && c.total_gap !== 0 && ` / ズレ ${c.total_gap.toLocaleString()}`}
              </span>
            </Card>
          )
        })
      )}

      <span style={{ fontSize: 12, color: C.ink, marginTop: 6 }}>台帳の外部バックアップ（0047）</span>
      <Card alert={stale}>
        {h.ledgerExport === null ? (
          <span style={{ fontSize: 11.5, color: '#E5484D', lineHeight: 1.7 }}>
            まだ一度も成功していません。`workers/ledger-export` が未デプロイの可能性があります。
            <b>取引データの復旧手段が無い状態です。</b>
          </span>
        ) : (
          <span style={{ fontSize: 11, color: C.muted, lineHeight: 1.7 }}>
            最終実行 {jst(h.ledgerExport.ran_at)} / {h.ledgerExport.ok ? '成功' : '失敗'} /{' '}
            {h.ledgerExport.row_count.toLocaleString()}行
            {h.ledgerExport.error && (
              <>
                <br />
                <span style={{ color: '#E5484D' }}>{h.ledgerExport.error}</span>
              </>
            )}
            {stale && (
              <>
                <br />
                <b style={{ color: '#E5484D' }}>36時間以上動いていません。</b>
              </>
            )}
          </span>
        )}
      </Card>

      <span style={{ fontSize: 12, color: C.ink, marginTop: 6 }}>プッシュ通知（0064）</span>
      <Card alert={h.push.givenUp > 0}>
        <span style={{ fontSize: 11, color: C.muted, lineHeight: 1.8 }}>
          送信待ち {h.push.pending}件 / 諦めた{' '}
          <b style={{ color: h.push.givenUp > 0 ? '#E5484D' : C.ink }}>{h.push.givenUp}件</b>
          <br />
          登録端末 {h.push.devices}台 / 停止した端末 {h.push.disabled}台
          {h.push.lastError && (
            <>
              <br />
              直近のエラー: {h.push.lastError}
            </>
          )}
        </span>
        {h.push.pending > 50 && (
          <span style={{ fontSize: 10.5, color: '#E5484D', lineHeight: 1.6 }}>
            滞留しています。pg_cron から push-send が叩けているか確認してください
            （docs/web-push-setup.md 手順5）。
          </span>
        )}
      </Card>
    </>
  )
}

// ------------------------------------------------------------
// 操作記録
// ------------------------------------------------------------

const KIND_LABEL: Record<string, string> = {
  resolve_report: '通報の処分',
  release_hold_complete: '保留の解除（確定）',
  release_hold_refund: '保留の解除（返還）',
  mark_payout_paid: '振込済みにした',
  mark_payout_failed: '振込失敗にした',
  view_pending_payouts: '口座情報を表示した',
  account_request_processing: '請求に着手',
  account_request_completed: '請求を対応済みに',
}

function LogTab() {
  const { items, error } = useList<AdminAction>(fetchAdminActions, [])

  if (error) return <ErrorBox>{error}</ErrorBox>
  if (!items) return <Note>読み込み中…</Note>
  if (items.length === 0) return <Note>まだ記録がありません。</Note>

  return (
    <>
      <Note>
        運営の操作記録です。<b style={{ color: C.ink }}>後から書き換えられません</b>
        （読み取り専用のポリシーだけを置いています）。金銭トラブル・税務・弁護士対応で
        「誰の判断か」を説明するために使います。
      </Note>
      {items.map((a) => (
        <div
          key={a.id}
          style={{
            background: C.white,
            border: `1.5px solid ${C.border}`,
            borderRadius: 8,
            padding: '10px 12px',
            display: 'flex',
            flexDirection: 'column',
            gap: 3,
          }}
        >
          <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10 }}>
            <span style={{ fontSize: 11.5, color: C.ink }}>{KIND_LABEL[a.kind] ?? a.kind}</span>
            <span style={{ fontSize: 10, color: C.muted, flex: 'none' }}>{jst(a.at)}</span>
          </div>
          <span style={{ fontSize: 10, color: C.muted, lineHeight: 1.6, wordBreak: 'break-all' }}>
            {a.actorName}
            {a.note && ` / ${a.note}`}
          </span>
        </div>
      ))}
    </>
  )
}
