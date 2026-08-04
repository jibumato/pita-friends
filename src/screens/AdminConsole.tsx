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
  fetchAdminCashRefunds,
  resolveCashRefund,
  fetchAdminOffsetablePurchases,
  notifyChargebackOffset,
  fetchAdminChargebackOffsets,
  executeChargebackOffset,
  cancelChargebackOffset,
  fetchAdminRecentPurchases,
  fetchAdminFeeSchedules,
  scheduleFeeChange,
  type AdminFeeSchedule,
  type FeeTier,
  voidPurchase,
  type AdminPurchase,
  type AdminCashRefund,
  type AdminOffsetablePurchase,
  type AdminChargebackOffset,
  resolveDispute,
  type AdminDispute,
  fetchAccountingBalances,
  fetchAccountingRevenue,
  fetchAccountingJournal,
  fetchAccountingJournalCheck,
  fetchAccountingHostPayments,
  type AccountingBalanceRow,
  type AccountingRevenueRow,
  type AccountingJournalRow,
  type AccountingJournalCheckRow,
  type AccountingHostPaymentRow,
  fetchPlatformLimits,
  updatePlatformLimits,
  fetchBusinessKpis,
  fetchPaymentMethodMix,
  type BusinessKpis,
  type PaymentMethodMixRow,
  type PlatformLimits,
  type PlatformLimitKey,
} from '../lib/queries'

type Tab =
  | 'summary'
  | 'reports'
  | 'holds'
  | 'payouts'
  | 'requests'
  | 'disputes'
  | 'refunds'
  | 'offsets'
  | 'fees'
  | 'limits'
  | 'accounting'
  | 'kpi'
  | 'health'
  | 'log'

const TABS: { key: Tab; label: string }[] = [
  { key: 'summary', label: 'やること' },
  { key: 'holds', label: '保留' },
  { key: 'reports', label: '通報' },
  { key: 'payouts', label: '換金' },
  { key: 'requests', label: '請求' },
  { key: 'disputes', label: '異議申立て' },
  { key: 'refunds', label: '返金' },
  { key: 'offsets', label: '相殺' },
  { key: 'fees', label: '料率' },
  { key: 'limits', label: '制限値' },
  { key: 'accounting', label: '会計' },
  { key: 'kpi', label: '経営' },
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
        {tab === 'refunds' && <RefundsTab onChanged={loadSummary} />}
        {tab === 'offsets' && <OffsetsTab onChanged={loadSummary} />}
        {tab === 'fees' && <FeesTab />}
        {tab === 'limits' && <LimitsTab />}
        {tab === 'accounting' && <AccountingTab />}
        {tab === 'kpi' && <KpiTab />}
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

type PayoutIssue = { level: 'block' | 'warn'; text: string }

/**
 * 受取人名を**半角カナ**にする。
 *
 * 口座の登録フォームは**全角カタカナ**で受けている(`host_bank_accounts` の
 * check 制約が `^[ァ-ヶー0-9A-Z()（）./\- 　]+$`)。一方、総合振込の受取人名は
 * **半角カナ**が指定である。**この変換をどこかでやらないと銀行に通らない。**
 *
 * 以前は「銀行のアップロード画面の変換機能に任せる」と手順書に書いていたが、
 * 変換機能が無い銀行もあり、そのときにExcelで手作業になる。金額を扱う作業に
 * 手加工を挟まないという方針(bankTransferCsv のコメント)と食い違うので、
 * こちらで変換して出す。
 *
 * ⚠️ **濁点・半濁点は2文字になる**(ガ → ｶﾞ)。全銀の受取人名は半角30文字までなので、
 * 全角で15文字でも半角では30文字を超えうる。**長さは変換後で数える。**
 */
function toHankakuKana(s: string): string {
  const MAP: Record<string, string> = {
    ァ: 'ｧ', ア: 'ｱ', ィ: 'ｨ', イ: 'ｲ', ゥ: 'ｩ', ウ: 'ｳ', ェ: 'ｪ', エ: 'ｴ', ォ: 'ｫ', オ: 'ｵ',
    カ: 'ｶ', キ: 'ｷ', ク: 'ｸ', ケ: 'ｹ', コ: 'ｺ', サ: 'ｻ', シ: 'ｼ', ス: 'ｽ', セ: 'ｾ', ソ: 'ｿ',
    タ: 'ﾀ', チ: 'ﾁ', ツ: 'ﾂ', テ: 'ﾃ', ト: 'ﾄ', ナ: 'ﾅ', ニ: 'ﾆ', ヌ: 'ﾇ', ネ: 'ﾈ', ノ: 'ﾉ',
    ハ: 'ﾊ', ヒ: 'ﾋ', フ: 'ﾌ', ヘ: 'ﾍ', ホ: 'ﾎ', マ: 'ﾏ', ミ: 'ﾐ', ム: 'ﾑ', メ: 'ﾒ', モ: 'ﾓ',
    ャ: 'ｬ', ヤ: 'ﾔ', ュ: 'ｭ', ユ: 'ﾕ', ョ: 'ｮ', ヨ: 'ﾖ',
    ラ: 'ﾗ', リ: 'ﾘ', ル: 'ﾙ', レ: 'ﾚ', ロ: 'ﾛ', ワ: 'ﾜ', ヲ: 'ｦ', ン: 'ﾝ',
    ガ: 'ｶﾞ', ギ: 'ｷﾞ', グ: 'ｸﾞ', ゲ: 'ｹﾞ', ゴ: 'ｺﾞ',
    ザ: 'ｻﾞ', ジ: 'ｼﾞ', ズ: 'ｽﾞ', ゼ: 'ｾﾞ', ゾ: 'ｿﾞ',
    ダ: 'ﾀﾞ', ヂ: 'ﾁﾞ', ヅ: 'ﾂﾞ', デ: 'ﾃﾞ', ド: 'ﾄﾞ',
    バ: 'ﾊﾞ', ビ: 'ﾋﾞ', ブ: 'ﾌﾞ', ベ: 'ﾍﾞ', ボ: 'ﾎﾞ',
    パ: 'ﾊﾟ', ピ: 'ﾋﾟ', プ: 'ﾌﾟ', ペ: 'ﾍﾟ', ポ: 'ﾎﾟ',
    ヴ: 'ｳﾞ', ヵ: 'ｶ', ヶ: 'ｹ', ッ: 'ｯ',
    ー: '-', '　': ' ', '（': '(', '）': ')', '．': '.', '／': '/',
  }
  return [...s]
    .map((c) => MAP[c] ?? (c >= '０' && c <= '９' ? String.fromCharCode(c.charCodeAt(0) - 0xfee0) : c))
    .join('')
}

/**
 * 振込を実行する**前に**見つけたい問題。
 *
 * `block` は銀行アップロード用CSVから除外する。**黙って落とさない**こと——
 * 何件をなぜ外したかは画面に出す(下の PayoutsTab)。除外を黙ってやると
 * 「全員に振り込んだつもり」で締めてしまう。
 */
function payoutIssues(p: AdminPayout): PayoutIssue[] {
  const out: PayoutIssue[] = []
  if (!p.isVerified) {
    out.push({ level: 'block', text: '本人確認が未完了です。振り込まないでください。' })
  }
  // 全銀の受取人名は半角カナ最大30文字。アプリ側はカナ48文字まで通すので、
  // 長い名義は**銀行のアップロードで初めて弾かれる**。ここで先に気づく。
  const han = toHankakuKana(p.accountHolderKana).length
  if (han > 30) {
    out.push({
      level: 'block',
      // **半角に直した後の長さで数える。** 濁点は2文字になるので、
      // 全角で15文字の名義が半角で30文字を超えることがある
      text: `受取人名が半角${han}文字になります（全銀の上限は30文字）。このままでは銀行側で弾かれるので、名義の短縮を依頼してください。`,
    })
  }
  // ゆうちょ(9900)は通帳の記号・番号のままでは他行から振り込めない。
  // 変換後は店番3桁・口座番号7桁。7桁でなければ未変換を疑う。
  if (p.bankCode === '9900' && p.accountNumber.replace(/\D/g, '').length !== 7) {
    out.push({
      level: 'warn',
      text: 'ゆうちょ銀行ですが口座番号が7桁ではありません。通帳の記号・番号のままだと振込不能になります。変換後の値か本人に確認してください。',
    })
  }
  return out
}

const isBlocked = (p: AdminPayout) => payoutIssues(p).some((i) => i.level === 'block')

/**
 * 銀行の総合振込にそのまま載せる形のCSV。
 *
 * **確認用CSV(下の payoutsCsv)とは別物。** あちらは目視確認の一覧で、
 * 申請IDやニックネームまで入っている。銀行に渡すのは6列だけで、列順も
 * 預金種目の表し方(1=普通/2=当座)も銀行の指定に合わせる。
 *
 * 分けている理由は、**間にExcelの手作業を挟ませないため**。金額を扱う作業で
 * 列を並べ替えると、行がずれた瞬間に別人へ振り込む。
 *
 * ⚠️ 列順・ヘッダの有無・文字コードは銀行によって違う。GMOあおぞらネット銀行の
 * 管理画面のテンプレートと突き合わせること(`docs/payouts-bank-operations.md` §①)。
 */
function bankTransferCsv(rows: AdminPayout[]): string {
  const head = ['銀行コード', '支店コード', '預金種目', '口座番号', '受取人名', '振込金額']
  const esc = (v: string | number) => `"${String(v).replace(/"/g, '""')}"`
  const body = rows.map((r) =>
    [
      r.bankCode,
      r.branchCode,
      // account_type は DB 側で '普通' | '当座' に制約済み(0014_bank_payouts.sql:51)
      r.accountType === '当座' ? '2' : '1',
      r.accountNumber,
      // 口座は全角カタカナで登録されている。総合振込は半角カナ指定なので変換する
      toHankakuKana(r.accountHolderKana),
      r.amountYen,
    ]
      .map(esc)
      .join(','),
  )
  return '﻿' + [head.map(esc).join(','), ...body].join('\r\n')
}

/** 口座情報つきの確認用CSV。目視確認と控えのため。Excelで開けるようBOM付き。 */
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
      // 口座は全角カタカナで登録されている。総合振込は半角カナ指定なので変換する
      toHankakuKana(r.accountHolderKana),
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

  function save(csv: string, name: string) {
    const blob = new Blob([csv], { type: 'text/csv;charset=utf-8' })
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = name
    a.click()
    URL.revokeObjectURL(url)
  }

  const today = () => new Date().toISOString().slice(0, 10)

  /** 口座情報つきの確認用。**全件**出す(除外した分も控えとして残すため) */
  function download() {
    if (!items || items.length === 0) return
    save(payoutsCsv(items), `payouts-${today()}.csv`)
  }

  /** 銀行の総合振込にアップロードする用。**問題のある行は入れない** */
  function downloadBank(rows: AdminPayout[]) {
    if (rows.length === 0) return
    save(bankTransferCsv(rows), `payouts-bank-${today()}.csv`)
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
  // 銀行に渡してよい行と、先に解消が要る行を分ける
  const payable = items.filter((p) => !isBlocked(p))
  const blocked = items.filter(isBlocked)
  const payableTotal = payable.reduce((n, r) => n + r.amountYen, 0)

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
          <div style={{ display: 'grid', gap: 6 }}>
            <Btn disabled={payable.length === 0} onClick={() => downloadBank(payable)}>
              銀行アップロード用CSV（{payable.length}件 / {payableTotal.toLocaleString()}円）
            </Btn>
            <Btn onClick={download}>確認用CSV（口座情報つき・全{items.length}件）</Btn>
          </div>
          <Note>
            銀行アップロード用は<b style={{ color: C.ink }}>6列だけ</b>
            （銀行コード・支店コード・預金種目・口座番号・受取人名・振込金額）で、
            そのまま総合振込に載せられます。
            <b style={{ color: C.ink }}>Excelで並べ替えないでください</b>
            ——列をいじると行がずれて別人に振り込みます。
            <br />
            列順・ヘッダの有無・文字コードは銀行によって違うので、初回だけ
            管理画面のテンプレートと突き合わせてください（docs/payouts-bank-operations.md §①）。
          </Note>
          {blocked.length > 0 && (
            <ErrorBox>
              <b>{blocked.length}件を銀行アップロード用CSVから外しました。</b>
              理由は各カードの赤い注意書きです。外した分は「振込済みにする」を押さずに残し、
              解消してから次回に回してください（報酬コインは失効しません）。
            </ErrorBox>
          )}
          {items.map((p) => (
            <Card key={p.id} alert={isBlocked(p) || p.sharedCardCount > 0}>
              <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10 }}>
                <span style={{ fontSize: 12.5, color: C.ink }}>{p.nickname}</span>
                <span style={{ fontSize: 13, color: C.ink, flex: 'none', fontVariantNumeric: 'tabular-nums' }}>
                  {p.amountYen.toLocaleString()}円
                </span>
              </div>
              {/* 本人確認・受取人名の長さ・ゆうちょの未変換。
                  block は銀行アップロード用CSVから外れている(上のErrorBoxで件数を出す) */}
              {payoutIssues(p).map((issue, i) => (
                <span
                  key={i}
                  style={{
                    fontSize: 11,
                    lineHeight: 1.7,
                    color: issue.level === 'block' ? '#E5484D' : C.body,
                  }}
                >
                  ⚠️ {issue.text}
                </span>
              ))}
              {/* 0080・E-9。**資金が出る瞬間に目に入る**のがこの表示の値打ち。
                  遮断しないのは、家族カード・同一世帯で正当に一致しうるため */}
              {p.sharedCardCount > 0 && (
                <span style={{ fontSize: 11, color: '#E5484D', lineHeight: 1.7 }}>
                  ⚠️ 他の{p.sharedCardCount}アカウントと
                  <b>同じ決済カード</b>を使った履歴があります。
                  <br />
                  <span style={{ color: C.muted }}>
                    家族カードでも一致するので、これだけで不正とは判断しないでください。
                    自作自演（自分で買ったコインを別アカウントに送って換金）が疑われる場合は、
                    先に事情を確認してから振り込んでください。
                  </span>
                </span>
              )}
              {/* 0096。カード共有の判定ができない購入があることを、
                  **sharedCardCount が 0 のときこそ**知らせる。
                  「調べた結果シロ」と「調べようがなかった」は別の事実 */}
              {p.nonCardPurchaseCount > 0 && (
                <span style={{ fontSize: 11, color: C.body, lineHeight: 1.7 }}>
                  このピタメイトの購入のうち{p.nonCardPurchaseCount}件はPayPay等で、
                  <b style={{ color: C.ink }}>カードの共有では判定できません</b>。
                  上のカード共有の件数だけで安全とは言えない相手です。
                </span>
              )}
              {p.flaggedGiftCount > 0 && (
                <span style={{ fontSize: 11, color: C.body, lineHeight: 1.7 }}>
                  受け取ったギフトのうち{p.flaggedGiftCount}件に、IPまたはカードの共有で印が付いています。
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
// 返金(規約 第9条5の3・0085)
// ------------------------------------------------------------

function RefundsTab({ onChanged }: { onChanged: () => void }) {
  const { items, error, reload } = useList<AdminCashRefund>(fetchAdminCashRefunds, [])
  const [note, setNote] = useState<Record<string, string>>({})
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)

  async function run(id: string, status: 'paid' | 'rejected') {
    if (busy) return
    setBusy(true)
    setErr(null)
    try {
      await resolveCashRefund(id, status, note[id] ?? '')
      setNote((n) => ({ ...n, [id]: '' }))
      reload()
      onChanged()
    } catch (e) {
      const m = e instanceof Error ? e.message : ''
      setErr(m === 'NOTE_REQUIRED' ? '却下するときは理由が必須です' : m || '処理に失敗しました')
    } finally {
      setBusy(false)
    }
  }

  if (error) return <ErrorBox>{error}</ErrorBox>
  if (!items) return <Note>読み込み中…</Note>
  // **0件でも早期returnしない。** 購入の取消しはここからしか行えないので、
  // 返金が0件のときに導線ごと消えると運用できなくなる
  if (items.length === 0)
    return (
      <>
        <Note>未払いの返金はありません。</Note>
        <span style={{ fontSize: 11, color: C.muted, marginTop: 8 }}>購入の取消し</span>
        <VoidPurchaseSection onChanged={onChanged} />
      </>
    )

  return (
    <>
      <Note>
        <b style={{ color: C.ink }}>お客様に落ち度のないキャンセル</b>
        で、有効期限切れによりコインをお戻しできなかった分です（利用規約 第9条5の3）。
        <br />
        1コイン = 1円で、<b style={{ color: C.ink }}>お振込みは手作業</b>です。
        振り込んでから「支払済みにする」を押してください。
        <br />
        却下は理由が必須です（後から説明を求められる操作のため）。
      </Note>
      {err && <ErrorBox>{err}</ErrorBox>}
      {items.map((r) => (
        <Card key={r.id}>
          <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10 }}>
            <span style={{ fontSize: 12.5, color: C.ink }}>{r.nickname ?? '(名前なし)'}</span>
            <span style={{ fontSize: 13, fontWeight: 700, color: C.ink, flex: 'none' }}>
              ¥{r.amountYen.toLocaleString()}
            </span>
          </div>
          <span style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.7 }}>
            {r.coins.toLocaleString()}コインが失効 / 事由: {causeLabel(r.cause)} / {jst(r.createdAt)}
            <br />
            ユーザーID: {r.userId}
            {r.bookingId && (
              <>
                <br />
                予約: {r.bookingId}
              </>
            )}
          </span>
          <Field
            value={note[r.id] ?? ''}
            onChange={(v) => setNote((n) => ({ ...n, [r.id]: v }))}
            placeholder="メモ 例: 2026-08-05 ゆうちょ宛に振込 / 却下の場合は理由（必須）"
          />
          <div style={{ display: 'flex', gap: 8 }}>
            <Btn disabled={busy} onClick={() => void run(r.id, 'paid')}>
              支払済みにする
            </Btn>
            <Btn disabled={busy} onClick={() => void run(r.id, 'rejected')}>
              却下する
            </Btn>
          </div>
        </Card>
      ))}
      <span style={{ fontSize: 11, color: C.muted, marginTop: 8 }}>購入の取消し</span>
      <VoidPurchaseSection onChanged={onChanged} />
    </>
  )
}

/**
 * 購入の取消し(規約 第7条の3第5項・税理士 第2回回答 Q14(c))。
 *
 * 未成年者取消しの申出や誤課金など、**当社が自ら購入を取り消す**場面。
 * チャージバックはカード会社が決済ごと戻すので、ここには出しません
 * （出すと二重返金になります）。
 */
function VoidPurchaseSection({ onChanged }: { onChanged: () => void }) {
  const { items, error, reload } = useList<AdminPurchase>(
    () => fetchAdminRecentPurchases(20),
    [],
  )
  const [reason, setReason] = useState<Record<string, string>>({})
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [msg, setMsg] = useState<string | null>(null)

  async function run(id: string) {
    if (busy) return
    setBusy(true)
    setErr(null)
    setMsg(null)
    try {
      const r = await voidPurchase(id, reason[id] ?? '')
      setReason((x) => ({ ...x, [id]: '' }))
      setMsg(
        `取り消しました。未使用${r.voidedCoins.toLocaleString()}コインを消し、` +
          `¥${r.refundYen.toLocaleString()}（うちサポート料 ¥${r.feeYen.toLocaleString()}）を返金債務に立てました`,
      )
      reload()
      onChanged()
    } catch (e) {
      const raw = e instanceof Error ? e.message : ''
      setErr(
        {
          REASON_REQUIRED: '取消しの理由は必須です',
          ALREADY_VOIDED: 'すでに取り消されています',
          HAS_DISPUTE:
            'この購入は異議申立て（チャージバック）があります。カード会社が決済ごと戻すため、ここで取り消すと二重返金になります',
        }[raw] ?? raw ?? '取消しに失敗しました',
      )
    } finally {
      setBusy(false)
    }
  }

  if (error) return <ErrorBox>{error}</ErrorBox>
  if (!items) return <Note>読み込み中…</Note>

  const targets = items.filter((p) => !p.voidedAt)
  if (targets.length === 0) return <Note>取り消せる購入はありません。</Note>

  return (
    <>
      <Note>
        <b style={{ color: C.ink }}>未成年者取消しの申出・誤課金</b>
        など、当社から購入を取り消す場合はここから行います。
        <br />
        取り消すと、<b style={{ color: C.ink }}>未使用コインが消え</b>、
        <b style={{ color: C.ink }}>コイン代金とあんしんサポート料の両方</b>
        が上の返金一覧に入ります（利用規約 第7条の3第5項）。
        <br />
        ⚠️ チャージバックがある購入は<b style={{ color: C.ink }}>二重返金</b>
        になるため取り消せません。
      </Note>
      {err && <ErrorBox>{err}</ErrorBox>}
      {msg && <Note>{msg}</Note>}
      {targets.map((p) => (
        <Card key={p.purchaseId} alert={p.hasDispute}>
          <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10 }}>
            <span style={{ fontSize: 12.5, color: C.ink }}>{p.nickname ?? '(名前なし)'}</span>
            <span style={{ fontSize: 12, color: C.muted, flex: 'none' }}>
              ¥{(p.priceYen + p.safetyFeeYen).toLocaleString()}
            </span>
          </div>
          <span style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.7 }}>
            {p.coins.toLocaleString()}コイン（未使用 {p.unusedCoins.toLocaleString()}） /{' '}
            コイン代金 ¥{p.priceYen.toLocaleString()} / サポート料 ¥
            {p.safetyFeeYen.toLocaleString()}
            <br />
            {jst(p.createdAt)}
            {p.hasDispute && (
              <>
                <br />
                <b style={{ color: '#E5484D' }}>異議申立てあり（取り消せません）</b>
              </>
            )}
          </span>
          {!p.hasDispute && (
            <>
              <Field
                value={reason[p.purchaseId] ?? ''}
                onChange={(v) => setReason((x) => ({ ...x, [p.purchaseId]: v }))}
                placeholder="取消しの理由（必須）例: 未成年者取消しの申出を受領"
              />
              <Btn disabled={busy} onClick={() => void run(p.purchaseId)}>
                この購入を取り消す
              </Btn>
            </>
          )}
        </Card>
      ))}
    </>
  )
}

function causeLabel(cause: string): string {
  return (
    {
      host_fault: 'ピタメイト都合',
      host_no_show: '無断欠席',
      support: '申出対応',
      system: 'システム障害',
    }[cause] ?? cause
  )
}

// ------------------------------------------------------------
// 相殺(規約 第8条の6・0088)
// ------------------------------------------------------------

function OffsetsTab({ onChanged }: { onChanged: () => void }) {
  const purchases = useList<AdminOffsetablePurchase>(fetchAdminOffsetablePurchases, [])
  const offsets = useList<AdminChargebackOffset>(fetchAdminChargebackOffsets, [])
  const [note, setNote] = useState<Record<string, string>>({})
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [msg, setMsg] = useState<string | null>(null)

  function reloadAll() {
    purchases.reload()
    offsets.reload()
    onChanged()
  }

  async function act(fn: () => Promise<string | null>) {
    if (busy) return
    setBusy(true)
    setErr(null)
    setMsg(null)
    try {
      const m = await fn()
      if (m) setMsg(m)
      reloadAll()
    } catch (e) {
      const raw = e instanceof Error ? e.message : ''
      setErr(
        {
          PURCHASE_NOT_LOST: 'この購入は異議が成立していません（当社が損失を負担していない取引は対象外です）',
          OBJECTION_PERIOD_OPEN: '異議を述べる期間がまだ終わっていません',
          NOTE_REQUIRED_AFTER_OBJECTION: '異議が出ています。判断の理由を書いてください',
          NOTE_REQUIRED: '理由は必須です',
          NOT_PENDING: 'すでに処理済みです',
        }[raw] ?? raw ?? '処理に失敗しました',
      )
    } finally {
      setBusy(false)
    }
  }

  if (purchases.error) return <ErrorBox>{purchases.error}</ErrorBox>

  return (
    <>
      <Note>
        カード決済の<b style={{ color: C.ink }}>異議申立てが成立した（lost）</b>
        購入について、その決済で支払われた分をピタメイトの
        <b style={{ color: C.ink }}>未払の報酬コインから控除</b>できます（利用規約 第8条の6）。
        <br />
        手順は3段です。<b style={{ color: C.ink }}>①予告 → ②異議の機会（7日） → ③実行</b>。
        予告の時点では1コインも引きません。
        <br />
        ⚠️ 引けるのは<b style={{ color: C.ink }}>未払の分だけ</b>です。振込済みの金銭は請求しません。
      </Note>
      {err && <ErrorBox>{err}</ErrorBox>}
      {msg && <Note>{msg}</Note>}

      <span style={{ fontSize: 11, color: C.muted, marginTop: 4 }}>① 予告する</span>
      {!purchases.items ? (
        <Note>読み込み中…</Note>
      ) : purchases.items.length === 0 ? (
        <Note>異議が成立した購入はありません。</Note>
      ) : (
        purchases.items.map((p) => (
          <Card key={p.purchaseId}>
            <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10 }}>
              <span style={{ fontSize: 12.5, color: C.ink }}>{p.nickname ?? '(名前なし)'}</span>
              <span style={{ fontSize: 12, color: C.muted, flex: 'none' }}>
                ¥{p.priceYen.toLocaleString()}
              </span>
            </div>
            <span style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.7 }}>
              異議の成立: {jst(p.disputedAt)}
              <br />
              控除できる取引: {p.candidateCount}件 / 合計{p.candidateCoins.toLocaleString()}コイン
              {p.notifiedCount > 0 && <> ／ 予告済み {p.notifiedCount}件</>}
            </span>
            <Btn
              disabled={busy || p.candidateCount === 0 || p.candidateCount === p.notifiedCount}
              onClick={() =>
                void act(async () => {
                  const n = await notifyChargebackOffset(p.purchaseId)
                  return `${n}件に控除を予告しました（実行は7日後から）`
                })
              }
            >
              {p.candidateCount === 0
                ? '控除できる取引がありません'
                : p.candidateCount === p.notifiedCount
                  ? '予告済み'
                  : '控除を予告する'}
            </Btn>
          </Card>
        ))
      )}

      <span style={{ fontSize: 11, color: C.muted, marginTop: 8 }}>②③ 予告した控除</span>
      {!offsets.items ? (
        <Note>読み込み中…</Note>
      ) : offsets.items.length === 0 ? (
        <Note>予告した控除はありません。</Note>
      ) : (
        offsets.items.map((o) => {
          const open = new Date(o.objectionDeadline).getTime() > Date.now()
          return (
            <Card key={o.id} alert={o.objectedAt != null && o.status === 'notified'}>
              <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10 }}>
                <span style={{ fontSize: 12.5, color: C.ink }}>{o.nickname ?? '(名前なし)'}</span>
                <span style={{ fontSize: 11, color: C.muted, flex: 'none' }}>
                  {o.status === 'executed' ? '控除済み' : open ? '異議期間中' : '実行できます'}
                </span>
              </div>
              <span style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.7 }}>
                対象 {o.coins.toLocaleString()}コイン / 未払の報酬{' '}
                {o.unpaidEarned.toLocaleString()}コイン
                {o.status === 'executed' && (
                  <> ／ 実際に控除 {(o.executedCoins ?? 0).toLocaleString()}コイン</>
                )}
                <br />
                予告 {jst(o.notifiedAt)} / 異議の期限 {jst(o.objectionDeadline)}
                {o.objectedAt && (
                  <>
                    <br />
                    <b style={{ color: '#E5484D' }}>
                      異議あり（{jst(o.objectedAt)}）: {o.objectionNote}
                    </b>
                  </>
                )}
              </span>
              {o.status === 'notified' && (
                <>
                  <Field
                    value={note[o.id] ?? ''}
                    onChange={(v) => setNote((n) => ({ ...n, [o.id]: v }))}
                    placeholder="判断の理由（異議が出ている場合は必須）"
                  />
                  <div style={{ display: 'flex', gap: 8 }}>
                    <Btn
                      disabled={busy || open}
                      onClick={() =>
                        void act(async () => {
                          const n = await executeChargebackOffset(o.id, note[o.id] ?? '')
                          setNote((x) => ({ ...x, [o.id]: '' }))
                          return `${n}コインを控除しました`
                        })
                      }
                    >
                      控除を実行する
                    </Btn>
                    <Btn
                      disabled={busy}
                      onClick={() =>
                        void act(async () => {
                          await cancelChargebackOffset(o.id, note[o.id] ?? '')
                          setNote((x) => ({ ...x, [o.id]: '' }))
                          return '控除を取りやめました'
                        })
                      }
                    >
                      取りやめる
                    </Btn>
                  </div>
                </>
              )}
            </Card>
          )
        })
      )}
    </>
  )
}


// ------------------------------------------------------------
// 料率(規約 第8条の2)
// ------------------------------------------------------------

/**
 * 料率の変更は**30日以上先の日付でしか予約できません**（第4項）。
 * 変更前に成立した予約・ギフトには旧料率が適用されます（第5項）ので、
 * 「いつからの率か」を持たせた予定表として扱います。
 */
function FeesTab() {
  const { items, error, reload } = useList<AdminFeeSchedule>(fetchAdminFeeSchedules, [])
  const [date, setDate] = useState('')
  const [reason, setReason] = useState('')
  const [tiersText, setTiersText] = useState('')
  const [giftText, setGiftText] = useState('')
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [msg, setMsg] = useState<string | null>(null)

  const current = items?.find((s) => s.isCurrent)

  function tiersLabel(t: FeeTier[]): string {
    return t
      .map((x) => `${x.upperBound ? `〜${x.upperBound.toLocaleString()}` : 'それ以上'}: ${x.percent}%`)
      .join(' / ')
  }

  async function run() {
    if (busy) return
    setBusy(true)
    setErr(null)
    setMsg(null)
    try {
      // 「〜30000:25, それ以上:20」のような入力を素直に受ける。
      // **段の数は変えられるべき**なので、固定のフォームにしない
      const tiers: FeeTier[] = tiersText
        .split(',')
        .map((s) => s.trim())
        .filter(Boolean)
        .map((s) => {
          const [bound, pct] = s.split(':').map((x) => x.trim())
          return {
            upperBound: /^\d+$/.test(bound) ? Number(bound) : null,
            percent: Number(pct),
          }
        })
      if (tiers.length === 0 || tiers.some((t) => !Number.isFinite(t.percent))) {
        throw new Error('段の書き方が違います。例: 30000:25, -:20')
      }
      const r = await scheduleFeeChange(
        new Date(date).toISOString(),
        reason,
        tiers,
        Number(giftText),
      )
      setMsg(
        `${new Date(r.effectiveFrom).toLocaleDateString('ja-JP')}からの変更を予約し、` +
          `${r.notifiedHosts}名のピタメイトへ個別に通知しました`,
      )
      setDate('')
      setReason('')
      setTiersText('')
      setGiftText('')
      reload()
    } catch (e) {
      const raw = e instanceof Error ? e.message : ''
      setErr(
        {
          NOTICE_PERIOD_TOO_SHORT: '変更は30日以上先の日付でしか予約できません（規約 第8条の2第4項）',
          REASON_REQUIRED: '変更の理由は必須です（第4項が「理由を明らかにして」と定めています）',
          BOOKING_RATE_OVER_CAP: '予約の率は30%を超えられません（第3の2項）',
          GIFT_RATE_OVER_CAP: 'ギフトの率は40%を超えられません（第3の2項）',
          ALREADY_SCHEDULED: 'その施行日はすでに登録されています',
          TIERS_REQUIRED: '段を1つ以上入れてください',
        }[raw] ?? raw ?? '登録に失敗しました',
      )
    } finally {
      setBusy(false)
    }
  }

  if (error) return <ErrorBox>{error}</ErrorBox>
  if (!items) return <Note>読み込み中…</Note>

  return (
    <>
      <Note>
        料率の変更は<b style={{ color: C.ink }}>30日以上先の日付でしか予約できません</b>
        （利用規約 第8条の2第4項）。登録すると、
        <b style={{ color: C.ink }}>ピタメイト全員へ個別に通知</b>が飛びます。
        <br />
        <b style={{ color: C.ink }}>変更前に成立した予約・ギフトには旧料率がそのまま適用されます</b>
        （第5項）。過去の組は消さないでください。
        <br />
        上限は予約30% / ギフト40%（第3の2項）。これはDBの制約でも止まります。
      </Note>
      {err && <ErrorBox>{err}</ErrorBox>}
      {msg && <Note>{msg}</Note>}

      <span style={{ fontSize: 11, color: C.muted, marginTop: 4 }}>変更を予約する</span>
      <Card>
        <span style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.7 }}>
          施行日（30日以上先）。例: 2026-10-01
        </span>
        <Field value={date} onChange={setDate} placeholder="2026-10-01" />
        <span style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.7 }}>
          予約の段（カンマ区切り。「上限:率」。上限なしは -）
          <br />
          例: 30000:20, 100000:17, 300000:14, -:12
          {current && <> ／ 現在: {tiersLabel(current.bookingTiers)}</>}
        </span>
        <Field
          value={tiersText}
          onChange={setTiersText}
          placeholder="30000:20, 100000:17, 300000:14, -:12"
        />
        <span style={{ fontSize: 10.5, color: C.muted }}>
          ギフトの率（%）{current?.giftPercent != null && <> ／ 現在: {current.giftPercent}%</>}
        </span>
        <Field value={giftText} onChange={setGiftText} placeholder="35" />
        <span style={{ fontSize: 10.5, color: C.muted }}>変更の理由（必須・通知にそのまま載ります）</span>
        <Field value={reason} onChange={setReason} placeholder="例: 決済手数料の上昇のため" />
        <Btn disabled={busy} onClick={() => void run()}>
          この内容で予約し、全ピタメイトへ通知する
        </Btn>
      </Card>

      <span style={{ fontSize: 11, color: C.muted, marginTop: 8 }}>料率の予定表</span>
      {items.map((s) => (
        <Card key={s.effectiveFrom} alert={s.isFuture}>
          <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10 }}>
            <span style={{ fontSize: 12.5, color: C.ink }}>
              {new Date(s.effectiveFrom).getFullYear() <= 2000
                ? '当初'
                : new Date(s.effectiveFrom).toLocaleDateString('ja-JP')}
              から
            </span>
            <span style={{ fontSize: 11, color: C.muted, flex: 'none' }}>
              {s.isCurrent ? '現行' : s.isFuture ? '予告中' : '過去'}
            </span>
          </div>
          <span style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.7 }}>
            予約: {tiersLabel(s.bookingTiers)}
            <br />
            ギフト: {s.giftPercent ?? '—'}%
            {s.reason && (
              <>
                <br />
                理由: {s.reason}
                {s.notifiedHosts != null && <> ／ {s.notifiedHosts}名へ通知済み</>}
              </>
            )}
          </span>
        </Card>
      ))}
    </>
  )
}

// ------------------------------------------------------------
// 制限値（0101）
//
// **条文は幅でしか書いていない**（「一定期間」「最長30日」「具体的な数値は
// 変更することがあります」）。だから数値はここから動かせる。
// 天井はサーバの CHECK 制約が持っていて `caps` として降ってくるので、
// **この画面に天井の数字を書かないこと。**
// ------------------------------------------------------------

type LimitRow = {
  key: PlatformLimitKey
  label: string
  unit: string
  capKey?: string
  hint?: string
}

const NEW_USER_ROWS: LimitRow[] = [
  { key: 'newUserDays', label: '新規とみなす期間', unit: '日' },
  { key: 'newUserPurchaseMaxYen', label: '1回あたりの購入上限', unit: '円' },
  { key: 'newUserPeriodPurchaseMaxYen', label: '期間中の購入上限', unit: '円' },
  {
    key: 'newUserPayoutHoldDays',
    label: '換金の保留',
    unit: '日',
    capKey: 'newUserPayoutHoldDays',
    hint: '規約が「最長30日間」と画しているため、31日以上は入りません',
  },
]

const GIFT_ROWS: LimitRow[] = [
  { key: 'giftMaxPerTx', label: '1回あたり', unit: 'コイン', capKey: 'giftMaxPerTx' },
  { key: 'giftMaxPerDay', label: '送り主・24時間', unit: 'コイン', capKey: 'giftMaxPerDay' },
  { key: 'giftMaxPerMonth', label: '送り主・30日', unit: 'コイン', capKey: 'giftMaxPerMonth' },
  { key: 'giftMaxRecvMonth', label: '受け取る側・30日', unit: 'コイン', capKey: 'giftMaxRecvMonth' },
  { key: 'giftMaxPairMonth', label: '同じ相手へ・30日', unit: 'コイン', capKey: 'giftMaxPairMonth' },
  {
    key: 'giftWindowDays',
    label: 'プレイ完了から贈れる期間',
    unit: '日',
    capKey: 'giftWindowDays',
    hint: '短いほど「完了した役務への謝礼」という性格が強まります',
  },
]

function LimitsTab() {
  const [limits, setLimits] = useState<PlatformLimits | null>(null)
  const [draft, setDraft] = useState<Record<string, string>>({})
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [msg, setMsg] = useState<string | null>(null)

  const load = useCallback(() => {
    if (!isBackendConfigured) return
    fetchPlatformLimits()
      .then((l) => {
        setLimits(l)
        setDraft({
          newUserDays: String(l.newUser.days),
          newUserPurchaseMaxYen: String(l.newUser.purchaseMaxYen),
          newUserPeriodPurchaseMaxYen: String(l.newUser.periodPurchaseMaxYen),
          newUserPayoutHoldDays: String(l.newUser.payoutHoldDays),
          giftMaxPerTx: String(l.gift.maxPerTx),
          giftMaxPerDay: String(l.gift.maxPerDay),
          giftMaxPerMonth: String(l.gift.maxPerMonth),
          giftMaxRecvMonth: String(l.gift.maxRecvMonth),
          giftMaxPairMonth: String(l.gift.maxPairMonth),
          giftWindowDays: String(l.gift.windowDays),
        })
      })
      .catch((e) => setErr(e instanceof Error ? e.message : '読み込めませんでした'))
  }, [])

  useEffect(load, [load])

  /** いま値が変わっている項目だけ。**変えていないキーは送らない。** */
  const changed: Partial<Record<PlatformLimitKey, number>> = {}
  if (limits) {
    const now: Record<string, number> = {
      newUserDays: limits.newUser.days,
      newUserPurchaseMaxYen: limits.newUser.purchaseMaxYen,
      newUserPeriodPurchaseMaxYen: limits.newUser.periodPurchaseMaxYen,
      newUserPayoutHoldDays: limits.newUser.payoutHoldDays,
      giftMaxPerTx: limits.gift.maxPerTx,
      giftMaxPerDay: limits.gift.maxPerDay,
      giftMaxPerMonth: limits.gift.maxPerMonth,
      giftMaxRecvMonth: limits.gift.maxRecvMonth,
      giftMaxPairMonth: limits.gift.maxPairMonth,
      giftWindowDays: limits.gift.windowDays,
    }
    for (const [k, v] of Object.entries(draft)) {
      const n = Number(v)
      if (v.trim() !== '' && Number.isInteger(n) && n !== now[k]) {
        changed[k as PlatformLimitKey] = n
      }
    }
  }
  const changedKeys = Object.keys(changed)

  async function run() {
    if (busy) return
    setBusy(true)
    setErr(null)
    setMsg(null)
    try {
      const r = await updatePlatformLimits(reason, changed)
      setMsg(`変更しました: ${r.changed}`)
      setReason('')
      load()
    } catch (e) {
      const raw = e instanceof Error ? e.message : ''
      // 天井はDBの CHECK 制約が持っている。**画面で先回りして判定しない**
      // （制約を直したときに画面だけ古い天井で止め続ける）
      setErr(
        raw.includes('platform_pricing_gift_limits_check') ||
          raw.includes('platform_pricing_new_user_limits_check')
          ? '入れられる範囲を超えています。各項目の「上限」と、' +
              '1回 ≦ 24時間 ≦ 30日 / 同じ相手 ≦ 受け取る側 の順序を確認してください'
          : {
              REASON_REQUIRED: '変更の理由は必須です（あとから説明できる記録がこれしかありません）',
              NO_CHANGES: '変わっている項目がありません',
              NOT_ADMIN: '権限がありません',
            }[raw] ?? raw ?? '変更できませんでした',
      )
    } finally {
      setBusy(false)
    }
  }

  function rows(list: LimitRow[]) {
    return list.map((r) => (
      <Card key={r.key} alert={changed[r.key] != null}>
        <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10 }}>
          <span style={{ fontSize: 12.5, color: C.ink }}>{r.label}</span>
          <span style={{ fontSize: 11, color: C.muted, flex: 'none' }}>
            {r.capKey && limits?.caps[r.capKey] != null
              ? `上限 ${limits.caps[r.capKey].toLocaleString()}${r.unit}`
              : `単位: ${r.unit}`}
          </span>
        </div>
        <Field
          value={draft[r.key] ?? ''}
          onChange={(v) => setDraft((d) => ({ ...d, [r.key]: v }))}
          placeholder={r.unit}
        />
        {r.hint && <Note>{r.hint}</Note>}
      </Card>
    ))
  }

  if (err && !limits) return <ErrorBox>{err}</ErrorBox>
  if (!limits) return <Note>読み込み中…</Note>

  return (
    <>
      <Note>
        ここの数値は<b style={{ color: C.ink }}>規約に書かれていません</b>。
        規約は「一定期間」「最長30日」という幅だけを定めていて（第7条の2・第8条の6第5項）、
        <b style={{ color: C.ink }}>具体的な数値は運営が変更できる</b>という建て付けです。
        だから変更に告知期間は要りません。
        <br />
        代わりに<b style={{ color: C.ink }}>理由が必須</b>で、
        前後の値とあわせて操作記録に残ります。
        あとから「理由なく上限を下げた」と言われたときの反証材料はこれだけです。
        <br />
        各項目の<b style={{ color: C.ink }}>上限（天井）はDBの制約が持っています</b>。
        ギフトの天井は、ギフトを「プレイへの謝礼」の範囲に留めるための線です
        （為替取引に当たらないという整理の一部）。
        <b style={{ color: C.ink }}>天井そのものを上げるのは弁護士に相談してから。</b>
      </Note>
      {err && <ErrorBox>{err}</ErrorBox>}
      {msg && <Note>{msg}</Note>}

      <span style={{ fontSize: 11, color: C.muted, marginTop: 4 }}>
        新規ユーザーの制限（規約 第8条の6第5項・不正利用の防止）
      </span>
      {rows(NEW_USER_ROWS)}

      <span style={{ fontSize: 11, color: C.muted, marginTop: 8 }}>
        ありがとうギフトの上限（規約 第7条の2）
      </span>
      {rows(GIFT_ROWS)}
      <Note>
        ギフトの「相手はプレイした人に限る」「贈り合いの禁止」「原資は購入コインのみ」
        「チャージから24時間は贈れない」「受け取りから7日は換金できない」は
        <b style={{ color: C.ink }}>数値ではないのでここにありません</b>。
        これらは変えられません。
      </Note>

      <span style={{ fontSize: 11, color: C.muted, marginTop: 8 }}>変更する</span>
      <Card alert={changedKeys.length > 0}>
        <Note>
          {changedKeys.length === 0
            ? '変更した項目はありません'
            : `${changedKeys.length}項目を変更します`}
        </Note>
        <span style={{ fontSize: 10.5, color: C.muted }}>変更の理由（必須・操作記録に残ります）</span>
        <Field value={reason} onChange={setReason} placeholder="例: 開業から3か月の実績を見て緩和" />
        <Btn disabled={busy || changedKeys.length === 0} onClick={() => void run()}>
          この内容で変更する
        </Btn>
      </Card>
      {limits.updatedAt && (
        <Note>最終更新: {new Date(limits.updatedAt).toLocaleString('ja-JP')}</Note>
      )}
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

// ------------------------------------------------------------
// 会計(0079)
//
// **月次の締めを、この画面だけで終わらせる**ためのタブ。
// これまで会計の数字は Supabase の SQL Editor でしか見られなかった。
// 月に一度しかやらない作業を、毎回SQLを手打ちで始めるのは続かない。
//
// ここで出るのは「アプリの中で起きた取引」だけ。
// **Stripeの着金と決済手数料、経費、家事按分はここには出ない**
// (DBに無いものは出せない)。手順は docs/accounting-monthly-close.md。
// ------------------------------------------------------------

/** 会計ソフトが読めるCSVにして落とす。Excelで開けるようにBOM付き・CRLF。 */
function downloadCsv(filename: string, header: string[], rows: (string | number)[][]) {
  const esc = (v: string | number) => {
    const s = String(v ?? '')
    return /[",\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s
  }
  const body = [header, ...rows].map((r) => r.map(esc).join(',')).join('\r\n')
  const blob = new Blob(['﻿' + body], { type: 'text/csv;charset=utf-8' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  a.click()
  URL.revokeObjectURL(url)
}

const yen = (n: number) => n.toLocaleString('ja-JP')

/** 前月の初日・末日。締めは前月分をやるので、これを初期値にする。 */
function lastMonthRange(): { from: string; to: string } {
  const now = new Date()
  const first = new Date(now.getFullYear(), now.getMonth() - 1, 1)
  const last = new Date(now.getFullYear(), now.getMonth(), 0)
  const fmt = (d: Date) =>
    `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
  return { from: fmt(first), to: fmt(last) }
}

function AccountingTab() {
  const init = lastMonthRange()
  const [from, setFrom] = useState(init.from)
  const [to, setTo] = useState(init.to)
  /** 実際に問い合わせた期間。入力のたびに叩かないよう「表示」ボタンで確定する */
  const [range, setRange] = useState(init)
  /**
   * 純額処理を採るか。**税理士の推奨は純額**(第4回回答)。
   * 両建てのままだと、現金を受け取っていない無償コイン起因の利用料まで
   * 課税売上高に乗り、1,000万円の判定が実態より早く来る。
   */
  const [netting, setNetting] = useState(true)

  const balances = useList<AccountingBalanceRow>(fetchAccountingBalances, [])
  const revenue = useList<AccountingRevenueRow>(
    () => fetchAccountingRevenue(range.from, range.to),
    [range.from, range.to],
  )
  const journal = useList<AccountingJournalRow>(
    () => fetchAccountingJournal(range.from, range.to),
    [range.from, range.to],
  )
  // 自己検証は**開業日から当日まで**の累計で見る。月だけを渡すと必ず食い違う
  const check = useList<AccountingJournalCheckRow>(
    () => fetchAccountingJournalCheck('2026-08-01', todayIso()),
    [],
  )
  const payments = useList<AccountingHostPaymentRow>(
    () => fetchAccountingHostPayments(new Date(range.to).getFullYear()),
    [range.to],
  )

  const err =
    balances.error ?? revenue.error ?? journal.error ?? check.error ?? payments.error ?? null
  const ng = (check.items ?? []).filter((c) => c.判定 !== 'OK')
  const rows = (journal.items ?? []).filter((j) => netting || j.区分 !== '純額調整')

  return (
    <>
      <Note>
        アプリの中で起きた取引だけが出ます。
        <b style={{ color: C.ink }}>
          Stripeの着金と決済手数料、経費、家事按分はここには出ません
        </b>
        （Stripeの明細と領収書から別に起票します）。手順は
        docs/accounting-monthly-close.md にあります。
      </Note>
      {err && <ErrorBox>{err}</ErrorBox>}

      {/* 期間 */}
      <Card>
        <b style={{ fontSize: 12.5, color: C.ink }}>期間</b>
        <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
          <DateField value={from} onChange={setFrom} />
          <span style={{ fontSize: 12, color: C.body }}>〜</span>
          <DateField value={to} onChange={setTo} />
        </div>
        <Btn onClick={() => setRange({ from, to })}>この期間で表示</Btn>
        <Note>初期値は前月です（締めは前月分を扱うため）。</Note>
      </Card>

      {/* 自己検証。**合わないことに気づけない自動化は、手作業より危ない** */}
      <Card alert={ng.length > 0}>
        <b style={{ fontSize: 12.5, color: C.ink }}>仕訳と元帳の突合（開業日からの累計）</b>
        {!check.items && <Note>読み込み中…</Note>}
        {(check.items ?? []).map((c) => (
          <Row
            key={c.項目}
            left={c.項目}
            right={`${c.判定}${c.差額円 === 0 ? '' : ` / 差 ${yen(c.差額円)}円`}`}
            alert={c.判定 !== 'OK'}
          />
        ))}
        {ng.length > 0 && (
          <Note>
            ⚠️ 差額が出ています。<b style={{ color: C.ink }}>この状態のCSVは取り込まないでください。</b>
            仕訳の生成漏れか、関数を経由しない残高の書き換えが疑われます。
          </Note>
        )}
      </Card>

      {/* 残高 */}
      <Card>
        <b style={{ fontSize: 12.5, color: C.ink }}>残高（今日時点）</b>
        {!balances.items && <Note>読み込み中…</Note>}
        {(balances.items ?? []).map((b) => (
          <Row
            key={b.勘定科目}
            left={`${b.区分}・${b.勘定科目}`}
            right={`${yen(b.金額円)}円`}
            alert={b.区分 === '要確認' && b.金額円 > 0}
          />
        ))}
        <Btn
          onClick={() =>
            downloadCsv(
              `残高_${todayIso()}.csv`,
              ['区分', '勘定科目', '金額円', '備考'],
              (balances.items ?? []).map((b) => [b.区分, b.勘定科目, b.金額円, b.備考]),
            )
          }
          disabled={!balances.items?.length}
        >
          CSVで保存
        </Btn>
      </Card>

      {/* 損益 */}
      <Card>
        <b style={{ fontSize: 12.5, color: C.ink }}>売上・雑収入（{range.from}〜{range.to}）</b>
        {!revenue.items && <Note>読み込み中…</Note>}
        {(revenue.items ?? []).map((r) => (
          <Row key={`${r.区分}/${r.科目}`} left={`${r.区分}・${r.科目}`} right={`${yen(r.金額円)}円`} />
        ))}
        <Btn
          onClick={() =>
            downloadCsv(
              `売上_${range.from}_${range.to}.csv`,
              ['区分', '科目', '金額円', '消費税'],
              (revenue.items ?? []).map((r) => [r.区分, r.科目, r.金額円, r.消費税]),
            )
          }
          disabled={!revenue.items?.length}
        >
          CSVで保存
        </Btn>
      </Card>

      {/* 仕訳 */}
      <Card>
        <b style={{ fontSize: 12.5, color: C.ink }}>
          仕訳（{rows.length}行）
        </b>
        <Note>
          1行が「借方1・貸方1・金額1」になっています。会計ソフトの
          <b style={{ color: C.ink }}>汎用仕訳インポート</b>で取り込めます。
          金額は1コイン＝1円です。
        </Note>
        <label
          style={{
            display: 'flex',
            gap: 8,
            alignItems: 'flex-start',
            fontSize: 11.5,
            color: C.body,
            lineHeight: 1.6,
            cursor: 'pointer',
          }}
        >
          <input
            type="checkbox"
            checked={netting}
            onChange={(e) => setNetting(e.target.checked)}
            style={{ marginTop: 3, flex: 'none' }}
          />
          <span>
            純額処理で出力する（区分「純額調整」を含める）
            <br />
            <span style={{ color: C.muted }}>
              無償コインで成立した予約の利用料を売上から落とします。
              両建てのままだと、現金を受け取っていない分まで課税売上高に乗り、
              <b style={{ color: C.ink }}>1,000万円の判定が実態より早く来ます</b>
              （税理士の第4回回答）。
            </span>
          </span>
        </label>
        <Btn
          onClick={() =>
            downloadCsv(
              `仕訳_${range.from}_${range.to}${netting ? '_純額' : '_両建て'}.csv`,
              [
                '日付',
                '借方勘定科目',
                '借方補助科目',
                '借方金額',
                '借方税区分',
                '貸方勘定科目',
                '貸方補助科目',
                '貸方金額',
                '貸方税区分',
                '摘要',
              ],
              rows.map((j) => [
                j.日付,
                j.借方科目,
                j.借方補助,
                j.金額円,
                // 税区分は収益側に付く。借方が売上でない限り対象外
                j.借方科目 === '売上高' ? j.税区分 : '対象外',
                j.貸方科目,
                j.貸方補助,
                j.金額円,
                j.貸方科目 === '売上高' ? j.税区分 : '対象外',
                j.摘要,
              ]),
            )
          }
          disabled={rows.length === 0 || ng.length > 0}
        >
          {ng.length > 0 ? '突合が合うまで出力できません' : '仕訳CSVで保存'}
        </Btn>
      </Card>

      {/* ピタメイト別の年間支払額 */}
      <Card>
        <b style={{ fontSize: 12.5, color: C.ink }}>
          ピタメイト別の年間支払額（{new Date(range.to).getFullYear()}年）
        </b>
        <Note>
          源泉徴収は不要と整理していますが（docs/legal/tax-inquiry-withholding.md）、
          <b style={{ color: C.ink }}>誰にいくら払ったかは即答できる状態にしておきます。</b>
        </Note>
        {!payments.items && <Note>読み込み中…</Note>}
        {(payments.items ?? []).slice(0, 20).map((p) => (
          <Row key={p.userId} left={`${p.nickname}（${p.件数}件）`} right={`${yen(p.支払額円)}円`} />
        ))}
        {(payments.items?.length ?? 0) > 20 && (
          <Note>上位20名のみ表示しています。全件はCSVで。</Note>
        )}
        <Btn
          onClick={() =>
            downloadCsv(
              `ピタメイト別支払額_${new Date(range.to).getFullYear()}.csv`,
              ['user_id', 'ニックネーム', '件数', '支払額円', '手数料円', '最終支払日'],
              (payments.items ?? []).map((p) => [
                p.userId,
                p.nickname,
                p.件数,
                p.支払額円,
                p.手数料円,
                p.最終支払日 ?? '',
              ]),
            )
          }
          disabled={!payments.items?.length}
        >
          CSVで保存
        </Btn>
      </Card>
    </>
  )
}

// ------------------------------------------------------------
// 経営（0105）
//
// **構造の欠陥を探す画面ではない。** 事業計画書が置いた前提
// （実効利用料率18% / 貢献利益率19.4%）が実績とずれたことに、
// 早く気づくためだけの3つ。判断はここではしない。
// ------------------------------------------------------------

/** 計画の前提。**画面に数字を直書きせず、ここ1か所に置く。** */
const PLAN = {
  /** 事業計画書 §3 の実効利用料率 */
  effectiveFeePercent: 18,
  /** これを割ったら段の見直しを検討する（§5 の貢献利益率が崩れ始める） */
  feeWarnPercent: 16,
  /** 上位5人がこれを超えたら、1人の離脱で売上が大きく動く */
  concentrationWarnPercent: 60,
  /** カード会社の監視プログラムは概ね1%が目安。手前で気づくため0.5%で警告 */
  chargebackWarnPercent: 0.5,
}

function KpiTab() {
  const init = lastMonthRange()
  const [from, setFrom] = useState(init.from)
  const [to, setTo] = useState(init.to)
  const [range, setRange] = useState(init)

  const [kpi, setKpi] = useState<BusinessKpis | null>(null)
  const [error, setError] = useState<string | null>(null)
  const mix = useList<PaymentMethodMixRow>(
    () => fetchPaymentMethodMix(range.from, range.to),
    [range.from, range.to],
  )

  useEffect(() => {
    if (!isBackendConfigured) return
    let active = true
    setKpi(null)
    fetchBusinessKpis(range.from, range.to)
      .then((k) => active && setKpi(k))
      .catch((e) => active && setError(e instanceof Error ? e.message : '読み込めませんでした'))
    return () => {
      active = false
    }
  }, [range.from, range.to])

  /** 率の表示。**null は「0%」ではなく「—」。** 取引が無いだけなのを 0 と読ませない */
  const pct = (v: number | null) => (v == null ? '—' : `${v.toFixed(2)}%`)

  if (error) return <ErrorBox>{error}</ErrorBox>

  return (
    <>
      <Note>
        事業計画書が置いた前提
        <b style={{ color: C.ink }}>（実効利用料率{PLAN.effectiveFeePercent}%）</b>
        が、実績とずれていないかを見る画面です。
        <br />
        <b style={{ color: C.ink }}>「—」は0%ではなく、その期間に取引が無かった</b>
        という意味です。
      </Note>

      <Card>
        <b style={{ fontSize: 12.5, color: C.ink }}>期間</b>
        <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
          <DateField value={from} onChange={setFrom} />
          <span style={{ fontSize: 12, color: C.body }}>〜</span>
          <DateField value={to} onChange={setTo} />
        </div>
        <Btn onClick={() => setRange({ from, to })}>この期間で表示</Btn>
      </Card>

      {!kpi ? (
        <Note>読み込み中…</Note>
      ) : (
        <>
          {/* ① 実効率 */}
          <span style={{ fontSize: 11, color: C.muted, marginTop: 4 }}>
            ① 混合実効率（計画: {PLAN.effectiveFeePercent}%）
          </span>
          <Card
            alert={
              kpi.fees.bookingPercent != null &&
              kpi.fees.bookingPercent < PLAN.feeWarnPercent
            }
          >
            <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10 }}>
              <span style={{ fontSize: 12.5, color: C.ink }}>予約とギフトの合算</span>
              <b style={{ fontSize: 15, color: C.ink, fontVariantNumeric: 'tabular-nums' }}>
                {pct(kpi.fees.blendedPercent)}
              </b>
            </div>
            <div style={{ borderTop: `1.5px solid ${C.divider}`, paddingTop: 8 }} />
            <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10 }}>
              <span style={{ fontSize: 12, color: C.body }}>
                予約だけ（{kpi.fees.bookingGrossCoins.toLocaleString()}コイン）
              </span>
              <b style={{ fontSize: 13, color: C.ink, fontVariantNumeric: 'tabular-nums' }}>
                {pct(kpi.fees.bookingPercent)}
              </b>
            </div>
            <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10 }}>
              <span style={{ fontSize: 12, color: C.body }}>
                ギフトだけ（{kpi.fees.giftGrossCoins.toLocaleString()}コイン）
              </span>
              <span style={{ fontSize: 13, color: C.body, fontVariantNumeric: 'tabular-nums' }}>
                {pct(kpi.fees.giftPercent)}
              </span>
            </div>
            <Note>
              {/* ギフトは一律35%なので、合算だけ見ていると予約側の下振れが隠れる */}
              計画の{PLAN.effectiveFeePercent}%と比べるのは
              <b style={{ color: C.ink }}>「予約だけ」</b>です。ギフトは一律
              {kpi.fees.giftPercent != null ? `${kpi.fees.giftPercent}%` : '35%'}
              なので、合算は上に引っぱられます。
              {kpi.fees.bookingPercent != null &&
                kpi.fees.bookingPercent < PLAN.feeWarnPercent && (
                  <>
                    <br />
                    <b style={{ color: '#E5484D' }}>
                      予約の実効率が{PLAN.feeWarnPercent}%を下回っています。
                    </b>
                    段の見直しを検討してください（「料率」タブから30日前に予告）。
                  </>
                )}
            </Note>
          </Card>

          {/* ② 上位集中 */}
          <span style={{ fontSize: 11, color: C.muted, marginTop: 8 }}>
            ② 上位への集中（予約GMV）
          </span>
          <Card
            alert={
              kpi.concentration.top5Percent != null &&
              kpi.concentration.top5Percent > PLAN.concentrationWarnPercent
            }
          >
            <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10 }}>
              <span style={{ fontSize: 12.5, color: C.ink }}>上位5人のシェア</span>
              <b style={{ fontSize: 15, color: C.ink, fontVariantNumeric: 'tabular-nums' }}>
                {kpi.concentration.top5Percent == null
                  ? '—'
                  : `${kpi.concentration.top5Percent.toFixed(1)}%`}
              </b>
            </div>
            <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10 }}>
              <span style={{ fontSize: 12, color: C.body }}>最大の1人</span>
              <b style={{ fontSize: 13, color: C.ink, fontVariantNumeric: 'tabular-nums' }}>
                {kpi.concentration.top1Percent == null
                  ? '—'
                  : `${kpi.concentration.top1Percent.toFixed(1)}%`}
              </b>
            </div>
            <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10 }}>
              <span style={{ fontSize: 12, color: C.body }}>稼働したピタメイト</span>
              <span style={{ fontSize: 13, color: C.body, fontVariantNumeric: 'tabular-nums' }}>
                {kpi.concentration.activeHosts}人
              </span>
            </div>
            <Note>
              {/* 集中は実効率が下がる原因であり、同時にチャーンリスクでもある */}
              <b style={{ color: C.ink }}>最大の1人が抜けたら、売上のその割合が消えます。</b>
              上位に集中するほど超過累進で率が下がるため、①の下振れの原因にもなります。
            </Note>
          </Card>

          {/* ③ チャージバック */}
          <span style={{ fontSize: 11, color: C.muted, marginTop: 8 }}>
            ③ チャージバック（購入額に対する比）
          </span>
          <Card
            alert={
              kpi.chargebacks.openCount > 0 ||
              (kpi.chargebacks.ratePercent != null &&
                kpi.chargebacks.ratePercent > PLAN.chargebackWarnPercent)
            }
          >
            <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10 }}>
              <span style={{ fontSize: 12.5, color: C.ink }}>申立て額 ÷ 購入額</span>
              <b style={{ fontSize: 15, color: C.ink, fontVariantNumeric: 'tabular-nums' }}>
                {pct(kpi.chargebacks.ratePercent)}
              </b>
            </div>
            <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10 }}>
              <span style={{ fontSize: 12, color: C.body }}>件数（うち係争中／敗）</span>
              <span style={{ fontSize: 13, color: C.ink, fontVariantNumeric: 'tabular-nums' }}>
                {kpi.chargebacks.count}件（{kpi.chargebacks.openCount}／
                {kpi.chargebacks.lostCount}）
              </span>
            </div>
            <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10 }}>
              <span style={{ fontSize: 12, color: C.body }}>購入額 ／ サポート料</span>
              <span style={{ fontSize: 13, color: C.body, fontVariantNumeric: 'tabular-nums' }}>
                ¥{kpi.chargebacks.purchaseYen.toLocaleString()} ／ ¥
                {kpi.safetyFeeYen.toLocaleString()}
              </span>
            </div>
            <Note>
              {/* 平常時の収支は堅いが、ここだけが一撃で月次を壊せる */}
              <b style={{ color: C.ink }}>
                平常時は堅い収支の中で、ここだけが一撃で月次を壊せます。
              </b>
              {PLAN.chargebackWarnPercent}%を超えたら、3DSの設定（`STRIPE_3DS`）と
              「制限値」タブの新規ユーザー上限を見直してください。
              <br />
              係争中がある間は、対象の報酬が「相殺」タブで保留されています。
            </Note>
          </Card>

          {/* おまけ: 決済手段 */}
          <span style={{ fontSize: 11, color: C.muted, marginTop: 8 }}>
            決済手段の内訳（原価が下がる余地）
          </span>
          {mix.error && <ErrorBox>{mix.error}</ErrorBox>}
          {(mix.items ?? []).length === 0 ? (
            <Note>この期間に購入がありません。</Note>
          ) : (
            <Card>
              {(mix.items ?? []).map((m) => (
                <div
                  key={m.method}
                  style={{ display: 'flex', justifyContent: 'space-between', gap: 10 }}
                >
                  <span style={{ fontSize: 12, color: C.body }}>
                    {m.method}（{m.purchases}件）
                  </span>
                  <span style={{ fontSize: 13, color: C.ink, fontVariantNumeric: 'tabular-nums' }}>
                    ¥{m.amountYen.toLocaleString()}
                    {m.sharePercent != null && ` / ${m.sharePercent.toFixed(1)}%`}
                  </span>
                </div>
              ))}
              <Note>
                PayPayはカードより決済手数料が低いため、
                <b style={{ color: C.ink }}>比率が上がるほど貢献利益率が改善します</b>
                （計画では19.4%）。
                <br />
                <b style={{ color: C.ink }}>「(記録なし)」</b>
                は0096より前の購入です。公開後にこれが増えるなら、webhookの記録
                （0104）が効いていません。
              </Note>
            </Card>
          )}
        </>
      )}
    </>
  )
}

function todayIso(): string {
  const d = new Date()
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

function DateField({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  return (
    <input
      type="date"
      value={value}
      onChange={(e) => onChange(e.target.value)}
      style={{
        background: C.white,
        border: `1.5px solid ${C.border}`,
        borderRadius: 8,
        padding: '8px 10px',
        fontSize: 12,
        color: C.ink,
        outline: 'none',
        fontFamily: 'inherit',
        flex: 1,
        minWidth: 0,
      }}
    />
  )
}

/** 見出しと金額の1行。数字は右端で揃える(桁を目で追えるように)。 */
function Row({
  left,
  right,
  alert = false,
}: {
  left: string
  right: string
  alert?: boolean
}) {
  return (
    <div
      style={{
        display: 'flex',
        justifyContent: 'space-between',
        gap: 10,
        fontSize: 11.5,
        lineHeight: 1.6,
        color: alert ? '#E5484D' : C.body,
      }}
    >
      <span style={{ minWidth: 0 }}>{left}</span>
      <span
        style={{
          flex: 'none',
          color: alert ? '#E5484D' : C.ink,
          fontVariantNumeric: 'tabular-nums',
        }}
      >
        {right}
      </span>
    </div>
  )
}
