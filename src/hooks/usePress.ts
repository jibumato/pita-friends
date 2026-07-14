import { useState, useCallback } from 'react'
import type { CSSProperties } from 'react'

/**
 * ハンドオフの style-hover(押し込み表現)を再現するフック。
 * ホバー/押下時にオフセットを 1px 減らし transform:translate(1px,1px)。
 * @param shadow 通常時の box-shadow。'none' のときは影を動かさない。
 */
export function usePress(shadow: string) {
  const [active, setActive] = useState(false)

  const pressedShadow =
    shadow === 'none'
      ? 'none'
      : shadow
          .replace(/^3px 3px/, '2px 2px')
          .replace(/^4px 4px/, '3px 3px')
          .replace(/^2px 2px/, '1px 1px')

  const style: CSSProperties = active
    ? { transform: 'translate(1px,1px)', boxShadow: pressedShadow }
    : { boxShadow: shadow }

  const handlers = {
    onMouseEnter: useCallback(() => setActive(true), []),
    onMouseLeave: useCallback(() => setActive(false), []),
    onPointerDown: useCallback(() => setActive(true), []),
    onPointerUp: useCallback(() => setActive(false), []),
    onPointerCancel: useCallback(() => setActive(false), []),
  }

  return { style, handlers }
}
