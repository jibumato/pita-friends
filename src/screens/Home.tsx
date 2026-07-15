import { useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import BottomTabs from '../components/BottomTabs'
import { Bell, Sun, MoonSmall, Moon } from '../components/Icon'
import { usePress } from '../hooks/usePress'
import { clickable } from '../hooks/clickable'

const ONLINE = [
  { initial: 'る', name: 'るか', color: C.avatarOrange },
  { initial: 'そ', name: 'そら', color: C.avatarAqua },
  { initial: 'ひ', name: 'ひなた', color: C.avatarPink },
  { initial: 'カ', name: 'カイ', color: C.lime },
]

export default function HomeScreen({ flow }: { flow: Flow }) {
  const card = usePress(`4px 4px 0 ${C.shadowCol}`)
  // 深夜オフライン状態(状態網羅 C1)のデモ切替
  const [night, setNight] = useState(false)
  return (
    <Screen background={C.surface}>
      <StatusBar time={night ? '03:12' : '21:47'} />
      <div
        style={{
          display: 'flex',
          justifyContent: 'space-between',
          alignItems: 'center',
          padding: '12px 20px 4px',
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <div
            style={{
              width: 36,
              height: 36,
              borderRadius: 6,
              background: C.lime,
              border: `1.5px solid ${C.border}`,
              boxShadow: `3px 3px 0 ${C.lavender}`,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              color: C.ink,
              fontSize: 16,
            }}
          >
            ピ
          </div>
          <span style={{ fontSize: 21, color: C.ink, letterSpacing: '.05em' }}>ピタフレ</span>
        </div>
        <div style={{ display: 'flex', gap: 8 }}>
          <div
            onClick={flow.toggleTheme}
            {...clickable(flow.toggleTheme, flow.theme === 'dark' ? 'ライトテーマに切替' : 'ダークテーマに切替')}
            style={{
              cursor: 'pointer',
              width: 38,
              height: 38,
              borderRadius: 8,
              background: C.white,
              border: `1.5px solid ${C.border}`,
              boxShadow: `2px 2px 0 ${C.shadowCol}`,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
            }}
          >
            {flow.theme === 'dark' ? <Sun /> : <MoonSmall />}
          </div>
          <div
            onClick={() => flow.go('notifications')}
            {...clickable(() => flow.go('notifications'), '通知')}
            style={{
              cursor: 'pointer',
              width: 38,
              height: 38,
              borderRadius: 8,
              background: C.white,
              border: `1.5px solid ${C.border}`,
              boxShadow: `2px 2px 0 ${C.shadowCol}`,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
            }}
          >
            <Bell />
          </div>
        </div>
      </div>
      <div
        style={{
          flex: 1,
          overflow: 'hidden',
          display: 'flex',
          flexDirection: 'column',
          gap: 18,
          padding: '14px 20px 0',
        }}
      >
        {/* デモ: 通常 / 深夜オフライン 状態の切替 */}
        <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 4, marginBottom: -8 }}>
          {(
            [
              [false, '通常'],
              [true, '深夜'],
            ] as [boolean, string][]
          ).map(([v, label]) => (
            <span
              key={label}
              onClick={() => setNight(v)}
              {...clickable(() => setNight(v), `${label}状態を表示`)}
              style={{
                cursor: 'pointer',
                fontSize: 9,
                color: night === v ? C.lime : C.muted,
                background: night === v ? C.fill : 'transparent',
                border: `1.5px solid ${night === v ? C.border : C.placeholder}`,
                padding: '2px 8px',
                borderRadius: 4,
              }}
            >
              {label}
            </span>
          ))}
        </div>

        {/* 受け取った誘い(承認制) */}
        <div
          onClick={() => flow.go('requests')}
          style={{
            cursor: 'pointer',
            background: C.lime,
            border: `1.5px solid ${C.border}`,
            borderRadius: 10,
            boxShadow: `2px 2px 0 ${C.shadowCol}`,
            padding: '10px 13px',
            display: 'flex',
            alignItems: 'center',
            gap: 10,
          }}
        >
          <span style={{ fontSize: 16 }}>🙌</span>
          <span style={{ flex: 1, fontSize: 12, color: C.ink }}>
            2件の誘いが承認待ちです
          </span>
          <span style={{ fontSize: 11, color: C.ink }}>確認する ›</span>
        </div>

        {night ? (
          <NightHome flow={flow} />
        ) : (
        <>
        {/* いま遊べる */}
        <div
          style={{
            background: C.lavender,
            border: `1.5px solid ${C.border}`,
            borderRadius: 12,
            boxShadow: `4px 4px 0 ${C.shadowCol}`,
            padding: 16,
            display: 'flex',
            flexDirection: 'column',
            gap: 10,
          }}
        >
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <span style={{ fontSize: 15, color: '#fff' }}>▶ いま遊べる</span>
            <span
              style={{
                fontSize: 11,
                color: C.ink,
                background: C.lime,
                border: `1.5px solid ${C.border}`,
                padding: '3px 10px',
                borderRadius: 4,
              }}
            >
              18人 ONLINE
            </span>
          </div>
          <div style={{ display: 'flex', gap: 9 }}>
            {ONLINE.map((u) => (
              <div
                key={u.name}
                style={{
                  flex: 1,
                  background: C.white,
                  border: `1.5px solid ${C.border}`,
                  borderRadius: 8,
                  padding: '9px 6px',
                  display: 'flex',
                  flexDirection: 'column',
                  alignItems: 'center',
                  gap: 4,
                }}
              >
                <div
                  style={{
                    width: 42,
                    height: 42,
                    borderRadius: 8,
                    background: u.color,
                    border: `1.5px solid ${C.border}`,
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'center',
                    fontSize: 17,
                    color: C.ink,
                  }}
                >
                  {u.initial}
                </div>
                <span style={{ fontSize: 11.5, color: C.ink }}>{u.name}</span>
              </div>
            ))}
          </div>
        </div>
        {/* 今夜のおすすめマッチ */}
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          <div
            style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline' }}
          >
            <span style={{ fontSize: 15, color: C.ink }}>▶ 今夜のおすすめマッチ</span>
            <span style={{ fontSize: 10, color: C.lavender }}>タップでプロフィール →</span>
          </div>
          <div
            className="pita-press"
            onClick={() => flow.go('profile')}
            {...card.handlers}
            style={{
              cursor: 'pointer',
              background: C.white,
              border: `1.5px solid ${C.border}`,
              borderRadius: 12,
              padding: 16,
              display: 'flex',
              flexDirection: 'column',
              gap: 12,
              ...card.style,
            }}
          >
            <div style={{ display: 'flex', gap: 12, alignItems: 'center' }}>
              <div
                style={{
                  width: 56,
                  height: 56,
                  borderRadius: 10,
                  background: C.avatarAqua,
                  border: `1.5px solid ${C.border}`,
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  fontSize: 23,
                  color: C.ink,
                }}
              >
                み
              </div>
              <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 3 }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                  <span style={{ fontSize: 16, color: C.ink }}>みなと</span>
                  <span
                    style={{
                      fontSize: 9.5,
                      color: C.ink,
                      background: C.lime,
                      border: `1.5px solid ${C.border}`,
                      padding: '2px 7px',
                      borderRadius: 4,
                    }}
                  >
                    ✓ 本人確認済み
                  </span>
                </div>
                <span style={{ fontSize: 11, color: C.muted }}>
                  社会人 / 平日21時〜 / エンジョイ寄り
                </span>
              </div>
              <div
                style={{
                  display: 'flex',
                  flexDirection: 'column',
                  alignItems: 'center',
                  background: C.lavender,
                  border: `1.5px solid ${C.border}`,
                  borderRadius: 8,
                  padding: '6px 9px',
                }}
              >
                <span style={{ fontSize: 18, color: C.lime }}>{flow.score}%</span>
                <span style={{ fontSize: 8.5, color: '#fff' }}>相性</span>
              </div>
            </div>
            <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
              {['Apex ゴールドⅡ', '今夜 22時〜'].map((t) => (
                <span
                  key={t}
                  style={{
                    fontSize: 11,
                    color: C.ink,
                    background: C.surfaceLavender,
                    padding: '4px 10px',
                    borderRadius: 4,
                    border: `1.5px solid ${C.border}`,
                  }}
                >
                  {t}
                </span>
              ))}
            </div>
          </div>
        </div>
        </>
        )}
      </div>
      <BottomTabs current={flow.screen} onNavigate={flow.go} />
    </Screen>
  )
}

/** 深夜オフライン状態(状態網羅 C1): オンライン0人 + 予約導線。 */
function NightHome({ flow }: { flow: Flow }) {
  return (
    <>
      {/* いま遊べる(深夜) */}
      <div
        style={{
          background: C.deepCard,
          border: `1.5px solid ${C.border}`,
          borderRadius: 12,
          boxShadow: `4px 4px 0 ${C.shadowCol}`,
          padding: 16,
          display: 'flex',
          flexDirection: 'column',
          gap: 10,
        }}
      >
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <span style={{ fontSize: 15, color: '#fff' }}>▶ いま遊べる</span>
          <span
            style={{
              fontSize: 10.5,
              color: C.ink,
              background: C.muted,
              border: `1.5px solid ${C.border}`,
              padding: '3px 9px',
              borderRadius: 4,
            }}
          >
            0人 ONLINE
          </span>
        </div>
        <div
          style={{
            display: 'flex',
            flexDirection: 'column',
            alignItems: 'center',
            gap: 8,
            padding: '14px 0',
          }}
        >
          <Moon size={34} color="#948DA8" />
          <span style={{ fontSize: 11.5, color: C.muted, textAlign: 'center', lineHeight: 1.6 }}>
            いまはみんな寝ているみたい。
            <br />
            朝以降にまた覗いてみて
          </span>
        </div>
      </div>

      {/* 予約して寝る */}
      <div
        style={{
          background: C.white,
          border: `1.5px solid ${C.border}`,
          borderRadius: 12,
          boxShadow: `4px 4px 0 ${C.shadowCol}`,
          padding: 16,
          display: 'flex',
          flexDirection: 'column',
          gap: 10,
        }}
      >
        <span style={{ fontSize: 13, color: C.ink }}>▶ 予約して寝る</span>
        <span style={{ fontSize: 11, color: C.muted, lineHeight: 1.6 }}>
          「明日21時〜Apex」で募集を予約しておくと、起きたら候補が集まっています。
        </span>
        <div
          onClick={() => flow.go('boardCreate')}
          {...clickable(() => flow.go('boardCreate'), '予約募集をつくる')}
          style={{
            cursor: 'pointer',
            background: C.lime,
            color: C.ink,
            border: `1.5px solid ${C.border}`,
            borderRadius: 8,
            padding: '11px 0',
            textAlign: 'center',
            fontSize: 13,
            boxShadow: `2px 2px 0 ${C.shadowCol}`,
          }}
        >
          予約募集をつくる
        </div>
      </div>
    </>
  )
}
