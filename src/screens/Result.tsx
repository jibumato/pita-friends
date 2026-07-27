import { useEffect, useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen, { DotPattern } from '../components/Screen'
import Confetti from '../components/Confetti'
import PitaButton from '../components/PitaButton'
import { ArrowRight } from '../components/Icon'
import SupportSheet from '../components/SupportSheet'
import NextSlots from '../components/NextSlots'
import { isBackendConfigured } from '../lib/supabase'
import { fetchThreadPartner } from '../lib/queries'

export default function Result({ flow }: { flow: Flow }) {
  // ★4.90 を起点に、選択星数で微増(最大5.00)
  const newScore = Math.min(5, 4.9 + (flow.reviewStars - 5) * 0.02 + 0.02).toFixed(2)

  // 応援(ありがとうチップ)。評価を送り終えた直後、気持ちが高いこの場面で一度だけ出す。
  // **閉じたら二度と出さない。** 毎回せがむ形にすると、金銭を促す圧に見える。
  const promiseId = isBackendConfigured ? flow.activeThreadId : null
  const [partnerName, setPartnerName] = useState<string | null>(null)
  const [partnerId, setPartnerId] = useState<string | null>(null)
  const [supportOpen, setSupportOpen] = useState(false)
  const [supported, setSupported] = useState<number | null>(null)
  const [dismissed, setDismissed] = useState(false)

  useEffect(() => {
    if (!promiseId) return
    let active = true
    fetchThreadPartner(promiseId)
      .then((p) => {
        if (!active || !p) return
        setPartnerName(p.name)
        setPartnerId(p.userId)
        setSupportOpen(true)
      })
      .catch(() => {
        /* 相手が取れなければ応援は出さない。RESULT自体は表示する */
      })
    return () => {
      active = false
    }
  }, [promiseId])
  return (
    <Screen background={C.fill} style={{ animation: 'scrIn .3s ease both' }}>
      <DotPattern />
      <Confetti />
      <div
        style={{
          position: 'relative',
          flex: 1,
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          justifyContent: 'center',
          gap: 24,
          padding: '0 30px',
        }}
      >
        <span
          style={{
            fontSize: 34,
            color: C.lime,
            letterSpacing: '.06em',
            textShadow: `3px 3px 0 ${C.lavender}`,
            animation: 'popIn .55s cubic-bezier(.2,1.3,.4,1) both',
          }}
        >
          GG!
        </span>
        <div
          style={{
            background: C.deepCard,
            border: `2px solid ${C.lime}`,
            borderRadius: 16,
            padding: 22,
            display: 'flex',
            flexDirection: 'column',
            gap: 16,
            width: '100%',
            animation: 'popIn .55s .1s cubic-bezier(.2,1.3,.4,1) both',
          }}
        >
          <span
            style={{ fontSize: 12, color: C.muted, textAlign: 'center', letterSpacing: '.1em' }}
          >
            ▶ 信用スコアが上がりました
          </span>
          <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'center', gap: 10 }}>
            <span style={{ fontSize: 16, color: '#5A5272' }}>★4.90</span>
            <ArrowRight />
            <span style={{ fontSize: 36, color: C.lime }}>★{newScore}</span>
          </div>
          <div style={{ display: 'flex', gap: 8, justifyContent: 'center' }}>
            {[
              { v: '+1', l: '一緒に遊んだ' },
              { v: '0%', l: 'ドタキャン率' },
              { v: '解放', l: '称号ゲット' },
            ].map((s) => (
              <div
                key={s.l}
                style={{
                  background: C.fill,
                  border: `1.5px solid ${C.deepBorder}`,
                  borderRadius: 8,
                  padding: '9px 12px',
                  display: 'flex',
                  flexDirection: 'column',
                  alignItems: 'center',
                  gap: 2,
                }}
              >
                <span style={{ fontSize: 16, color: C.lime }}>{s.v}</span>
                <span style={{ fontSize: 9, color: C.muted }}>{s.l}</span>
              </div>
            ))}
          </div>
        </div>
        <span style={{ fontSize: 11, color: C.muted, textAlign: 'center', lineHeight: 1.6 }}>
          信頼はアプリの中でだけ積み上がります。
          <br />
          また {partnerName ?? 'みなと'} さんと遊べます。
        </span>
        {/* また遊びたい気持ちがいちばん強いのはこの瞬間。探し直させずに、
            相手のあいている枠をそのまま押せるようにしておく。 */}
        {partnerId && partnerName && (
          <NextSlots flow={flow} hostUserId={partnerId} hostName={partnerName} />
        )}
      </div>
      <div
        style={{
          position: 'relative',
          display: 'flex',
          flexDirection: 'column',
          gap: 10,
          padding: '0 24px 40px',
        }}
      >
        {supported !== null && (
          <span style={{ fontSize: 12, color: C.lime, textAlign: 'center' }}>
            ✓ {supported.toLocaleString()}コインを贈りました
          </span>
        )}
        {/* 一度閉じた人にも、押したくなったときの入口だけは残す */}
        {promiseId && partnerName && supported === null && dismissed && (
          <span
            onClick={() => setSupportOpen(true)}
            style={{ cursor: 'pointer', textAlign: 'center', fontSize: 12, color: C.lavenderText, textDecoration: 'underline' }}
          >
            {partnerName}さんを応援する
          </span>
        )}
        <PitaButton label="ホームにもどる ▶" variant="confirm" full onClick={() => flow.go('home')} />
        <span
          onClick={flow.restart}
          style={{ cursor: 'pointer', textAlign: 'center', fontSize: 12, color: C.muted }}
        >
          最初から見る
        </span>
      </div>
      {supportOpen && promiseId && partnerName && (
        <SupportSheet
          promiseId={promiseId}
          partnerName={partnerName}
          onClose={() => {
            setSupportOpen(false)
            setDismissed(true)
          }}
          onSent={(coins) => {
            setSupported(coins)
            setSupportOpen(false)
          }}
        />
      )}
    </Screen>
  )
}
