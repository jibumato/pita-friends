/**
 * ピタフレ Design Tokens (CSS変数ベース / ライト・ダーク対応)
 * 値は CSS カスタムプロパティ(--pf-*)を参照し、テーマは :root[data-theme] で切替。
 * 実値は index.css に定義。ネオブルータリズム: 1.5px ボーダー + ハードシャドウ。
 *
 * ink が担っていた役割を分離:
 *  - ink       : 主要テキスト/前景 (light #453D5C / dark #fff)
 *  - border    : ボーダー           (light #453D5C / dark #6E648C)
 *  - shadowCol : ハードシャドウ      (light #453D5C / dark #6E648C)
 *  - fill      : 濃い塗り(選択チップ/装飾/感情ピーク背景) (両テーマ #453D5C)
 *  - ctaBg/ctaFg : 主要CTA (light 黒地ライム / dark ライム地黒)
 */

export const color = {
  /** 主要テキスト/前景 */
  ink: 'var(--pf-ink)',
  /** ボーダー全般 */
  border: 'var(--pf-border)',
  /** ハードシャドウ色 */
  shadowCol: 'var(--pf-shadow)',
  /** 濃い塗り(選択チップ/装飾/感情ピーク背景)。両テーマで濃色 */
  fill: 'var(--pf-fill)',
  /** 主要CTAの地/文字 */
  ctaBg: 'var(--pf-cta-bg)',
  ctaFg: 'var(--pf-cta-fg)',

  lavender: 'var(--pf-lavender)',
  lavenderHover: '#9D82E0',
  lime: 'var(--pf-lime)',
  deepCard: 'var(--pf-deep-card)',
  deepBorder: 'var(--pf-deep-border)',

  avatarOrange: '#FBD79E',
  avatarAqua: '#B3E5F2',
  avatarPink: '#F5B8CE',
  /** 未読バッジ用の濃い赤。 */
  badge: '#E23B3B',

  muted: 'var(--pf-muted)',
  body: 'var(--pf-body)',
  placeholder: 'var(--pf-placeholder)',
  surface: 'var(--pf-surface)',
  surfaceLavender: 'var(--pf-surface-lav)',
  canvas: 'var(--pf-canvas)',
  /** 面(カード/入力)。ライト白 / ダーク濃カード */
  white: 'var(--pf-card)',
  lavenderText: '#E3DCFF',
  disabledBg: 'var(--pf-disabled-bg)',
  disabledBorder: 'var(--pf-disabled-border)',
  disabledFg: 'var(--pf-disabled-fg)',
  starOff: 'var(--pf-star-off)',
  divider: 'var(--pf-divider)',
} as const

/** アバターに使うパステル5色(テーマ非依存) */
export const avatarColors = [
  color.avatarAqua,
  color.avatarOrange,
  color.avatarPink,
  color.lime,
  color.lavender,
] as const

export const radius = {
  sm: 4,
  md: 8,
  lg: 12,
  xl: 16,
  screen: 27,
  bezel: 38,
} as const

export const shadow = {
  primary: `3px 3px 0 ${color.lavender}`,
  confirm: `3px 3px 0 ${color.shadowCol}`,
  card: `4px 4px 0 ${color.shadowCol}`,
  sm: `2px 2px 0 ${color.shadowCol}`,
  smLavender: `2px 2px 0 ${color.lavender}`,
  device: '0 18px 44px rgba(40,30,80,.28)',
} as const

export const font = {
  family: "'DotGothic16', monospace",
} as const

export const device = {
  outerW: 399,
  outerH: 836,
  innerW: 375,
  innerH: 812,
  pad: 12,
} as const
