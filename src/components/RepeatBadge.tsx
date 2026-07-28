import { color as C } from '../theme/tokens'

/**
 * 「また呼ばれている」ことを示すバッジ(0058)。
 *
 * マナースコアもレビュー件数も通算のプレイ回数も、**1回来た人を何度数えても
 * 増える**。100人が1回ずつ来たピタメイトと、10人が10回ずつ来たピタメイトが
 * 同じに見えてしまう。後者を選びたい人のために、繰り返し来た人の数だけを出す。
 *
 * **0人のときは何も出さない。** 始めたばかりの人に「リピーター0人」を貼るのは、
 * 新規を別枠で拾う方針(ホームの「新しく入った」)と逆になる。
 */
export default function RepeatBadge({
  count,
  size = 'md',
}: {
  count: number | null | undefined
  size?: 'sm' | 'md'
}) {
  if (!count || count < 1) return null
  const sm = size === 'sm'
  return (
    <span
      aria-label={`${count}人がくり返し遊んでいます`}
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        gap: 4,
        flex: 'none',
        fontSize: sm ? 9.5 : 10.5,
        color: C.ink,
        background: C.surfaceLavender,
        border: `1.5px solid ${C.lavender}`,
        borderRadius: 20,
        padding: sm ? '2px 7px' : '3px 9px',
        lineHeight: 1.4,
      }}
    >
      🔁 リピーター{count}人
    </span>
  )
}

/**
 * 「あなたとは○回目」の節目(0055の回数から出す)。
 *
 * 毎回出すと数字が流れるだけになるので、**節目のときだけ**強調する。
 * 5・10・25・50 は、続けている人が「そこまで来た」と感じる間隔で選んだ。
 */
const MILESTONES = [5, 10, 25, 50, 100]

export function playMilestone(count: number): number | null {
  let hit: number | null = null
  for (const m of MILESTONES) if (count >= m) hit = m
  return hit
}

/** その回数がちょうど節目か(達成した回にだけ祝う用)。 */
export function isMilestone(count: number): boolean {
  return MILESTONES.includes(count)
}
