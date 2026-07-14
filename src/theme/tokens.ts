/**
 * ピタフレ Design Tokens
 * ハンドオフ資料「Design Tokens」のペール改定後の値を忠実に定数化。
 * ネオブルータリズム風: 1.5px solid インク色ボーダー + ぼかし無しのハードシャドウ。
 */

export const color = {
  /** インク: ボーダー全般 / 主要テキスト / ハードシャドウ / 感情ピーク背景 */
  ink: '#453D5C',
  /** ラベンダー(プライマリ): 強調カード背景 / ヘッダー / スコアバッジ / リンク */
  lavender: '#A78BDF',
  /** リンク hover */
  lavenderHover: '#9D82E0',
  /** ペールライム: 確定ボタン / 信頼バッジ / 濃背景上の強調テキスト */
  lime: '#E4F0A0',
  /** 濃背景カード(感情ピーク画面の内側カード) */
  deepCard: '#5A5175',
  /** 濃背景ボーダー */
  deepBorder: '#6E648C',
  /** アバター橙 */
  avatarOrange: '#FBD79E',
  /** アバター水 */
  avatarAqua: '#B3E5F2',
  /** アバター桃 / エラーアクセント */
  avatarPink: '#F5B8CE',
  /** ミュートテキスト(補足) */
  muted: '#948DA8',
  /** 本文サブ(段落本文) */
  body: '#6A6480',
  /** プレースホルダ / 非活性 */
  placeholder: '#B9B3CC',
  /** ライト背景(画面ベース) */
  surface: '#F7F6FB',
  /** 薄ラベンダー面(タグ背景 / 注意書き帯) */
  surfaceLavender: '#F1EEFB',
  /** ボディ背景(プロト外側の地) */
  canvas: '#EDECF3',
  /** 白面 */
  white: '#ffffff',
  /** 感情ピークの淡ラベンダー文字 */
  lavenderText: '#E3DCFF',
  /** disabled ボタン */
  disabledBg: '#EDEBF2',
  disabledBorder: '#C9C4D6',
  disabledFg: '#B9B3CC',
  /** レビュー星の非選択色 */
  starOff: '#D8D3E4',
  /** 区切り線 */
  divider: '#EDEBF2',
} as const

/** アバターに使うパステル5色 */
export const avatarColors = [
  color.avatarAqua,
  color.avatarOrange,
  color.avatarPink,
  color.lime,
  color.lavender,
] as const

export const radius = {
  sm: 4, // バッジ / チップ / 入力
  md: 8, // ボタン / 小カード
  lg: 12, // カード
  xl: 16, // 大カード
  screen: 27, // 端末画面角
  bezel: 38, // 端末ベゼル
} as const

export const shadow = {
  /** 主要ボタン(黒地に紫影) */
  primary: `3px 3px 0 ${color.lavender}`,
  /** 肯定 / カード */
  confirm: `3px 3px 0 ${color.ink}`,
  card: `4px 4px 0 ${color.ink}`,
  /** 副次 / 小要素 */
  sm: `2px 2px 0 ${color.ink}`,
  smLavender: `2px 2px 0 ${color.lavender}`,
  /** 端末の落ち影 */
  device: '0 18px 44px rgba(40,30,80,.28)',
} as const

export const font = {
  family: "'DotGothic16', monospace",
} as const

/** 端末フレーム寸法 */
export const device = {
  outerW: 399,
  outerH: 836,
  innerW: 375,
  innerH: 812,
  pad: 12,
} as const
