/**
 * 案内シートを開く係。App に一度だけ置く。
 *
 * 開くきっかけは画面をまたぐ(設定の行 / 一覧の⭐ / マイページのカード)ので、
 * flow に口を増やすのではなく lib/install.ts の小さなイベントで受けている。
 * ⭐から自動で開くときだけ少し待つ — 押した手応え(星が光る)を先に見せないと、
 * 何を押したのか分からないまま知らないシートが出てくることになる。
 */
import { useEffect, useRef, useState } from 'react'
import InstallSheet from './InstallSheet'
import { subscribeInstallGuide } from '../lib/install'

const AUTO_DELAY_MS = 1100

export default function InstallGuideHost() {
  const [open, setOpen] = useState(false)
  const timer = useRef<number | null>(null)

  useEffect(() => {
    const off = subscribeInstallGuide((auto) => {
      if (!auto) {
        setOpen(true)
        return
      }
      if (timer.current !== null) return
      timer.current = window.setTimeout(() => {
        timer.current = null
        setOpen(true)
      }, AUTO_DELAY_MS)
    })
    return () => {
      off()
      if (timer.current !== null) window.clearTimeout(timer.current)
    }
  }, [])

  if (!open) return null
  return <InstallSheet onClose={() => setOpen(false)} />
}
