/**
 * 表示用の価格設定。
 *
 * 権威はサーバ側(platform_pricing テーブル)で、請求額はそちらで計算される。
 * ここの値は購入前の画面に総額を出すためだけのもの。
 * **サーバ側の料率を変えたら、必ずこの値も合わせること**(ズレると表示額と
 * 請求額が食い違い、申込前の価格表示として問題になる)。
 */
export const SAFETY_FEE_RATE = 0.05

/** コイン価格に対するあんしんサポート料(円)。サーバ側の safety_fee_for と同じ丸め。 */
export function safetyFeeYen(priceYen: number): number {
  return Math.max(0, Math.round(priceYen * SAFETY_FEE_RATE))
}
