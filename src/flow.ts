/** コアフローの状態機械定義。ハンドオフ「State Management」を移植。 */
import { avatarColors } from './theme/tokens'

export type ScreenKey =
  | 'welcome'
  | 'verify'
  | 'setup'
  | 'home'
  | 'profile'
  | 'invite'
  | 'sending'
  | 'match'
  | 'party'
  | 'talk'
  | 'reminder'
  | 'joining'
  | 'review'
  | 'result'

export const screenNames: Record<ScreenKey, string> = {
  welcome: 'ようこそ',
  verify: '本人確認',
  setup: 'プロフィール作成',
  home: 'ホーム',
  profile: 'プロフィール',
  invite: '誘う',
  sending: '返事待ち',
  match: 'MATCH FOUND',
  party: 'PARTY成立',
  talk: 'トークルーム',
  reminder: '合流リマインド',
  joining: '合流中',
  review: 'プレイ後レビュー',
  result: 'RESULT',
}

/** 各画面がフローレールのどのステップ(0..4)に対応するか。 */
export const stepOf: Record<ScreenKey, number> = {
  welcome: 0,
  verify: 0,
  setup: 0,
  home: 1,
  profile: 1,
  invite: 1,
  sending: 1,
  match: 2,
  party: 2,
  talk: 2,
  reminder: 3,
  joining: 3,
  review: 4,
  result: 4,
}

export const GAMES = ['Apex', 'VALORANT', 'マイクラ'] as const
export const WHENS = ['今夜 22:00〜', '明日 21:00〜', '日時を指定'] as const
export const REVIEW_TAGS = ['時間ぴったり', 'マナー◎', 'また遊びたい', '盛り上げ上手'] as const

export type Confetti = {
  left: string
  size: string
  color: string
  dur: string
  delay: string
}

/** 紙吹雪 14 片。ランダム値は index から決定的に生成(SSR/再現性のため)。 */
export function makeConfetti(): Confetti[] {
  return Array.from({ length: 14 }, (_, i) => ({
    left: 5 + ((i * 67) % 90) + '%',
    size: 6 + (i % 3) * 2 + 'px',
    color: avatarColors[i % avatarColors.length],
    dur: 2.4 + (i % 4) * 0.4 + 's',
    delay: (i % 6) * 0.35 + 's',
  }))
}
