/**
 * 未ログインの訪問者が「やろうとしたこと」を、登録が終わるまで覚えておく。
 *
 * ■ なぜ必要か
 *   予約・メッセージ・お気に入りは、押した瞬間に**誰に対して**やろうとしたかが
 *   決まっている。登録に送ってそのまま忘れると、登録を終えた人はホームに着き、
 *   **さっき見ていた相手をもう一度さがすところから**やり直すことになる。
 *   いちばん気持ちが乗っている瞬間に、いちばん手間のかかる作業を渡すことになる。
 *
 * ■ 覚えるのは「誰を見ていたか」まで
 *   予約そのものは再開しない。開始時刻も料金も、登録しているあいだに
 *   変わりうる（枠が埋まる・料金が変わる）。**古い前提のまま申し込ませない。**
 *   相手のページまで戻して、そこからもう一度選んでもらう。
 *
 *   お気に入りも同じで、**勝手に登録しない。** 押したのは登録前なので、
 *   本人が改めて押せる場所まで連れて行くだけにする。
 *
 * ■ localStorage を使う理由と、消し方は hostIntent.ts と同じ
 *   登録は画面をまたぎ、メール確認を有効にすると途中でタブが変わる。
 *   取り出しは1回だけ・24時間で失効させ、何日かあとに突然発火しないようにする。
 */

export type PendingAction = 'booking' | 'message' | 'favorite'

export type PendingIntent = {
  action: PendingAction
  /** 相手のユーザーID。登録後、この人のページへ戻す。 */
  hostId: string
  /** 表示用の名前。関所の文面に使う。 */
  name: string
}

const KEY = 'pita:pendingIntent:v1'
/** これを過ぎたら無かったことにする。登録を1日以上またぐことは想定しない。 */
const TTL_MS = 86_400_000

/** 関所を出した瞬間に呼ぶ。 */
export function markPendingIntent(intent: PendingIntent): void {
  try {
    localStorage.setItem(KEY, JSON.stringify({ ...intent, at: Date.now() }))
  } catch {
    /* 保存できなければ、ふつうに登録が終わってホームに着くだけ */
  }
}

/** 覚えていることがあれば返し、**同時に消す。** 2回目からは null。 */
export function consumePendingIntent(): PendingIntent | null {
  try {
    const raw = localStorage.getItem(KEY)
    if (!raw) return null
    localStorage.removeItem(KEY)
    const v = JSON.parse(raw) as PendingIntent & { at?: number }
    if (!v || typeof v.hostId !== 'string' || !v.hostId) return null
    if (!Number.isFinite(v.at) || Date.now() - (v.at as number) >= TTL_MS) return null
    return { action: v.action, hostId: v.hostId, name: v.name ?? '' }
  } catch {
    return null
  }
}

/** 登録をやめた等で、覚えていることを捨てる。 */
export function clearPendingIntent(): void {
  try {
    localStorage.removeItem(KEY)
  } catch {
    /* 消せなくても 24 時間で失効する */
  }
}
