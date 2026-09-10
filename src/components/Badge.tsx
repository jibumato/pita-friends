/**
 * Badge — ステータス小バッジ。角丸4px統一。
 * variant: trust(✓本人確認) / online(●オンライン) / pending(確定待ち橙) /
 *          done(確定済み) / tag(ゲームタグ黒地) / rank(ランク薄紫)。
 */
import { color as C } from '../theme/tokens'

export type BadgeVariant = 'trust' | 'online' | 'pending' | 'done' | 'tag' | 'rank'

type BadgeProps = {
  variant?: BadgeVariant
  label?: string
}

/**
 * ⚠️ 淡い固定色（lime・avatarOrange）を bg にする種別の fg は **必ず `onPale`**。
 *    `ink` はダークで白になるので、淡色の上に白文字が載って読めなくなる
 *    （2026-09 のレビューで実際にそうなっていた。詳細は tokens.ts の onPale）。
 */
const variantMap: Record<BadgeVariant, { fg: string; bg: string; border: string; prefix: string }> =
  {
    trust: { fg: C.onPale, bg: C.lime, border: C.ink, prefix: '✓ ' },
    online: { fg: C.lavender, bg: C.surfaceLavender, border: C.lavender, prefix: '● ' },
    pending: { fg: C.onPale, bg: C.avatarOrange, border: C.ink, prefix: '' },
    done: { fg: C.onPale, bg: C.lime, border: C.ink, prefix: '' },
    tag: { fg: C.lime, bg: C.ink, border: C.ink, prefix: '' },
    rank: { fg: C.ink, bg: C.surfaceLavender, border: C.ink, prefix: '' },
  }

const defaults: Record<BadgeVariant, string> = {
  trust: '本人確認済み',
  online: 'オンライン',
  pending: '確定待ち',
  done: '確定済み',
  tag: 'Apex',
  rank: 'ゴールドⅡ',
}

export default function Badge({ variant = 'trust', label }: BadgeProps) {
  const s = variantMap[variant] ?? variantMap.trust
  return (
    <span
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        gap: 4,
        fontFamily: "'DotGothic16', monospace",
        fontSize: 10.5,
        color: s.fg,
        background: s.bg,
        border: `1.5px solid ${s.border}`,
        padding: '3px 9px',
        borderRadius: 4,
        whiteSpace: 'nowrap',
      }}
    >
      {s.prefix + (label ?? defaults[variant])}
    </span>
  )
}
