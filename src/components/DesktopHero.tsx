/**
 * デスクトップ専用ヒーロー。ホーム画面の上部に表示。
 *
 * ■ 初めて来た人と、常連とで出すものを分ける
 *   ヒーローの仕事は「初めて来た人にサービスを説明する」こと。一度登録した人に
 *   480pxの説明を毎回見せると、推し・通知・次の予約が全部その下にあるので
 *   ただの遠回りになる。
 *
 *   しかも以前ログイン済みに出していた「フレンドをさがす」は、
 *   直下の「ゲーム・ジャンルからさがす」・トップバーの検索欄・サイドバーの
 *   「さがす」と**3重に重なっていて**、押すと絞り込み前の空の検索へ後退していた。
 *
 *   なので:
 *     未ログイン(とデモ) → 大ヒーローのまま。説明して登録へ送る
 *     ログイン済み       → その人が**まだやっていない一手**だけを細い帯で出す。
 *                          無ければ何も出さない(トップバーにロゴがあるので、
 *                          ブランドのために場所を取る必要もない)
 *
 * ■ ログイン済みに出す一手は、ピタメイトの「あそべる時間」
 *   枠の登録はこの人しかできず、しかも効果が大きい:
 *     ・**枠が未登録だと、いつでも予約が入る。** `booking_fits_availability` は
 *       枠を1つも持たない相手を「制限なし」として扱う(0051)。深夜でも入る
 *     ・**枠を増やすと、推してくれている人に通知が届く**(0054。24時間に1回まで)
 *     ・常連への先行予約(0057)も枠がある前提の仕組み
 *
 *   ゲストには出さない。相手を選ぶ導線は下の一覧そのもので、
 *   ボタンを足すと4重目になる。
 */
import { useEffect, useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import { isBackendConfigured } from '../lib/supabase'
import { fetchMyAvailability } from '../lib/queries'

export default function DesktopHero({ flow }: { flow: Flow }) {
  // バックエンド未接続(デモ)は「初めて来た人」として扱う。説明を見せる場面なので、
  // 常連向けの細い帯にはしない。
  const firstTime = !isBackendConfigured || flow.userId === null
  const isHost = flow.hostSettings.isHost

  // 枠の数。ピタメイトのときだけ読む。読めるまでは null
  const [slots, setSlots] = useState<number | null>(null)

  useEffect(() => {
    if (firstTime || !isHost || !isBackendConfigured) return
    let active = true
    fetchMyAvailability()
      .then((s) => active && setSlots(s.length))
      // 取れなくても帯は出す(文言だけ「枠あり」の側に寄せる)。ここで消すと
      // 「枠が無いのに何も言われない」が起きうる
      .catch(() => active && setSlots(null))
    return () => {
      active = false
    }
  }, [firstTime, isHost])

  if (firstTime) return <FullHero flow={flow} />
  if (!isHost) return null
  return <HostBand slots={slots} onGo={() => flow.go('hostSettings')} />
}

// ------------------------------------------------------------
// ログイン済みのピタメイト向け・細い帯
// ------------------------------------------------------------

function HostBand({ slots, onGo }: { slots: number | null; onGo: () => void }) {
  // slots===null は読み込み中か失敗。**高さを変えないために帯は先に出す**
  // (あとから現れると下の内容が押し下げられる)。文言だけ差し替える。
  const empty = slots === 0
  const label = empty ? '▶ あそべる時間を登録する' : '▶ あそべる時間を追加する'
  const sub = empty
    ? '枠が未登録のあいだは、深夜でも予約が入ります。登録すると希望の時間だけになります。'
    : '枠を増やすと、推してくれている人に通知が届きます（24時間に1回まで）。'

  return (
    <div
      style={{
        flex: 'none',
        background: empty ? C.surfaceLavender : C.surface,
        borderBottom: `1.5px solid ${C.border}`,
        padding: '14px 24px',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        gap: 16,
        flexWrap: 'wrap',
      }}
    >
      <div style={{ display: 'flex', flexDirection: 'column', gap: 3, minWidth: 0 }}>
        <span style={{ fontSize: 14, color: C.ink }}>
          {empty ? 'あそべる時間が未登録です' : '今週の枠は埋まっていませんか？'}
        </span>
        <span style={{ fontSize: 11.5, color: C.muted, lineHeight: 1.7 }}>{sub}</span>
      </div>
      <span
        onClick={onGo}
        role="button"
        tabIndex={0}
        onKeyDown={(e) => {
          if (e.key === 'Enter' || e.key === ' ') onGo()
        }}
        style={{
          cursor: 'pointer',
          flex: 'none',
          fontSize: 14,
          color: C.ink,
          background: C.lime,
          border: `1.5px solid ${C.border}`,
          borderRadius: 10,
          boxShadow: `3px 3px 0 ${C.border}`,
          padding: '11px 20px',
        }}
      >
        {label}
      </span>
    </div>
  )
}

// ------------------------------------------------------------
// 未ログイン向け・大ヒーロー
// ------------------------------------------------------------

/**
 * コピー・演出はスクリーンショットでのユーザー art-direction を経て確定した内容。
 * **勝手に文言を変えないこと。**
 */
function FullHero({ flow }: { flow: Flow }) {
  const go = () => flow.go('signUp')
  return (
    <div
      style={{
        position: 'relative',
        flex: 'none',
        minHeight: 480,
        borderBottom: `1.5px solid ${C.border}`,
        overflow: 'hidden',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
      }}
    >
      <img
        src="/hero.webp"
        alt="オンラインで一緒に遊ぶ2人"
        style={{
          position: 'absolute',
          inset: 0,
          width: '100%',
          height: '100%',
          objectFit: 'cover',
          objectPosition: 'center 38%',
          display: 'block',
        }}
      />
      <div
        aria-hidden
        style={{
          position: 'absolute',
          inset: 0,
          background:
            `linear-gradient(0deg, rgba(255,255,255,.4) 0%, rgba(255,255,255,0) 30%),` +
            `linear-gradient(90deg, rgba(255,255,255,0) 0%, rgba(255,255,255,.7) 28%, rgba(255,255,255,.7) 72%, rgba(255,255,255,0) 100%)`,
        }}
      />
      <div
        style={{
          position: 'relative',
          color: C.ink,
          maxWidth: 640,
          textAlign: 'center',
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          padding: '40px 0',
        }}
      >
        <img
          src="/logo.webp"
          alt="ピタフレ"
          style={{
            height: 168,
            display: 'block',
            filter: 'drop-shadow(0 2px 6px rgba(255,255,255,.85))',
          }}
        />
        <h1
          style={{
            margin: '12px 0 10px',
            fontSize: 34,
            fontWeight: 800,
            letterSpacing: '.01em',
            lineHeight: 1.32,
            color: C.ink,
            textShadow: '0 2px 3px rgba(255,255,255,.85), 0 0 20px rgba(255,255,255,.9), 0 0 40px rgba(255,255,255,.6)',
          }}
        >
          息が"ピタッ"とあう
          <br />
          ゲーム友達、見つけよう！
        </h1>
        <p
          style={{
            margin: 0,
            fontSize: 15,
            fontWeight: 600,
            color: C.ink,
            lineHeight: 1.8,
            textShadow: '0 1px 3px rgba(255,255,255,.85), 0 0 14px rgba(255,255,255,.75)',
          }}
        >
          ゲーム・時間帯・好みのプレイスタイルで、ピタッと合う相手を検索。
          <br />
          最短30分から一緒にゲームや通話を楽しもう♪
        </p>
        <span
          onClick={go}
          role="button"
          tabIndex={0}
          onKeyDown={(e) => {
            if (e.key === 'Enter' || e.key === ' ') go()
          }}
          style={{
            cursor: 'pointer',
            display: 'inline-block',
            marginTop: 22,
            fontSize: 18,
            fontWeight: 800,
            letterSpacing: '.02em',
            color: C.ink,
            background: C.lime,
            border: `2.5px solid ${C.border}`,
            borderRadius: 12,
            boxShadow: `5px 5px 0 ${C.border}`,
            padding: '16px 38px',
            animation: 'heroPulse 2.2s ease-in-out infinite',
          }}
        >
          ▶ 無料ではじめる
        </span>
      </div>
    </div>
  )
}
