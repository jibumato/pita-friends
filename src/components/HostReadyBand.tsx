/**
 * 掲載中なのに、**予約が入らない状態**になっているピタメイトへの帯。
 *
 * ■ なぜ要るか
 *   ピタメイトの設定は「掲載する」を押した時点では完成しない。あと2つ、
 *   **押していないと静かに損をする**設定がある。しかもどちらも
 *   「何も起きない」という形でしか現れないので、**本人からは
 *   「人気が無い」のか「設定が足りない」のかが区別できない。**
 *
 *     対応ゲームが空   … ゲストのリクエストが**1件も届かない**(0120)。
 *                        リクエストは登録ゲームの一致で宛先を絞っているため
 *     あそべる時間が空 … `booking_fits_availability`(0051) は枠を1つも持たない
 *                        相手を「制限なし」として扱うので、**深夜でも予約が入る**
 *
 * ■ もともとデスクトップにしか出ていなかった
 *   枠の帯は `DesktopHero` の中にあり、**スマホのピタメイトには
 *   一度も表示されていなかった。** ピタフレはスマホのPWAなので、
 *   いちばん多い利用者にいちばん届いていなかったことになる。
 *   ここに出して、ホーム（モバイル・デスクトップ両方）から見えるようにする。
 *
 * ■ 出さない場面
 *   掲載していない人・未ログイン・読めなかったとき。
 *   **取得に失敗したら黙る。** 憶測で「未登録です」と言わない。
 *   設定を済ませれば消えるので、ふだんのホームには何も挟まらない。
 */
import { useEffect, useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import { isBackendConfigured } from '../lib/supabase'
import { fetchMyAvailability } from '../lib/queries'

type Missing = { title: string; body: string }

export default function HostReadyBand({
  flow,
  variant = 'card',
}: {
  flow: Flow
  /** 'card' … ホームの本文中（モバイル）。'band' … ヒーロー直下の全幅（デスクトップ） */
  variant?: 'card' | 'band'
}) {
  const signedOut = !isBackendConfigured || flow.userId === null
  const isHost = flow.hostSettings.isHost
  const games = flow.hostSettings.games

  /** 枠の数。ピタメイトのときだけ読む。読めるまで／読めなければ null。 */
  const [slots, setSlots] = useState<number | null>(null)

  useEffect(() => {
    if (signedOut || !isHost || !isBackendConfigured) return
    let active = true
    fetchMyAvailability()
      .then((s) => active && setSlots(s.length))
      .catch(() => active && setSlots(null))
    return () => {
      active = false
    }
  }, [signedOut, isHost])

  if (signedOut || !isHost) return null

  const missing: Missing[] = []
  // ゲームを先に出す。**こちらは「届かない」＝機会がゼロ**で、
  // 枠の未登録（＝望まない時間に入る）より損が大きい
  if (games.length === 0) {
    missing.push({
      title: '対応ゲームが未登録です',
      body: 'ゲストのリクエストは、登録しているゲームが一致する方にだけ届きます。1つも登録がないと、リクエストは1件も届きません。',
    })
  }
  if (slots === 0) {
    missing.push({
      title: 'あそべる時間が未登録です',
      body: '枠が未登録のあいだは、深夜でも予約が入ります。登録すると希望の時間だけになり、枠を開けたことがお気に入りに入れてくれている人に届きます。',
    })
  }
  if (missing.length === 0) return null

  const go = () => flow.go('hostSettings')

  return (
    <div
      style={
        variant === 'band'
          ? {
              flex: 'none',
              background: C.surfaceLavender,
              borderBottom: `1.5px solid ${C.border}`,
              padding: '14px 24px',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              gap: 16,
              flexWrap: 'wrap',
            }
          : {
              background: C.surfaceLavender,
              border: `1.5px solid ${C.lavender}`,
              borderRadius: 12,
              padding: '13px 14px',
              display: 'flex',
              flexDirection: 'column',
              gap: 10,
            }
      }
    >
      <div style={{ display: 'flex', flexDirection: 'column', gap: 9, minWidth: 0 }}>
        {missing.map((m) => (
          <div key={m.title} style={{ display: 'flex', flexDirection: 'column', gap: 3 }}>
            <span style={{ fontSize: variant === 'band' ? 14 : 12.5, color: C.ink }}>{m.title}</span>
            <span style={{ fontSize: 11, color: C.muted, lineHeight: 1.7 }}>{m.body}</span>
          </div>
        ))}
      </div>
      <span
        onClick={go}
        role="button"
        tabIndex={0}
        onKeyDown={(e) => {
          if (e.key === 'Enter' || e.key === ' ') go()
        }}
        style={{
          flex: 'none',
          alignSelf: variant === 'band' ? 'center' : 'flex-start',
          cursor: 'pointer',
          fontSize: 12.5,
          color: C.ctaFg,
          background: C.ctaBg,
          borderRadius: 8,
          padding: '10px 16px',
          whiteSpace: 'nowrap',
        }}
      >
        ピタメイト設定へ
      </span>
    </div>
  )
}
