/**
 * デスクトップ専用ヒーロー。ホーム画面の上部に表示。
 *
 * ■ ヒーローは**必ず出す**
 *   ログイン済みでは出さない実装を一度入れたが、ビジュアルが寂しくなるとの
 *   判断で常時表示に戻した。コピー・演出はスクリーンショットでの
 *   art-direction で確定したもので、**一字も変えない。**
 *
 * ■ 変えるのはCTAだけ
 *   以前ログイン済みに出していた「フレンドをさがす」には2つ問題があった。
 *     ・「フレンド」が商品と合っていない。ピタフレは**特定の人の時間を買う**
 *       サービスで、無料で友達を作る場ではない。ここで友達を約束すると、
 *       コインが必要だと分かった時点で落ちる
 *     ・直下の「ゲーム・ジャンルからさがす」・トップバーの検索欄・
 *       サイドバーの「さがす」と重なっている
 *   後者は「ヒーローを常に出す以上、CTAが無いと未完成に見える」ほうを取って
 *   許容し、前者だけ直して「ピタメイトをさがす」にした。
 *   (行き先の さがす画面は空の検索ではなく、fetchDiscoverableHosts で
 *    掲載中の全ピタメイトを出す。押して情報が減るわけではない)
 *
 * ■ 未ログインの主CTAは「無料で登録する」
 *   「無料ではじめる」だと**サービス全体が無料に読める。** 無料なのは
 *   登録だけで、遊ぶにはコインが要る。景表法(有利誤認)の観点から、
 *   無料の範囲を「登録」に絞って言い切る。
 *
 * ■ 副CTAで「ピタメイトになる」を出す
 *   いま足りないのは供給(遊べる相手)で、需要ではない。ヒーローが
 *   「さがす」しか言わないと、来た人は全員ゲスト側にしか流れない。
 *   ただし**主CTAと張り合わせない。** 副CTAは枠線も影も持たない
 *   ただの文字リンクにして、視線の順番を主CTA→副CTAに固定する。
 *
 *   **金額(20%〜/12%〜)はここに書かない。** 「20%〜」は
 *   「20%以上」と読めて実際と逆向きだし、12%はGMVが月30万円を
 *   超えてからの数字なので、条件を書かずに出すと有利誤認になる。
 *
 * ■ 副CTAの行き先(未ログインのとき)
 *   未ログインでは主CTAも副CTAも登録画面にしか行けない。同じ画面に
 *   着地する2つのボタンは押した人から見ると壊れているので、
 *   hostIntent.ts に意思を預けて、登録が終わってホームに着いた1回だけ
 *   ピタメイト設定へ送る(消費はHome側)。
 *
 * ■ 枠が未登録のピタメイトにだけ、ヒーローの下に細い帯を出す
 *   これは**実害のある状態**なので別扱いにしている:
 *     ・`booking_fits_availability` は枠を1つも持たない相手を「制限なし」として
 *       扱う(0051)。つまり**枠が未登録だと深夜でも予約が入る**
 *     ・枠を増やすとお気に入りに入れてくれている人に通知が届く(0054。24時間に1回まで)
 *     ・常連への先行予約(0057)も枠がある前提の仕組み
 *   帯は枠を登録すれば消える。それ以外の状態では出さないので、
 *   ふだんのホームはヒーロー→内容のままで余計なものが挟まらない。
 */
import { useEffect, useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import { isBackendConfigured } from '../lib/supabase'
import { fetchMyAvailability } from '../lib/queries'
import { markHostIntent } from '../lib/hostIntent'

export default function DesktopHero({ flow }: { flow: Flow }) {
  // バックエンド未接続(デモ)は未ログイン扱い。説明を見せる場面なので
  const signedOut = !isBackendConfigured || flow.userId === null
  const isHost = flow.hostSettings.isHost

  // 枠の数。ピタメイトのときだけ読む。読めるまでは null
  const [slots, setSlots] = useState<number | null>(null)

  useEffect(() => {
    if (signedOut || !isHost || !isBackendConfigured) return
    let active = true
    fetchMyAvailability()
      .then((s) => active && setSlots(s.length))
      // 取れなかったときは帯を出さない。憶測で「未登録です」と言わない
      .catch(() => active && setSlots(null))
    return () => {
      active = false
    }
  }, [signedOut, isHost])

  return (
    <>
      <FullHero
        label={signedOut ? '▶ 無料で登録する' : '▶ ピタメイトをさがす'}
        onGo={() => flow.go(signedOut ? 'signUp' : 'search')}
        // すでにピタメイトの人には出さない(その人にとっては用の無い誘い)
        sub={
          signedOut
            ? {
                label: 'ピタメイトとして登録する ›',
                onGo: () => {
                  markHostIntent()
                  flow.go('signUp')
                },
              }
            : isHost
              ? null
              : { label: 'ピタメイトになる ›', onGo: () => flow.go('hostSettings') }
        }
      />
      {/* 枠が未登録のピタメイトにだけ。登録すれば消える */}
      {!signedOut && isHost && slots === 0 && (
        <NoSlotsBand onGo={() => flow.go('hostSettings')} />
      )}
    </>
  )
}

// ------------------------------------------------------------
// 枠が未登録のピタメイトにだけ出す帯
// ------------------------------------------------------------

/**
 * ヒーローの直下。**枠を登録すれば消える**ので、ふだんは邪魔にならない。
 * 「深夜でも予約が入る」は 0051 の実際の挙動
 * (`booking_fits_availability` は枠を1つも持たない相手を制限なしとして扱う)。
 */
function NoSlotsBand({ onGo }: { onGo: () => void }) {
  return (
    <div
      style={{
        flex: 'none',
        background: C.surfaceLavender,
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
        <span style={{ fontSize: 14, color: C.ink }}>あそべる時間が未登録です</span>
        <span style={{ fontSize: 11.5, color: C.muted, lineHeight: 1.7 }}>
          枠が未登録のあいだは、深夜でも予約が入ります。登録すると希望の時間だけになり、
          枠を開けたことがお気に入りに入れてくれている人に届きます。
        </span>
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
        ▶ あそべる時間を登録する
      </span>
    </div>
  )
}

// ------------------------------------------------------------
// 大ヒーロー(常に出す)
// ------------------------------------------------------------

type Cta = { label: string; onGo: () => void }

/**
 * コピー・演出はスクリーンショットでのユーザー art-direction を経て確定した内容。
 * **勝手に文言を変えないこと。** 差し替えてよいのはCTAのラベルと行き先だけ。
 */
function FullHero({ label, onGo, sub }: { label: string; onGo: () => void; sub: Cta | null }) {
  const go = onGo
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
          {label}
        </span>
        {/*
          副CTA。**枠線も影も持たせない。** 主CTAと同じ強さで置くと
          「どちらを押せばいいのか」が生まれて、両方の反応が落ちる。
        */}
        {sub && (
          <span
            onClick={sub.onGo}
            role="button"
            tabIndex={0}
            onKeyDown={(e) => {
              if (e.key === 'Enter' || e.key === ' ') sub.onGo()
            }}
            style={{
              cursor: 'pointer',
              // 主CTAには 5px の影があるので、その分を足して間隔を確保する
              marginTop: 18,
              fontSize: 13.5,
              fontWeight: 700,
              color: C.ink,
              textDecoration: 'underline',
              textUnderlineOffset: 3,
              textShadow: '0 1px 3px rgba(255,255,255,.9), 0 0 12px rgba(255,255,255,.85)',
            }}
          >
            {sub.label}
          </span>
        )}
      </div>
    </div>
  )
}
