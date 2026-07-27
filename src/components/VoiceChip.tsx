import { useEffect, useRef, useState } from 'react'
import { color as C } from '../theme/tokens'

/**
 * ボイスあいさつの再生ボタン(0024)。
 *
 * 声はこのサービスで**いちばん人となりが伝わる材料**なのに、これまで
 * プロフィールの下のほう(自己紹介とゲームの後ろ)にしか無く、ほとんど
 * 聞かれないまま埋もれていた。カードから直接押せる形にして前に出す。
 *
 * 一覧の中に置くので、押しても親のカードは開かない(stopPropagation)。
 * 音源が無いデモでは秒数ぶんだけ再生状態を演出する。
 */
export default function VoiceChip({
  url,
  seconds,
  variant = 'solid',
}: {
  url: string | null
  seconds: number | null
  /** solid=写真に重ねる / quiet=白地の行に置く */
  variant?: 'solid' | 'quiet'
}) {
  const [playing, setPlaying] = useState(false)
  const audioRef = useRef<HTMLAudioElement | null>(null)
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  useEffect(
    () => () => {
      if (timerRef.current) clearTimeout(timerRef.current)
    },
    [],
  )

  if (!url && seconds == null) return null

  const toggle = (e: React.MouseEvent | React.KeyboardEvent) => {
    e.stopPropagation()
    if (url) {
      const a = audioRef.current
      if (!a) return
      if (playing) {
        a.pause()
        a.currentTime = 0
        setPlaying(false)
      } else {
        a.currentTime = 0
        a.play()
          .then(() => setPlaying(true))
          .catch(() => {})
      }
      return
    }
    if (playing) {
      if (timerRef.current) clearTimeout(timerRef.current)
      setPlaying(false)
    } else {
      setPlaying(true)
      timerRef.current = setTimeout(() => setPlaying(false), (seconds ?? 8) * 1000)
    }
  }

  const solid = variant === 'solid'
  return (
    <>
      <span
        onClick={toggle}
        role="button"
        tabIndex={0}
        aria-label={playing ? 'ボイスを止める' : 'ボイスあいさつを聞く'}
        onKeyDown={(e) => {
          if (e.key === 'Enter' || e.key === ' ') toggle(e)
        }}
        style={{
          display: 'inline-flex',
          alignItems: 'center',
          gap: 6,
          cursor: 'pointer',
          background: solid ? C.lime : C.white,
          color: C.ink,
          border: `1.5px solid ${C.border}`,
          borderRadius: 20,
          boxShadow: solid ? `2px 2px 0 ${C.border}` : 'none',
          padding: solid ? '5px 11px' : '4px 10px',
          fontSize: solid ? 11 : 10.5,
          fontWeight: 700,
          flex: 'none',
        }}
      >
        {playing ? (
          <>
            <span style={{ display: 'inline-flex', alignItems: 'flex-end', gap: 2, height: 12 }} aria-hidden>
              {[0, 1, 2].map((i) => (
                <span
                  key={i}
                  style={{
                    width: 2.5,
                    height: 12,
                    background: C.ink,
                    borderRadius: 2,
                    transformOrigin: 'bottom',
                    animation: `vpBar .8s ease-in-out ${i * 0.16}s infinite`,
                  }}
                />
              ))}
            </span>
            再生中
          </>
        ) : (
          <>▶ ボイス{seconds ? ` ${seconds}秒` : ''}</>
        )}
      </span>
      {url && <audio ref={audioRef} src={url} preload="none" onEnded={() => setPlaying(false)} />}
    </>
  )
}
