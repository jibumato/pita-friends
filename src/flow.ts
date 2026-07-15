/** コアフローの状態機械定義。ハンドオフ「State Management」を移植。 */
import { avatarColors } from './theme/tokens'

export type ScreenKey =
  // --- コアフロー(信頼ループ) ---
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
  // --- 周辺画面(アプリシェル) ---
  | 'search'
  | 'board'
  | 'boardCreate'
  | 'talkList'
  | 'mypage'
  | 'settings'
  | 'safety'
  | 'notifications'
  | 'safetyPrefs'
  | 'requests'
  | 'wallet'
  | 'hostSettings'
  | 'booking'

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
  search: 'さがす',
  board: '募集板',
  boardCreate: '募集作成',
  talkList: 'トーク一覧',
  mypage: 'マイページ',
  settings: '設定',
  safety: '安全センター',
  notifications: '通知',
  safetyPrefs: '安心設定',
  requests: '受け取った誘い',
  wallet: 'コインウォレット',
  hostSettings: 'ホスト設定',
  booking: '予約する',
}

/** 性別(任意公開)。 */
export type Gender = 'female' | 'male' | 'na'

export const genderLabel: Record<Gender, string> = {
  female: '女性',
  male: '男性',
  na: '回答しない',
}

/** だれから連絡・誘いを受けるか。女性ファーストの中核コントロール。 */
export type ContactScope = 'verified' | 'sameGender' | 'all'

export const contactScopeLabel: Record<ContactScope, string> = {
  verified: '本人確認済みのみ',
  sameGender: '同性のみ',
  all: '全員',
}

/** 安心設定(女性ファースト)。 */
export type SafetyPrefs = {
  /** 連絡・誘いを受け付ける相手の範囲 */
  contactScope: ContactScope
  /** 誘いを承認制にする(届いた誘いはリクエストとして受け、承認するまで連絡先やトークは開かない) */
  approvalRequired: boolean
  /** オンライン状態を公開する */
  showOnline: boolean
  /** 相手からの検索・おすすめに自分を表示する(オフで完全に受け身) */
  discoverable: boolean
  /** 低マナー・未確認ユーザーからの接触をブロック */
  blockLowTrust: boolean
}

export const defaultSafetyPrefs: SafetyPrefs = {
  contactScope: 'verified',
  approvalRequired: true,
  showOnline: true,
  discoverable: true,
  blockLowTrust: true,
}

/** 女性ユーザー向けの推奨初期値(より保守的)。 */
export const recommendedFemalePrefs: SafetyPrefs = {
  contactScope: 'verified',
  approvalRequired: true,
  showOnline: false,
  discoverable: true,
  blockLowTrust: true,
}

/**
 * コイン経済(GameRoom型マーケットプレイス)。
 * ユーザーはコインを購入し、ホスト(一緒に遊ぶ時間を提供する相手)に
 * 時間単位で消費する。公式コイン決済のみが「安全な金銭のやり取り」で、
 * アプリ外・直接の金銭要求は引き続き禁止・通報対象。
 */
export type CoinPack = {
  coins: number
  priceYen: number
  bonus?: string
}

export const COIN_PACKS: CoinPack[] = [
  { coins: 300, priceYen: 300 },
  { coins: 1000, priceYen: 1000, bonus: '+50コイン' },
  { coins: 3000, priceYen: 3000, bonus: '+300コイン' },
  { coins: 6000, priceYen: 6000, bonus: '+900コイン' },
]

/** ホスト設定(一緒に遊ぶ時間を時給コインで提供する)。 */
export type HostSettings = {
  isHost: boolean
  hourlyRate: number
  games: string[]
  bio: string
}

export const defaultHostSettings: HostSettings = {
  isHost: false,
  hourlyRate: 400,
  games: ['Apex'],
  bio: '',
}

/** 予約できる時間(分)と、それに対応するラベル。 */
export const BOOKING_DURATIONS = [30, 60, 120] as const
export type BookingDuration = (typeof BOOKING_DURATIONS)[number]

export function durationLabel(min: BookingDuration): string {
  return min === 30 ? '30分' : min === 60 ? '1時間' : '2時間'
}

/** 時給コインと分数から、消費コインを計算(30分単位切り上げなし・比例配分)。 */
export function coinsForDuration(hourlyRate: number, minutes: number): number {
  return Math.round((hourlyRate * minutes) / 60)
}

/**
 * 各画面がフローレールのどのステップ(0..4)に対応するか。
 * 周辺画面(タブシェル)は信頼ループ外なので -1(レール非表示)。
 */
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
  search: -1,
  board: -1,
  boardCreate: -1,
  talkList: -1,
  mypage: -1,
  settings: -1,
  safety: -1,
  notifications: -1,
  safetyPrefs: -1,
  requests: -1,
  wallet: -1,
  hostSettings: -1,
  booking: -1,
}

/** 下部タブと画面キーの対応。 */
export type TabKey = 'home' | 'search' | 'post' | 'talk' | 'mypage'

export const tabToScreen: Record<TabKey, ScreenKey> = {
  home: 'home',
  search: 'search',
  post: 'board',
  talk: 'talkList',
  mypage: 'mypage',
}

/** 現在の画面がどのタブに属するか(タブのハイライト用)。 */
export function activeTabOf(screen: ScreenKey): TabKey | null {
  switch (screen) {
    case 'home':
      return 'home'
    case 'search':
      return 'search'
    case 'board':
    case 'boardCreate':
      return 'post'
    case 'talkList':
    case 'talk':
      return 'talk'
    case 'mypage':
    case 'settings':
    case 'safety':
    case 'safetyPrefs':
    case 'requests':
    case 'wallet':
    case 'hostSettings':
      return 'mypage'
    default:
      return null
  }
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
