/**
 * 予約画面に表示するキャンセルポリシーのバージョン。
 *
 * 直前キャンセルでのコイン没収は、消費者契約法9条(平均的な損害を超える部分は
 * 無効)との関係で争われうる。争いになったとき「申込前にこの内容を示して同意を
 * 得ていた」と言えるようにするため、予約行に版を記録する
 * (docs/legal/lawyer-review-round2-request.md Q14 ①)。
 *
 * 予約画面(src/screens/Booking.tsx)のキャンセルに関する記載を変更したら、
 * **必ずこの値を上げること**。上げないと、旧文言で申し込んだ予約と
 * 新文言で申し込んだ予約が記録上区別できなくなる。
 *
 * 2026-07-26b: 開始時刻の指定(0040)に伴い、キャンセルを段階制に変更した。
 * 2026-07-27: あそぶ時間を最長10時間に延ばし(0048/0049)、あわせて没収額に
 *   「経過した時間ぶん＋3時間ぶん」の上限を設けた。長時間の予約で没収額が
 *   消費者契約法9条の「平均的な損害」を超えないようにするための頭打ちで、
 *   4時間以下の予約では従来と同じ額になる。
 */
export const CANCELLATION_POLICY_VERSION = '2026-07-27'

/**
 * 予約の申込画面に出す、キャンセル・返金の説明そのもの。
 *
 * ⚠️ **表示とログを1か所にまとめてある。** 従来は版だけを予約行に記録して
 * いたが、版番号だけでは「その版が何と書いてあったか」を後から示せない。
 * 0106 で、申込時に**この文面のまま** `policy_consents` へ残すようにした。
 *
 * 画面のJSXと記録用の文字列が別々にあると、片方を直したときに黙ってずれる。
 * **ずれた瞬間、「この文面を見せた」と言えなくなり証跡の価値が消える**ので、
 * ここを唯一の出典にして、Booking.tsx はこの配列から描画する。
 *
 * `**…**` は画面で太字になる。ログにはマーカーごと残す
 * （どこを強調して見せたかも記録の一部）。
 * **1文字でも変えたら、上の版を上げること。**
 */
export const CANCELLATION_POLICY_LINES: string[] = [
  'コインは申し込んだ時点で確保され、相手が承諾すると予約が成立します。',
  '・承諾される**前**の取り消し → **全額戻ります**',
  '・**ピタメイト都合**のキャンセル・無断欠席 → **全額戻ります**',
  '・**あなたの都合**のキャンセル',
  '　→ 承諾から5分以内、または開始1時間前までは**全額戻ります**',
  '　→ 開始1時間前を切ってから開始までは**半額戻ります**',
  '　→ 開始後・無断欠席は戻らず、コインは相手の報酬になります',
  '　※ただし相手の報酬になるのは、**すでに経過した時間ぶん＋3時間ぶんまで**です。長い予約でも、それを超える分は戻ります。',
  '　※戻るのはコインです。日本円での返金はできません。',
  'トラブル時はいつでも通報・相談ができます。',
]

/** 記録用の1本のテキスト。**画面に出したものと同じ配列から作る。** */
export function cancellationPolicyText(): string {
  return (
    `【キャンセル・返金について】(版 ${CANCELLATION_POLICY_VERSION})\n` +
    CANCELLATION_POLICY_LINES.join('\n')
  )
}

/**
 * 開始時刻の選び方。サーバ(platform_pricing)の受付範囲と揃えること。
 * ずれると、画面では選べるのに申込時に START_TOO_SOON で弾かれる。
 */
export const MIN_LEAD_MINUTES = 30
/** 0061でまとめ予約(4回分=28日先)が入るよう14→35に延ばした。 */
export const MAX_LEAD_DAYS = 35

/**
 * 開始時刻の候補を30分刻みで作る。
 * 最短の受付時刻(いまから MIN_LEAD_MINUTES 後)より後ろの、次のキリのよい時刻から。
 */
export function startTimeOptions(from: Date, count = 16): Date[] {
  const first = new Date(from.getTime() + MIN_LEAD_MINUTES * 60_000)
  first.setSeconds(0, 0)
  // 次の :00 / :30 に切り上げる(切り上げるので必ず受付範囲の内側に入る)
  first.setMinutes(first.getMinutes() <= 30 ? 30 : 60)
  return Array.from({ length: count }, (_, i) => new Date(first.getTime() + i * 30 * 60_000))
}

/** 「今日 21:30」のような表示。 */
export function formatStart(d: Date, now = new Date()): string {
  const hhmm = `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`
  const day = new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime()
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()
  const diff = Math.round((day - today) / 86_400_000)
  if (diff === 0) return `今日 ${hhmm}`
  if (diff === 1) return `明日 ${hhmm}`
  return `${d.getMonth() + 1}/${d.getDate()} ${hhmm}`
}

/** 終了時刻まで含めた「今日 21:30〜22:30」形式。 */
export function formatStartRange(d: Date, minutes: number, now = new Date()): string {
  const end = new Date(d.getTime() + minutes * 60_000)
  const endHhmm = `${String(end.getHours()).padStart(2, '0')}:${String(end.getMinutes()).padStart(2, '0')}`
  return `${formatStart(d, now)}〜${endHhmm}`
}
