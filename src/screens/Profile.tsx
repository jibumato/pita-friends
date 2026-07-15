import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import { ChevronLeft, DotsHorizontal, Heart } from '../components/Icon'
import { usePress } from '../hooks/usePress'

const STATS = [
  { value: '★4.9', label: 'マナースコア', bg: C.white, fg: C.lavender, sub: C.muted },
  { value: '0%', label: 'ドタキャン率', bg: C.lime, fg: C.ink, sub: C.ink },
  { value: '132', label: '一緒に遊んだ', bg: C.white, fg: C.ink, sub: C.muted },
]

const WEEK = [
  { d: '月', on: true },
  { d: '火', on: true },
  { d: '水', on: false },
  { d: '木', on: true },
  { d: '金', on: true },
  { d: '土', on: false },
  { d: '日', on: false },
]

const GAME_TAGS = [
  { name: 'Apex', rank: 'ゴールドⅡ' },
  { name: 'VALORANT', rank: 'シルバーⅠ' },
  { name: 'マイクラ', rank: '' },
  { name: 'あつ森', rank: '' },
]

export default function Profile({ flow }: { flow: Flow }) {
  const cta = usePress(`3px 3px 0 ${C.lavender}`)
  return (
    <Screen background={C.surface}>
      {/* ラベンダーヘッダー */}
      <div
        style={{
          background: C.lavender,
          borderBottom: `1.5px solid ${C.border}`,
          padding: '14px 24px 0',
          display: 'flex',
          flexDirection: 'column',
        }}
      >
        <div
          style={{
            display: 'flex',
            justifyContent: 'space-between',
            alignItems: 'center',
            color: '#fff',
            fontSize: 13,
          }}
        >
          <span>21:47</span>
          <div style={{ display: 'flex', gap: 5, alignItems: 'center' }}>
            <div style={{ width: 16, height: 9, borderRadius: 2, background: '#fff' }} />
            <div style={{ width: 20, height: 9, borderRadius: 3, border: '1.5px solid #fff' }} />
          </div>
        </div>
        <div
          style={{
            display: 'flex',
            justifyContent: 'space-between',
            alignItems: 'center',
            padding: '10px 0 40px',
          }}
        >
          <div onClick={() => flow.go('home')} style={{ cursor: 'pointer' }}>
            <ChevronLeft color="#fff" />
          </div>
          <DotsHorizontal color="#fff" />
        </div>
      </div>
      <div
        className="pita-scroll"
        style={{
          flex: 1,
          overflowY: 'auto',
          display: 'flex',
          flexDirection: 'column',
          padding: '0 20px 16px',
          gap: 12,
        }}
      >
        <div style={{ display: 'flex', alignItems: 'flex-end', gap: 14, marginTop: -32 }}>
          <div
            style={{
              width: 86,
              height: 86,
              borderRadius: 16,
              background: C.avatarAqua,
              border: `1.5px solid ${C.border}`,
              boxShadow: `4px 4px 0 ${C.shadowCol}`,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              fontSize: 34,
              color: C.ink,
            }}
          >
            み
          </div>
          <div
            style={{ display: 'flex', flexDirection: 'column', gap: 4, paddingBottom: 4 }}
          >
            <div style={{ display: 'flex', alignItems: 'center', gap: 7 }}>
              <span style={{ fontSize: 20, color: C.ink }}>みなと</span>
              <span
                style={{
                  fontSize: 9.5,
                  color: C.ink,
                  background: C.lime,
                  border: `1.5px solid ${C.border}`,
                  padding: '3px 8px',
                  borderRadius: 4,
                }}
              >
                ✓ 本人確認済み
              </span>
            </div>
            <span style={{ fontSize: 11, color: C.muted }}>
              社会人ゲーマー · 平日夜メイン · 都内
            </span>
          </div>
        </div>
        {/* スタットタイル */}
        <div style={{ display: 'flex', gap: 8 }}>
          {STATS.map((s) => (
            <div
              key={s.label}
              style={{
                flex: 1,
                background: s.bg,
                border: `1.5px solid ${C.border}`,
                borderRadius: 8,
                boxShadow: `2px 2px 0 ${C.shadowCol}`,
                padding: '10px 6px',
                display: 'flex',
                flexDirection: 'column',
                alignItems: 'center',
                gap: 2,
              }}
            >
              <span style={{ fontSize: 16, color: s.fg }}>{s.value}</span>
              <span style={{ fontSize: 9.5, color: s.sub }}>{s.label}</span>
            </div>
          ))}
        </div>
        <p style={{ margin: 0, fontSize: 12.5, lineHeight: 1.7, color: C.body }}>
          仕事終わりの21時から遊べます。ランクはガチすぎず、笑いながら上を目指したい派。建築ゲーも好きなのでまったり勢も歓迎です。
        </p>
        {/* あそぶゲーム */}
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          <span style={{ fontSize: 13, color: C.ink }}>▶ あそぶゲーム</span>
          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
            {GAME_TAGS.map((g) => (
              <span
                key={g.name}
                style={{
                  fontSize: 11,
                  color: C.ink,
                  background: C.white,
                  border: `1.5px solid ${C.border}`,
                  padding: '6px 11px',
                  borderRadius: 4,
                }}
              >
                {g.name} {g.rank && <b style={{ color: C.lavender }}>{g.rank}</b>}
              </span>
            ))}
          </div>
        </div>
        {/* あそべる時間 */}
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          <span style={{ fontSize: 13, color: C.ink }}>▶ あそべる時間</span>
          <div style={{ display: 'flex', gap: 5 }}>
            {WEEK.map((w) => (
              <div
                key={w.d}
                style={{
                  flex: 1,
                  display: 'flex',
                  flexDirection: 'column',
                  alignItems: 'center',
                  gap: 4,
                }}
              >
                <span style={{ fontSize: 10, color: C.muted }}>{w.d}</span>
                <div
                  style={{
                    width: '100%',
                    height: 24,
                    borderRadius: 4,
                    background: w.on ? C.lavender : C.white,
                    border: `1.5px solid ${C.border}`,
                  }}
                />
              </div>
            ))}
          </div>
        </div>
        {/* レビュー */}
        <div
          style={{
            background: C.white,
            border: `1.5px solid ${C.border}`,
            borderRadius: 8,
            boxShadow: `2px 2px 0 ${C.shadowCol}`,
            padding: '12px 14px',
            display: 'flex',
            flexDirection: 'column',
            gap: 5,
          }}
        >
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <span style={{ fontSize: 12, color: C.ink }}>るか さんからのレビュー</span>
            <span style={{ fontSize: 11, color: C.avatarOrange }}>★★★★★</span>
          </div>
          <p style={{ margin: 0, fontSize: 11.5, lineHeight: 1.6, color: C.muted }}>
            時間ぴったりに来てくれて、負けても空気が重くならない神フレでした！
          </p>
        </div>
      </div>
      {/* フッターCTA */}
      <div
        style={{
          display: 'flex',
          gap: 10,
          padding: '12px 20px 26px',
          background: C.white,
          borderTop: `1.5px solid ${C.border}`,
        }}
      >
        <div
          style={{
            width: 50,
            height: 50,
            borderRadius: 8,
            background: C.white,
            border: `1.5px solid ${C.border}`,
            boxShadow: `2px 2px 0 ${C.shadowCol}`,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
          }}
        >
          <Heart />
        </div>
        <div
          className="pita-press"
          onClick={() => flow.go('invite')}
          {...cta.handlers}
          style={{
            cursor: 'pointer',
            flex: 1,
            background: C.ctaBg,
            color: C.ctaFg,
            borderRadius: 8,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            fontSize: 15,
            ...cta.style,
          }}
        >
          いっしょに遊ぶ ▶
        </div>
      </div>
    </Screen>
  )
}
