import { color as C } from '../theme/tokens'
import { gameMetaOf } from '../content/games'

/**
 * ゲームタイトルのサムネ。
 *
 * 既定ではブランドに合わせた自作タイル(グラデーション+略号)を描く。
 * 許諾済みの画像がある場合のみ、src/content/games.ts の `image` に
 * パスを入れるとそのタイトルだけ画像に切り替わる。
 * 公式のキーアート・ロゴを無断で使わないための作り
 * (詳細は src/content/games.ts の冒頭コメント)。
 */
/** 略号の見た目の横幅(半角=1, 全角=2)から、タイルに収まる文字サイズ比を返す。 */
function fontScale(short: string): number {
  const width = [...short].reduce((n, ch) => n + (/[\x20-\x7e]/.test(ch) ? 1 : 2), 0)
  if (width >= 4) return 0.36
  if (width === 3) return 0.38
  return 0.44
}

export default function GameThumb({ name, size = 26 }: { name: string; size?: number }) {
  const m = gameMetaOf(name)
  const radius = Math.round(size * 0.28)

  if (m.image) {
    return (
      <img
        src={m.image}
        alt=""
        aria-hidden
        width={size}
        height={size}
        style={{
          width: size,
          height: size,
          borderRadius: radius,
          objectFit: 'cover',
          border: `1.5px solid ${C.border}`,
          flex: 'none',
        }}
      />
    )
  }

  return (
    <span
      aria-hidden
      style={{
        width: size,
        height: size,
        flex: 'none',
        borderRadius: radius,
        border: `1.5px solid ${C.border}`,
        background: `linear-gradient(140deg, ${m.from}, ${m.to})`,
        color: '#fff',
        display: 'inline-flex',
        alignItems: 'center',
        justifyContent: 'center',
        // 枠に収まるよう文字幅で縮める。全角は半角2つぶんとして数える
        // (「雑談」のような全角2文字は、半角2文字より横に長い)
        fontSize: size * fontScale(m.short),
        letterSpacing: '-0.02em',
        lineHeight: 1,
        overflow: 'hidden',
      }}
    >
      {m.short}
    </span>
  )
}
