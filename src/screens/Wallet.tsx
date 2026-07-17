import { useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { SubHeader } from '../components/Ui'
import { Coin, Shield } from '../components/Icon'
import { COIN_PACKS } from '../flow'
import { usePress } from '../hooks/usePress'
import { isBackendConfigured } from '../lib/supabase'

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

export default function Wallet({ flow }: { flow: Flow }) {
  const [justBought, setJustBought] = useState<number | null>(null)

  const buy = (coins: number) => {
    flow.buyCoins(coins)
    setJustBought(coins)
    setTimeout(() => setJustBought(null), 1800)
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

        <span style={{ fontSize: 13, color: C.ink }}>▶ コインを購入</span>
        {isBackendConfigured && (
          <div
            style={{
              background: C.disabledBg,
              border: `1.5px solid ${C.disabledBorder}`,
              borderRadius: 8,
              padding: '10px 12px',
              fontSize: 11,
              color: C.disabledFg,
              lineHeight: 1.7,
            }}
          >
            決済連携は準備中です。現在コインの購入はできません(実際の決済代行事業者は未選定のため)。
          </div>
        )}
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          {COIN_PACKS.map((p) => (
            <PackCard
              key={p.coins}
              coins={p.coins}
              priceYen={p.priceYen}
              bonus={p.bonus}
              disabled={isBackendConfigured}
              onBuy={() => buy(p.coins)}
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
