/** デスクトップ専用ヒーローバンド。ホーム/さがす画面の上部に共通表示。
 *  コピー・演出はスクリーンショットでのユーザー art-direction を経て確定した内容をそのまま実装。 */
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'

export default function DesktopHero({ flow }: { flow: Flow }) {
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
          onClick={() => flow.go('search')}
          role="button"
          tabIndex={0}
          onKeyDown={(e) => {
            if (e.key === 'Enter' || e.key === ' ') flow.go('search')
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
          ▶ フレンドをさがす
        </span>
      </div>
    </div>
  )
}
