import { useEffect, useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import BottomTabs from '../components/BottomTabs'
import { Bell, Sun, MoonSmall, Moon } from '../components/Icon'
import { usePress } from '../hooks/usePress'
import { clickable } from '../hooks/clickable'
import { useIsMobile } from '../hooks/useMediaQuery'
import { isBackendConfigured } from '../lib/supabase'
import { subscribeOnlineUsers, type OnlineUser } from '../lib/presence'
import { coinsPer30 } from '../flow'
import {
  fetchDiscoverableHosts,
  fetchPendingInviteCount,
  fetchUnreadNotificationCount,
  type DiscoverableHost,
} from '../lib/queries'

/** ヒーロー直下のアイコン一覧(いろんな人を紹介する用)のデモデータ。 */
const ONLINE_STRIP = [
  { initial: 'る', color: C.avatarOrange },
  { initial: 'そ', color: C.avatarAqua },
  { initial: 'ひ', color: C.avatarPink },
  { initial: 'カ', color: C.lime },
  { initial: 'み', color: C.avatarAqua },
  { initial: 'あ', color: C.lavender },
  { initial: 'り', color: '#C9F2C7' },
  { initial: 'の', color: '#FFC7D9' },
  { initial: 'ゆ', color: C.avatarOrange },
  { initial: 'は', color: C.avatarAqua },
  { initial: 'な', color: C.avatarPink },
  { initial: 'れ', color: '#C9F2C7' },
]

/** ヒーロー直下に置く、今あそべる人のアイコンのみ横並び(コンパクト)。 */
function OnlineStrip({ flow, online }: { flow: Flow; online: OnlineUser[] }) {
  const items = isBackendConfigured
    ? online.map((u) => ({ key: u.userId, initial: u.avatarInitial, color: u.avatarColor, userId: u.userId }))
    : ONLINE_STRIP.map((u, i) => ({ key: `${u.initial}-${i}`, initial: u.initial, color: u.color, userId: null as string | null }))

  if (isBackendConfigured && items.length === 0) return null

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
        <span style={{ fontSize: 12.5, color: C.ink }}>🟢 今あそべる</span>
        <span style={{ fontSize: 10.5, color: C.muted }}>{items.length}人</span>
        <div style={{ flex: 1 }} />
        <span
          onClick={() => flow.go('search')}
          {...clickable(() => flow.go('search'), 'ホストをさがす')}
          style={{ cursor: 'pointer', fontSize: 10.5, color: C.lavender, fontWeight: 700 }}
        >
          もっと見る ›
        </span>
      </div>
      <div className="pita-scroll" style={{ display: 'flex', gap: 8, overflowX: 'auto', paddingBottom: 2 }}>
        {items.map((u) => (
          <div
            key={u.key}
            onClick={() => (u.userId ? flow.openProfile(u.userId) : flow.go('profile'))}
            {...clickable(() => (u.userId ? flow.openProfile(u.userId) : flow.go('profile')), 'プロフィールを見る')}
            style={{ position: 'relative', flex: 'none', cursor: 'pointer' }}
          >
            <div
              style={{
                width: 44,
                height: 44,
                borderRadius: '50%',
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
            <span
              aria-hidden
              style={{
                position: 'absolute',
                bottom: 1,
                right: 1,
                width: 11,
                height: 11,
                borderRadius: '50%',
                background: '#5FC26A',
                border: `2px solid ${C.surface}`,
              }}
            />
          </div>
        ))}
      </div>
    </div>
  )
}

export default function HomeScreen({ flow }: { flow: Flow }) {
  const mobile = useIsMobile()
  const card = usePress(`4px 4px 0 ${C.shadowCol}`)
  // 深夜オフライン状態(状態網羅 C1)のデモ切替
  const [night, setNight] = useState(false)

  const [pendingCount, setPendingCount] = useState<number | null>(null)
  const [onlineUsers, setOnlineUsers] = useState<OnlineUser[]>([])
  const [recommended, setRecommended] = useState<DiscoverableHost | null>(null)
  const [unreadNotifs, setUnreadNotifs] = useState(0)

  useEffect(() => {
    if (!isBackendConfigured) return
    let active = true
    fetchPendingInviteCount()
      .then((n) => active && setPendingCount(n))
      .catch(() => active && setPendingCount(0))
    const refreshNotifs = () =>
      fetchUnreadNotificationCount()
        .then((n) => active && setUnreadNotifs(n))
        .catch(() => {
          /* 取れなくてもベルは表示する */
        })
    refreshNotifs()
    // 新着通知に気づけるよう5秒ごとに未読数を取り直す
    const notifTimer = setInterval(refreshNotifs, 5000)
    fetchDiscoverableHosts(flow.userId)
      .then((hosts) => {
        if (!active || hosts.length === 0) return
        const best = [...hosts].sort((a, b) => b.mannerScore - a.mannerScore)[0]
        setRecommended(best)
      })
      .catch(() => {
        /* おすすめが取れなくてもホーム自体は表示する */
      })
    const unsubscribe = subscribeOnlineUsers(flow.userId, setOnlineUsers)
    return () => {
      active = false
      unsubscribe()
      clearInterval(notifTimer)
    }
    // 初回マウント時のみ実行
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  return (
    <Screen background={C.surface}>
      <StatusBar time={night ? '03:12' : '21:47'} />
      {/* デスクトップではロゴ/通知/テーマ切替をDesktopTopBarが担うため、ここは非表示。 */}
      {mobile && (
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
            {...clickable(
              () => flow.go('notifications'),
              unreadNotifs > 0 ? `通知 未読${unreadNotifs}件` : '通知',
            )}
            style={{
              cursor: 'pointer',
              position: 'relative',
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
            {isBackendConfigured && unreadNotifs > 0 && (
              <span
                aria-hidden
                style={{
                  position: 'absolute',
                  top: -6,
                  right: -6,
                  minWidth: 18,
                  height: 18,
                  padding: '0 5px',
                  boxSizing: 'border-box',
                  borderRadius: 9,
                  background: C.badge,
                  color: '#fff',
                  fontSize: 10.5,
                  lineHeight: '18px',
                  textAlign: 'center',
                  fontWeight: 700,
                  border: `1.5px solid ${C.white}`,
                }}
              >
                {unreadNotifs > 99 ? '99+' : unreadNotifs}
              </span>
            )}
          </div>
        </div>
      </div>
      )}
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
        {/* ヒーロー直下: 今あそべる人のアイコン一覧(コンパクト)。深夜オフライン時は隠す。 */}
        {!night && <OnlineStrip flow={flow} online={onlineUsers} />}

        {/* デモ: 通常 / 深夜オフライン 状態の切替。実データ接続時は非表示。 */}
        {!isBackendConfigured && (
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
        )}

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
            {isBackendConfigured
              ? pendingCount === null
                ? '確認中…'
                : pendingCount > 0
                  ? `${pendingCount}件の誘いが承認待ちです`
                  : '承認待ちの誘いはありません'
              : '2件の誘いが承認待ちです'}
          </span>
          <span style={{ fontSize: 11, color: C.ink }}>確認する ›</span>
        </div>

        {/* ランキングへの導線(デスクトップはサイドバー/メニューに常設済みのため、モバイルのみ表示) */}
        {mobile && (
          <div
            onClick={() => flow.go('ranking')}
            style={{
              cursor: 'pointer',
              background: C.white,
              border: `1.5px solid ${C.border}`,
              borderRadius: 12,
              boxShadow: `3px 3px 0 ${C.lavender}`,
              padding: '12px 14px',
              display: 'flex',
              alignItems: 'center',
              gap: 10,
            }}
          >
            <span style={{ fontSize: 18 }}>🏆</span>
            <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 1 }}>
              <span style={{ fontSize: 13, color: C.ink }}>ランキング</span>
              <span style={{ fontSize: 10, color: C.muted }}>プレイ実績・評価で決まる今週の上位ホスト</span>
            </div>
            <span style={{ fontSize: 11, color: C.lavender, fontWeight: 700 }}>見る ›</span>
          </div>
        )}

        {night ? (
          <NightHome flow={flow} />
        ) : (
        <>
        {/* 今夜のおすすめマッチ */}
        {(!isBackendConfigured || recommended) && (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline' }}>
              <span style={{ fontSize: 15, color: C.ink }}>▶ 今夜のおすすめマッチ</span>
              <span style={{ fontSize: 10, color: C.lavender, fontWeight: 700 }}>タップでプロフィール →</span>
            </div>
            <div
              className="pita-press"
              onClick={() => (isBackendConfigured && recommended ? flow.openProfile(recommended.userId) : flow.go('profile'))}
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
                    background: isBackendConfigured && recommended ? recommended.avatarColor : C.avatarAqua,
                    border: `1.5px solid ${C.border}`,
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'center',
                    fontSize: 23,
                    color: C.ink,
                  }}
                >
                  {isBackendConfigured && recommended ? recommended.avatarInitial : 'み'}
                </div>
                <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 3 }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                    <span style={{ fontSize: 16, color: C.ink }}>
                      {isBackendConfigured && recommended ? recommended.nickname : 'みなと'}
                    </span>
                    {(!isBackendConfigured || recommended?.isVerified) && (
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
                    )}
                  </div>
                  <span style={{ fontSize: 11, color: C.muted }}>
                    {isBackendConfigured && recommended
                      ? recommended.bio || `30分 ${coinsPer30(recommended.hourlyRate)} コイン`
                      : '社会人 / 平日21時〜 / エンジョイ寄り'}
                  </span>
                </div>
                {!isBackendConfigured && (
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
                )}
              </div>
              <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                {(isBackendConfigured && recommended ? recommended.games : ['Apex ゴールドⅡ', '今夜 22時〜']).map((t) => (
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
        )}
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
