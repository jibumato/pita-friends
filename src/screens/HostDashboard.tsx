import { useEffect, useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { SubHeader, Card } from '../components/Ui'
import { Coin } from '../components/Icon'
import { isBackendConfigured } from '../lib/supabase'
import { fetchHostDashboard, type HostDashboard as Data } from '../lib/queries'

/**
 * ホスト向けダッシュボード。
 *
 * 目的は「次に何をすれば手取りが増えるか」が1画面で分かること。
 * 表示するのは**自分自身の実績だけ**で、他人との金額順位は出さない
 * (弁護士Q11-d: 投げ銭・人気ランキングは出会い系規制上のリスクが高い)。
 */

/**
 * パディング付きのカード。Ui の Card は枠だけで余白を持たないため、
 * そのまま文字を入れると1行目が枠線に重なる。
 */
function Panel({ children }: { children: React.ReactNode }) {
  return (
    <Card>
      <div style={{ padding: '13px 15px', display: 'flex', flexDirection: 'column', gap: 9 }}>
        {children}
      </div>
    </Card>
  )
}

const yen = (n: number) => '¥' + Math.round(n).toLocaleString('ja-JP')
const pct = (n: number) => (n * 100).toFixed(1) + '%'

function Row({ label, value, strong }: { label: string; value: string; strong?: boolean }) {
  return (
    <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', gap: 10 }}>
      <span style={{ fontSize: 11.5, color: C.muted }}>{label}</span>
      <span
        style={{
          fontSize: strong ? 17 : 13,
          color: C.ink,
          fontVariantNumeric: 'tabular-nums',
        }}
      >
        {value}
      </span>
    </div>
  )
}

/** 次のティアまでの進捗。到達後にいくら手取りが増えるかまで出す。 */
function TierGoal({ d }: { d: Data }) {
  if (d.tier.nextBound == null || d.tier.remainingCoins == null) {
    return (
      <Panel>
        <span style={{ fontSize: 12, color: C.ink, lineHeight: 1.7 }}>
          最上位の手数料 <b>{pct(d.tier.currentRate)}</b> に到達しています。
        </span>
      </Panel>
    )
  }
  const progress = d.tier.nextBound > 0 ? Math.min(1, d.ticketCoins / d.tier.nextBound) : 0
  // 1万コインぶん多く遊ばれたときの手取り差(到達前 → 到達後)
  const gainPer10k = d.tier.nextRate == null ? 0 : (d.tier.currentRate - d.tier.nextRate) * 10000
  return (
    <Panel>
      <>
        <span style={{ fontSize: 11, color: C.muted }}>次の手数料ティアまで</span>
        <div
          style={{
            height: 10,
            borderRadius: 5,
            background: C.divider,
            overflow: 'hidden',
          }}
          role="progressbar"
          aria-valuenow={Math.round(progress * 100)}
          aria-valuemin={0}
          aria-valuemax={100}
          aria-label="次のティアまでの進捗"
        >
          <div style={{ width: `${progress * 100}%`, height: '100%', background: C.lavender }} />
        </div>
        <span style={{ fontSize: 12.5, color: C.ink, lineHeight: 1.7 }}>
          あと <b>{yen(d.tier.remainingCoins)}</b> で、手数料が{' '}
          <b>
            {pct(d.tier.currentRate)} → {pct(d.tier.nextRate ?? 0)}
          </b>{' '}
          になります。
        </span>
        {gainPer10k > 0 && (
          <span style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.7 }}>
            到達後は、1万コインぶん遊ばれるごとの手取りが {yen(gainPer10k)} 増えます。
          </span>
        )}
      </>
    </Panel>
  )
}

/** 日別の売上。棒の高さだけの簡素な表示にする(小さい画面で軸を描くと読めないため)。 */
function DailyBars({ daily }: { daily: Data['daily'] }) {
  if (daily.length === 0) {
    return (
      <span style={{ fontSize: 11, color: C.muted }}>
        今月はまだ確定した予約がありません。
      </span>
    )
  }
  const max = Math.max(...daily.map((d) => d.coins), 1)
  const byDay = new Map(daily.map((d) => [d.day, d.coins]))
  const days = Array.from({ length: 31 }, (_, i) => i + 1)
  return (
    <div style={{ display: 'flex', alignItems: 'flex-end', gap: 2, height: 78 }}>
      {days.map((day) => {
        const coins = byDay.get(day) ?? 0
        return (
          <div
            key={day}
            title={`${day}日 ${yen(coins)}`}
            style={{
              flex: 1,
              height: `${(coins / max) * 100}%`,
              minHeight: coins > 0 ? 3 : 1,
              background: coins > 0 ? C.lavender : C.divider,
              borderRadius: 2,
            }}
          />
        )
      })}
    </div>
  )
}

/** 曜日×時間帯のリクエスト分布。濃いほど埋まりやすい。 */
function Heatmap({ cells }: { cells: Data['heatmap'] }) {
  if (cells.length === 0) {
    return (
      <span style={{ fontSize: 11, color: C.muted }}>
        直近4週にリクエストがまだありません。
      </span>
    )
  }
  const hours = Array.from({ length: 8 }, (_, i) => 16 + i) // 16〜23時
  const dows = [1, 2, 3, 4, 5, 6, 7]
  const label = ['月', '火', '水', '木', '金', '土', '日']
  const map = new Map(cells.map((c) => [`${c.dow}-${c.hour}`, c.count]))
  const max = Math.max(...cells.map((c) => c.count), 1)
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 3 }}>
      <div style={{ display: 'flex', gap: 3, paddingLeft: 22 }}>
        {hours.map((h) => (
          <span key={h} style={{ flex: 1, fontSize: 8.5, color: C.muted, textAlign: 'center' }}>
            {h}
          </span>
        ))}
      </div>
      {dows.map((dow, i) => (
        <div key={dow} style={{ display: 'flex', gap: 3, alignItems: 'center' }}>
          <span style={{ width: 19, fontSize: 9.5, color: C.muted, textAlign: 'right' }}>
            {label[i]}
          </span>
          {hours.map((h) => {
            const v = map.get(`${dow}-${h}`) ?? 0
            return (
              <div
                key={h}
                title={`${label[i]}曜 ${h}時台: ${v}件`}
                style={{
                  flex: 1,
                  height: 15,
                  borderRadius: 3,
                  background: v === 0 ? C.divider : C.lavender,
                  opacity: v === 0 ? 1 : 0.25 + (v / max) * 0.75,
                }}
              />
            )
          })}
        </div>
      ))}
    </div>
  )
}

function replyLabel(seconds: number | null): string {
  if (seconds == null) return '—'
  if (seconds < 60) return `${Math.round(seconds)}秒`
  if (seconds < 3600) return `${Math.round(seconds / 60)}分`
  return `${(seconds / 3600).toFixed(1)}時間`
}

export default function HostDashboard({ flow }: { flow: Flow }) {
  const [data, setData] = useState<Data | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    if (!isBackendConfigured) {
      setLoading(false)
      return
    }
    let active = true
    fetchHostDashboard()
      .then((d) => {
        if (active) setData(d)
      })
      .catch((e) => {
        if (active) setError(e instanceof Error ? e.message : '集計を取得できませんでした')
      })
      .finally(() => {
        if (active) setLoading(false)
      })
    return () => {
      active = false
    }
  }, [])

  return (
    <Screen background={C.surface}>
      <StatusBar time="21:45" />
      <SubHeader title="ホストの成績" onBack={() => flow.go('mypage')} />
      <div
        className="pita-scroll"
        style={{
          flex: 1,
          overflowY: 'auto',
          display: 'flex',
          flexDirection: 'column',
          gap: 12,
          padding: '4px 20px 30px',
        }}
      >
        {loading && <span style={{ fontSize: 12, color: C.muted }}>読み込み中…</span>}

        {!loading && !isBackendConfigured && (
          <Panel>
            <span style={{ fontSize: 12, color: C.muted, lineHeight: 1.8 }}>
              成績はログインすると表示されます。
            </span>
          </Panel>
        )}

        {error && (
          <Panel>
            <span style={{ fontSize: 12, color: C.avatarPink, lineHeight: 1.8 }}>{error}</span>
          </Panel>
        )}

        {data && (
          <>
            {/* 今月の手取り */}
            <Panel>
              <>
                <span style={{ fontSize: 11, color: C.muted }}>今月の手取り</span>
                <div style={{ display: 'flex', alignItems: 'center', gap: 7 }}>
                  <Coin size={20} />
                  <span
                    style={{
                      fontSize: 30,
                      color: C.ink,
                      lineHeight: 1.15,
                      fontVariantNumeric: 'tabular-nums',
                    }}
                  >
                    {data.netCoins.toLocaleString('ja-JP')}
                  </span>
                </div>
                <span style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.7 }}>
                  売上 {yen(data.grossCoins)} ・ 手数料 {yen(data.feeCoins)}(実効{' '}
                  {pct(data.effectiveRate)})
                </span>
              </>
            </Panel>

            <TierGoal d={data} />

            {/* 内訳 */}
            <Panel>
              <>
                <span style={{ fontSize: 11, color: C.muted }}>売上の内訳</span>
                <Row label="予約(チケット)" value={yen(data.ticketCoins)} />
                <Row label="ありがとうギフト" value={yen(data.giftCoins)} />
                <div style={{ height: 1, background: C.divider }} />
                <Row label="手取り" value={yen(data.netCoins)} strong />
              </>
            </Panel>

            {/* 日別 */}
            <Panel>
              <>
                <span style={{ fontSize: 11, color: C.muted }}>日別の売上</span>
                <DailyBars daily={data.daily} />
              </>
            </Panel>

            {/* 指名リピート */}
            <Panel>
              <>
                <span style={{ fontSize: 11, color: C.muted }}>指名リピート</span>
                <Row label="リピート率(金額ベース)" value={pct(data.repeat.repeatRate)} strong />
                <Row
                  label="リピーター / 新規"
                  value={`${data.repeat.repeaterGuests}人 / ${data.repeat.newGuests}人`}
                />
                <span style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.7 }}>
                  同じ方からの2回目以降のご予約は、手数料が3pt引きになります。
                  リピートが増えるほど手取りの割合が上がります。
                </span>
              </>
            </Panel>

            {/* 応答 */}
            <Panel>
              <>
                <span style={{ fontSize: 11, color: C.muted }}>リクエストへの応答</span>
                <Row label="成約率" value={pct(data.response.approvalRate)} strong />
                <Row
                  label="承諾 / 受信"
                  value={`${data.response.approved}件 / ${data.response.requests}件`}
                />
                <Row label="返信までの中央値" value={replyLabel(data.response.medianReplySeconds)} />
              </>
            </Panel>

            {/* 時間帯 */}
            <Panel>
              <>
                <span style={{ fontSize: 11, color: C.muted }}>
                  リクエストが多い時間帯(直近4週)
                </span>
                <Heatmap cells={data.heatmap} />
                <span style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.7 }}>
                  濃いマスほどリクエストが届いている時間帯です。ここに合わせて
                  「今すぐ遊べる」にしておくと、成約が増えやすくなります。
                </span>
              </>
            </Panel>
          </>
        )}
      </div>
    </Screen>
  )
}
