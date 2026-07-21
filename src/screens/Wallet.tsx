import { useEffect, useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { SubHeader } from '../components/Ui'
import { Coin, Shield } from '../components/Icon'
import { COIN_PACKS, packBonusLabel, type CoinPack } from '../flow'
import { usePress } from '../hooks/usePress'
import { isBackendConfigured } from '../lib/supabase'
import {
  createCheckoutSession,
  fetchCoinPacks,
  fetchEarnings,
  fetchBankAccount,
  fetchPayoutHistory,
  requestPayout,
  PAYOUT_FEE_COINS,
  PAYOUT_MIN_COINS,
  type EarningsSummary,
  type PayoutRecord,
} from '../lib/queries'

function PackCard({
  coins,
  priceYen,
  bonus,
  disabled,
  onBuy,
}: {
  coins: number
  priceYen: number
  bonus?: string
  disabled?: boolean
  onBuy: () => void
}) {
  const press = usePress(`3px 3px 0 ${C.shadowCol}`)
  return (
    <div
      className="pita-press"
      onClick={disabled ? undefined : onBuy}
      {...(disabled ? {} : press.handlers)}
      style={{
        cursor: disabled ? 'not-allowed' : 'pointer',
        opacity: disabled ? 0.55 : 1,
        background: C.white,
        border: `1.5px solid ${C.border}`,
        borderRadius: 12,
        padding: 14,
        display: 'flex',
        alignItems: 'center',
        gap: 12,
        ...(disabled ? {} : press.style),
      }}
    >
      <div
        style={{
          width: 44,
          height: 44,
          borderRadius: 10,
          background: C.lime,
          border: `1.5px solid ${C.border}`,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          flex: 'none',
        }}
      >
        <Coin size={22} />
      </div>
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 2 }}>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 6 }}>
          <span style={{ fontSize: 16, color: C.ink }}>{coins.toLocaleString()} コイン</span>
          {bonus && (
            <span
              style={{
                fontSize: 9.5,
                color: C.ink,
                background: C.surfaceLavender,
                border: `1.5px solid ${C.lavender}`,
                padding: '1px 6px',
                borderRadius: 4,
              }}
            >
              {bonus}
            </span>
          )}
        </div>
        <span style={{ fontSize: 10.5, color: C.muted }}>1コイン ≒ 1円</span>
      </div>
      <span style={{ fontSize: 15, color: C.ink }}>¥{priceYen.toLocaleString()}</span>
    </div>
  )
}

function statusLabel(s: PayoutRecord['status']): string {
  if (s === 'paid') return '振込済み'
  if (s === 'failed') return '失敗'
  return '振込待ち'
}

/** ホストとしての収益・換金セクション(報酬コインは購入コインとは別会計)。 */
function EarningsSection() {
  const [earnings, setEarnings] = useState<EarningsSummary | null>(null)
  const [hasBankAccount, setHasBankAccount] = useState<boolean | null>(null)
  const [history, setHistory] = useState<PayoutRecord[]>([])
  const [amount, setAmount] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [message, setMessage] = useState<string | null>(null)

  const load = () => {
    fetchEarnings().then(setEarnings).catch(() => {})
    fetchBankAccount().then((a) => setHasBankAccount(!!a)).catch(() => {})
    fetchPayoutHistory().then(setHistory).catch(() => {})
  }

  useEffect(load, [])

  const coins = parseInt(amount, 10) || 0

  async function handleRequest() {
    if (busy || coins <= 0) return
    if (coins < PAYOUT_MIN_COINS) {
      setError(`換金は${PAYOUT_MIN_COINS.toLocaleString()}コインから申請できます`)
      return
    }
    if (earnings && coins > earnings.earnedBalance) {
      setError('換金可能な残高を超えています')
      return
    }
    setBusy(true)
    setError(null)
    setMessage(null)
    try {
      await requestPayout(coins)
      setMessage('換金を申請しました。次回の振込日にご登録の口座へお振込みします。')
      setAmount('')
      load()
    } catch (e) {
      setError(e instanceof Error ? e.message : '換金に失敗しました')
    } finally {
      setBusy(false)
    }
  }

  if (!earnings || (earnings.earnedBalance === 0 && earnings.escrowedCoins === 0 && history.length === 0)) {
    return null
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
      <span style={{ fontSize: 13, color: C.ink }}>▶ ホストとしての収益</span>
      <div
        style={{
          background: C.white,
          border: `1.5px solid ${C.border}`,
          borderRadius: 12,
          boxShadow: `3px 3px 0 ${C.shadowCol}`,
          padding: 14,
          display: 'flex',
          flexDirection: 'column',
          gap: 10,
        }}
      >
        <div style={{ display: 'flex', gap: 10 }}>
          <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 2 }}>
            <span style={{ fontSize: 20, color: C.ink }}>{earnings.earnedBalance.toLocaleString()}</span>
            <span style={{ fontSize: 10, color: C.muted }}>換金可能</span>
          </div>
          <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 2 }}>
            <span style={{ fontSize: 20, color: C.muted }}>{earnings.escrowedCoins.toLocaleString()}</span>
            <span style={{ fontSize: 10, color: C.muted }}>プレイ完了待ち</span>
          </div>
        </div>

        {hasBankAccount === false ? (
          <span style={{ fontSize: 11, color: C.body, lineHeight: 1.6 }}>
            換金するには、ホスト設定から振込先口座を登録してください。
          </span>
        ) : earnings.earnedBalance > 0 ? (
          <>
            <div style={{ display: 'flex', gap: 8 }}>
              <input
                value={amount}
                onChange={(e) => setAmount(e.target.value.replace(/[^0-9]/g, ''))}
                placeholder={`${PAYOUT_MIN_COINS.toLocaleString()}〜${earnings.earnedBalance.toLocaleString()}`}
                inputMode="numeric"
                style={{
                  flex: 1,
                  background: C.surface,
                  border: `1.5px solid ${C.border}`,
                  borderRadius: 6,
                  padding: '9px 12px',
                  fontSize: 13,
                  color: C.ink,
                  outline: 'none',
                  fontFamily: 'inherit',
                }}
              />
              <span
                onClick={handleRequest}
                style={{
                  cursor: busy ? 'not-allowed' : 'pointer',
                  opacity: busy ? 0.6 : 1,
                  fontSize: 12.5,
                  color: C.ink,
                  background: C.lime,
                  border: `1.5px solid ${C.border}`,
                  borderRadius: 6,
                  padding: '9px 16px',
                }}
              >
                {busy ? '処理中…' : '換金する'}
              </span>
            </div>
            <span style={{ fontSize: 10, color: C.muted, lineHeight: 1.6 }}>
              換金事務手数料(振込手数料を含む) {PAYOUT_FEE_COINS}コイン/回
              {coins >= PAYOUT_MIN_COINS && ` — 振込額 ¥${(coins - PAYOUT_FEE_COINS).toLocaleString()}`}
              。月末締め・翌月払いでご登録の口座にお振込みします。
            </span>
          </>
        ) : null}

        {error && <span style={{ fontSize: 10.5, color: C.avatarPink }}>{error}</span>}
        {message && <span style={{ fontSize: 10.5, color: C.lavenderText }}>{message}</span>}

        {history.length > 0 && (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 6, marginTop: 4 }}>
            {history.slice(0, 5).map((h) => (
              <div key={h.id} style={{ display: 'flex', justifyContent: 'space-between', fontSize: 11 }}>
                <span style={{ color: C.muted }}>{new Date(h.createdAt).toLocaleDateString('ja-JP')}</span>
                <span style={{ color: C.ink }}>{h.coins.toLocaleString()}コイン → ¥{h.amountYen.toLocaleString()}</span>
                <span style={{ color: h.status === 'failed' ? C.avatarPink : C.muted }}>{statusLabel(h.status)}</span>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  )
}

export default function Wallet({ flow }: { flow: Flow }) {
  const [justBought, setJustBought] = useState<number | null>(null)
  // バックエンド接続時はサーバーのパック定義を使う。未取得のうちはコード側の定義で表示。
  const [packs, setPacks] = useState<CoinPack[]>(COIN_PACKS)
  const [redirecting, setRedirecting] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (!isBackendConfigured) return
    let active = true
    fetchCoinPacks()
      .then((data) => {
        if (active && data.length > 0) setPacks(data)
      })
      .catch(() => {
        /* 取得失敗時はコード側の定義のまま表示する */
      })
    return () => {
      active = false
    }
  }, [])

  // デモ: ローカル加算。バックエンド: Stripe Checkout へ遷移(付与は決済後にwebhook)。
  const buy = async (pack: CoinPack) => {
    if (redirecting) return
    if (!isBackendConfigured) {
      const total = pack.coins + pack.bonusCoins
      flow.buyCoins(total)
      setJustBought(total)
      setTimeout(() => setJustBought(null), 1800)
      return
    }
    setRedirecting(true)
    setError(null)
    try {
      const url = await createCheckoutSession(pack.id)
      window.location.href = url
    } catch (e) {
      setError(e instanceof Error ? e.message : '決済ページの準備に失敗しました')
      setRedirecting(false)
    }
  }

  return (
    <Screen background={C.surface}>
      <StatusBar time="21:47" />
      <SubHeader title="コインウォレット" onBack={() => flow.go('mypage')} />
      <div
        className="pita-scroll"
        style={{
          flex: 1,
          overflowY: 'auto',
          padding: '4px 20px 24px',
          display: 'flex',
          flexDirection: 'column',
          gap: 16,
        }}
      >
        {/* 残高 */}
        <div
          style={{
            background: C.lavender,
            border: `1.5px solid ${C.border}`,
            borderRadius: 12,
            boxShadow: `4px 4px 0 ${C.shadowCol}`,
            padding: 18,
            display: 'flex',
            flexDirection: 'column',
            alignItems: 'center',
            gap: 4,
          }}
        >
          <span style={{ fontSize: 11, color: '#fff' }}>コイン残高</span>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <Coin size={26} color={C.lime} />
            <span style={{ fontSize: 34, color: C.lime }}>{flow.coinBalance.toLocaleString()}</span>
          </div>
          {justBought && (
            <span style={{ fontSize: 11, color: '#fff' }}>+{justBought} コインを追加しました</span>
          )}
        </div>

        {isBackendConfigured && <EarningsSection />}

        <span style={{ fontSize: 13, color: C.ink }}>▶ コインを購入</span>
        {redirecting && (
          <div
            style={{
              background: C.surfaceLavender,
              border: `1.5px solid ${C.lavender}`,
              borderRadius: 8,
              padding: '10px 12px',
              fontSize: 11,
              color: C.body,
            }}
          >
            決済ページへ移動しています…
          </div>
        )}
        {error && (
          <div
            style={{
              background: C.avatarPink,
              border: `1.5px solid ${C.border}`,
              borderRadius: 8,
              padding: '10px 12px',
              fontSize: 11.5,
              color: C.ink,
            }}
          >
            {error}
          </div>
        )}
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          {packs.map((p) => (
            <PackCard
              key={p.id}
              coins={p.coins}
              priceYen={p.priceYen}
              bonus={packBonusLabel(p)}
              disabled={redirecting}
              onBuy={() => buy(p)}
            />
          ))}
        </div>

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
          <span style={{ fontSize: 10.5, lineHeight: 1.6, color: C.body }}>
            コイン決済はピタフレが仲介し、安全に処理されます。<b style={{ color: C.ink }}>アプリ外での直接の金銭要求・受け渡しは引き続き禁止・通報対象</b>です。
          </span>
        </div>
      </div>
    </Screen>
  )
}
