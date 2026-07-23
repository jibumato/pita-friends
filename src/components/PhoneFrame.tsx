/**
 * アプリの表示コンテナ。
 * - モバイル実機幅: 画面いっぱいに全画面表示
 * - デスクトップ/タブレット: スマホの“モック枠(ベゼル)”は使わず、
 *   角丸のクリーンなアプリパネルとして中央に置く(GameRoom型の入口はLP側)
 */
import type { ReactNode } from 'react'
import { color as C } from '../theme/tokens'
import { useIsMobile } from '../hooks/useMediaQuery'

export default function PhoneFrame({ children }: { children: ReactNode }) {
  const mobile = useIsMobile()

  if (mobile) {
    return (
      <div
        className="app-fullbleed"
        style={{
          position: 'relative',
          width: '100%',
          background: C.surface,
          overflow: 'hidden',
        }}
      >
        {children}
      </div>
    )
  }

  return (
    <div
      style={{
        position: 'relative',
        width: 440,
        maxWidth: '100%',
        height: 'min(860px, 92vh)',
        background: C.surface,
        borderRadius: 20,
        border: `1.5px solid ${C.border}`,
        overflow: 'hidden',
        boxShadow: '0 20px 50px rgba(40,30,80,.18)',
      }}
    >
      {children}
    </div>
  )
}
