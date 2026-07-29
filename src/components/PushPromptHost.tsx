/**
 * 通知の誘いを開く係。App に一度だけ置く。
 * InstallGuideHost と同じ形。⭐や予約完了から飛んでくる要求を受ける。
 *
 * 自動で開くときは少し待つ。押した手応え(星が光る・予約完了の表示)を
 * 先に見せないと、何をした結果なのか分からないまま許可を求めることになる。
 */
import { useEffect, useRef, useState } from 'react'
import PushPrompt from './PushPrompt'
import { subscribePushPrompt, type PushReason } from '../lib/push'

const DELAY_MS = 1100

export default function PushPromptHost() {
  const [reason, setReason] = useState<PushReason | null>(null)
  const timer = useRef<number | null>(null)

  useEffect(() => {
    const off = subscribePushPrompt((r) => {
      if (timer.current !== null) return
      timer.current = window.setTimeout(() => {
        timer.current = null
        setReason(r)
      }, DELAY_MS)
    })
    return () => {
      off()
      if (timer.current !== null) window.clearTimeout(timer.current)
    }
  }, [])

  if (!reason) return null
  return <PushPrompt reason={reason} onClose={() => setReason(null)} />
}
