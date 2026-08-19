import { useEffect, useState } from 'react'
import { color as C } from '../theme/tokens'
import { isBackendConfigured } from '../lib/supabase'
import { fetchActivityStats, type ActivityStats as Stats } from '../lib/queries'

/**
 * 「賑わい」を、個人を出さずに見せる(0117)。
 *
 * ■ なぜ要るか
 *   `public_host_cards`(0052)は在席も空き枠も返さない。**その判断は正しい**
 *   ——未ログインの相手に「いま誰が居るか」を教えるのは付きまといの材料になる。
 *   ただし副作用として、初めて来た人には**誰も動いていないサイト**に見える。
 *   ゲストが買いに来ているのは「確実性」なので、動いている形跡がまったく
 *   無いと、料金を見る前に引き返す。
 *
 * ■ 出さない判断はサーバが持つ
 *   下限を下回る項目は null で返る。**画面側で「0なら隠す」といった判定を
 *   足さないこと。** 出す/出さないの線を2か所に置くと、片方だけ直したときに
 *   黙ってずれる。下限は運営コンソールから動かせる。
 */
export default function ActivityStats() {
  const [stats, setStats] = useState<Stats | null>(null)

  useEffect(() => {
    if (!isBackendConfigured) return
    let active = true
    fetchActivityStats()
      .then((s) => active && setStats(s))
      // 取れなければ何も出さない。ここは飾りで、無くても先に進める
      .catch(() => {})
    return () => {
      active = false
    }
  }, [])

  if (!stats) return null

  const items: { value: string; label: string }[] = []
  if (stats.playsThisWeek != null) {
    items.push({ value: `${stats.playsThisWeek.toLocaleString()}件`, label: '今週の同行' })
  }
  if (stats.hostCount != null) {
    items.push({ value: `${stats.hostCount.toLocaleString()}人`, label: '掲載中のピタメイト' })
  }
  if (stats.openSlots != null) {
    items.push({ value: `${stats.openSlots.toLocaleString()}件`, label: '募集中' })
  }
  if (stats.gameCount > 0) {
    items.push({ value: `${stats.gameCount}本`, label: '対応タイトル' })
  }

  // 出せるものが対応タイトルしか無いなら、わざわざ枠を作らない
  if (items.length < 2) return null

  return (
    <div
      style={{
        display: 'flex',
        flexWrap: 'wrap',
        gap: 8,
        background: C.white,
        border: `1.5px solid ${C.border}`,
        borderRadius: 10,
        padding: '12px 14px',
      }}
    >
      {items.map((it) => (
        <div
          key={it.label}
          style={{
            flex: '1 1 90px',
            display: 'flex',
            flexDirection: 'column',
            gap: 2,
            alignItems: 'center',
            textAlign: 'center',
          }}
        >
          <span style={{ fontSize: 17, color: C.ink, fontVariantNumeric: 'tabular-nums' }}>
            {it.value}
          </span>
          <span style={{ fontSize: 10, color: C.muted }}>{it.label}</span>
        </div>
      ))}
    </div>
  )
}
