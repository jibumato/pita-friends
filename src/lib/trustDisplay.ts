/**
 * 信頼指標の表示ルール。docs/trust-safety-spec.md §1.2 / §2.2。
 *
 * スコアや率は「件数が少ないうちは数値を出さない」。
 * 少ない母数の数値は実力と無関係にぶれ、新規ユーザーを不当に不利にするため。
 */

/** これ未満のレビュー件数ではマナースコアを数値表示しない(§1.2)。 */
export const MIN_REVIEWS_FOR_SCORE = 3
/** これ未満の約束件数ではドタキャン率を数値表示しない(§2.2)。 */
export const MIN_PROMISES_FOR_RATE = 3

/** 実績が少ないときに数値の代わりに出す文言(§1.2)。 */
export const NEW_MEMBER_LABEL = '実績これから'

/**
 * マナースコアの表示文字列。件数が足りなければ null を返し、
 * 呼び出し側でバッジ等に置き換える。
 */
export function mannerScoreLabel(score: number, reviewCount: number): string | null {
  if (reviewCount < MIN_REVIEWS_FOR_SCORE) return null
  return `★${score.toFixed(1)}`
}

/** ドタキャン率の表示文字列。母数が足りなければ「—」(データなし)。 */
export function dotakyanLabel(ratePercent: number, promiseCount: number): string {
  if (promiseCount < MIN_PROMISES_FOR_RATE) return '—'
  return `${ratePercent}%`
}
