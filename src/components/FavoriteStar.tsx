/**
 * お気に入り登録の⭐ボタン。カードやプロフィールの隅に置く。
 *
 * ⚠️ **利用者に見せる言葉は「お気に入り」で統一する。**「推し」「推す」は使わない。
 *
 * **誰をお気に入りにしているかは相手にも他人にも見えない。** 相手に伝わるのは人数だけ
 * (0053)。押した瞬間に相手へ通知は飛ばない — 「お気に入りに入れられた」ことが即座に伝わると、
 * 見ているだけの人が押しづらくなる。
 */
import { useState } from 'react'
import { color as C } from '../theme/tokens'
import { setFavorite } from '../lib/queries'
import { isBackendConfigured } from '../lib/supabase'
import { armNotifyPrompt } from '../lib/push'

type Props = {
  hostId: string
  initialOn: boolean
  /** 未ログインなど、押せない状態のときに呼ぶ(登録へ誘導する等)。 */
  onBlocked?: () => void
  size?: number
  /** 変更が確定したときに親へ知らせる(一覧の再取得など)。 */
  onChanged?: (on: boolean) => void
}

export default function FavoriteStar({ hostId, initialOn, onBlocked, size = 30, onChanged }: Props) {
  const [on, setOn] = useState(initialOn)
  const [busy, setBusy] = useState(false)

  async function toggle(e: React.MouseEvent) {
    // カード全体が押せるようになっている場所に置くので、親への伝播を止める
    e.stopPropagation()
    if (busy) return
    if (!isBackendConfigured) {
      onBlocked?.()
      return
    }
    const next = !on
    setOn(next) // 先に見た目を変える(戻すのは失敗したときだけ)
    setBusy(true)
    try {
      await setFavorite(hostId, next)
      onChanged?.(next)
      // お気に入りに入れた直後は「この人をまた見に来る」気持ちがいちばん強い瞬間で、
      // 枠が空いたときの通知(0054)が届く相手ができた瞬間でもある。
      // 通知が取れるなら通知を、iOSで未追加ならホーム画面への追加を勧める
      // (どちらも抑制中なら何も起きない)。
      if (next) armNotifyPrompt('favorite')
    } catch {
      setOn(!next)
      onBlocked?.()
    } finally {
      setBusy(false)
    }
  }

  return (
    <button
      onClick={toggle}
      aria-pressed={on}
      aria-label={on ? 'お気に入りから外す' : 'お気に入りに追加する'}
      title={on ? 'お気に入りから外す' : 'お気に入りに追加する'}
      style={{
        cursor: busy ? 'default' : 'pointer',
        flex: 'none',
        width: size,
        height: size,
        borderRadius: '50%',
        background: on ? C.lime : C.white,
        border: `1.5px solid ${C.border}`,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        fontSize: size * 0.5,
        lineHeight: 1,
        padding: 0,
        opacity: busy ? 0.6 : 1,
        transition: 'background .15s ease',
      }}
    >
      <span aria-hidden>{on ? '⭐' : '☆'}</span>
    </button>
  )
}
