/**
 * ペアで予約する(0126)。
 *
 * ゲームは人数単位(Apex 3人・Valorant 5人・マリカー4人)で、ゲスト1人＋
 * ピタメイト1人では卓が埋まらない。**ペア相手**(0125・両方の承認で成立)の
 * 2人を、ゲストがまとめて1回で予約できるようにする。
 *
 * ⚠️ **成立後の各予約は、ふつうの1対1予約と完全に同じ。** 承諾・チェック
 * イン・完了・キャンセル・手数料・GMV・リピート判定は、ホストごとに独立
 * して従来どおり流れる(0126のSQL側コメント参照)。この画面が作るのは
 * 「同じ時刻で2件同時に申し込む」ところまで。
 *
 * ⚠️ 今回のリリース範囲は新規予約のみ。時間の候補はサーバに問い合わせず
 * (2人の空きの積集合を取る専用APIが無い)、選んだ時刻がどちらかで
 * 空いていなければ、申し込み時にサーバがエラーで教える形にしている。
 */
import { useEffect, useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { SubHeader } from '../components/Ui'
import { coinsForDuration, coinsPer30, durationLabel, BOOKING_DURATIONS } from '../flow'
import { CANCELLATION_POLICY_VERSION } from '../content/bookingPolicy'
import { fetchPublicProfile, createPairedBooking, type PublicProfile } from '../lib/queries'

const DOW = ['日', '月', '火', '水', '木', '金', '土']

/** 「9/7(日)」。 */
function dayKey(d: Date): string {
  return `${d.getMonth() + 1}/${d.getDate()}(${DOW[d.getDay()]})`
}

/** 今から先、毎正時の候補を日ごとにまとめる(RequestInbox.tsxと同じ考え方)。 */
function hourlyCandidates(days: number, minLeadMinutes: number): [string, Date[]][] {
  const first = new Date()
  first.setHours(first.getHours() + 1, 0, 0, 0)
  const earliest = Date.now() + minLeadMinutes * 60_000
  const until = Date.now() + days * 86_400_000
  const out: [string, Date[]][] = []
  for (let t = first.getTime(); t < until; t += 3600_000) {
    if (t < earliest) continue
    const d = new Date(t)
    const key = dayKey(d)
    const last = out[out.length - 1]
    if (last && last[0] === key) last[1].push(d)
    else out.push([key, [d]])
  }
  return out
}

type HostMini = Pick<PublicProfile, 'userId' | 'nickname' | 'avatarInitial' | 'avatarColor' | 'hourlyRate'>

function HostChip({ host }: { host: HostMini | null }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 9, flex: 1, minWidth: 0 }}>
      <div
        style={{
          flex: 'none',
          width: 40,
          height: 40,
          borderRadius: 8,
          background: host?.avatarColor ?? C.fill,
          border: `1.5px solid ${C.border}`,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          fontSize: 16,
          color: C.onPale,
        }}
      >
        {host?.avatarInitial ?? '?'}
      </div>
      <div style={{ display: 'flex', flexDirection: 'column', minWidth: 0 }}>
        <span style={{ fontSize: 13, color: C.ink, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
          {host?.nickname ?? '読み込み中…'}
        </span>
        {host && <span style={{ fontSize: 10.5, color: C.muted }}>{coinsPer30(host.hourlyRate)}コイン/30分</span>}
      </div>
    </div>
  )
}

export default function PairBooking({ flow }: { flow: Flow }) {
  const target = flow.pairBookingTarget
  const [hostA, setHostA] = useState<HostMini | null>(null)
  const [hostB, setHostB] = useState<HostMini | null>(null)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [duration, setDuration] = useState(60)
  const [picked, setPicked] = useState<Date | null>(null)
  const [submitting, setSubmitting] = useState(false)
  const [submitError, setSubmitError] = useState<string | null>(null)
  const [done, setDone] = useState(false)

  useEffect(() => {
    if (!target) return
    let active = true
    Promise.all([fetchPublicProfile(target.hostAId), fetchPublicProfile(target.hostBId)])
      .then(([a, b]) => {
        if (!active) return
        if (!a || !b) {
          setLoadError('お二人の情報を取得できませんでした')
          return
        }
        setHostA(a)
        setHostB(b)
      })
      .catch((e) => active && setLoadError(e instanceof Error ? e.message : '取得に失敗しました'))
    return () => {
      active = false
    }
  }, [target])

  if (!target) {
    // 直接この画面のURLに来た等、対象が無いケース。**ここで止める**
    // (孫の状態を前提にした先の描画で undefined 参照が起きるのを防ぐ)。
    return (
      <Screen background={C.surface}>
        <StatusBar time="21:47" />
        <SubHeader title="ペアで予約" onBack={() => flow.go('home')} />
        <div style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 20 }}>
          <span style={{ fontSize: 12, color: C.muted, textAlign: 'center', lineHeight: 1.8 }}>
            予約する相手が見つかりませんでした。
            <br />
            プロフィールの「ペアで予約する」からやり直してください。
          </span>
        </div>
      </Screen>
    )
  }

  const total = hostA && hostB ? coinsForDuration(hostA.hourlyRate, duration) + coinsForDuration(hostB.hourlyRate, duration) : null
  const candidates = hourlyCandidates(14, 30)

  async function handleSubmit() {
    if (!target || !picked || submitting) return
    setSubmitting(true)
    setSubmitError(null)
    try {
      await createPairedBooking(target.hostAId, target.hostBId, duration, CANCELLATION_POLICY_VERSION, picked)
      setDone(true)
    } catch (e) {
      setSubmitError(e instanceof Error ? e.message : '申し込みに失敗しました')
    } finally {
      setSubmitting(false)
    }
  }

  if (done) {
    return (
      <Screen background={C.surface}>
        <StatusBar time="21:47" />
        <SubHeader title="ペアで予約" onBack={() => flow.go('talkList')} />
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 14, padding: 20 }}>
          <span style={{ fontSize: 32 }}>🤝</span>
          <span style={{ fontSize: 14, color: C.ink, textAlign: 'center' }}>
            2件の申し込みを送信しました
          </span>
          <span style={{ fontSize: 11.5, color: C.muted, textAlign: 'center', lineHeight: 1.8 }}>
            お二人がそれぞれ承諾すると成立します。
            <br />
            どちらか一方が承諾を見送った場合、もう一方も自動的に取り消され、
            <br />
            コインは全額返却されます。
          </span>
          <span
            onClick={() => flow.go('talkList')}
            role="button"
            tabIndex={0}
            onKeyDown={(e) => {
              if (e.key === 'Enter' || e.key === ' ') flow.go('talkList')
            }}
            style={{
              cursor: 'pointer',
              marginTop: 8,
              fontSize: 13,
              color: C.ctaFg,
              background: C.ctaBg,
              borderRadius: 8,
              padding: '11px 24px',
            }}
          >
            トーク一覧へ
          </span>
        </div>
      </Screen>
    )
  }

  return (
    <Screen background={C.surface}>
      <StatusBar time="21:47" />
      <SubHeader title="ペアで予約" onBack={() => flow.go('profile')} />

      <div
        className="pita-scroll"
        style={{ flex: 1, overflowY: 'auto', padding: '4px 20px 24px', display: 'flex', flexDirection: 'column', gap: 16 }}
      >
        <span style={{ fontSize: 11, color: C.muted, lineHeight: 1.7 }}>
          お二人まとめて同じ時間で申し込みます。それぞれの承諾で成立します。
        </span>

        {loadError && (
          <div style={{ background: C.avatarPink, border: `1.5px solid ${C.border}`, borderRadius: 8, padding: '10px 12px', fontSize: 11.5, color: C.onPale }}>
            {loadError}
          </div>
        )}

        <div style={{ display: 'flex', gap: 10, background: C.white, border: `1.5px solid ${C.border}`, borderRadius: 12, padding: 12, boxShadow: `2px 2px 0 ${C.shadowCol}` }}>
          <HostChip host={hostA} />
          <span style={{ fontSize: 16, color: C.muted, alignSelf: 'center' }}>＋</span>
          <HostChip host={hostB} />
        </div>

        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          <span style={{ fontSize: 12.5, color: C.ink }}>長さ</span>
          <div style={{ display: 'flex', gap: 6, overflowX: 'auto' }} className="pita-scroll">
            {BOOKING_DURATIONS.map((min) => {
              const sel = duration === min
              return (
                <span
                  key={min}
                  onClick={() => setDuration(min)}
                  role="button"
                  tabIndex={0}
                  aria-pressed={sel}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter' || e.key === ' ') setDuration(min)
                  }}
                  style={{
                    cursor: 'pointer',
                    flex: 'none',
                    fontSize: 12,
                    color: sel ? C.onPale : C.body,
                    background: sel ? C.lime : C.white,
                    border: `1.5px solid ${C.border}`,
                    padding: '8px 13px',
                    borderRadius: 8,
                    whiteSpace: 'nowrap',
                  }}
                >
                  {durationLabel(min)}
                </span>
              )
            })}
          </div>
        </div>

        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          <span style={{ fontSize: 12.5, color: C.ink }}>いつから</span>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
            {candidates.map(([key, hours]) => (
              <div key={key} style={{ display: 'flex', flexDirection: 'column', gap: 5 }}>
                <span style={{ fontSize: 10.5, color: C.muted }}>{key}</span>
                <div className="pita-scroll" style={{ display: 'flex', gap: 6, overflowX: 'auto', paddingBottom: 2 }}>
                  {hours.map((d) => {
                    const sel = picked?.getTime() === d.getTime()
                    return (
                      <span
                        key={d.toISOString()}
                        onClick={() => setPicked(d)}
                        role="button"
                        tabIndex={0}
                        aria-pressed={sel}
                        onKeyDown={(e) => {
                          if (e.key === 'Enter' || e.key === ' ') setPicked(d)
                        }}
                        style={{
                          flex: 'none',
                          cursor: 'pointer',
                          fontSize: 12,
                          color: sel ? C.onPale : C.body,
                          background: sel ? C.lime : C.white,
                          border: `1.5px solid ${C.border}`,
                          padding: '9px 13px',
                          borderRadius: 8,
                          whiteSpace: 'nowrap',
                        }}
                      >
                        {d.getHours()}:00
                      </span>
                    )
                  })}
                </div>
              </div>
            ))}
          </div>
        </div>

        {total !== null && (
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', fontSize: 12.5, color: C.ink }}>
            <span>合計</span>
            <span>{total} コイン(お二人分)</span>
          </div>
        )}

        {submitError && (
          <div style={{ background: C.avatarPink, border: `1.5px solid ${C.border}`, borderRadius: 8, padding: '10px 12px', fontSize: 11.5, color: C.onPale }}>
            {submitError}
          </div>
        )}

        <span
          onClick={() => void handleSubmit()}
          role="button"
          tabIndex={0}
          onKeyDown={(e) => {
            if (e.key === 'Enter' || e.key === ' ') void handleSubmit()
          }}
          style={{
            cursor: submitting || !picked || !hostA || !hostB ? 'not-allowed' : 'pointer',
            opacity: submitting || !picked || !hostA || !hostB ? 0.5 : 1,
            textAlign: 'center',
            fontSize: 13,
            color: C.ctaFg,
            background: C.ctaBg,
            borderRadius: 8,
            padding: '13px 0',
          }}
        >
          {submitting ? '送信中…' : 'この内容でまとめて申し込む'}
        </span>
      </div>
    </Screen>
  )
}
