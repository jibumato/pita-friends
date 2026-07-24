/** 周辺画面のモックデータ。将来 API 層に差し替えられるよう分離。 */
import { color as C } from '../theme/tokens'

export type SearchUser = {
  initial: string
  color: string
  name: string
  gender: '女性' | '男性'
  meta: string
  score: number
  tags: string[]
  /** ホストとして掲載中の場合の時給コイン(未掲載は undefined) */
  hourlyRate?: number
}

export const searchUsers: SearchUser[] = [
  {
    initial: 'る',
    color: C.avatarOrange,
    name: 'るか',
    gender: '女性',
    meta: 'マナー ★4.9 · ドタキャン 0% · 132回プレイ',
    score: 89,
    tags: ['Apex プラチナⅣ', '今夜 22時〜'],
    hourlyRate: 450,
  },
  {
    initial: 'そ',
    color: C.avatarAqua,
    name: 'そら',
    gender: '男性',
    meta: 'マナー ★4.8 · 社会人 / 夜メイン',
    score: 84,
    tags: ['Apex ゴールドⅠ', 'VALORANT'],
  },
  {
    initial: 'ひ',
    color: C.avatarPink,
    name: 'ひなた',
    gender: '女性',
    meta: 'マナー ★5.0 · まったり勢',
    score: 81,
    tags: ['あつ森', 'マイクラ 建築'],
    hourlyRate: 380,
  },
  {
    initial: 'み',
    color: C.avatarAqua,
    name: 'みお',
    gender: '女性',
    meta: 'マナー ★4.9 · 学生 / 夜メイン',
    score: 90,
    tags: ['VALORANT ダイヤ', '今夜 22時〜'],
    hourlyRate: 500,
  },
  {
    initial: 'か',
    color: C.lime,
    name: 'かい',
    gender: '男性',
    meta: 'マナー ★4.7 · 社会人 / 週末勢',
    score: 86,
    tags: ['Overwatch 2', 'VALORANT'],
    hourlyRate: 400,
  },
  {
    initial: 'の',
    color: '#FFC7D9',
    name: 'のの',
    gender: '女性',
    meta: 'マナー ★4.8 · エンジョイ寄り',
    score: 88,
    tags: ['Apex', 'Fortnite'],
    hourlyRate: 320,
  },
  {
    initial: 'り',
    color: '#C9F2C7',
    name: 'りく',
    gender: '男性',
    meta: 'マナー ★4.6 · まったり練習勢',
    score: 80,
    tags: ['LoL', '初心者歓迎'],
    hourlyRate: 300,
  },
  {
    initial: 'あ',
    color: C.lavender,
    name: 'あおい',
    gender: '女性',
    meta: 'マナー ★4.8 · 平日夜メイン',
    score: 83,
    tags: ['Fortnite', 'スプラ'],
    hourlyRate: 280,
  },
  {
    initial: 'ゆ',
    color: C.avatarOrange,
    name: 'ゆうき',
    gender: '男性',
    meta: 'マナー ★4.7 · 建築コツコツ勢',
    score: 78,
    tags: ['マイクラ 建築', '週末いつでも'],
    hourlyRate: 220,
  },
  {
    initial: 'れ',
    color: C.avatarAqua,
    name: 'れん',
    gender: '男性',
    meta: 'マナー ★4.8 · タンクメイン',
    score: 84,
    tags: ['Overwatch 2', '今夜 21時〜'],
    hourlyRate: 350,
  },
  {
    initial: 'な',
    color: C.avatarPink,
    name: 'なな',
    gender: '女性',
    meta: 'マナー ★4.9 · のんびり全般',
    score: 82,
    tags: ['あつ森', 'スプラ'],
    hourlyRate: 260,
  },
  {
    initial: 'は',
    color: C.avatarOrange,
    name: 'はると',
    gender: '男性',
    meta: 'マナー ★4.6 · ランク回し勢',
    score: 79,
    tags: ['Apex ゴールド', '平日夜'],
  },
  {
    initial: 'こ',
    color: C.lime,
    name: 'こはる',
    gender: '女性',
    meta: 'マナー ★5.0 · 通話まったり',
    score: 85,
    tags: ['マイクラ', 'あつ森'],
    hourlyRate: 300,
  },
]

export type BoardPost = {
  title: string
  slots: string
  tags: string[]
  host: { initial: string; color: string; name: string; score: string }
}

export const boardPosts: BoardPost[] = [
  {
    title: 'Apex ランク ゴールド帯',
    slots: 'あと2人',
    tags: ['今夜 21:30〜', 'VC必須', 'エンジョイ'],
    host: { initial: 'る', color: C.avatarOrange, name: 'るか', score: '★4.9' },
  },
  {
    title: 'マイクラ 建築まったり',
    slots: 'あと3人',
    tags: ['週末いつでも', 'VCどちらでも'],
    host: { initial: 'ひ', color: C.avatarPink, name: 'ひなた', score: '★5.0' },
  },
  {
    title: '雀魂 半荘2〜3戦',
    slots: 'あと1人',
    tags: ['今夜 23:00〜', 'VCなし可'],
    host: { initial: 'カ', color: C.lime, name: 'カイ', score: '★4.7' },
  },
  {
    title: 'VALORANT アンレートわいわい',
    slots: 'あと2人',
    tags: ['今夜 22:00〜', 'VCどちらでも', 'エンジョイ'],
    host: { initial: 'み', color: C.avatarAqua, name: 'みお', score: '★4.9' },
  },
  {
    title: 'Overwatch2 クイックまったり',
    slots: 'あと2人',
    tags: ['今夜 21:00〜', 'VC歓迎'],
    host: { initial: 'れ', color: C.avatarAqua, name: 'れん', score: '★4.8' },
  },
  {
    title: 'LoL ノーマル 初心者歓迎',
    slots: 'あと3人',
    tags: ['週末 夜', 'VCどちらでも', '初心者歓迎'],
    host: { initial: 'り', color: '#C9F2C7', name: 'りく', score: '★4.6' },
  },
  {
    title: 'スプラ サーモンラン',
    slots: 'あと1人',
    tags: ['今夜 23:30〜', 'VCなし可'],
    host: { initial: 'な', color: C.avatarPink, name: 'なな', score: '★4.9' },
  },
  {
    title: 'Fortnite デュオ ビクロイ狙い',
    slots: 'あと1人',
    tags: ['今夜 22:30〜', 'VC必須', 'ガチ寄り'],
    host: { initial: 'あ', color: C.lavender, name: 'あおい', score: '★4.8' },
  },
]

export type TalkThread = {
  initial: string
  color: string
  name: string
  verified: boolean
  last: string
  time: string
  unread?: number
}

export const talkThreads: TalkThread[] = [
  {
    initial: 'み',
    color: C.avatarAqua,
    name: 'みなと',
    verified: true,
    last: 'よろしくお願いします！ゴールド帯でランク回しましょ〜',
    time: '21:49',
    unread: 1,
  },
  {
    initial: 'る',
    color: C.avatarOrange,
    name: 'るか',
    verified: true,
    last: '時間ぴったりに来てくれてありがとう！また遊ぼ〜',
    time: '昨日',
  },
  {
    initial: 'の',
    color: '#FFC7D9',
    name: 'のの',
    verified: true,
    last: '今日の22時、Apex空いてたりする？',
    time: '昨日',
    unread: 2,
  },
  {
    initial: 'か',
    color: C.lime,
    name: 'かい',
    verified: true,
    last: 'OW2またやりましょ〜！タンク任せて',
    time: '火曜',
  },
  {
    initial: 'ひ',
    color: C.avatarPink,
    name: 'ひなた',
    verified: true,
    last: '建築の続き、週末やろ〜🏠',
    time: '月曜',
  },
]

export type InviteRequest = {
  id: string
  initial: string
  color: string
  name: string
  verified: boolean
  manner: string
  dotakyan: string
  plays: number
  common: string[]
  game: string
  when: string
  message: string
}

/** 受け取った誘い(リクエスト)。女性ファーストの承認制フローで表示。 */
export const inviteRequests: InviteRequest[] = [
  {
    id: 'r1',
    initial: 'ハ',
    color: C.avatarAqua,
    name: 'ハルト',
    verified: true,
    manner: '★4.8',
    dotakyan: '0%',
    plays: 96,
    common: ['Apex', 'エンジョイ'],
    game: 'Apex',
    when: '今夜 22:00〜',
    message: 'はじめまして！ゴールド帯でまったりランク回しませんか？',
  },
  {
    id: 'r2',
    initial: 'リ',
    color: C.avatarOrange,
    name: 'リク',
    verified: true,
    manner: '★4.6',
    dotakyan: '3%',
    plays: 41,
    common: ['マイクラ', 'まったり'],
    game: 'マイクラ',
    when: '週末',
    message: '建築まったり勢です。よかったら一緒にどうですか？',
  },
]

export type NotificationItem = {
  kind: 'invite' | 'reminder' | 'review' | 'system'
  icon: string
  tint: string
  title: string
  body: string
  time: string
  unread?: boolean
}

export const notifications: NotificationItem[] = [
  {
    kind: 'invite',
    icon: '🙌',
    tint: C.lime,
    title: 'みなと さんが誘いを承諾しました',
    body: '相性92% でマッチ成立！パーティを組みましょう。',
    time: '3分前',
    unread: true,
  },
  {
    kind: 'reminder',
    icon: '🔔',
    tint: C.avatarOrange,
    title: 'まもなく約束の時間です',
    body: '今夜 22:00〜 Apex ランクマッチ — 開始15分前です。',
    time: '10分前',
    unread: true,
  },
  {
    kind: 'review',
    icon: '⭐',
    tint: C.avatarPink,
    title: 'るか さんがあなたを評価しました',
    body: '「時間ぴったり」「また遊びたい」— マナースコアに反映されました。',
    time: '昨日',
  },
  {
    kind: 'system',
    icon: '🔓',
    tint: C.avatarAqua,
    title: '称号「時間の守り神」を獲得',
    body: 'ドタキャン0%を30回達成しました。',
    time: '3日前',
  },
]
