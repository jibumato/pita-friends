/** 紙吹雪 14 片。上→下 560px 落下 + 420deg 回転。 */
import { makeConfetti } from '../flow'

const PIECES = makeConfetti()

export default function Confetti() {
  return (
    <>
      {PIECES.map((c, i) => (
        <div
          key={i}
          style={{
            position: 'absolute',
            top: 0,
            left: c.left,
            width: c.size,
            height: c.size,
            background: c.color,
            animation: `conf ${c.dur} linear ${c.delay} infinite`,
          }}
        />
      ))}
    </>
  )
}
