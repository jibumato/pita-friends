import { useEffect, useState } from 'react'
import { color as C } from '../theme/tokens'
import { fetchFastRelease, setFastRelease } from '../lib/queries'

/**
 * 「この人とはすぐ確定でいい」(0062)。
 *
 * プレイ終了から72時間で自動的に確定するが、ゲストが「完了」を押し忘れると
 * その3日ぶん、ピタメイトの入金が遅れる。何度も遊んでいる相手なら毎回
 * 確認する必要も感じていないので、一度選べば以降ずっと24時間で確定する。
 *
 * **これはゲストが自分で選ぶもの。** 72時間はゲストが申し出を出すための
 * 窓でもあり、運営やピタメイトの側から短くしてよいものではない。だから
 *   ・既定は72時間のまま。押した人にだけ効く
 *   ・いつでも外せて、外した瞬間から72時間に戻る(既にある予約にも効く)
 *   ・3回以上遊んだ相手にしか出さない
 * という形にしてある。文言でもそれが伝わるようにする。
 */
export default function FastReleaseToggle({
  hostId,
  hostName,
}: {
  hostId: string
  hostName: string
}) {
  const [hours, setHours] = useState<number | null>(null)
  const [eligible, setEligible] = useState(false)
  const [loaded, setLoaded] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let active = true
    fetchFastRelease(hostId)
      .then((r) => {
        if (!active) return
        setHours(r.hours)
        setEligible(r.eligible)
        setLoaded(true)
      })
      .catch(() => active && setLoaded(true))
    return () => {
      active = false
    }
  }, [hostId])

  // 何度か遊んだ相手にしか出さない。初回から出すと、仕組みを理解する前に押させる
  if (!loaded || !eligible) return null

  const on = hours !== null
  const toggle = () => {
    if (busy) return
    setBusy(true)
    setError(null)
    const next = on ? null : 24
    setFastRelease(hostId, next)
      .then(() => setHours(next))
      .catch(() => setError('設定を変更できませんでした'))
      .finally(() => setBusy(false))
  }

  return (
    <div
      style={{
        background: C.white,
        border: `1.5px solid ${on ? C.lime : C.border}`,
        borderRadius: 8,
        padding: '11px 13px',
        display: 'flex',
        flexDirection: 'column',
        gap: 7,
      }}
    >
      <div
        onClick={toggle}
        role="button"
        tabIndex={0}
        aria-pressed={on}
        onKeyDown={(e) => {
          if (e.key === 'Enter' || e.key === ' ') toggle()
        }}
        style={{ cursor: busy ? 'default' : 'pointer', display: 'flex', alignItems: 'center', gap: 9 }}
      >
        <span
          aria-hidden
          style={{
            flex: 'none',
            width: 20,
            height: 20,
            borderRadius: 5,
            border: `1.5px solid ${C.border}`,
            background: on ? C.lime : C.white,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            fontSize: 12,
            color: C.ink,
          }}
        >
          {on ? '✓' : ''}
        </span>
        <span style={{ flex: 1, fontSize: 12.5, color: C.ink, lineHeight: 1.5 }}>
          {hostName}さんとの予約は、遊び終わってから<b>24時間</b>で確定してよい
        </span>
      </div>
      <span style={{ fontSize: 10, color: C.muted, lineHeight: 1.7 }}>
        通常は72時間です。短くすると、その分だけ相手に早くコインが渡ります。
        <b>あなたが困りごとを申し出られる期間も短くなります</b>ので、
        安心して遊べる相手にだけ。いつでも外せて、外すとその場で72時間に戻ります
        （通報や申し出をした予約は、この設定にかかわらず確定しません）。
      </span>
      {error && <span style={{ fontSize: 10.5, color: C.avatarPink }}>{error}</span>}
    </div>
  )
}
