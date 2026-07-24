/**
 * ゲーム相性診断(プレイスタイル診断)の質問・タイプ定義・スコアリング。
 *
 * 注意: これは「一緒に遊ぶときの楽しみ方の相性」を見る診断で、恋愛相性ではない。
 * ピタフレは出会い目的の利用を禁止しており、診断もあくまで「ゲーム友達との相性の目安」。
 * MBTI等の商標は使わず、独自の軸名・タイプ名にしている。
 */

/** 診断の4軸。スコアは正の極(+)/負の極(-)で表す。 */
export type AxisKey = 'competitive' | 'talk' | 'lead' | 'grind'

export type AxisDef = {
  key: AxisKey
  /** + 側(スコアが正)の極のラベル */
  pos: string
  /** - 側(スコアが負)の極のラベル */
  neg: string
  /** 相性の考え方: 'similar'=似てるほど良い / 'complement'=補完(離れてる)ほど良い */
  affinity: 'similar' | 'complement'
  /** 相性計算での重み(合計1.0) */
  weight: number
}

export const AXES: AxisDef[] = [
  { key: 'competitive', pos: 'ガチ', neg: 'エンジョイ', affinity: 'similar', weight: 0.3 },
  { key: 'talk', pos: 'わいわい', neg: 'もくもく', affinity: 'similar', weight: 0.3 },
  { key: 'lead', pos: 'リード', neg: 'サポート', affinity: 'complement', weight: 0.25 },
  { key: 'grind', pos: 'コツコツ', neg: 'ノリ', affinity: 'similar', weight: 0.15 },
]

/** 質問。選択肢Aは常に軸の「+側(pos)」、Bは「-側(neg)」に対応する。 */
export type Question = {
  id: number
  axis: AxisKey
  text: string
  a: string
  b: string
}

export const QUESTIONS: Question[] = [
  // ① ガチ ⇄ エンジョイ
  { id: 1, axis: 'competitive', text: 'ランクが下がりそう…どうする？', a: '集中して立て直す', b: '下がってもOK、笑って続ける' },
  { id: 2, axis: 'competitive', text: '味方がミスしたとき', a: '冷静に次の動きを立て直す', b: '「ドンマイ！」で切り替える' },
  { id: 3, axis: 'competitive', text: '新しいゲームを始めるなら', a: 'まず勝てるよう上達したい', b: 'とりあえず触って楽しみたい' },
  // ② わいわい ⇄ もくもく
  { id: 4, axis: 'talk', text: 'プレイ中の通話は', a: '実況しながらワイワイ', b: '大事な場面は静かに集中' },
  { id: 5, axis: 'talk', text: '初対面の相手と遊ぶとき', a: 'どんどん話して距離を縮める', b: 'まずはプレイで様子を見る' },
  { id: 6, axis: 'talk', text: '盛り上がるのは', a: 'ずっと喋って笑ってる時間', b: '連携がピタッと決まった瞬間' },
  // ③ リード ⇄ サポート
  { id: 7, axis: 'lead', text: 'パーティを組んだら', a: '作戦を決めて引っ張りたい', b: '得意な人に合わせて動きたい' },
  { id: 8, axis: 'lead', text: '意見が割れたとき', a: '自分の考えを提案しがち', b: 'まわりの意見を尊重しがち' },
  { id: 9, axis: 'lead', text: '遊ぶ約束をするとき', a: '日時やゲームを決めるのは自分', b: '相手の都合に合わせるのが楽' },
  // ④ コツコツ ⇄ ノリ
  { id: 10, axis: 'grind', text: 'うまくなるために', a: '攻略を調べて練習する', b: '数をこなして体で覚える' },
  { id: 11, axis: 'grind', text: 'ゲームの選び方', a: 'ハマれる1本を極めたい', b: 'その日の気分でいろいろ試す' },
  { id: 12, axis: 'grind', text: '負けが続いたとき', a: '原因を分析して次に活かす', b: '気分転換して勢いで巻き返す' },
]

/** 各軸のスコア(-3〜+3)。 */
export type AxisScores = Record<AxisKey, number>

/** 診断結果(保存対象)。 */
export type PersonalityResult = {
  scores: AxisScores
  /** メインタイプのID(① competitive × ② talk で決まる4種) */
  typeId: TypeId
}

export type TypeId = 'captain' | 'ace' | 'mood' | 'healer'

export type PersonalityType = {
  id: TypeId
  emoji: string
  name: string
  tagline: string
  /** ブランドカラーのトークン名(theme/tokens の color キー) */
  colorToken: 'lime' | 'fill' | 'lavender' | 'avatarAqua'
  /** 得意な遊び方(結果画面の箇条書き) */
  strengths: string[]
}

export const TYPES: Record<TypeId, PersonalityType> = {
  captain: {
    id: 'captain',
    emoji: '🔥',
    name: '熱血キャプテン',
    tagline: '盛り上げながら勝ちにいく司令塔',
    colorToken: 'lime',
    strengths: ['声をかけて場を引っ張るのが得意', '勝ちにこだわる真剣勝負も歓迎', 'テンション高めで連携もバッチリ'],
  },
  ace: {
    id: 'ace',
    emoji: '🎯',
    name: 'サイレントエース',
    tagline: '多くを語らず結果で魅せる職人',
    colorToken: 'fill',
    strengths: ['集中して黙々と実力を発揮', '無駄口より連携の精度で魅せる', '本気で上達を目指す相手と好相性'],
  },
  mood: {
    id: 'mood',
    emoji: '☀️',
    name: 'ムードメーカー',
    tagline: 'その場を明るくする太陽',
    colorToken: 'lavender',
    strengths: ['喋りながらワイワイ楽しむのが好き', '勝ち負けよりその場のノリを大事に', '初対面でも打ち解けるのが早い'],
  },
  healer: {
    id: 'healer',
    emoji: '🌿',
    name: 'まったりヒーラー',
    tagline: '穏やかに寄り添う癒し',
    colorToken: 'avatarAqua',
    strengths: ['マイペースにまったり遊ぶのが好き', '静かに集中する時間を大切にする', 'ガツガツせず気楽に付き合える'],
  },
}

/** A/B の回答列(true=A/pos, false=B/neg)からスコアを集計する。 */
export function scoreAnswers(answers: boolean[]): AxisScores {
  const scores: AxisScores = { competitive: 0, talk: 0, lead: 0, grind: 0 }
  QUESTIONS.forEach((q, i) => {
    // A(true)で + 側へ、B(false)で - 側へ
    scores[q.axis] += answers[i] ? 1 : -1
  })
  return scores
}

/** スコアからメインタイプを決める(① competitive × ② talk)。3問なので0にはならない。 */
export function typeFromScores(scores: AxisScores): TypeId {
  const gachi = scores.competitive >= 0
  const waiwai = scores.talk >= 0
  if (gachi && waiwai) return 'captain'
  if (gachi && !waiwai) return 'ace'
  if (!gachi && waiwai) return 'mood'
  return 'healer'
}

export function buildResult(answers: boolean[]): PersonalityResult {
  const scores = scoreAnswers(answers)
  return { scores, typeId: typeFromScores(scores) }
}

/** 軸スコア(-3〜+3)を、+側の割合(0〜100%)に変換する(バー表示用)。 */
export function axisPercent(score: number): number {
  return Math.round(((score + 3) / 6) * 100)
}

/**
 * 2人の相性を 55〜99% で返す。
 * - similar 軸: 近いほど高い / complement 軸: 離れてるほど高い
 * - 生の一致度(0〜1)を、体感の良い 55〜99 のレンジにマッピングする。
 */
export function compatibility(a: AxisScores, b: AxisScores): number {
  let sum = 0
  for (const ax of AXES) {
    const na = a[ax.key] / 3 // -1〜1
    const nb = b[ax.key] / 3
    const diff = Math.abs(na - nb) / 2 // 0〜1(0=同じ, 1=正反対)
    const raw = ax.affinity === 'similar' ? 1 - diff : diff
    sum += raw * ax.weight
  }
  return Math.round(55 + sum * 44)
}

/**
 * 「この人と一緒に遊ぶときのコツ」を、相手の軸スコアから生成する。
 * 相手プロフィールで「あなた→相手」向けに表示する用。
 */
export function playTips(partner: AxisScores): string[] {
  const tips: string[] = []
  if (partner.talk <= -1) tips.push('集中したい派。序盤はチャット中心、慣れてきたらVCが◎')
  else tips.push('おしゃべり好き。通話で盛り上がると打ち解けやすい')
  if (partner.competitive >= 1) tips.push('勝ちにこだわる派。要所は真剣に合わせると好かれる')
  else tips.push('楽しさ優先派。気楽なノリでOK、詰めすぎない')
  if (partner.lead <= -1) tips.push('合わせ上手で遠慮しがち。あなたから遊ぶ提案をするとスムーズ')
  else tips.push('引っ張るタイプ。作戦は任せて、良い動きを褒めると気持ちよく遊べる')
  return tips
}

/** メインタイプと相性の良いタイプ(結果画面の「合いそうなタイプ」表示用の代表例)。 */
export const GOOD_MATCH_TYPES: Record<TypeId, TypeId[]> = {
  captain: ['ace', 'mood'],
  ace: ['captain', 'healer'],
  mood: ['captain', 'healer'],
  healer: ['mood', 'ace'],
}
