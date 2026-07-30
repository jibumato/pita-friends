import { useEffect, useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import { inspectText, guardWarningText } from '../lib/contentGuard'
import { recordContentFlag, fetchMyHostStatus, setHostStatus } from '../lib/queries'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { SubHeader, Toggle, Card, ListRow } from '../components/Ui'
import { Coin, Shield } from '../components/Icon'
import {
  GAMES,
  coinsPer30,
  coinsForDuration,
  durationLabel,
  discountedCoins,
  TRIAL_DISCOUNT_MAX,
  REGULARS_FIRST_CHOICES,
} from '../flow'
import GameThumb from '../components/GameThumb'
import AvailabilityEditor from '../components/AvailabilityEditor'
import { usePress } from '../hooks/usePress'
import { isBackendConfigured } from '../lib/supabase'
import SignedOutPrompt from '../components/SignedOutPrompt'
import { fetchBankAccount, saveBankAccount, normalizeKanaName, type BankAccount } from '../lib/queries'
import { fetchFeeRates, type FeeRates } from '../lib/queries'

const EMPTY_ACCOUNT: BankAccount = {
  bankName: '',
  bankCode: '',
  branchName: '',
  branchCode: '',
  accountType: '普通',
  accountNumber: '',
  accountHolderKana: '',
}

/** 保存前のクライアント側チェック。問題があればメッセージを返す。 */
function validateAccount(a: BankAccount): string | null {
  if (!a.bankName.trim()) return '銀行名を入力してください'
  if (!/^[0-9]{4}$/.test(a.bankCode)) return '銀行コードは数字4桁で入力してください'
  if (!a.branchName.trim()) return '支店名を入力してください'
  if (!/^[0-9]{3}$/.test(a.branchCode)) return '支店コードは数字3桁で入力してください'
  if (!/^[0-9]{7}$/.test(a.accountNumber)) return '口座番号は数字7桁で入力してください(7桁未満は先頭に0を付けてください)'
  const kana = normalizeKanaName(a.accountHolderKana)
  if (!kana) return '口座名義(カナ)を入力してください'
  if (!/^[ァ-ヶー0-9A-Z()（）./\- 　]+$/.test(kana)) return '口座名義はカタカナで入力してください'
  return null
}

/**
 * プラットフォーム利用料の率を出す。
 *
 * **規約 第8条の2第3項で「具体的な率は本サービス上に表示します」と約束している。**
 * 弁護士の助言(Q22-a)で率の表を規約本文から外出しした結果、**画面に出さないと
 * 守れない約束になる。** ここがその表示。
 *
 * 数値はDB(0073の fee_rates)から取る。コードに直書きすると、率を変えたときに
 * 規約・実際の控除額・画面表示の3つがずれる。
 */
function FeeRatesSection() {
  const [rates, setRates] = useState<FeeRates | null>(null)
  const [failed, setFailed] = useState(false)

  useEffect(() => {
    if (!isBackendConfigured) return
    let active = true
    fetchFeeRates()
      .then((r) => active && setRates(r))
      .catch(() => active && setFailed(true))
    return () => {
      active = false
    }
  }, [])

  // 取れなかったときは黙って出さない。**古い数値を混ぜて出すほうが危ない**
  // (画面の率と実際の控除額が食い違うと、それ自体が表示の問題になる)。
  if (!isBackendConfigured || failed || !rates) return null

  const yen = (n: number) => n.toLocaleString()

  return (
    <>
      <span style={{ fontSize: 12, color: C.muted }}>プラットフォーム利用料</span>
      <div
        style={{
          background: C.white,
          border: `1.5px solid ${C.border}`,
          borderRadius: 8,
          padding: '13px 14px',
          display: 'flex',
          flexDirection: 'column',
          gap: 9,
        }}
      >
        <span style={{ fontSize: 11, color: C.body, lineHeight: 1.7 }}>
          受け取った対価から差し引かれる分です。予約は
          <b style={{ color: C.ink }}>その月の累計額</b>に応じて下がります
          （超えた分にだけ低い率がかかります）。
        </span>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
          {rates.bookingTiers.map((tier, i) => {
            const prev = i === 0 ? 0 : rates.bookingTiers[i - 1].upperBound ?? 0
            const label =
              tier.upperBound === null
                ? `${yen(prev)}コイン超`
                : i === 0
                  ? `${yen(tier.upperBound)}コインまで`
                  : `${yen(prev)}〜${yen(tier.upperBound)}コイン`
            return (
              <div
                key={i}
                style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', gap: 8 }}
              >
                <span style={{ fontSize: 11, color: C.muted }}>{label}</span>
                <span style={{ fontSize: 13, color: C.ink }}>{tier.percent}%</span>
              </div>
            )
          })}
        </div>
        <div style={{ borderTop: `1.5px solid ${C.divider}`, paddingTop: 8, display: 'flex', flexDirection: 'column', gap: 5 }}>
          <span style={{ fontSize: 10.5, color: C.body, lineHeight: 1.7 }}>
            同じゲストからの<b style={{ color: C.ink }}>2回目以降</b>は
            <b style={{ color: C.ink }}>{rates.repeatDiscountPoints}ポイント引き</b>
            （下限{rates.floorPercent}%）。
          </span>
          <span style={{ fontSize: 10.5, color: C.body, lineHeight: 1.7 }}>
            ありがとうギフトは一律<b style={{ color: C.ink }}>{rates.giftPercent}%</b>。
          </span>
          <span style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.7 }}>
            直前のキャンセルで受け取る分には利用料はかかりません。
            表示の率は消費税を含みます。
          </span>
        </div>
      </div>
    </>
  )
}

/** 振込先口座の登録フォーム。振込エラー(名義相違等)を防ぐため入力時に検証する。 */
function BankAccountSection() {
  const [account, setAccount] = useState<BankAccount>(EMPTY_ACCOUNT)
  const [registered, setRegistered] = useState(false)
  const [editing, setEditing] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [message, setMessage] = useState<string | null>(null)

  useEffect(() => {
    let active = true
    fetchBankAccount()
      .then((a) => {
        if (!active) return
        if (a) {
          setAccount(a)
          setRegistered(true)
        } else {
          setEditing(true)
        }
      })
      .catch(() => active && setEditing(true))
    return () => {
      active = false
    }
  }, [])

  const set = (patch: Partial<BankAccount>) => setAccount((a) => ({ ...a, ...patch }))

  async function handleSave() {
    if (busy) return
    const problem = validateAccount(account)
    if (problem) {
      setError(problem)
      return
    }
    setBusy(true)
    setError(null)
    setMessage(null)
    try {
      await saveBankAccount(account)
      setAccount((a) => ({ ...a, accountHolderKana: normalizeKanaName(a.accountHolderKana) }))
      setRegistered(true)
      setEditing(false)
      setMessage('振込先を保存しました')
    } catch (e) {
      setError(e instanceof Error ? e.message : '振込先の保存に失敗しました')
    } finally {
      setBusy(false)
    }
  }

  const inputStyle = {
    background: C.surface,
    border: `1.5px solid ${C.border}`,
    borderRadius: 6,
    padding: '9px 12px',
    fontSize: 12.5,
    color: C.ink,
    outline: 'none',
    fontFamily: 'inherit',
    minWidth: 0,
  } as const

  return (
    <>
      <span style={{ fontSize: 12, color: C.muted }}>振込先口座(報酬の受け取り)</span>
      <div
        style={{
          background: C.white,
          border: `1.5px solid ${C.border}`,
          borderRadius: 8,
          padding: '13px 14px',
          display: 'flex',
          flexDirection: 'column',
          gap: 8,
        }}
      >
        {registered && !editing ? (
          <>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <span
                style={{
                  fontSize: 10,
                  color: C.ink,
                  background: C.lime,
                  border: `1.5px solid ${C.border}`,
                  padding: '2px 8px',
                  borderRadius: 4,
                }}
              >
                登録済み
              </span>
              <span style={{ fontSize: 11.5, color: C.body }}>
                {account.bankName} {account.branchName} {account.accountType} •••{account.accountNumber.slice(-3)}
              </span>
            </div>
            <span
              onClick={() => {
                setEditing(true)
                setMessage(null)
              }}
              style={{ cursor: 'pointer', fontSize: 11.5, color: C.lavenderText, textDecoration: 'underline' }}
            >
              口座情報を変更する
            </span>
          </>
        ) : (
          <>
            <span style={{ fontSize: 11, color: C.body, lineHeight: 1.6 }}>
              報酬コインの換金(銀行振込)に使う口座です。名義はご本人のものに限ります。
            </span>
            <div style={{ display: 'flex', gap: 8 }}>
              <input
                value={account.bankName}
                onChange={(e) => set({ bankName: e.target.value })}
                placeholder="銀行名"
                style={{ ...inputStyle, flex: 2 }}
              />
              <input
                value={account.bankCode}
                onChange={(e) => set({ bankCode: e.target.value.replace(/[^0-9]/g, '').slice(0, 4) })}
                placeholder="コード4桁"
                inputMode="numeric"
                style={{ ...inputStyle, flex: 1 }}
              />
            </div>
            {/* ゆうちょ(9900)は記号・番号のままでは他行から振り込めない。
                変換後の店番・口座番号を入れてもらわないと、振込が失敗して
                組戻し手数料(¥660〜880)が当社負担になる。入力した瞬間に気づけるよう出す。 */}
            {account.bankCode === '9900' && (
              <div
                style={{
                  background: C.avatarOrange,
                  border: `1.5px solid ${C.border}`,
                  borderRadius: 6,
                  padding: '9px 11px',
                  fontSize: 10.5,
                  color: C.ink,
                  lineHeight: 1.7,
                }}
              >
                ゆうちょ銀行は、通帳の<b>記号・番号のままでは他行からの振込を受け取れません。</b>
                ゆうちょ銀行アプリ・通帳・ゆうちょの「振込用の店名・預金種目・口座番号」の照会で、
                <b>店番(3桁)・口座番号(7桁)</b>に変換した値を確認して入力してください。
              </div>
            )}
            <div style={{ display: 'flex', gap: 8 }}>
              <input
                value={account.branchName}
                onChange={(e) => set({ branchName: e.target.value })}
                placeholder="支店名"
                style={{ ...inputStyle, flex: 2 }}
              />
              <input
                value={account.branchCode}
                onChange={(e) => set({ branchCode: e.target.value.replace(/[^0-9]/g, '').slice(0, 3) })}
                placeholder="コード3桁"
                inputMode="numeric"
                style={{ ...inputStyle, flex: 1 }}
              />
            </div>
            <div style={{ display: 'flex', gap: 8 }}>
              <div style={{ flex: 1, display: 'flex', gap: 6 }}>
                {(['普通', '当座'] as const).map((t) => (
                  <span
                    key={t}
                    onClick={() => set({ accountType: t })}
                    style={{
                      cursor: 'pointer',
                      flex: 1,
                      textAlign: 'center',
                      fontSize: 11.5,
                      padding: '9px 0',
                      borderRadius: 6,
                      border: `1.5px solid ${C.border}`,
                      color: account.accountType === t ? C.lime : C.ink,
                      background: account.accountType === t ? C.fill : C.white,
                    }}
                  >
                    {t}
                  </span>
                ))}
              </div>
              <input
                value={account.accountNumber}
                onChange={(e) => set({ accountNumber: e.target.value.replace(/[^0-9]/g, '').slice(0, 7) })}
                placeholder="口座番号7桁"
                inputMode="numeric"
                style={{ ...inputStyle, flex: 1.4 }}
              />
            </div>
            <input
              value={account.accountHolderKana}
              onChange={(e) => set({ accountHolderKana: e.target.value })}
              placeholder="口座名義(カナ) 例: ヤマダ ハナコ"
              style={inputStyle}
            />
            <div
              onClick={handleSave}
              style={{
                cursor: busy ? 'not-allowed' : 'pointer',
                opacity: busy ? 0.6 : 1,
                textAlign: 'center',
                fontSize: 12.5,
                color: C.ink,
                background: C.lime,
                border: `1.5px solid ${C.border}`,
                borderRadius: 6,
                padding: '9px 0',
              }}
            >
              {busy ? '保存中…' : 'この口座を保存する'}
            </div>
          </>
        )}
        {error && <span style={{ fontSize: 10.5, color: C.avatarPink }}>{error}</span>}
        {message && <span style={{ fontSize: 10.5, color: C.lavenderText }}>{message}</span>}
      </div>
    </>
  )
}

export default function HostSettingsScreen({ flow }: { flow: Flow }) {
  const h = flow.hostSettings
  const save = usePress(`3px 3px 0 ${C.lavender}`)
  const signedIn = !isBackendConfigured || flow.userId !== null

  if (!signedIn) {
    // 未ログインで開くと、既定値(400コイン/時・Apex)の設定フォームが出て
    // 保存だけができない状態になる。先に登録してもらう。
    return (
      <Screen background={C.surface}>
        <StatusBar time="21:47" />
        <SubHeader title="ピタメイト設定" onBack={() => flow.go('home')} />
        <div style={{ flex: 1, overflowY: 'auto', padding: '10px 20px 24px' }}>
          <SignedOutPrompt
            flow={flow}
            title="ピタメイトになるには登録が必要です"
            body="遊ぶ時間を30分単位で提供して、報酬コインを受け取れます。まずアカウントを作り、本人確認を済ませてください。"
          />
        </div>
      </Screen>
    )
  }

  return (
    <Screen background={C.surface}>
      <StatusBar time="21:47" />
      <SubHeader title="ピタメイト設定" onBack={() => flow.go('mypage')} />
      <div
        className="pita-scroll"
        style={{
          flex: 1,
          overflowY: 'auto',
          padding: '4px 20px 0',
          display: 'flex',
          flexDirection: 'column',
          gap: 14,
        }}
      >
        <div
          style={{
            background: C.surfaceLavender,
            border: `1.5px solid ${C.lavender}`,
            borderRadius: 12,
            padding: '13px 14px',
            display: 'flex',
            gap: 10,
            alignItems: 'flex-start',
          }}
        >
          <Shield size={18} style={{ flex: 'none', marginTop: 1 }} />
          <span style={{ fontSize: 11.5, lineHeight: 1.7, color: C.body }}>
            ピタメイトになると、あなたと一緒に遊ぶ時間をコインで提供できます。掲載は本人確認済みの方のみ。安心設定（誘いを受ける範囲・承認制）は掲載中も有効です。
          </span>
        </div>

        {flow.hostSettingsError && (
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
            {flow.hostSettingsError}
          </div>
        )}

        <Card>
          <ListRow
            label="ピタメイトとして掲載する"
            sub={h.isHost ? '「さがす」に表示されます' : 'オフの間は表示されません'}
            divider={false}
            right={
              <Toggle
                on={h.isHost}
                onToggle={() => flow.setHostPref('isHost', !h.isHost)}
                label="ピタメイトとして掲載する"
              />
            }
          />
        </Card>

        <span style={{ fontSize: 12, color: C.muted }}>料金（30分あたり）</span>
        <div
          style={{
            background: C.white,
            border: `1.5px solid ${C.border}`,
            borderRadius: 8,
            padding: '13px 14px',
            display: 'flex',
            alignItems: 'center',
            gap: 10,
          }}
        >
          <Coin size={18} />
          <span
            onClick={() => flow.setHostPref('hourlyRate', Math.max(100, h.hourlyRate - 100))}
            style={{ cursor: 'pointer', fontSize: 18, color: C.ink, userSelect: 'none', padding: '0 6px' }}
          >
            −
          </span>
          <span style={{ flex: 1, textAlign: 'center', fontSize: 16, color: C.ink }}>
            {coinsPer30(h.hourlyRate)} コイン / 30分
          </span>
          <span
            onClick={() => flow.setHostPref('hourlyRate', Math.min(2000, h.hourlyRate + 100))}
            style={{ cursor: 'pointer', fontSize: 18, color: C.ink, userSelect: 'none', padding: '0 6px' }}
          >
            ＋
          </span>
        </div>

        {/* 初回お試し割引。そのピタメイトと初めて遊ぶゲストにだけ効く。
            値引き後の価格をその場で出さないと、いくら受け取れるのか
            分からないまま割引率だけ上げてしまうため、必ず併記する。 */}
        <span style={{ fontSize: 12, color: C.muted }}>初回お試し割引（任意）</span>
        <div
          style={{
            background: C.white,
            border: `1.5px solid ${C.border}`,
            borderRadius: 8,
            padding: '13px 14px',
            display: 'flex',
            flexDirection: 'column',
            gap: 11,
          }}
        >
          <span style={{ fontSize: 11, color: C.muted, lineHeight: 1.7 }}>
            あなたと<b style={{ color: C.ink }}>初めて</b>遊ぶ人だけが、この割引価格で予約できます。
            2回目以降は通常価格に戻ります。
          </span>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <span
              onClick={() =>
                flow.setHostPref('trialDiscountPercent', Math.max(0, h.trialDiscountPercent - 5))
              }
              style={{ cursor: 'pointer', fontSize: 18, color: C.ink, userSelect: 'none', padding: '0 6px' }}
            >
              −
            </span>
            <span style={{ flex: 1, textAlign: 'center', fontSize: 16, color: C.ink }}>
              {h.trialDiscountPercent === 0 ? 'なし' : `${h.trialDiscountPercent}% OFF`}
            </span>
            <span
              onClick={() =>
                flow.setHostPref(
                  'trialDiscountPercent',
                  Math.min(TRIAL_DISCOUNT_MAX, h.trialDiscountPercent + 5),
                )
              }
              style={{ cursor: 'pointer', fontSize: 18, color: C.ink, userSelect: 'none', padding: '0 6px' }}
            >
              ＋
            </span>
          </div>

          {h.trialDiscountPercent > 0 && (
            <div
              style={{
                background: C.surfaceLavender,
                border: `1.5px solid ${C.lavender}`,
                borderRadius: 8,
                padding: '11px 13px',
                display: 'flex',
                flexDirection: 'column',
                gap: 7,
              }}
            >
              {([30, 60, 120] as const).map((min) => {
                const list = coinsForDuration(h.hourlyRate, min)
                return (
                  <div
                    key={min}
                    style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', gap: 8 }}
                  >
                    <span style={{ fontSize: 11, color: C.muted, flex: 'none' }}>{durationLabel(min)}</span>
                    <div style={{ display: 'flex', alignItems: 'baseline', gap: 7 }}>
                      <span style={{ fontSize: 11.5, color: C.placeholder, textDecoration: 'line-through' }}>
                        {list.toLocaleString()}
                      </span>
                      <span style={{ fontSize: 10, color: C.muted }}>→</span>
                      <span style={{ fontSize: 15, color: C.lavender }}>
                        {discountedCoins(list, h.trialDiscountPercent).toLocaleString()}
                      </span>
                      <span style={{ fontSize: 10.5, color: C.muted }}>コイン</span>
                    </div>
                  </div>
                )
              })}
              <span style={{ fontSize: 10, color: C.muted, lineHeight: 1.7, marginTop: 2 }}>
                手数料は割引後の金額にかかります（値引きした分だけ手数料も下がります）。
              </span>
            </div>
          )}
        </div>

        <FeeRatesSection />

        <span style={{ fontSize: 12, color: C.muted }}>対応ゲーム</span>
        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
          {GAMES.map((g) => {
            const sel = h.games.includes(g)
            return (
              <span
                key={g}
                onClick={() =>
                  flow.setHostPref(
                    'games',
                    sel ? h.games.filter((x) => x !== g) : [...h.games, g],
                  )
                }
                style={{
                  cursor: 'pointer',
                  fontSize: 12,
                  color: sel ? C.lime : C.ink,
                  background: sel ? C.fill : C.white,
                  border: `1.5px solid ${C.border}`,
                  padding: '5px 11px 5px 6px',
                  borderRadius: 4,
                  display: 'inline-flex',
                  alignItems: 'center',
                  gap: 7,
                }}
              >
                <GameThumb name={g} size={22} />
                {g}
              </span>
            )
          })}
        </div>

        <span style={{ fontSize: 12, color: C.muted }}>募集する時間（任意）</span>
        {isBackendConfigured ? (
          <AvailabilityEditor />
        ) : (
          <span style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.6 }}>
            （デモ表示のため、募集枠の保存はできません）
          </span>
        )}

        {/* 常連への先行予約(0057)。値引きではないので取り分は減らない。
            減るのは「常連に取られる前に他人に取られる」取りこぼしだけ。 */}
        <span style={{ fontSize: 12, color: C.muted }}>常連への先行予約（任意）</span>
        <div
          style={{
            background: C.white,
            border: `1.5px solid ${C.border}`,
            borderRadius: 8,
            padding: '13px 14px',
            display: 'flex',
            flexDirection: 'column',
            gap: 11,
          }}
        >
          <span style={{ fontSize: 11, color: C.muted, lineHeight: 1.7 }}>
            先の枠を、<b style={{ color: C.ink }}>一緒に遊んだことのある人</b>だけが予約できる状態にします。
            開始が近づくと誰でも予約できるようになるので、枠が埋まらないまま流れることはありません。
          </span>
          <div style={{ display: 'flex', gap: 6 }}>
            {REGULARS_FIRST_CHOICES.map((v) => (
              <span
                key={v}
                onClick={() => flow.setHostPref('regularsFirstHours', v)}
                role="button"
                tabIndex={0}
                onKeyDown={(e) => {
                  if (e.key === 'Enter' || e.key === ' ') flow.setHostPref('regularsFirstHours', v)
                }}
                style={{
                  cursor: 'pointer',
                  flex: 1,
                  textAlign: 'center',
                  fontSize: 11.5,
                  padding: '9px 0',
                  borderRadius: 6,
                  border: `1.5px solid ${C.border}`,
                  color: h.regularsFirstHours === v ? C.lime : C.ink,
                  background: h.regularsFirstHours === v ? C.fill : C.white,
                }}
              >
                {v === 0 ? 'なし' : `${v}時間`}
              </span>
            ))}
          </div>
          {h.regularsFirstHours > 0 && (
            <span style={{ fontSize: 10.5, color: C.body, lineHeight: 1.7 }}>
              開始まで<b>{h.regularsFirstHours}時間</b>より先の枠は常連のみ。
              たとえば金曜22時の枠は、
              {h.regularsFirstHours === 24 ? '木曜22時' : h.regularsFirstHours === 48 ? '水曜22時' : '火曜22時'}
              から誰でも予約できます。
            </span>
          )}
        </div>

        {isBackendConfigured && <BankAccountSection />}

        {/* 近況(短く・書き換える)と 自己紹介(長く・そのまま)は別のもの。
            同じ「ひとこと」という名前だと、どちらを書き換えればいいか分からない。 */}
        {isBackendConfigured && (
          <>
            <span style={{ fontSize: 12, color: C.muted }}>いまのひとこと</span>
            <StatusField />
          </>
        )}

        <span style={{ fontSize: 12, color: C.muted }}>自己紹介</span>
        <BioField flow={flow} />

        <div
          style={{
            background: C.white,
            border: `1.5px solid ${C.border}`,
            borderRadius: 8,
            boxShadow: `2px 2px 0 ${C.shadowCol}`,
            padding: '11px 13px',
            display: 'flex',
            flexDirection: 'column',
            gap: 5,
            marginBottom: 10,
          }}
        >
          <span style={{ fontSize: 11.5, color: C.ink }}>ピタメイトとして遊ぶときのルール</span>
          <span style={{ fontSize: 10.5, lineHeight: 1.7, color: C.body }}>
            ・提供するのは「ゲームを一緒に遊ぶ時間」です。出会い・恋愛目的の勧誘は禁止
            <br />
            ・受け取りはコイン決済のみ。アプリ外での金銭要求は禁止
            <br />
            ・ドタキャン・無断キャンセルはマナースコアに反映されます
            <br />
            ・不適切な要求を受けたら、その場で通報してください
          </span>
        </div>
      </div>
      <div style={{ padding: '12px 20px 26px', background: C.white, borderTop: `1.5px solid ${C.border}` }}>
        <div
          className="pita-press"
          onClick={() => flow.go('mypage')}
          {...save.handlers}
          style={{
            cursor: 'pointer',
            background: C.ctaBg,
            color: C.ctaFg,
            borderRadius: 8,
            padding: '14px 0',
            textAlign: 'center',
            fontSize: 14,
            ...save.style,
          }}
        >
          この設定で保存する ▶
        </div>
      </div>
    </Screen>
  )
}

/** ひとことの上限。サーバ側(set_host_status)の60字と揃えること。 */
const STATUS_MAX = 60

/**
 * 「いまのひとこと」(近況)の入力欄(0056)。
 *
 * 自己紹介と違って、書き換えられてこそ意味がある欄。だから
 *   ・短くする(60字)。長いと書き直す気にならない
 *   ・保存を明示的にする。時刻が入るので、入力のたびに押したことに
 *     したくない(「1分前に更新」が打鍵のたびに動くのは嘘に近い)
 *   ・14日で自動的に見えなくなることを、書く前に伝えておく
 */
function StatusField() {
  const [text, setText] = useState('')
  const [savedText, setSavedText] = useState('')
  const [updatedAt, setUpdatedAt] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const hits = inspectText(text).hits
  const save = usePress(`2px 2px 0 ${C.lavender}`)

  useEffect(() => {
    let active = true
    fetchMyHostStatus()
      .then((s) => {
        if (!active) return
        setText(s.text)
        setSavedText(s.text)
        setUpdatedAt(s.updatedAt)
      })
      .catch(() => active && setError('ひとことを読み込めませんでした'))
    return () => {
      active = false
    }
  }, [])

  const onSave = () => {
    setSaving(true)
    setError(null)
    for (const h of hits) void recordContentFlag(h.category, 'profile', h.matched, true)
    setHostStatus(text)
      .then((at) => {
        setUpdatedAt(at)
        setSavedText(text.trim())
      })
      .catch(() => setError('保存に失敗しました。時間をおいて再度お試しください。'))
      .finally(() => setSaving(false))
  }

  const dirty = text.trim() !== savedText

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 7 }}>
      <input
        value={text}
        onChange={(e) => setText(e.target.value.slice(0, STATUS_MAX))}
        maxLength={STATUS_MAX}
        placeholder="今夜21時から遊べます！"
        style={{
          background: C.white,
          border: `1.5px solid ${hits.length > 0 ? C.avatarPink : C.border}`,
          borderRadius: 8,
          padding: '12px 14px',
          fontSize: 12.5,
          color: C.ink,
          fontFamily: 'inherit',
          outline: 'none',
        }}
      />
      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
        <span style={{ fontSize: 10.5, color: C.muted }}>
          {text.length}/{STATUS_MAX}
        </span>
        {updatedAt && !dirty && (
          <span style={{ fontSize: 10.5, color: C.muted }}>✓ 保存済み</span>
        )}
        <div style={{ flex: 1 }} />
        <div
          onClick={dirty && !saving ? onSave : undefined}
          role="button"
          tabIndex={dirty && !saving ? 0 : -1}
          onKeyDown={(e) => {
            if (dirty && !saving && (e.key === 'Enter' || e.key === ' ')) onSave()
          }}
          style={{
            cursor: dirty && !saving ? 'pointer' : 'default',
            opacity: dirty && !saving ? 1 : 0.45,
            background: C.lime,
            border: `1.5px solid ${C.border}`,
            borderRadius: 8,
            padding: '7px 14px',
            fontSize: 11.5,
            color: C.ink,
            ...(dirty && !saving ? save.style : {}),
          }}
        >
          {saving ? '保存中…' : text.trim() === '' ? '消す' : '更新する'}
        </div>
      </div>
      {hits.length > 0 && (
        <span style={{ fontSize: 10.5, color: C.avatarPink, lineHeight: 1.6 }}>
          {guardWarningText(hits)}
        </span>
      )}
      {error && <span style={{ fontSize: 10.5, color: C.avatarPink }}>{error}</span>}
      <span style={{ fontSize: 10, color: C.muted, lineHeight: 1.6 }}>
        ホームやプロフィールに出ます。14日を過ぎると自動で見えなくなります
        （消えるのは表示だけで、書き直せばまた出ます）。
      </span>
    </div>
  )
}

/**
 * 自己紹介(プロフィール文)の入力欄。
 * 「みまもり」の一次検知に当たる内容を書いている間は注意を表示する。
 * 入力のたびに保存される作りのため、記録(record_content_flag)は
 * 入力を終えた時(blur)に一度だけ行う。投稿はブロックしない(§4.2)。
 */
function BioField({ flow }: { flow: Flow }) {
  const bio = flow.hostSettings.bio
  const hits = inspectText(bio).hits

  return (
    <>
      <textarea
        value={bio}
        onChange={(e) => flow.setHostPref('bio', e.target.value)}
        onBlur={() => {
          for (const h of hits) void recordContentFlag(h.category, 'profile', h.matched, true)
        }}
        maxLength={200}
        placeholder="ゴールド帯でまったり回してます。初心者さんも歓迎です！"
        style={{
          background: C.white,
          border: `1.5px solid ${hits.length > 0 ? C.avatarPink : C.border}`,
          borderRadius: 8,
          padding: '12px 14px',
          minHeight: 60,
          fontSize: 12.5,
          color: C.ink,
          resize: 'none',
          fontFamily: 'inherit',
          outline: 'none',
        }}
      />
      {hits.length > 0 && (
        <span style={{ fontSize: 10.5, color: C.avatarPink, lineHeight: 1.6 }}>
          {guardWarningText(hits)}
        </span>
      )}
    </>
  )
}
