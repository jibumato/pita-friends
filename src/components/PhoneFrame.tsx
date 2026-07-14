/** 端末フレーム(375×812 の内側 + ベゼル)。中に現在画面を描画。 */
import type { ReactNode } from 'react'
import { color as C, device, radius, shadow } from '../theme/tokens'

export default function PhoneFrame({ children }: { children: ReactNode }) {
  return (
    <div
      style={{
        width: device.outerW,
        height: device.outerH,
        maxWidth: '100%',
        background: C.ink,
        borderRadius: radius.bezel,
        padding: device.pad,
        boxSizing: 'border-box',
        boxShadow: shadow.device,
      }}
    >
      <div
        style={{
          position: 'relative',
          width: device.innerW,
          height: device.innerH,
          maxWidth: '100%',
          background: C.surface,
          borderRadius: radius.screen,
          overflow: 'hidden',
        }}
      >
        {children}
      </div>
    </div>
  )
}
