/**
 * 「ピタメイトとして登録する」で入ってきた人の意思を、登録が終わるまで覚えておく。
 *
 * ■ なぜ必要か
 *   未ログインの訪問者に対しては、主CTAも副CTAも行き先が同じ登録画面になる。
 *   同じ画面に着地する2つのボタンは、約束が違うのに結果が同じなので、
 *   **押した人からは壊れて見える。** ここで意思を預かって、登録が終わった
 *   あとにピタメイト設定へ送ることで、副CTAが本当に別の行き先になる。
 *
 * ■ なぜ localStorage か
 *   登録は 登録 → 同意 → 本人確認 → プロフィール作成(→ 安心設定) → ホーム と
 *   画面をまたぐうえ、メール確認を有効にすると途中でタブが切り替わる。
 *   メモリに置くと消える。
 *
 * ■ 取り出しは1回だけ・24時間で失効
 *   登録を途中でやめた人の意思が、何日かあとのログインで突然発火して
 *   ピタメイト設定に飛ばされる、という事故を防ぐ。
 */

const KEY = 'pita:hostIntent:v1'
/** これを過ぎたら無かったことにする。登録を1日以上またぐことは想定しない。 */
const TTL_MS = 86_400_000

/** 副CTAを押した瞬間に呼ぶ。 */
export function markHostIntent(): void {
  try {
    localStorage.setItem(KEY, String(Date.now()))
  } catch {
    /* 保存できなければ、ふつうに登録が終わってホームに着くだけ */
  }
}

/**
 * 意思があれば true を返し、**同時に消す。** 2回目からは false。
 * ホームに着いた1回だけ効かせたいので、読むと同時に消す形にしている。
 */
export function consumeHostIntent(): boolean {
  try {
    const raw = localStorage.getItem(KEY)
    if (!raw) return false
    localStorage.removeItem(KEY)
    const at = Number(raw)
    return Number.isFinite(at) && Date.now() - at < TTL_MS
  } catch {
    return false
  }
}
